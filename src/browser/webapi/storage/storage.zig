// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const DOMException = @import("../DOMException.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{Lookup};
}

pub const Cookie = @import("Cookie.zig");

const OriginAreas = struct {
    _origins: std.StringHashMapUnmanaged(*Area) = .empty,

    fn deinit(self: *OriginAreas, allocator: Allocator) void {
        var it = self._origins.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit();
            allocator.destroy(kv.value_ptr.*);
        }
        self._origins.deinit(allocator);
    }

    fn getOrPut(self: *OriginAreas, allocator: Allocator, origin: []const u8) !*Area {
        const gop = try self._origins.getOrPut(allocator, origin);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer std.debug.assert(self._origins.remove(origin));

        const area = try allocator.create(Area);
        errdefer allocator.destroy(area);
        area.* = .{ ._allocator = allocator };

        gop.key_ptr.* = try allocator.dupe(u8, origin);
        gop.value_ptr.* = area;
        return area;
    }

    fn get(self: *const OriginAreas, origin: []const u8) ?*Area {
        return self._origins.get(origin);
    }

    fn clone(self: *const OriginAreas, allocator: Allocator) !OriginAreas {
        var result: OriginAreas = .{};
        errdefer result.deinit(allocator);

        var it = self._origins.iterator();
        while (it.next()) |entry| {
            const origin = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(origin);

            const area = try allocator.create(Area);
            errdefer allocator.destroy(area);
            area.* = try entry.value_ptr.*.clone(allocator);
            errdefer area.deinit();

            try result._origins.putNoClobber(allocator, origin, area);
        }
        return result;
    }
};

/// Session-owned DOM-storage state. Local storage is keyed only by origin
/// inside the Session. Session storage adds the stable top-level browsing
/// context identity; a document/Frame replacement carries its NavigationContext
/// forward, while a separate tab or popup receives a distinct identity.
pub const Shed = struct {
    _local: OriginAreas = .{},
    _session: std.AutoHashMapUnmanaged(usize, OriginAreas) = .empty,

    pub fn deinit(self: *Shed, allocator: Allocator) void {
        self._local.deinit(allocator);
        var it = self._session.valueIterator();
        while (it.next()) |origins| origins.deinit(allocator);
        self._session.deinit(allocator);
    }

    pub fn getLocal(self: *Shed, allocator: Allocator, origin: []const u8) !*Area {
        return self._local.getOrPut(allocator, origin);
    }

    pub fn getSession(
        self: *Shed,
        allocator: Allocator,
        top_level_context_identity: usize,
        origin: []const u8,
    ) !*Area {
        const gop = try self._session.getOrPut(allocator, top_level_context_identity);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr.getOrPut(allocator, origin);
    }

    pub fn peekLocal(self: *const Shed, origin: []const u8) ?*Area {
        return self._local.get(origin);
    }

    pub fn peekSession(
        self: *const Shed,
        top_level_context_identity: usize,
        origin: []const u8,
    ) ?*Area {
        const origins = self._session.get(top_level_context_identity) orelse return null;
        return origins.get(origin);
    }

    /// Snapshot the complete sessionStorage namespace for a newly-created
    /// auxiliary browsing context. Values are deep-copied so subsequent
    /// mutations in opener and popup are isolated. A source which has never
    /// materialized sessionStorage leaves the destination lazy and empty.
    pub fn cloneSessionNamespace(
        self: *Shed,
        allocator: Allocator,
        source_identity: usize,
        destination_identity: usize,
    ) !void {
        std.debug.assert(source_identity != destination_identity);
        if (self._session.contains(destination_identity)) {
            return error.SessionNamespaceAlreadyExists;
        }

        const source = self._session.get(source_identity) orelse return;
        var cloned = try source.clone(allocator);
        errdefer cloned.deinit(allocator);
        try self._session.putNoClobber(allocator, destination_identity, cloned);
    }

    /// Called only when the top-level browsing context is permanently closed.
    /// Cross-document navigation must not call this: its NavigationContext is
    /// deliberately stable and owns the namespace across the replacement.
    pub fn removeSessionNamespace(
        self: *Shed,
        allocator: Allocator,
        top_level_context_identity: usize,
    ) void {
        var removed = self._session.fetchRemove(top_level_context_identity) orelse return;
        removed.value.deinit(allocator);
    }
};

pub const Kind = enum {
    local,
    session,
};

