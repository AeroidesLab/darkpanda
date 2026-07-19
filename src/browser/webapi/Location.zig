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
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const URL = @import("URL.zig");
const U = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Document = @import("Document.zig");
const DOMException = @import("DOMException.zig");
const DOMStringList = @import("collections/DOMStringList.zig").DOMStringList;
const TaggedOpaque = @import("../js/TaggedOpaque.zig");

const Location = @This();

_url: *URL,
// Location belongs to one inner Window/Document, not to the reusable outer
// browsing-context Frame address. Document._frame becomes null on detach,
// while URL and security-origin snapshots remain available to cached wrappers.
_owner: *Document,
// The retired Context remains alive until Page teardown. Keep it so platform
// objects created after detach still use this Location's relevant Realm.
_owner_context: *js.Context,
_ancestor_origins: ?*DOMStringList = null,
_rc: lp.RC(u32) = .{},

pub fn init(raw_url: []const u8, frame: *Frame) !*Location {
    const url = try URL.init(raw_url, null, &frame.js.execution);
    url.acquireRef();
    errdefer url.releaseRef(frame._page);

    return frame._factory.create(Location{
        ._url = url,
        ._owner = frame.document,
        ._owner_context = frame.js,
    });
}

pub fn deinit(self: *const Location, page: *Page) void {
    if (self._ancestor_origins) |list| list.releaseRef(page);
    self._url.releaseRef(page);
}

pub fn acquireRef(self: *Location) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *Location, page: *Page) void {
    self._rc.release(self, page);
}

/// A same-document navigation changes the URL represented by this Location,
/// but it must not replace the Location platform object. Cached JavaScript
/// references therefore keep both object and creation-realm identity.
pub fn updateUrl(self: *Location, raw_url: []const u8, frame: *Frame) !void {
    const url = try URL.init(raw_url, null, &frame.js.execution);
    url.acquireRef();

    const previous = self._url;
    self._url = url;
    previous.releaseRef(frame._page);
}

pub fn getPathname(self: *const Location) []const u8 {
    return self._url.getPathname();
}

pub fn getProtocol(self: *const Location) []const u8 {
    return self._url.getProtocol();
}

pub fn getHostname(self: *const Location) []const u8 {
    return self._url.getHostname();
}

pub fn getHost(self: *const Location) []const u8 {
    return self._url.getHost();
}

pub fn getPort(self: *const Location) []const u8 {
    return self._url.getPort();
}

pub fn getOrigin(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.getOrigin(exec);
}

pub fn getSearch(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.getSearch(exec);
}

pub fn getHash(self: *const Location) []const u8 {
    return self._url.getHash();
}

fn serializedAncestorOrigin(frame: *const Frame) []const u8 {
    const key = frame.js.origin.key;
    // Opaque Origin keys are unguessable identifiers and must serialize as
    // "null". document.domain's internal `!` key is also not observable;
    // SecurityOrigin::ToString() continues to return the raw tuple origin.
    if (key.len == 0 or (key[0] != '!' and std.mem.indexOf(u8, key, "://") == null)) {
        return "null";
    }
    return frame.origin orelse "null";
}

/// Blink caches Location.ancestorOrigins on the Location object. Keep a
/// native reference in addition to any JS wrapper references so collecting a
/// wrapper cannot leave this identity cache dangling.
fn materializeAncestorOriginsInOwnerRealm(self: *Location, list: *DOMStringList) !void {
    var ls: js.Local.Scope = undefined;
    self._owner_context.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.mapZigInstanceToJs(null, list);
}

/// V8 cannot instantiate a new platform wrapper after a navigation has
/// detached the owner Context's global. Discard/close keeps that global
/// attached and uses getAncestorOrigins's normal lazy invalidation instead.
pub fn prepareForDocumentDetach(self: *Location, exec: *const js.Execution) !void {
    if (self._ancestor_origins) |list| {
        if (list.length() == 0) return;
        list.releaseRef(self._owner_context.page);
        self._ancestor_origins = null;
    }

    const list = blk: {
        const arena = try exec.getArena(.small, "Location.detachedAncestorOrigins");
        errdefer exec.releaseArena(arena);
        const value = try arena.create(DOMStringList);
        value.* = .{ ._arena = arena, ._items = &.{} };
        break :blk value;
    };
    list.acquireRef();
    errdefer list.releaseRef(self._owner_context.page);
    try self.materializeAncestorOriginsInOwnerRealm(list);
    self._ancestor_origins = list;
}

