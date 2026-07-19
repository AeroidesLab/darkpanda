// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");
const MessagePort = @import("../MessagePort.zig");
const UserActivation = @import("../UserActivation.zig");
const Window = @import("../Window.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const MessageEvent = @This();

_proto: *Event,
_data: ?Data = null,
_origin: []const u8 = "",
_last_event_id: []const u8 = "",
_source: ?Source = null,
_ports: []const *MessagePort = &.{},
_user_activation: ?*UserActivation = null,

pub const Source = union(enum) {
    window: *Window,
    message_port: *MessagePort,
};

const SourceAccess = union(enum) {
    window: Window.Access,
    message_port: *MessagePort,
};

const MessageEventOptions = struct {
    data: ?Data = null,
    origin: ?[]const u8 = null,
    lastEventId: ?[]const u8 = null,
    source: ?Source = null,
    ports: []const *MessagePort = &.{},
    userActivation: ?*UserActivation = null,
};

pub const Data = union(enum) {
    value: js.Value.Global,
    string: []const u8,
    arraybuffer: js.ArrayBuffer,
    blob: *@import("../Blob.zig"),
};

const Options = Event.inheritOptions(MessageEvent, MessageEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*MessageEvent {
    const arena = try page.getArena(.small, "MessageEvent");
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, page);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*MessageEvent {
    const arena = try page.getArena(.small, "MessageEvent.trusted");
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, opts_, true, page);
}

fn initWithTrusted(arena: Allocator, typ: String, opts_: ?Options, trusted: bool, page: *Page) !*MessageEvent {
    const opts = opts_ orelse Options{};

    const event = try page.factory.event(
        arena,
        typ,
        MessageEvent{
            ._proto = undefined,
            ._data = opts.data,
            ._origin = if (opts.origin) |str| try arena.dupe(u8, str) else "",
            ._last_event_id = if (opts.lastEventId) |str| try arena.dupe(u8, str) else "",
            ._source = opts.source,
            ._ports = if (opts.ports.len == 0) &.{} else try arena.dupe(*MessagePort, opts.ports),
            ._user_activation = opts.userActivation,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *MessageEvent, page: *Page) void {
    if (self._data) |d| {
        switch (d) {
            .value => |js_val| js_val.release(),
            .blob => |blob| blob.releaseRef(page),
            .string, .arraybuffer => {},
        }
    }
    self._proto.deinit(page);
}

pub fn acquireRef(self: *MessageEvent) void {
    self._proto.acquireRef();
}

pub fn releaseRef(self: *MessageEvent, page: *Page) void {
    self._proto._rc.release(self, page);
}

pub fn asEvent(self: *MessageEvent) *Event {
    return self._proto;
}

pub fn getData(self: *const MessageEvent) ?Data {
    return self._data;
}

pub fn getOrigin(self: *const MessageEvent) []const u8 {
    return self._origin;
}

pub fn getLastEventId(self: *const MessageEvent) []const u8 {
    return self._last_event_id;
}

pub fn getSource(self: *const MessageEvent, exec: *js.Execution) ?SourceAccess {
    const source = self._source orelse return null;
    return switch (source) {
        .window => |window| switch (exec.js.global) {
            .frame => |frame| .{ .window = Window.Access.init(frame.window, window) },
            // A Worker realm cannot obtain a Window object to put in a
            // constructed MessageEventInit dictionary.
            .worker => null,
        },
        .message_port => |port| .{ .message_port = port },
    };
}

pub fn getPorts(self: *const MessageEvent) []const *MessagePort {
    return self._ports;
}

pub fn getUserActivation(self: *const MessageEvent) ?*UserActivation {
    return self._user_activation;
}

pub fn setUserActivationSnapshot(
    self: *MessageEvent,
    has_been_active: bool,
    is_active: bool,
) !void {
    // Allocate in the MessageEvent's own arena.  Window.postMessage's queued
    // callback arena is released immediately after dispatch, while script may
    // retain the event and read its snapshot later.
    const snapshot = try self._proto._arena.create(UserActivation);
    snapshot.* = UserActivation.initSnapshot(has_been_active, is_active);
    self._user_activation = snapshot;
}

const init_message_operation: js.WebIDL.Operation = .{
    .interface = "MessageEvent",
    .name = "initMessageEvent",
};

fn optionalString(raw: ?js.Value, exec: *js.Execution) ![]const u8 {
    const value = raw orelse return "";
    if (value.isUndefined()) return "";
    // Both DOMString and USVString conversion begin with ToString.  The
    // current DOM storage is UTF-8; String.toSlice performs the scalar-value
    // replacement required by initMessageEvent's USVString origin.
    return (try js.WebIDL.toDOMStringValue(value, exec, init_message_operation)).toSlice();
}

fn optionalSource(raw: ?js.Value, exec: *js.Execution) !?Source {
    const value = raw orelse return null;
    if (value.isNullOrUndefined()) return null;

    if (value.toZig(*Window)) |window| {
        return .{ .window = window };
    } else |_| {}
    if (value.toZig(*MessagePort)) |port| {
        return .{ .message_port = port };
    } else |_| {}

    return js.WebIDL.typeError(
        exec,
        init_message_operation,
        "The optional 'source' property is neither a Window nor MessagePort.",
    );
}

fn optionalPorts(raw: ?js.Value, exec: *js.Execution) ![]const *MessagePort {
    const value = raw orelse return &.{};
    if (value.isUndefined()) return &.{};
    if (value.isNull()) {
        return js.WebIDL.typeError(
            exec,
            init_message_operation,
            "The provided value cannot be converted to a sequence.",
        );
    }
    return value.toZig([]const *MessagePort) catch
        return js.WebIDL.typeError(
            exec,
            init_message_operation,
            "The provided value cannot be converted to a sequence.",
        );
}

fn releaseData(data: ?Data, page: *Page) void {
    if (data) |value| switch (value) {
        .value => |global| global.release(),
        .blob => |blob| blob.releaseRef(page),
        .string, .arraybuffer => {},
    };
}

pub fn initMessageEvent(
    self: *MessageEvent,
    event_type: js.DOMString,
    bubbles_: ?js.Value,
    cancelable_: ?js.Value,
    data_: ?js.Value,
    origin_: ?js.Value,
    last_event_id_: ?js.Value,
    source_: ?js.Value,
    ports_: ?js.Value,
    exec: *js.Execution,
) !void {
    // Generated Web IDL bindings convert every supplied argument before the
    // implementation observes IsBeingDispatched().  Preserve author getter /
    // @@toPrimitive side effects even when initialization will be a no-op.
    const bubbles = if (bubbles_) |value| value.toBool() else false;
    const cancelable = if (cancelable_) |value| value.toBool() else false;
    const origin = try optionalString(origin_, exec);
    const last_event_id = try optionalString(last_event_id_, exec);
    const source = try optionalSource(source_, exec);
    const ports = try optionalPorts(ports_, exec);

    if (self._proto.isBeingDispatched()) return;

    const arena = self._proto._arena;
    const new_origin = if (origin.len == 0) "" else try arena.dupe(u8, origin);
    const new_last_event_id = if (last_event_id.len == 0) "" else try arena.dupe(u8, last_event_id);
    const new_ports = if (ports.len == 0) &.{} else try arena.dupe(*MessagePort, ports);

    const local = exec.js.local.?;
    const raw_data = data_ orelse js.Value{
        .local = local,
        .handle = local.isolate.initNull(),
    };
    // Blink's optional-any binding supplies its null default for both omitted
    // and explicitly undefined arguments on this legacy initializer.
    const normalized_data = if (raw_data.isNullOrUndefined())
        js.Value{ .local = local, .handle = local.isolate.initNull() }
    else
        raw_data;
    const new_data = try normalized_data.persist();
    errdefer new_data.release();

    try self._proto.initEvent(event_type.value, bubbles, cancelable);
    releaseData(self._data, exec.page);
    self._data = .{ .value = new_data };
    self._origin = new_origin;
    self._last_event_id = new_last_event_id;
    self._source = source;
    self._ports = new_ports;
    // Chromium intentionally leaves user_activation_ untouched: it is not an
    // argument of the legacy initMessageEvent method.
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MessageEvent);

    pub const Meta = struct {
        pub const name = "MessageEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(MessageEvent.init, .{});
    pub const data = bridge.accessor(MessageEvent.getData, null, .{});
    pub const origin = bridge.accessor(MessageEvent.getOrigin, null, .{});
    pub const lastEventId = bridge.accessor(MessageEvent.getLastEventId, null, .{});
    pub const source = bridge.accessor(MessageEvent.getSource, null, .{});
    pub const ports = bridge.accessor(MessageEvent.getPorts, null, .{});
    pub const userActivation = bridge.accessor(MessageEvent.getUserActivation, null, .{});
    pub const initMessageEvent = bridge.function(MessageEvent.initMessageEvent, .{ .arity = 1 });
};

const testing = @import("../../../testing.zig");
test "WebApi: MessageEvent" {
    try testing.htmlRunner("event/message.html", .{});
}

test "WebApi: sandboxed Window.postMessage uses committed SecurityOrigin" {
    try testing.htmlRunner("event/sandbox_postmessage_origin.html", .{ .timeout_ms = 8000 });
}