pub const Area = struct {
    _data: std.StringHashMapUnmanaged([]const u8) = .empty,
    _quota_used: usize = 0,
    _allocator: Allocator,

    // components/services/storage/dom_storage/dom_storage_constants.h
    const max_size = 10 * 1024 * 1024;

    const SetResult = struct {
        // Ownership transfers from the map to the caller. This keeps the old
        // value alive while asynchronous StorageEvent payloads are snapshotted.
        old_value: ?[]const u8,
        changed: bool,
    };

    pub fn deinit(self: *Area) void {
        var it = self._data.iterator();
        while (it.next()) |entry| {
            self._allocator.free(entry.key_ptr.*);
            self._allocator.free(entry.value_ptr.*);
        }
        self._data.deinit(self._allocator);
        self._quota_used = 0;
    }

    fn clone(self: *const Area, allocator: Allocator) !Area {
        var result = Area{ ._allocator = allocator };
        errdefer result.deinit();

        var it = self._data.iterator();
        while (it.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);
            const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
            errdefer allocator.free(value_copy);
            try result._data.putNoClobber(allocator, key_copy, value_copy);
        }
        result._quota_used = self._quota_used;
        return result;
    }

    fn getItem(self: *const Area, k: []const u8) ?[]const u8 {
        return self._data.get(k);
    }

    fn setItem(self: *Area, k: []const u8, value: []const u8) !SetResult {
        const old_value = self._data.get(k);
        const old_item_size = if (old_value) |old| quotaForItem(k, old) else 0;
        const new_item_size = quotaForItem(k, value);
        std.debug.assert(old_item_size <= self._quota_used);
        const new_quota_used = std.math.add(
            usize,
            self._quota_used - old_item_size,
            new_item_size,
        ) catch std.math.maxInt(usize);

        // Blink StorageAreaMap only checks quota when this item grows. This is
        // observable for an already-over-budget area restored from persistence.
        if (new_item_size > old_item_size and new_quota_used > max_size) {
            return error.QuotaExceeded;
        }

        if (self._data.getPtr(k)) |value_ptr| {
            const value_owned = try self._allocator.dupe(u8, value);
            const old_owned = value_ptr.*;
            value_ptr.* = value_owned;
            self._quota_used = new_quota_used;
            return .{
                .old_value = old_owned,
                .changed = !std.mem.eql(u8, old_owned, value),
            };
        } else {
            const key_owned = try self._allocator.dupe(u8, k);
            errdefer self._allocator.free(key_owned);
            const value_owned = try self._allocator.dupe(u8, value);
            errdefer self._allocator.free(value_owned);

            try self._data.put(self._allocator, key_owned, value_owned);
            self._quota_used = new_quota_used;
            return .{ .old_value = null, .changed = true };
        }
    }

    fn removeItem(self: *Area, k: []const u8) ?[]const u8 {
        const kv = self._data.fetchRemove(k) orelse return null;
        self._quota_used -= quotaForItem(kv.key, kv.value);
        self._allocator.free(kv.key);
        return kv.value;
    }

    fn clear(self: *Area) bool {
        if (self._data.count() == 0) return false;
        var it = self._data.iterator();
        while (it.next()) |entry| {
            self._allocator.free(entry.key_ptr.*);
            self._allocator.free(entry.value_ptr.*);
        }
        self._data.clearRetainingCapacity();
        self._quota_used = 0;
        return true;
    }

    fn key(self: *const Area, index: u32) ?[]const u8 {
        var it = self._data.keyIterator();
        var i: u32 = 0;
        while (it.next()) |k| {
            if (i == index) {
                return k.*;
            }
            i += 1;
        }
        return null;
    }

    fn getLength(self: *const Area) u32 {
        return @intCast(self._data.count());
    }

    fn hasItem(self: *const Area, k: []const u8) bool {
        return self._data.contains(k);
    }

    fn releaseOldValue(self: *Area, value: ?[]const u8) void {
        if (value) |owned| self._allocator.free(owned);
    }

    fn quotaForItem(key_: []const u8, value: []const u8) usize {
        const units = std.math.add(
            usize,
            utf16CodeUnits(key_),
            utf16CodeUnits(value),
        ) catch std.math.maxInt(usize);
        return std.math.mul(usize, units, 2) catch std.math.maxInt(usize);
    }

    /// V8 exposes DOMString arguments as scalar-normalized UTF-8. A four-byte
    /// scalar is one Unicode code point but two UTF-16 code units; all other
    /// valid sequences occupy one. Invalid/truncated input is counted as one
    /// unit defensively, matching the replacement scalar used by Web IDL.
    fn utf16CodeUnits(value: []const u8) usize {
        var units: usize = 0;
        var i: usize = 0;
        while (i < value.len) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
            if (i + sequence_len > value.len) {
                units += 1;
                i += 1;
                continue;
            }
            units += if (sequence_len == 4) 2 else 1;
            i += sequence_len;
        }
        return units;
    }
};

