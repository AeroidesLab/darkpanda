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

const Node = @import("Node.zig");
const EventTarget = @import("EventTarget.zig");
const Performance = @import("Performance.zig");

const String = lp.String;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub const Event = @This();

pub const _prototype_root = true;
_type: Type,
_arena: Allocator,
_bubbles: bool = false,
_cancelable: bool = false,
_composed: bool = false,
_type_string: String,
_target: ?*EventTarget = null,
_current_target: ?*EventTarget = null,
_dispatch_target: ?*EventTarget = null, // Original target for composedPath()
// Chromium builds EventPath once, before invoking any listener.  Keep the
// complete per-dispatch snapshot here so listener-side DOM mutations cannot
// change propagation, retargeting, closed-root visibility, or composedPath().
_dispatch_path: []const DispatchPathEntry = &.{},
_prevent_default: bool = false,
_stop_propagation: bool = false,
_stop_immediate_propagation: bool = false,
_event_phase: EventPhase = .none,
// Absolute monotonic platform timestamp. The JS getter converts this through
// the accessor realm's Performance time origin, as Blink does.
_time_stamp: u64,
_needs_retargeting: bool = false,
_is_trusted: bool = false,
_in_passive_listener: bool = false,
_listeners_did_throw: bool = false, // IndexedDB needs to abort on callback throw

// There's a period of time between creating an event and handing it off to v8
// where things can fail. If it does fail, we need to deinit the event. The timing
// window can be difficult to capture, so we use a reference count.
// should be 0, 1, or 2. 0
// - 0: no reference, always a transient state going to either 1 or about to be deinit'd
// - 1: either zig or v8 have a reference
// - 2: both zig and v8 have a reference
_rc: lp.RC(u8) = .{},

pub const DispatchPathEntry = struct {
    invocation_target: *EventTarget,
    adjusted_target: ?*EventTarget,
    adjusted_related_target: ?*EventTarget,
    // Closed shadow roots containing this entry, captured before dispatch.
    // Node pointers keep this representation independent of ShadowRoot's
    // concrete type and avoid a circular top-level import.
    closed_roots: []const *Node,
};

pub const EventPhase = enum(u8) {
    none = 0,
    capturing_phase = 1,
    at_target = 2,
    bubbling_phase = 3,
};

pub const Type = union(enum) {
    generic,
    error_event: *@import("event/ErrorEvent.zig"),
    custom_event: *@import("event/CustomEvent.zig"),
    message_event: *@import("event/MessageEvent.zig"),
    storage_event: *@import("event/StorageEvent.zig"),
    progress_event: *@import("event/ProgressEvent.zig"),
    navigation_current_entry_change_event: *@import("event/NavigationCurrentEntryChangeEvent.zig"),
    page_transition_event: *@import("event/PageTransitionEvent.zig"),
    pop_state_event: *@import("event/PopStateEvent.zig"),
    hash_change_event: *@import("event/HashChangeEvent.zig"),
    ui_event: *@import("event/UIEvent.zig"),
    promise_rejection_event: *@import("event/PromiseRejectionEvent.zig"),
    submit_event: *@import("event/SubmitEvent.zig"),
    form_data_event: *@import("event/FormDataEvent.zig"),
    close_event: *@import("event/CloseEvent.zig"),
    cookie_change_event: *@import("event/CookieChangeEvent.zig"),
    idb_version_change_event: *@import("storage/idb/IDBVersionChangeEvent.zig"),
    toggle_event: *@import("event/ToggleEvent.zig"),
};

