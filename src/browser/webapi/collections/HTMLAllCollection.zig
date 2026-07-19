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
const lp = @import("darkpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const HTMLCollection = @import("HTMLCollection.zig");
const Execution = js.Execution;

const HTMLAllCollection = @This();

_tw: TreeWalker.FullExcludeSelf,
_last_index: usize,
_last_length: ?u32,
_cached_version: usize,
_named_cache: std.StringHashMapUnmanaged(*HTMLCollection),

pub fn init(root: *Node, frame: *Frame) HTMLAllCollection {
    return .{
        ._last_index = 0,
        ._last_length = null,
        ._tw = TreeWalker.FullExcludeSelf.init(root, .{}),
        ._cached_version = frame._page.dom_version,
        ._named_cache = .empty,
    };
}

fn versionCheck(self: *HTMLAllCollection, frame: *const Frame) bool {
    const current = frame._page.dom_version;
    if (self._cached_version != current) {
        self._cached_version = current;
        self._last_index = 0;
        self._last_length = null;
        self._tw.reset();
        return false;
    }
    return true;
}

pub fn length(self: *HTMLAllCollection, frame: *const Frame) u32 {
    if (self.versionCheck(frame)) {
        if (self._last_length) |cached_length| {
            return cached_length;
        }
        // Indexed access may have advanced the shared walker before length was
        // first requested. Chromium's live collection cache restarts from the
        // root in that case.
        if (self._last_index != 0) {
            self._last_index = 0;
            self._tw.reset();
        }
    }

    lp.assert(self._last_index == 0, "HTMLAllCollection.length", .{ .last_index = self._last_index });

    var tw = &self._tw;
    defer tw.reset();

    var l: u32 = 0;
    while (tw.next()) |node| {
        if (node.is(Element) != null) {
            l += 1;
        }
    }

    self._last_length = l;
    return l;
}

pub fn getAtIndex(self: *HTMLAllCollection, index: usize, frame: *const Frame) ?*Element {
    _ = self.versionCheck(frame);
    var current = self._last_index;
    if (index <= current) {
        current = 0;
        self._tw.reset();
    }
    defer self._last_index = current + 1;

    const tw = &self._tw;
    while (tw.next()) |node| {
        if (node.is(Element)) |el| {
            if (index == current) {
                return el;
            }
            current += 1;
        }
    }

    return null;
}

pub const NamedItemResult = union(enum) {
    element: *Element,
    html_collection: *HTMLCollection,
};

pub fn getByName(self: *HTMLAllCollection, name: []const u8, frame: *Frame) !?NamedItemResult {
    if (name.len == 0) return null;

    var matches = HTMLCollection.DocumentAllNamed.init(self._tw._root, name);
    const count = matches.length(frame);
    if (count == 0) return null;
    if (count == 1) return .{ .element = matches.getAtIndex(0, frame).? };

    if (self._named_cache.get(name)) |cached| {
        return .{ .html_collection = cached };
    }

    const stable_name = try frame.dupeString(name);
    const collection = try frame._factory.create(HTMLCollection{
        ._data = .{ .document_all_named = HTMLCollection.DocumentAllNamed.init(self._tw._root, stable_name) },
    });
    try self._named_cache.put(frame.arena, stable_name, collection);
    return .{ .html_collection = collection };
}

fn parseArrayIndex(value: []const u8) ?u32 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return null;
    for (value) |c| if (c < '0' or c > '9') return null;
    const index = std.fmt.parseInt(u32, value, 10) catch return null;
    // 2^32-1 is a property key but never an array index.
    if (index == std.math.maxInt(u32)) return null;
    return index;
}

fn itemImpl(
    self: *HTMLAllCollection,
    raw: ?js.Value,
    exec: *Execution,
    operation: ?js.WebIDL.Operation,
) !?NamedItemResult {
    const frame: *Frame = switch (exec.js.global) {
        .frame => |frame| frame,
        .worker => unreachable,
    };
    // Blink's optional-any overload returns null immediately when omitted; it
    // does not convert a synthetic undefined and perform a named lookup.
    const value = raw orelse return null;

    if (value.isUint32()) {
        const index = try value.toU32();
        if (index != std.math.maxInt(u32)) {
            const element = self.getAtIndex(index, frame) orelse return null;
            return .{ .element = element };
        }
    }

    // V8::Value::ToArrayIndex stringifies non-Smi inputs. If the resulting
    // string is not an array index, Blink then performs the IDL DOMString
    // conversion on the original value, making a second ToPrimitive call
    // observable for objects with side effects.
    const array_index_text = try js.WebIDL.toDOMString(value, exec, operation);
    if (parseArrayIndex(array_index_text)) |index| {
        const element = self.getAtIndex(index, frame) orelse return null;
        return .{ .element = element };
    }
    const name = try js.WebIDL.toDOMString(value, exec, operation);
    return self.getByName(name, frame);
}

pub fn callable(self: *HTMLAllCollection, raw: ?js.Value, exec: *Execution) !?NamedItemResult {
    // Blink's legacy call-as-function handler leaves this conversion error
    // unqualified, unlike the prototype item() operation.
    return self.itemImpl(raw, exec, null);
}