/// A Storage object is Window/Document-bound even though its StorageArea is
/// shared by same-origin environments. Keeping a distinct wrapper per Window
/// is required both for realm identity and for post-detach access checks.
pub const Lookup = struct {
    _area: *Area,
    _owner: *Frame,
    _kind: Kind,

    pub fn init(area: *Area, owner: *Frame, kind: Kind) Lookup {
        return .{ ._area = area, ._owner = owner, ._kind = kind };
    }

    fn throwDOMException(
        exec: *const js.Execution,
        name: []const u8,
        message: []const u8,
    ) !void {
        const local = exec.js.local orelse return error.TryCatchRethrow;
        const exception = try local.zigValueToJs(DOMException.init(message, name), .{});
        _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
        _ = local.isolate.throwException(exception.handle);
        return error.TryCatchRethrow;
    }

    fn deny(self: *const Lookup, exec: *const js.Execution, message: []const u8) !void {
        if (!self._owner.isRetired()) return;
        return throwDOMException(exec, "SecurityError", message);
    }

    pub fn getItem(self: *const Lookup, k: []const u8, exec: *const js.Execution) !?[]const u8 {
        try self.deny(exec, "Failed to execute 'getItem' on 'Storage': Access is denied for this document.");
        return self._area.getItem(k);
    }

    pub fn setItem(self: *Lookup, k: []const u8, value: []const u8, exec: *const js.Execution) !void {
        try self.deny(exec, "Failed to execute 'setItem' on 'Storage': Access is denied for this document.");
        return self.set(k, value, .method, exec);
    }

    pub fn removeItem(self: *Lookup, k: []const u8, exec: *const js.Execution) !void {
        try self.deny(exec, "Failed to execute 'removeItem' on 'Storage': Access is denied for this document.");
        try self.remove(k);
    }

    pub fn clear(self: *Lookup, exec: *const js.Execution) !void {
        try self.deny(exec, "Failed to execute 'clear' on 'Storage': Access is denied for this document.");
        if (!self._area.clear()) return;
        try self._owner.window.broadcastStorageMutation(self, null, null, null);
    }

    pub fn key(self: *const Lookup, index: u32, exec: *const js.Execution) !?[]const u8 {
        try self.deny(exec, "Failed to execute 'key' on 'Storage': Access is denied for this document.");
        return self._area.key(index);
    }

    pub fn getLength(self: *const Lookup, exec: *const js.Execution) !u32 {
        try self.deny(exec, "Failed to read the 'length' property from 'Storage': Access is denied for this document.");
        return self._area.getLength();
    }

    fn namedMessage(exec: *const js.Execution, comptime operation: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            exec.call_arena,
            "Failed to {s} a named property '{s}' {s} 'Storage': Access is denied for this document.",
            .{
                operation,
                name,
                if (std.mem.eql(u8, operation, "set")) "on" else "from",
            },
        );
    }

    fn indexedMessage(exec: *const js.Execution, comptime operation: []const u8, index: u32) ![]const u8 {
        return std.fmt.allocPrint(
            exec.call_arena,
            "Failed to {s} an indexed property [{d}] {s} 'Storage': Access is denied for this document.",
            .{
                operation,
                index,
                if (std.mem.eql(u8, operation, "set")) "on" else "from",
            },
        );
    }

    fn getNamed(self: *const Lookup, name: []const u8, exec: *const js.Execution) !?[]const u8 {
        try self.deny(exec, try namedMessage(exec, "read", name));
        return self._area.getItem(name);
    }

    fn setNamed(self: *Lookup, name: []const u8, value: []const u8, exec: *const js.Execution) !void {
        try self.deny(exec, try namedMessage(exec, "set", name));
        return self.set(name, value, .{ .named = name }, exec);
    }

    fn removeNamed(self: *Lookup, name: []const u8, exec: *const js.Execution) !void {
        try self.deny(exec, try namedMessage(exec, "delete", name));
        try self.remove(name);
    }

    fn hasNamed(self: *const Lookup, name: []const u8, exec: *const js.Execution) !bool {
        try self.deny(exec, try namedMessage(exec, "read", name));
        return self._area.hasItem(name);
    }

    fn keys(self: *const Lookup, exec: *const js.Execution) !js.Array {
        try self.deny(exec, "Failed to enumerate the properties of 'Storage': Access is denied for this document.");
        const local = exec.js.local.?;
        var arr = local.newArray(self._area.getLength());
        var it = self._area._data.keyIterator();
        var i: u32 = 0;
        while (it.next()) |k| : (i += 1) {
            _ = try arr.set(i, k.*, .{});
        }
        return arr;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Lookup);

        pub const Meta = struct {
            pub const name = "Storage";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const length = bridge.accessor(Lookup.getLength, null, .{});
        pub const getItem = bridge.function(Lookup.getItem, .{});
        pub const setItem = bridge.function(Lookup.setItem, .{});
        pub const removeItem = bridge.function(Lookup.removeItem, .{});
        pub const clear = bridge.function(Lookup.clear, .{});
        pub const key = bridge.function(Lookup.key, .{});
        pub const @"[str]" = bridge.namedIndexed(Lookup.getNamed, Lookup.setNamed, Lookup.removeNamed, Lookup.keys, Lookup.hasNamed, .{ .null_as_undefined = true });
        pub const @"[int]" = bridge.indexedReadWrite(_getByIndex, _setByIndex, _removeByIndex, _indexHas, null, .{ .null_as_undefined = true });

        // v8 routes storage[9] to the indexed interceptor, so we need to do the
        // int -> string conversion
        fn _getByIndex(self: *const Lookup, idx: u32, exec: *const js.Execution) !?[]const u8 {
            try self.deny(exec, try indexedMessage(exec, "read", idx));
            var buf: [10]u8 = undefined;
            return self._area.getItem(std.fmt.bufPrint(&buf, "{d}", .{idx}) catch unreachable);
        }

        fn _setByIndex(self: *Lookup, idx: u32, value: []const u8, exec: *const js.Execution) !void {
            try self.deny(exec, try indexedMessage(exec, "set", idx));
            var buf: [10]u8 = undefined;
            return self.set(
                std.fmt.bufPrint(&buf, "{d}", .{idx}) catch unreachable,
                value,
                .{ .indexed = idx },
                exec,
            );
        }

        fn _removeByIndex(self: *Lookup, idx: u32, exec: *const js.Execution) !void {
            try self.deny(exec, try indexedMessage(exec, "delete", idx));
            var buf: [10]u8 = undefined;
            try self.remove(std.fmt.bufPrint(&buf, "{d}", .{idx}) catch unreachable);
        }

        fn _indexHas(self: *const Lookup, idx: u32, exec: *const js.Execution) !bool {
            try self.deny(exec, try indexedMessage(exec, "read", idx));
            var buf: [10]u8 = undefined;
            return self._area.hasItem(std.fmt.bufPrint(&buf, "{d}", .{idx}) catch unreachable);
        }
    };

    const SetContext = union(enum) {
        method,
        named: []const u8,
        indexed: u32,
    };

    fn set(
        self: *Lookup,
        key_: []const u8,
        value: []const u8,
        context: SetContext,
        exec: *const js.Execution,
    ) !void {
        const result = self._area.setItem(key_, value) catch |err| switch (err) {
            error.QuotaExceeded => {
                const message = switch (context) {
                    .method => try std.fmt.allocPrint(
                        exec.call_arena,
                        "Failed to execute 'setItem' on 'Storage': Setting the value of '{s}' exceeded the quota.",
                        .{key_},
                    ),
                    .named => |name| try std.fmt.allocPrint(
                        exec.call_arena,
                        "Failed to set a named property '{s}' on 'Storage': Setting the value of '{s}' exceeded the quota.",
                        .{ name, key_ },
                    ),
                    .indexed => |index| try std.fmt.allocPrint(
                        exec.call_arena,
                        "Failed to set an indexed property [{d}] on 'Storage': Setting the value of '{s}' exceeded the quota.",
                        .{ index, key_ },
                    ),
                };
                return throwDOMException(exec, "QuotaExceededError", message);
            },
            else => return err,
        };
        defer self._area.releaseOldValue(result.old_value);

        if (!result.changed) return;
        try self._owner.window.broadcastStorageMutation(
            self,
            key_,
            result.old_value,
            value,
        );
    }

    fn remove(self: *Lookup, key_: []const u8) !void {
        const old_value = self._area.removeItem(key_) orelse return;
        defer self._area.releaseOldValue(old_value);
        try self._owner.window.broadcastStorageMutation(
            self,
            key_,
            old_value,
            null,
        );
    }
};