pub const Options = struct {
    bubbles: bool = false,
    cancelable: bool = false,
    composed: bool = false,
};

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*Event {
    const arena = try page.getArena(.tiny, "Event");
    errdefer page.releaseArena(arena);
    const str = try String.init(arena, typ, .{});
    return initWithTrusted(arena, str, opts_, false);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*Event {
    const arena = try page.getArena(.tiny, "Event.trusted");
    errdefer page.releaseArena(arena);
    return initWithTrusted(arena, typ, opts_, true);
}

fn initWithTrusted(arena: Allocator, typ: String, opts_: ?Options, comptime trusted: bool) !*Event {
    const opts = opts_ orelse Options{};

    const event = try arena.create(Event);
    event.* = .{
        ._arena = arena,
        ._type = .generic,
        ._bubbles = opts.bubbles,
        ._time_stamp = Performance.monotonicMicroseconds(),
        ._cancelable = opts.cancelable,
        ._composed = opts.composed,
        ._type_string = typ,
        ._is_trusted = trusted,
    };
    return event;
}

pub fn initEvent(
    self: *Event,
    event_string: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
) !void {
    if (self._event_phase != .none) {
        return;
    }

    self._type_string = try String.init(self._arena, event_string, .{});
    self._bubbles = bubbles orelse false;
    self._cancelable = cancelable orelse false;
    self._stop_propagation = false;
    self._stop_immediate_propagation = false;
    self._prevent_default = false;
    // DOM's initialize-an-event algorithm always clears the trusted flag.
    self._is_trusted = false;
}

pub fn isBeingDispatched(self: *const Event) bool {
    return self._event_phase != .none;
}

pub fn acquireRef(self: *Event) void {
    self._rc.acquire();
}

pub fn deinit(self: *Event, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *Event, page: *Page) void {
    self._rc.release(self, page);
}

pub fn as(self: *Event, comptime T: type) *T {
    return self.is(T).?;
}

pub fn is(self: *Event, comptime T: type) ?*T {
    switch (self._type) {
        .generic => return if (T == Event) self else null,
        .error_event => |e| return if (T == @import("event/ErrorEvent.zig")) e else null,
        .custom_event => |e| return if (T == @import("event/CustomEvent.zig")) e else null,
        .message_event => |e| return if (T == @import("event/MessageEvent.zig")) e else null,
        .storage_event => |e| return if (T == @import("event/StorageEvent.zig")) e else null,
        .progress_event => |e| return if (T == @import("event/ProgressEvent.zig")) e else null,
        .navigation_current_entry_change_event => |e| return if (T == @import("event/NavigationCurrentEntryChangeEvent.zig")) e else null,
        .page_transition_event => |e| return if (T == @import("event/PageTransitionEvent.zig")) e else null,
        .pop_state_event => |e| return if (T == @import("event/PopStateEvent.zig")) e else null,
        .hash_change_event => |e| return if (T == @import("event/HashChangeEvent.zig")) e else null,
        .promise_rejection_event => |e| return if (T == @import("event/PromiseRejectionEvent.zig")) e else null,
        .submit_event => |e| return if (T == @import("event/SubmitEvent.zig")) e else null,
        .form_data_event => |e| return if (T == @import("event/FormDataEvent.zig")) e else null,
        .close_event => |e| return if (T == @import("event/CloseEvent.zig")) e else null,
        .cookie_change_event => |e| return if (T == @import("event/CookieChangeEvent.zig")) e else null,
        .idb_version_change_event => |e| return if (T == @import("storage/idb/IDBVersionChangeEvent.zig")) e else null,
        .toggle_event => |e| return if (T == @import("event/ToggleEvent.zig")) e else null,
        .ui_event => |e| {
            if (T == @import("event/UIEvent.zig")) {
                return e;
            }
            return e.is(T);
        },
    }
    return null;
}

pub fn getType(self: *const Event) []const u8 {
    return self._type_string.str();
}

pub fn getBubbles(self: *const Event) bool {
    return self._bubbles;
}

pub fn getCancelable(self: *const Event) bool {
    return self._cancelable;
}

pub fn getComposed(self: *const Event) bool {
    return self._composed;
}

pub fn getTarget(self: *const Event) ?*EventTarget {
    return self._target;
}

pub fn getCurrentTarget(self: *const Event) ?*EventTarget {
    return self._current_target;
}

pub fn preventDefault(self: *Event) void {
    if (self._cancelable and !self._in_passive_listener) {
        self._prevent_default = true;
    }
}

pub fn stopPropagation(self: *Event) void {
    self._stop_propagation = true;
}

pub fn stopImmediatePropagation(self: *Event) void {
    self._stop_immediate_propagation = true;
    self._stop_propagation = true;
}

pub fn getDefaultPrevented(self: *const Event) bool {
    return self._prevent_default;
}

pub fn getReturnValue(self: *const Event) bool {
    return !self._prevent_default;
}

pub fn setReturnValue(self: *Event, v: bool) void {
    if (!v) {
        // Setting returnValue=false is equivalent to preventDefault()
        if (self._cancelable and !self._in_passive_listener) {
            self._prevent_default = true;
        }
    }
}

pub fn getCancelBubble(self: *const Event) bool {
    return self._stop_propagation;
}

pub fn setCancelBubble(self: *Event) void {
    self.stopPropagation();
}

pub fn getEventPhase(self: *const Event) u8 {
    return @intFromEnum(self._event_phase);
}

pub fn getTimeStamp(self: *const Event, exec: *const Execution) f64 {
    return exec.performance().monotonicTimeToDOMHighResTimeStamp(self._time_stamp);
}

pub fn setTrusted(self: *Event) void {
    self._is_trusted = true;
}

pub fn setUntrusted(self: *Event) void {
    self._is_trusted = false;
}

pub fn getIsTrusted(self: *const Event) bool {
    return self._is_trusted;
}

pub fn composedPath(self: *Event, exec: *Execution) ![]const *EventTarget {
    // Return empty array if event is not being dispatched
    if (self._event_phase == .none) {
        return &.{};
    }

    const snapshot = self._dispatch_path;
    if (snapshot.len == 0) return &.{};

    // Visibility is also derived from the dispatch-time snapshot.  Looking at
    // getRootNode() here would make moving a node during a listener alter this
    // same event's path and could expose a formerly closed tree.
    const current_closed_roots: []const *Node = blk: {
        const current = self._current_target orelse break :blk &.{};
        for (snapshot) |entry| {
            if (entry.invocation_target == current) break :blk entry.closed_roots;
        }
        break :blk &.{};
    };

    const path = try exec.call_arena.alloc(*EventTarget, snapshot.len);
    var visible_len: usize = 0;
    for (snapshot) |entry| {
        if (!closedRootsVisibleFrom(entry.closed_roots, current_closed_roots)) continue;
        path[visible_len] = entry.invocation_target;
        visible_len += 1;
    }
    return path[0..visible_len];
}

fn closedRootsVisibleFrom(candidate_roots: []const *Node, current_roots: []const *Node) bool {
    for (candidate_roots) |candidate_root| {
        var found = false;
        for (current_roots) |current_root| {
            if (candidate_root == current_root) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub fn getRelatedTarget(self: *Event) ?*EventTarget {
    if (self.is(@import("event/MouseEvent.zig"))) |mouse| return mouse._related_target;
    if (self.is(@import("event/FocusEvent.zig"))) |focus| return focus._related_target;
    return null;
}

pub fn setRelatedTarget(self: *Event, target: ?*EventTarget) void {
    if (self.is(@import("event/MouseEvent.zig"))) |mouse| {
        mouse._related_target = target;
    } else if (self.is(@import("event/FocusEvent.zig"))) |focus| {
        focus._related_target = target;
    }
}

pub fn populateFromOptions(self: *Event, opts: anytype) void {
    self._bubbles = opts.bubbles;
    self._cancelable = opts.cancelable;
    self._composed = opts.composed;
}

pub fn inheritOptions(comptime T: type, comptime additions: anytype) type {
    var all_fields: []const std.builtin.Type.StructField = &.{};

    if (@hasField(T, "_proto")) {
        const t_fields = @typeInfo(T).@"struct".fields;

        inline for (t_fields) |field| {
            if (std.mem.eql(u8, field.name, "_proto")) {
                const ProtoType = @typeInfo(field.type).pointer.child;
                if (@hasDecl(ProtoType, "Options")) {
                    const parent_options = @typeInfo(ProtoType.Options);
                    all_fields = all_fields ++ parent_options.@"struct".fields;
                }
            }
        }
    }

    const additions_info = @typeInfo(additions);
    all_fields = all_fields ++ additions_info.@"struct".fields;

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = all_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn populatePrototypes(self: anytype, opts: anytype, trusted: bool) void {
    const T = @TypeOf(self.*);

    if (@hasField(T, "_proto")) {
        populatePrototypes(self._proto, opts, trusted);
    }

    if (@hasDecl(T, "populateFromOptions")) {
        T.populateFromOptions(self, opts);
    }

    // Set isTrusted at the Event level (base of prototype chain)
    if (T == Event or @hasField(T, "is_trusted")) {
        self._is_trusted = trusted;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Event);

    pub const Meta = struct {
        pub const name = "Event";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Event.init, .{});
    pub const @"type" = bridge.accessor(Event.getType, null, .{});
    pub const bubbles = bridge.accessor(Event.getBubbles, null, .{});
    pub const cancelable = bridge.accessor(Event.getCancelable, null, .{});
    pub const composed = bridge.accessor(Event.getComposed, null, .{});
    pub const target = bridge.accessor(Event.getTarget, null, .{});
    pub const srcElement = bridge.accessor(Event.getTarget, null, .{});
    pub const currentTarget = bridge.accessor(Event.getCurrentTarget, null, .{});
    pub const eventPhase = bridge.accessor(Event.getEventPhase, null, .{});
    pub const defaultPrevented = bridge.accessor(Event.getDefaultPrevented, null, .{});
    pub const timeStamp = bridge.accessor(Event.getTimeStamp, null, .{});
    pub const isTrusted = bridge.legacyUnforgeableAccessor(Event.getIsTrusted, null, .{});
    pub const preventDefault = bridge.function(Event.preventDefault, .{});
    pub const stopPropagation = bridge.function(Event.stopPropagation, .{});
    pub const stopImmediatePropagation = bridge.function(Event.stopImmediatePropagation, .{});
    pub const composedPath = bridge.function(Event.composedPath, .{});
    pub const initEvent = bridge.function(Event.initEvent, .{});
    // deprecated
    pub const returnValue = bridge.accessor(Event.getReturnValue, Event.setReturnValue, .{});
    // deprecated
    pub const cancelBubble = bridge.accessor(Event.getCancelBubble, Event.setCancelBubble, .{});

    // Event phase constants
    pub const NONE = bridge.property(@intFromEnum(EventPhase.none), .{ .template = true });
    pub const CAPTURING_PHASE = bridge.property(@intFromEnum(EventPhase.capturing_phase), .{ .template = true });
    pub const AT_TARGET = bridge.property(@intFromEnum(EventPhase.at_target), .{ .template = true });
    pub const BUBBLING_PHASE = bridge.property(@intFromEnum(EventPhase.bubbling_phase), .{ .template = true });
};

const testing = @import("../../testing.zig");
test "WebApi: Event Chrome 149 timestamp and unforgeable surface" {
    try testing.htmlRunner("event/chrome149_surface.html", .{});
}

// Remaining dispatch behavior is tested in event_target.
