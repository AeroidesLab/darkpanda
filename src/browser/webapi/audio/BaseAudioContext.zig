// Copyright (C) 2026 Lightpanda contributors

const js = @import("../../js/js.zig");
const EventTarget = @import("../EventTarget.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");

const BaseAudioContext = @This();

_proto: *EventTarget,
_type: Type,
_sample_rate: f32 = 0,
_state: State = .suspended,
_destination: ?*AudioDestinationNode = null,

pub const Type = union(enum) {
    offline: *@import("OfflineAudioContext.zig"),
};

pub const State = enum { suspended, running, closed };

pub fn asEventTarget(self: *BaseAudioContext) *EventTarget {
    return self._proto;
}

pub fn getSampleRate(self: *const BaseAudioContext) f32 {
    return self._sample_rate;
}

pub fn getState(self: *const BaseAudioContext) []const u8 {
    return @tagName(self._state);
}

pub fn getCurrentTime(_: *const BaseAudioContext) f64 {
    return 0;
}

pub fn getDestination(self: *BaseAudioContext, exec: *const js.Execution) !*AudioDestinationNode {
    if (self._destination) |destination| return destination;
    const destination = try AudioDestinationNode.init(self, exec);
    self._destination = destination;
    return destination;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BaseAudioContext);

    pub const Meta = struct {
        pub const name = "BaseAudioContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const sampleRate = bridge.accessor(BaseAudioContext.getSampleRate, null, .{});
    pub const currentTime = bridge.accessor(BaseAudioContext.getCurrentTime, null, .{});
    pub const state = bridge.accessor(BaseAudioContext.getState, null, .{});
    pub const destination = bridge.accessor(BaseAudioContext.getDestination, null, .{});
};