pub fn getAncestorOrigins(self: *Location, exec: *const js.Execution) !*DOMStringList {
    const attached = self._owner._frame != null;
    if (self._ancestor_origins) |list| {
        // Blink invalidates a previously non-empty ancestor snapshot when the
        // corresponding Document detaches, then caches a new empty list.
        if (attached or list.length() == 0) return list;
        list.releaseRef(self._owner_context.page);
        self._ancestor_origins = null;
    }

    const list = blk: {
        const arena = try exec.getArena(.small, "Location.ancestorOrigins");
        errdefer exec.releaseArena(arena);

        var count: usize = 0;
        var ancestor = if (self._owner._frame) |frame| frame.parent else null;
        while (ancestor) |current| : (ancestor = current.parent) count += 1;

        const items = try arena.alloc([]const u8, count);
        ancestor = if (self._owner._frame) |frame| frame.parent else null;
        var index: usize = 0;
        while (ancestor) |current| : (ancestor = current.parent) {
            items[index] = try arena.dupe(u8, serializedAncestorOrigin(current));
            index += 1;
        }

        const value = try arena.create(DOMStringList);
        value.* = .{ ._arena = arena, ._items = items };
        break :blk value;
    };
    list.acquireRef();
    errdefer list.releaseRef(self._owner_context.page);

    // A foreign caller can be first to read the Location. Always materialize
    // in the Location's relevant Realm.
    try self.materializeAncestorOriginsInOwnerRealm(list);

    self._ancestor_origins = list;
    return list;
}

