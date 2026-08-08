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
const js = @import("../../js/js.zig");
const AudioParam = @import("AudioParam.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioNode = @import("AudioNode.zig");

const Execution = js.Execution;

/// DynamicsCompressorNode — 简化实现,只跟踪 fp_audio 探针需要的参数。
/// 实际渲染在 OfflineAudioContext.startRendering 中统一进行。
pub const DynamicsCompressorNode = @This();

_proto: *AudioNode,
_threshold: ?*AudioParam.AudioParam = null,
_knee: ?*AudioParam.AudioParam = null,
_ratio: ?*AudioParam.AudioParam = null,
_attack: ?*AudioParam.AudioParam = null,
_release: ?*AudioParam.AudioParam = null,

pub fn init(context: *BaseAudioContext, exec: *const Execution) !*DynamicsCompressorNode {
    const comp = try exec._factory.audioNode(context, DynamicsCompressorNode{ ._proto = undefined });
    comp._threshold = try AudioParam.init(exec, -24, -100, 0);
    comp._knee = try AudioParam.init(exec, 30, 0, 40);
    comp._ratio = try AudioParam.init(exec, 12, 1, 20);
    comp._attack = try AudioParam.init(exec, 0.003, 0, 1);
    comp._release = try AudioParam.init(exec, 0.250, 0, 1);
    return comp;
}

pub fn getThreshold(self: *DynamicsCompressorNode) ?*AudioParam.AudioParam {
    return self._threshold;
}

pub fn getKnee(self: *DynamicsCompressorNode) ?*AudioParam.AudioParam {
    return self._knee;
}

pub fn getRatio(self: *DynamicsCompressorNode) ?*AudioParam.AudioParam {
    return self._ratio;
}

pub fn getAttack(self: *DynamicsCompressorNode) ?*AudioParam.AudioParam {
    return self._attack;
}

pub fn getRelease(self: *DynamicsCompressorNode) ?*AudioParam.AudioParam {
    return self._release;
}

pub fn getReduction(_: *DynamicsCompressorNode) f32 {
    return 0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DynamicsCompressorNode);

    pub const Meta = struct {
        pub const name = "DynamicsCompressorNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const threshold = bridge.accessor(DynamicsCompressorNode.getThreshold, null, .{});
    pub const knee = bridge.accessor(DynamicsCompressorNode.getKnee, null, .{});
    pub const ratio = bridge.accessor(DynamicsCompressorNode.getRatio, null, .{});
    pub const attack = bridge.accessor(DynamicsCompressorNode.getAttack, null, .{});
    pub const release = bridge.accessor(DynamicsCompressorNode.getRelease, null, .{});
    pub const reduction = bridge.accessor(DynamicsCompressorNode.getReduction, null, .{});
};
