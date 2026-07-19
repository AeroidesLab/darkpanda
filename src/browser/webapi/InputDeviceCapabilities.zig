// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

const js = @import("../js/js.zig");

const Execution = js.Execution;
const InputDeviceCapabilities = @This();

_fires_touch_events: bool = false,

pub const Options = struct {
    firesTouchEvents: bool = false,
};

pub fn init(opts_: ?Options, exec: *Execution) !*InputDeviceCapabilities {
    const opts = opts_ orelse Options{};
    return exec._factory.create(fromBool(opts.firesTouchEvents));
}

pub fn fromBool(fires_touch_events: bool) InputDeviceCapabilities {
    return .{ ._fires_touch_events = fires_touch_events };
}

pub fn getFiresTouchEvents(self: *const InputDeviceCapabilities) bool {
    return self._fires_touch_events;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(InputDeviceCapabilities);

    pub const Meta = struct {
        pub const name = "InputDeviceCapabilities";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(InputDeviceCapabilities.init, .{});
    pub const firesTouchEvents = bridge.accessor(InputDeviceCapabilities.getFiresTouchEvents, null, .{});
};
