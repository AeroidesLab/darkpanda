// Copyright (C) 2026 Lightpanda contributors

const js = @import("../../js/js.zig");
const EventTarget = @import("../EventTarget.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const AudioNode = @This();

_proto: *EventTarget,
_type: Type,
_context: *BaseAudioContext = undefined,

pub const Type = union(enum) {
    scheduled_source: *@import("AudioScheduledSourceNode.zig"),
    analyser: *@import("AnalyserNode.zig"),
    biquad_filter: *@import("BiquadFilterNode.zig"),
    dynamics_compressor: *@import("DynamicsCompressorNode.zig"),
    destination: *@import("AudioDestinationNode.zig"),
};

pub fn asEventTarget(self: *AudioNode) *EventTarget {
    return self._proto;
}

pub fn getContext(self: *AudioNode) *BaseAudioContext {
    return self._context;
}

pub fn connect(_: *AudioNode, destination: js.Value) js.Value {
    return destination;
}

pub fn disconnect(_: *AudioNode) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioNode);

    pub const Meta = struct {
        pub const name = "AudioNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const context = bridge.accessor(AudioNode.getContext, null, .{});
    pub const numberOfInputs = bridge.constantAccessor(1);
    pub const numberOfOutputs = bridge.constantAccessor(1);
    pub const channelCount = bridge.constantAccessor(2);
    pub const channelCountMode = bridge.constantAccessor("max");
    pub const channelInterpretation = bridge.constantAccessor("speakers");
    pub const connect = bridge.function(AudioNode.connect, .{ .required_args = 1 });
    pub const disconnect = bridge.function(AudioNode.disconnect, .{});
};