pub fn setProtocol(self: *const Location, protocol: []const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    const new_url = try U.setProtocol(target.url, protocol, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

pub fn setHost(self: *const Location, host: []const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    const new_url = try U.setHost(target.url, host, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

pub fn setHostname(self: *const Location, hostname: []const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    const new_url = try U.setHostname(target.url, hostname, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

pub fn setPort(self: *const Location, port: []const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    const new_url = try U.setPort(target.url, port, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

pub fn setPathname(self: *const Location, pathname: []const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    const new_url = try U.setPathname(target.url, pathname, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

pub fn setSearch(self: *const Location, search: []const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    const new_url = try U.setSearch(target.url, search, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

pub fn setHash(self: *const Location, hash: []const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    // Blink's Location::setHash mutates a KURL first and compares the old and
    // new canonical fragment identifiers before asking Frame to navigate.
    // Resolve against the target Document (not the caller) to get the same
    // special-URL slash and percent-encoding normalization. An empty setter
    // value represents an empty fragment and therefore serializes as `#` when
    // it actually changes a non-empty fragment.
    const fragment_reference = if (hash.len == 0 or hash[0] == '#')
        hash
    else
        try std.fmt.allocPrint(frame.call_arena, "#{s}", .{hash});
    const normalized_reference: []const u8 = if (fragment_reference.len == 0) "#" else fragment_reference;
    const new_url = try U.resolve(frame.call_arena, target.url, normalized_reference, .{});

    if (U.eqlFragmentIdentifierIgnoringNullity(target.url, new_url)) return;

    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

pub fn assign(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = target });
}

pub fn replace(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .replace = null } }, .{ .script = target });
}

pub fn reload(self: *const Location, frame: *Frame) !void {
    const target = self._owner._frame orelse return;
    return frame.scheduleNavigation(target.url, .{ .reason = .script, .kind = .reload }, .{ .script = target });
}

pub fn toString(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.toString(exec);
}

fn crossOriginAccessCheck(
    accessing_context: ?*const js.v8.Context,
    accessed_object: ?*const js.v8.Object,
    data: ?*const js.v8.Value,
) callconv(.c) bool {
    _ = data;

    const context = js.Context.fromC(accessing_context orelse return false) orelse
        return false;
    const caller = switch (context.global) {
        .frame => |frame| frame,
        .worker => return false,
    };
    const location = TaggedOpaque.fromJS(*Location, accessed_object orelse return false) catch
        return false;

    // Attached access follows the current inner Document. Detached Location
    // wrappers retain that Document's stable origin snapshot: returning to an
    // A2 Document must not make a cached B Location same-origin, while a
    // cached A1 Location remains readable from same-origin A2.
    if (location._owner._frame) |owner_frame| {
        if (caller == owner_frame) return true;
    }
    return std.mem.eql(
        u8,
        caller.js.origin.key,
        location._owner._security_origin_key,
    );
}

fn throwCrossOriginMessage(frame: *Frame, message: []const u8) !js.Value {
    const local = frame.js.local orelse return error.SecurityError;
    const value = local.zigValueToJs(DOMException.init(message, "SecurityError"), .{}) catch
        return error.OutOfMemory;
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(value.handle));
    return .{
        .local = local,
        .handle = local.isolate.throwException(value.handle),
    };
}

const detachedSecurityPolicy =
    "An attempt was made to break through the security policy of the user agent.";

fn crossOriginSecurityPolicy(self: *const Location, frame: *Frame) ![]const u8 {
    if (self._owner._frame == null) return detachedSecurityPolicy;

    return std.fmt.allocPrint(
        frame.call_arena,
        "Blocked a frame with origin \"{s}\" from accessing a cross-origin frame.",
        .{frame.origin orelse "null"},
    );
}

fn throwCrossOriginNamedSecurityError(
    self: *const Location,
    frame: *Frame,
    name: []const u8,
    comptime operation: enum { read, write },
) !js.Value {
    const policy = try self.crossOriginSecurityPolicy(frame);
    const message = switch (operation) {
        .read => try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to read a named property '{s}' from 'Location': {s}",
            .{ name, policy },
        ),
        .write => try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to set a named property '{s}' on 'Location': {s}",
            .{ name, policy },
        ),
    };
    return throwCrossOriginMessage(frame, message);
}

fn throwCrossOriginIndexedSecurityError(
    self: *const Location,
    frame: *Frame,
    index: u32,
    comptime operation: enum { read, write },
) !js.Value {
    const policy = try self.crossOriginSecurityPolicy(frame);
    const message = switch (operation) {
        .read => try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to read an indexed property [{d}] from 'Location': {s}",
            .{ index, policy },
        ),
        .write => try std.fmt.allocPrint(
            frame.call_arena,
            "Failed to set an indexed property [{d}] on 'Location': {s}",
            .{ index, policy },
        ),
    };
    return throwCrossOriginMessage(frame, message);
}

fn throwCrossOriginGenericSecurityError(self: *const Location, frame: *Frame) !js.Value {
    return throwCrossOriginMessage(frame, try self.crossOriginSecurityPolicy(frame));
}

pub fn throwFailedAccessCheckSecurityError(self: *const Location, frame: *Frame) !void {
    _ = try self.throwCrossOriginGenericSecurityError(frame);
}

fn crossOriginCallbackFunction(
    frame: *Frame,
    comptime callback: *const fn (?*const js.v8.FunctionCallbackInfo) callconv(.c) void,
    comptime name: []const u8,
    length: i32,
) !js.Value {
    return frame.js.crossOriginFunction(
        JsApi.Meta.class_id,
        callback,
        name,
        length,
    );
}

fn crossOriginDataDescriptor(frame: *Frame, value: js.Value) !js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    return local.zigValueToJs(.{
        .value = value,
        .writable = false,
        .enumerable = false,
        .configurable = true,
    }, .{});
}

fn crossOriginUndefinedDescriptor(local: *const js.Local) !js.Value {
    return local.zigValueToJs(.{
        .value = js.Undefined{},
        .writable = false,
        .enumerable = false,
        .configurable = true,
    }, .{});
}

fn crossOriginHrefDescriptor(frame: *Frame) !js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    const setter = try crossOriginCallbackFunction(
        frame,
        JsApi.href.setter.?,
        "set href",
        1,
    );
    return local.zigValueToJs(.{
        .get = js.Undefined{},
        .set = setter,
        .enumerable = false,
        .configurable = true,
    }, .{});
}

fn crossOriginNavigationString(value: js.Value) ![:0]const u8 {
    return value.toStringSliceZ() catch |err| switch (err) {
        error.JsException => error.TryCatchRethrow,
        else => err,
    };
}

fn isAllowedCrossOriginSymbol(name: js.Caller.PropertyName) bool {
    return switch (name.kind) {
        .to_string_tag, .has_instance, .is_concat_spreadable => true,
        .string, .symbol => false,
    };
}

fn crossOriginReplaceCallback(
    raw_info: ?*const js.v8.FunctionCallbackInfo,
) callconv(.c) void {
    const info = raw_info orelse return;
    if (js.v8.v8__FunctionCallbackInfo__Length(info) >= 1) {
        return JsApi.replace.func(raw_info);
    }

    const isolate_handle = js.v8.v8__FunctionCallbackInfo__GetIsolate(info) orelse return;
    const isolate: js.Isolate = .{ .handle = isolate_handle };
    const message = "Failed to execute 'replace' on 'Location': 1 argument required, but only 0 present.";
    _ = isolate.throwException(isolate.createTypeError(message));
}

fn crossOriginNamedGet(self: *Location, name: js.Caller.PropertyName, frame: *Frame) !js.Value {
    if (isAllowedCrossOriginSymbol(name)) {
        const local = frame.js.local orelse return error.InvalidStateError;
        return local.zigValueToJs(js.Undefined{}, .{});
    }
    if (name.kind == .string and std.mem.eql(u8, name.text, "replace")) {
        return crossOriginCallbackFunction(
            frame,
            crossOriginReplaceCallback,
            "replace",
            1,
        );
    }
    if (name.kind == .string and std.mem.eql(u8, name.text, "then")) {
        const local = frame.js.local orelse return error.InvalidStateError;
        return local.zigValueToJs(js.Undefined{}, .{});
    }
    return self.throwCrossOriginNamedSecurityError(frame, name.text, .read);
}

fn crossOriginNamedSet(self: *Location, name: js.Caller.PropertyName, value: js.Value, frame: *Frame) !void {
    if (name.kind == .string and std.mem.eql(u8, name.text, "href")) {
        return self.assign(try crossOriginNavigationString(value), frame);
    }
    _ = try self.throwCrossOriginNamedSecurityError(frame, name.text, .write);
}

fn crossOriginNamedDelete(self: *Location, _: js.Caller.PropertyName, frame: *Frame) !void {
    _ = try self.throwCrossOriginGenericSecurityError(frame);
}

fn crossOriginNamedEnumerate(_: *Location, frame: *Frame) ![]js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    const keys = try frame.call_arena.alloc(js.Value, 6);
    keys[0] = try local.zigValueToJs("href", .{});
    keys[1] = try local.zigValueToJs("replace", .{});
    keys[2] = try local.zigValueToJs("then", .{});
    keys[3] = .{ .local = local, .handle = @ptrCast(js.v8.v8__Symbol__GetToStringTag(local.isolate.handle)) };
    keys[4] = .{ .local = local, .handle = @ptrCast(js.v8.v8__Symbol__GetHasInstance(local.isolate.handle)) };
    keys[5] = .{ .local = local, .handle = @ptrCast(js.v8.v8__Symbol__GetIsConcatSpreadable(local.isolate.handle)) };
    return keys;
}

fn crossOriginNamedQuery(self: *Location, name: js.Caller.PropertyName, frame: *Frame) !?u32 {
    if (isAllowedCrossOriginSymbol(name)) return js.v8.ReadOnly | js.v8.DontEnum;
    if (name.kind == .string and std.mem.eql(u8, name.text, "href")) return js.v8.DontEnum;
    if (name.kind == .string and std.mem.eql(u8, name.text, "replace")) return js.v8.ReadOnly | js.v8.DontEnum;
    // CrossOriginPropertyFallback exposes `location.then` and its descriptor,
    // but HTML does not grant [[HasProperty]] access. Let V8 continue into the
    // denied ordinary lookup so `'then' in location` reaches the failed-access
    // callback and throws the generic SecurityError. Enumerator+descriptor
    // still make Reflect.ownKeys expose it while Object.keys filters it out.
    if (name.kind == .string and std.mem.eql(u8, name.text, "then")) return null;

    _ = try self.throwCrossOriginGenericSecurityError(frame);
    return 0;
}

fn crossOriginNamedDefine(self: *Location, _: js.Caller.PropertyName, frame: *Frame) !void {
    _ = try self.throwCrossOriginGenericSecurityError(frame);
}

fn crossOriginNamedDescriptor(self: *Location, name: js.Caller.PropertyName, frame: *Frame) !js.Value {
    if (isAllowedCrossOriginSymbol(name)) {
        const local = frame.js.local orelse return error.InvalidStateError;
        return crossOriginUndefinedDescriptor(local);
    }
    if (name.kind == .string and std.mem.eql(u8, name.text, "href")) return crossOriginHrefDescriptor(frame);
    if (name.kind == .string and std.mem.eql(u8, name.text, "replace")) {
        return crossOriginDataDescriptor(
            frame,
            try crossOriginCallbackFunction(
                frame,
                crossOriginReplaceCallback,
                "replace",
                1,
            ),
        );
    }
    if (name.kind == .string and std.mem.eql(u8, name.text, "then")) {
        const local = frame.js.local orelse return error.InvalidStateError;
        return crossOriginUndefinedDescriptor(local);
    }
    return self.throwCrossOriginNamedSecurityError(frame, name.text, .read);
}

fn crossOriginIndexedGet(self: *Location, index: u32, frame: *Frame) !js.Value {
    return self.throwCrossOriginIndexedSecurityError(frame, index, .read);
}

fn crossOriginIndexedSet(self: *Location, index: u32, _: js.Value, frame: *Frame) !void {
    _ = try self.throwCrossOriginIndexedSecurityError(frame, index, .write);
}

fn crossOriginIndexedDelete(self: *Location, _: u32, frame: *Frame) !void {
    _ = try self.throwCrossOriginGenericSecurityError(frame);
}

fn crossOriginIndexedQuery(self: *Location, index: u32, frame: *Frame) !?u32 {
    _ = try self.throwCrossOriginIndexedSecurityError(frame, index, .read);
    return 0;
}

fn crossOriginIndexedEnumerate(_: *Location) []const u32 {
    return &.{};
}

fn crossOriginIndexedDefine(self: *Location, _: u32, frame: *Frame) !void {
    _ = try self.throwCrossOriginGenericSecurityError(frame);
}

fn crossOriginIndexedDescriptor(self: *Location, index: u32, frame: *Frame) !js.Value {
    return self.throwCrossOriginIndexedSecurityError(frame, index, .read);
}

const CrossOriginAccessHandlers = struct {
    const bridge = js.Bridge(Location);

    pub const callback = crossOriginAccessCheck;

    pub const named = bridge.namedIndexedFull(
        crossOriginNamedGet,
        crossOriginNamedSet,
        crossOriginNamedDelete,
        crossOriginNamedEnumerate,
        crossOriginNamedQuery,
        crossOriginNamedDefine,
        crossOriginNamedDescriptor,
        .{},
    );

    pub const indexed = bridge.indexedFull(
        crossOriginIndexedGet,
        crossOriginIndexedSet,
        crossOriginIndexedDelete,
        crossOriginIndexedQuery,
        crossOriginIndexedEnumerate,
        crossOriginIndexedDefine,
        crossOriginIndexedDescriptor,
        .{},
    );
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Location);

    pub const Meta = struct {
        pub const name = "Location";
        pub const access_check = CrossOriginAccessHandlers;
        pub const legacy_unforgeable_members = true;
        pub const immutable_proto = js.bridge.ImmutableProto.both;
        pub const instance_template_properties = [_]js.bridge.InstanceTemplateProperty{
            .{
                .key = .{ .string = "valueOf" },
                .value = .{ .intrinsic = .object_prototype_value_of },
                .writable = false,
                .enumerable = false,
                .configurable = false,
                .phase = .before_members,
            },
            .{
                .key = .{ .well_known_symbol = .to_primitive },
                .value = .undefined_value,
                .writable = false,
                .enumerable = false,
                .configurable = false,
                .phase = .after_members,
            },
        };
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const ancestorOrigins = bridge.accessor(Location.getAncestorOrigins, null, .{});
    pub const href = bridge.accessor(Location.toString, setHref, .{});
    fn setHref(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
        return self.assign(url, frame);
    }

    pub const origin = bridge.accessor(Location.getOrigin, null, .{});
    pub const protocol = bridge.accessor(Location.getProtocol, Location.setProtocol, .{});
    pub const host = bridge.accessor(Location.getHost, Location.setHost, .{});
    pub const hostname = bridge.accessor(Location.getHostname, Location.setHostname, .{});
    pub const port = bridge.accessor(Location.getPort, Location.setPort, .{});
    pub const pathname = bridge.accessor(Location.getPathname, Location.setPathname, .{});
    pub const search = bridge.accessor(Location.getSearch, Location.setSearch, .{});
    pub const hash = bridge.accessor(Location.getHash, Location.setHash, .{});
    pub const assign = bridge.function(Location.assign, .{});
    pub const reload = bridge.function(Location.reload, .{});
    pub const replace = bridge.function(Location.replace, .{});
    pub const toString = bridge.function(Location.toString, .{});
};