const testing = @import("../../../testing.zig");
test "WebApi: Storage" {
    try testing.htmlRunner("storage.html", .{});
}

test "WebApi: Storage lifecycle" {
    try testing.htmlRunner("storage_lifecycle.html", .{ .timeout_ms = 8000 });
}

test "WebApi: Storage immutable origin" {
    try testing.htmlRunner("storage_origin.html", .{ .timeout_ms = 8000 });
}

test "WebApi: Storage popup namespaces" {
    try testing.htmlRunner("storage_popup.html", .{ .timeout_ms = 8000 });
}

test "Storage quota uses UTF-16 code units and only rejects growth" {
    try std.testing.expectEqual(@as(usize, 2), Area.utf16CodeUnits("🌠"));
    try std.testing.expectEqual(@as(usize, 2), Area.utf16CodeUnits("資料"));
    try std.testing.expectEqual(@as(usize, 8), Area.quotaForItem("🌠", "資料"));
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), Area.max_size);

    var area = Area{ ._allocator = std.testing.allocator };
    defer area.deinit();
    const initial = try area.setItem("k", "xx");
    area.releaseOldValue(initial.old_value);

    // Model an area restored from persistence while already over budget.
    area._quota_used = Area.max_size + 64;
    const shrink = try area.setItem("k", "x");
    area.releaseOldValue(shrink.old_value);
    try std.testing.expectError(error.QuotaExceeded, area.setItem("k", "xxx"));
}

