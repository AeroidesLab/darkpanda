// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// https://html.spec.whatwg.org/multipage/interaction.html#the-useractivation-interface

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const UserActivation = @This();

pub const Snapshot = struct {
    has_been_active: bool,
    is_active: bool,
};

// Navigator owns a live view over its current browsing context.  MessageEvent
// can instead own a frozen call-time snapshot when postMessage() is invoked
// with includeUserActivation=true.  Blink uses the same UserActivation
// interface for both objects, but a snapshot must never start reading the
// receiving frame's later state.
_snapshot: ?Snapshot = null,

pub const init: UserActivation = .{};

pub fn initSnapshot(has_been_active: bool, is_active: bool) UserActivation {
    return .{ ._snapshot = .{
        .has_been_active = has_been_active,
        .is_active = is_active,
    } };
}

pub fn getHasBeenActive(self: *const UserActivation, frame: *const Frame) bool {
    if (self._snapshot) |snapshot| return snapshot.has_been_active;
    return frame.hasStickyUserActivation();
}

pub fn getIsActive(self: *const UserActivation, frame: *const Frame) bool {
    if (self._snapshot) |snapshot| return snapshot.is_active;
    return frame.hasTransientUserActivation();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(UserActivation);

    pub const Meta = struct {
        pub const name = "UserActivation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Blink installs these in this observable order.
    pub const hasBeenActive = bridge.accessor(UserActivation.getHasBeenActive, null, .{});
    pub const isActive = bridge.accessor(UserActivation.getIsActive, null, .{});
};