fn item(self: *HTMLAllCollection, raw: ?js.Value, exec: *Execution) !?NamedItemResult {
    return self.itemImpl(
        raw,
        exec,
        .{ .interface = "HTMLAllCollection", .name = "item" },
    );
}

fn namedItem(self: *HTMLAllCollection, raw: ?js.Value, exec: *Execution) !?NamedItemResult {
    const frame: *Frame = switch (exec.js.global) {
        .frame => |frame| frame,
        .worker => unreachable,
    };
    const value = raw orelse return js.WebIDL.requiredArgument(
        exec,
        .{ .interface = "HTMLAllCollection", .name = "namedItem" },
        1,
        0,
    );
    const name = try js.WebIDL.toDOMString(
        value,
        exec,
        .{ .interface = "HTMLAllCollection", .name = "namedItem" },
    );
    return self.getByName(name, frame);
}

fn getNamedProperty(self: *HTMLAllCollection, name: []const u8, frame: *Frame) !NamedItemResult {
    return try self.getByName(name, frame) orelse error.NotHandled;
}

fn hasIndex(self: *HTMLAllCollection, index: u32, frame: *const Frame) ?u32 {
    if (index >= self.length(frame)) return null;
    return @intCast(js.v8.ReadOnly);
}

fn getIndexes(self: *HTMLAllCollection, exec: *const Execution) !js.Array {
    const frame: *Frame = switch (exec.js.global) {
        .frame => |frame| frame,
        .worker => unreachable,
    };
    const len = self.length(frame);
    var keys = exec.js.local.?.newArray(len);
    for (0..len) |index| {
        _ = try keys.set(@intCast(index), index, .{});
    }
    return keys;
}

fn hasNamed(self: *HTMLAllCollection, name: []const u8, frame: *Frame) ?u32 {
    if (name.len == 0) return null;
    var matches = HTMLCollection.DocumentAllNamed.init(self._tw._root, name);
    if (matches.length(frame) == 0) return null;
    return @intCast(js.v8.ReadOnly | js.v8.DontEnum);
}

fn getNamedKeys(self: *HTMLAllCollection, exec: *const Execution) !js.Array {
    const frame: *Frame = switch (exec.js.global) {
        .frame => |frame| frame,
        .worker => unreachable,
    };
    var names: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var tw = self._tw.clone();
    tw.reset();
    while (tw.next()) |node| {
        const element = node.is(Element) orelse continue;
        if (element.getAttributeSafe(comptime .wrap("id"))) |id| {
            if (id.len != 0) {
                const gop = try seen.getOrPut(frame.local_arena, id);
                if (!gop.found_existing) try names.append(frame.local_arena, id);
            }
        }
        if (HTMLCollection.nameVisibleInDocumentAll(element)) {
            if (element.getAttributeSafe(comptime .wrap("name"))) |name| {
                if (name.len != 0) {
                    const gop = try seen.getOrPut(frame.local_arena, name);
                    if (!gop.found_existing) try names.append(frame.local_arena, name);
                }
            }
        }
    }

    var keys = exec.js.local.?.newArray(@intCast(names.items.len));
    for (names.items, 0..) |name, index| {
        _ = try keys.set(@intCast(index), name, .{});
    }
    return keys;
}

pub fn iterator(self: *HTMLAllCollection, exec: *const Execution) !*Iterator {
    return Iterator.init(.{
        .list = self,
        .tw = self._tw.clone(),
    }, exec);
}

const GenericIterator = @import("iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    list: *HTMLAllCollection,
    tw: TreeWalker.FullExcludeSelf,

    pub fn next(self: *@This(), _: *const Execution) ?*Element {
        while (self.tw.next()) |node| {
            if (node.is(Element)) |el| {
                return el;
            }
        }
        return null;
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLAllCollection);

    pub const Meta = struct {
        pub const name = "HTMLAllCollection";
        pub const prototype_template_properties = [_]js.bridge.InstanceTemplateProperty{.{
            .key = .{ .well_known_symbol = .iterator },
            .value = .{ .intrinsic = .array_prototype_values },
            .writable = true,
            .enumerable = false,
            .configurable = true,
            .phase = .after_members,
        }};
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;

        // This is a very weird class that requires special JavaScript behavior
        // this htmldda and callable are only used here..
        pub const htmldda = true;
        pub const callable = JsApi.callable;
    };

    pub const length = bridge.accessor(HTMLAllCollection.length, null, .{});
    pub const @"[int]" = bridge.indexedLegacyReadOnly(
        HTMLAllCollection.getAtIndex,
        HTMLAllCollection.hasIndex,
        HTMLAllCollection.getIndexes,
        "HTMLAllCollection",
        .{ .null_as_undefined = true },
    );
    pub const @"[str]" = bridge.namedIndexedLegacyReadOnly(
        HTMLAllCollection.getNamedProperty,
        HTMLAllCollection.getNamedKeys,
        HTMLAllCollection.hasNamed,
        "HTMLAllCollection",
        .{},
    );

    pub const item = bridge.function(HTMLAllCollection.item, .{ .arity = 0, .required_args = 0 });
    pub const namedItem = bridge.function(HTMLAllCollection.namedItem, .{ .arity = 1, .required_args = 1 });
    pub const callable = bridge.callable(HTMLAllCollection.callable, .{});
};
