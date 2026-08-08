// Copyright (C) 2026 Lightpanda contributors

const std = @import("std");
const js = @import("../../js/js.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioNode = @import("AudioNode.zig");
const AudioParam = @import("AudioParam.zig");

const BiquadFilterNode = @This();

_proto: *AudioNode,
_frequency: *AudioParam.AudioParam = undefined,
_detune: *AudioParam.AudioParam = undefined,
_q: *AudioParam.AudioParam = undefined,
_gain: *AudioParam.AudioParam = undefined,

pub fn init(context: *BaseAudioContext, exec: *const js.Execution) !*BiquadFilterNode {
    const self = try exec._factory.audioNode(context, BiquadFilterNode{ ._proto = undefined });
    self._frequency = try AudioParam.init(exec, 350, 0, context._sample_rate / 2);
    self._detune = try AudioParam.init(exec, 0, -153600, 153600);
    self._q = try AudioParam.init(exec, 1, -std.math.floatMax(f32), std.math.floatMax(f32));
    self._gain = try AudioParam.init(exec, 0, -std.math.floatMax(f32), 1541.273681640625);
    return self;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BiquadFilterNode);

    pub const Meta = struct {
        pub const name = "BiquadFilterNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const frequency = bridge.accessor(struct {
        fn get(self: *BiquadFilterNode) *AudioParam.AudioParam {
            return self._frequency;
        }
    }.get, null, .{});
    pub const detune = bridge.accessor(struct {
        fn get(self: *BiquadFilterNode) *AudioParam.AudioParam {
            return self._detune;
        }
    }.get, null, .{});
    pub const Q = bridge.accessor(struct {
        fn get(self: *BiquadFilterNode) *AudioParam.AudioParam {
            return self._q;
        }
    }.get, null, .{});
    pub const gain = bridge.accessor(struct {
        fn get(self: *BiquadFilterNode) *AudioParam.AudioParam {
            return self._gain;
        }
    }.get, null, .{});
};
