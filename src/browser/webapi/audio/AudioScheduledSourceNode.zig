// Copyright (C) 2026 Lightpanda contributors

const js = @import("../../js/js.zig");
const AudioNode = @import("AudioNode.zig");

const AudioScheduledSourceNode = @This();

_proto: *AudioNode,
_type: Type,

pub const Type = union(enum) {
    oscillator: *@import("OscillatorNode.zig"),
};

pub fn asAudioNode(self: *AudioScheduledSourceNode) *AudioNode {
    return self._proto;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioScheduledSourceNode);

    pub const Meta = struct {
        pub const name = "AudioScheduledSourceNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
