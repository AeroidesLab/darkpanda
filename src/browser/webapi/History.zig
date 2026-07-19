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
const js = @import("../js/js.zig");

const Frame = @import("../Frame.zig");
const PopStateEvent = @import("event/PopStateEvent.zig");
const DOMException = @import("DOMException.zig");

const History = @This();

const ScrollRestoration = enum { auto, manual };

_scroll_restoration: ScrollRestoration = .auto,
/// Stable browsing-context owner. The bridge-injected Frame is the caller's
/// realm, which can differ when a same-origin parent holds child.history.
_owner: ?*Frame = null,

fn owner(self: *const History, caller: *Frame) *Frame {
    return self._owner orelse caller;
}

fn requireActive(self: *const History, caller: *Frame, message: []const u8) !*Frame {
    const target = self.owner(caller);
    if (!target.isRetired()) return target;

    const local = caller.js.local orelse return error.SecurityError;
    const exception = try local.zigValueToJs(DOMException.init(message, "SecurityError"), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

pub fn getLength(self: *const History, caller: *Frame) !u32 {
    const target = try self.requireActive(caller, "Failed to read the 'length' property from 'History': May not use a History object associated with a Document that is not fully active");
    return @intCast(target.navigation()._entries.items.len);
}

pub fn getState(self: *const History, caller: *Frame) !?js.Value {
    const target = try self.requireActive(caller, "Failed to read the 'state' property from 'History': May not use a History object associated with a Document that is not fully active");
    const current = target.navigation().getCurrentEntryOrNull() orelse return null;
    if (current._state.value) |state| {
        const value = try caller.js.local.?.parseJSON(state);
        return value;
    } else return null;
}

pub fn getScrollRestoration(self: *History, caller: *Frame) ![]const u8 {
    _ = try self.requireActive(caller, "Failed to read the 'scrollRestoration' property from 'History': May not use a History object associated with a Document that is not fully active");
    return @tagName(self._scroll_restoration);
}

pub fn setScrollRestoration(self: *History, str: []const u8, caller: *Frame) !void {
    _ = try self.requireActive(caller, "Failed to set the 'scrollRestoration' property on 'History': May not use a History object associated with a Document that is not fully active");
    if (std.meta.stringToEnum(ScrollRestoration, str)) |sr| {
        self._scroll_restoration = sr;
    }
}

pub fn pushState(self: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8, caller: *Frame) !void {
    const frame = try self.requireActive(caller, "Failed to execute 'pushState' on 'History': May not use a History object associated with a Document that is not fully active");
    const arena = frame._session.arena;
    const url = if (_url) |u|
        try @import("../URL.zig").resolve(arena, frame.url, u, .{})
    else
        try arena.dupeZ(u8, frame.url);
    if (!frame.isSameOrigin(url)) return error.SecurityError;

    const json = state.toJson(arena) catch return error.DataClone;
    _ = try frame.navigation().pushEntry(url, .{ .source = .history, .value = json }, frame, true);

    frame.url = url;
    // setHref == reinitializing.
    try frame.window._location._url.setHref(url, &frame.js.execution);
}

pub fn replaceState(self: *History, state: js.Value, _: ?[]const u8, _url: ?[]const u8, caller: *Frame) !void {
    const frame = try self.requireActive(caller, "Failed to execute 'replaceState' on 'History': May not use a History object associated with a Document that is not fully active");
    const arena = frame._session.arena;
    const url = if (_url) |u|
        try @import("../URL.zig").resolve(arena, frame.url, u, .{})
    else
        try arena.dupeZ(u8, frame.url);
    if (!frame.isSameOrigin(url)) return error.SecurityError;

    const json = state.toJson(arena) catch return error.DataClone;
    _ = try frame.navigation().replaceEntry(url, .{ .source = .history, .value = json }, frame, true);

    frame.url = url;
    // setHref == reinitializing.
    try frame.window._location._url.setHref(url, &frame.js.execution);
}

fn goInner(_: *History, delta: i32, frame: *Frame) !void {
    // 0 behaves the same as no argument, both reloading the frame.

    if (delta == 0) {
        _ = try frame.navigation().navigateInner(frame.url, .reload, frame);
        return;
    }

    const navigation = frame.navigation();
    const current = navigation._index;
    const index_s: i64 = @intCast(@as(i64, @intCast(current)) + @as(i64, @intCast(delta)));
    if (index_s < 0 or index_s >= navigation._entries.items.len) {
        return;
    }

    const index = @as(usize, @intCast(index_s));
    const entry = navigation._entries.items[index];

    if (entry._url) |url| {
        if (frame.isSameOrigin(url)) {
            const target = frame.window.asEventTarget();
            if (frame._event_manager.hasDirectListeners(target, "popstate", frame.window._on_popstate)) {
                const event = (try PopStateEvent.initTrusted(comptime .wrap("popstate"), .{ .state = entry._state.value }, frame)).asEvent();
                try frame._event_manager.dispatchDirect(target, event, frame.window._on_popstate, .{ .context = "Pop State" });
            }
            // hashchange is queued by navigateInner.
        }
    }

    _ = try navigation.navigateInner(entry._url, .{ .traverse = index }, frame);
}

pub fn back(self: *History, frame: *Frame) !void {
    const target = try self.requireActive(frame, "Failed to execute 'back' on 'History': May not use a History object associated with a Document that is not fully active");
    try self.goInner(-1, target);
}

pub fn forward(self: *History, frame: *Frame) !void {
    const target = try self.requireActive(frame, "Failed to execute 'forward' on 'History': May not use a History object associated with a Document that is not fully active");
    try self.goInner(1, target);
}

pub fn go(self: *History, delta: ?i32, frame: *Frame) !void {
    const target = try self.requireActive(frame, "Failed to execute 'go' on 'History': May not use a History object associated with a Document that is not fully active");
    try self.goInner(delta orelse 0, target);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(History);

    pub const Meta = struct {
        pub const name = "History";
        pub var class_id: bridge.ClassId = 0;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const length = bridge.accessor(History.getLength, null, .{});
    pub const scrollRestoration = bridge.accessor(History.getScrollRestoration, History.setScrollRestoration, .{});
    pub const state = bridge.accessor(History.getState, null, .{});
    pub const pushState = bridge.function(History.pushState, .{});
    pub const replaceState = bridge.function(History.replaceState, .{});
    pub const back = bridge.function(History.back, .{});
    pub const forward = bridge.function(History.forward, .{});
    pub const go = bridge.function(History.go, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: History" {
    try testing.htmlRunner("history.html", .{});
    try testing.htmlRunner("history_url_update.html", .{});
    try testing.htmlRunner("history_browsing_context_isolation.html", .{ .timeout_ms = 8_000 });
}
