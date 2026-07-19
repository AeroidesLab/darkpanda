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

const Event = @import("../Event.zig");
const InputDeviceCapabilities = @import("../InputDeviceCapabilities.zig");
const Window = @import("../Window.zig");

const String = lp.String;

const UIEvent = @This();

_type: Type,
_proto: *Event,
_detail: u32 = 0,
_view: ?*Window = null,
_source_capabilities: ?*InputDeviceCapabilities = null,

pub const Type = union(enum) {
    generic,
    mouse_event: *@import("MouseEvent.zig"),
    keyboard_event: *@import("KeyboardEvent.zig"),
    focus_event: *@import("FocusEvent.zig"),
    text_event: *@import("TextEvent.zig"),
    input_event: *@import("InputEvent.zig"),
    composition_event: *@import("CompositionEvent.zig"),
};

pub const UIEventOptions = struct {
    detail: u32 = 0,
    view: ?*Window = null,
    sourceCapabilities: ?*InputDeviceCapabilities = null,
};

pub const Options = Event.inheritOptions(
    UIEvent,
    UIEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*UIEvent {
    const arena = try frame.getArena(.tiny, "UIEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = _opts orelse Options{};
    const event = try frame._factory.event(
        arena,
        type_string,
        UIEvent{
            ._type = .generic,
            ._proto = undefined,
            ._detail = opts.detail,
            ._view = opts.view,
            ._source_capabilities = opts.sourceCapabilities,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn as(self: *UIEvent, comptime T: type) *T {
    return self.is(T).?;
}

pub fn is(self: *UIEvent, comptime T: type) ?*T {
    switch (self._type) {
        .generic => return if (T == UIEvent) self else null,
        .mouse_event => |e| {
            if (T == @import("MouseEvent.zig")) return e;
            return e.is(T);
        },
        .keyboard_event => |e| return if (T == @import("KeyboardEvent.zig")) e else null,
        .focus_event => |e| return if (T == @import("FocusEvent.zig")) e else null,
        .text_event => |e| return if (T == @import("TextEvent.zig")) e else null,
        .input_event => |e| return if (T == @import("InputEvent.zig")) e else null,
        .composition_event => |e| return if (T == @import("CompositionEvent.zig")) e else null,
    }
    return null;
}

pub fn populateFromOptions(self: *UIEvent, opts: anytype) void {
    self._detail = opts.detail;
    self._view = opts.view;
    self._source_capabilities = opts.sourceCapabilities;
}

pub fn asEvent(self: *UIEvent) *Event {
    return self._proto;
}

pub fn getDetail(self: *UIEvent) u32 {
    return self._detail;
}

pub fn getSourceCapabilities(self: *const UIEvent) ?*InputDeviceCapabilities {
    return self._source_capabilities;
}

pub fn getView(self: *const UIEvent) ?*Window {
    return self._view;
}

// Legacy: see https://w3c.github.io/uievents/#dom-uievent-which
pub fn getWhich(self: *const UIEvent) u32 {
    return switch (self._type) {
        .mouse_event => |me| legacyMouseWhich(me),
        .keyboard_event => 0,
        else => 0,
    };
}

fn legacyMouseWhich(mouse: *const @import("MouseEvent.zig")) u32 {
    const button = mouse.getButton();
    if (button < 0) return 0;

    // Chromium reports zero for hover/move compatibility events even though
    // their MouseEvent.button getter is 0.  `which` only identifies a changed
    // button for the press/release/activation family.
    const typ = mouse._proto._proto._type_string.str();
    const reports_button = std.mem.eql(u8, typ, "mousedown") or
        std.mem.eql(u8, typ, "mouseup") or
        std.mem.eql(u8, typ, "click") or
        std.mem.eql(u8, typ, "dblclick") or
        std.mem.eql(u8, typ, "auxclick") or
        std.mem.eql(u8, typ, "contextmenu") or
        std.mem.eql(u8, typ, "pointerdown") or
        std.mem.eql(u8, typ, "pointerup");
    if (!reports_button) return 0;

    return switch (button) {
        0 => 1,
        1 => 2,
        2 => 3,
        else => 0,
    };
}

pub fn initUIEvent(
    self: *UIEvent,
    typ: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
    view: ?*Window,
    detail: ?i32,
) !void {
    const event = self._proto;
    if (event._event_phase != .none) {
        return;
    }

    event._type_string = try String.init(event._arena, typ, .{});
    event._bubbles = bubbles orelse false;
    event._cancelable = cancelable orelse false;
    self._view = view;
    self._detail = if (detail) |d| @intCast(@max(d, 0)) else 0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(UIEvent);

    pub const Meta = struct {
        pub const name = "UIEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(UIEvent.init, .{});
    pub const detail = bridge.accessor(UIEvent.getDetail, null, .{});
    pub const view = bridge.accessor(UIEvent.getView, null, .{});
    pub const sourceCapabilities = bridge.accessor(UIEvent.getSourceCapabilities, null, .{});
    pub const which = bridge.accessor(UIEvent.getWhich, null, .{});
    pub const initUIEvent = bridge.function(UIEvent.initUIEvent, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: UIEvent" {
    try testing.htmlRunner("event/ui.html", .{});
}