test "Storage shed partitions session areas by stable top-level identity" {
    const allocator = std.testing.allocator;
    var shed: Shed = .{};
    defer shed.deinit(allocator);

    const local_a = try shed.getLocal(allocator, "https://example.test");
    const local_b = try shed.getLocal(allocator, "https://example.test");
    try std.testing.expectEqual(local_a, local_b);

    const first = try shed.getSession(allocator, 0x1000, "https://example.test");
    const first_again = try shed.getSession(allocator, 0x1000, "https://example.test");
    const second = try shed.getSession(allocator, 0x2000, "https://example.test");
    try std.testing.expectEqual(first, first_again);
    try std.testing.expect(first != second);

    shed.removeSessionNamespace(allocator, 0x1000);
    try std.testing.expectEqual(@as(?*Area, null), shed.peekSession(0x1000, "https://example.test"));
    try std.testing.expectEqual(second, shed.peekSession(0x2000, "https://example.test").?);
    try std.testing.expectEqual(local_a, shed.peekLocal("https://example.test").?);
}

test "Storage session namespace clone snapshots every origin and then isolates" {
    const allocator = std.testing.allocator;
    var shed: Shed = .{};
    defer shed.deinit(allocator);

    const Put = struct {
        fn item(area: *Area, key: []const u8, value: []const u8) !void {
            const result = try area.setItem(key, value);
            area.releaseOldValue(result.old_value);
        }
    };

    const source_a = try shed.getSession(allocator, 0x1000, "https://a.example");
    const source_b = try shed.getSession(allocator, 0x1000, "https://b.example");
    try Put.item(source_a, "shared", "source-snapshot");
    try Put.item(source_b, "other-origin", "also-snapshotted");

    try shed.cloneSessionNamespace(allocator, 0x1000, 0x2000);
    const clone_a = shed.peekSession(0x2000, "https://a.example").?;
    const clone_b = shed.peekSession(0x2000, "https://b.example").?;
    try std.testing.expect(clone_a != source_a);
    try std.testing.expect(clone_b != source_b);
    try std.testing.expectEqual(source_a._quota_used, clone_a._quota_used);
    try std.testing.expectEqualStrings("source-snapshot", clone_a.getItem("shared").?);
    try std.testing.expectEqualStrings("also-snapshotted", clone_b.getItem("other-origin").?);

    try Put.item(source_a, "shared", "source-after-clone");
    try std.testing.expectEqualStrings("source-snapshot", clone_a.getItem("shared").?);
    try Put.item(clone_b, "other-origin", "clone-after-clone");
    try std.testing.expectEqualStrings("also-snapshotted", source_b.getItem("other-origin").?);

    // A noopener/new-tab identity does not call cloneSessionNamespace and is
    // therefore a fresh area even when the origin matches the opener.
    const fresh = try shed.getSession(allocator, 0x3000, "https://a.example");
    try std.testing.expectEqual(@as(u32, 0), fresh.getLength());
}
