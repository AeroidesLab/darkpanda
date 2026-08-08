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
const AudioScheduledSourceNode = @import("AudioScheduledSourceNode.zig");

const Execution = js.Execution;

/// OscillatorNode — 简化实现,只跟踪 fp_audio 探针需要的参数。
/// 实际渲染在 OfflineAudioContext.startRendering 中统一进行。
pub const OscillatorNode = @This();

_proto: *AudioScheduledSourceNode,
_type: OscillatorType = .sine,
_frequency: ?*AudioParam.AudioParam = null,
_detune: ?*AudioParam.AudioParam = null,
_started: bool = false,

pub const OscillatorType = enum {
    sine,
    square,
    sawtooth,
    triangle,
    custom,

    pub fn fromString(s: []const u8) OscillatorType {
        if (std.mem.eql(u8, s, "sine")) return .sine;
        if (std.mem.eql(u8, s, "square")) return .square;
        if (std.mem.eql(u8, s, "sawtooth")) return .sawtooth;
        if (std.mem.eql(u8, s, "triangle")) return .triangle;
        if (std.mem.eql(u8, s, "custom")) return .custom;
        return .sine;
    }
};

pub fn init(context: *BaseAudioContext, exec: *const Execution) !*OscillatorNode {
    const osc = try exec._factory.audioScheduledSourceNode(context, OscillatorNode{ ._proto = undefined });
    osc._frequency = try AudioParam.init(exec, 440, -context._sample_rate / 2, context._sample_rate / 2);
    osc._detune = try AudioParam.init(exec, 0, -153600, 153600);
    return osc;
}

pub fn getType(self: *const OscillatorNode) []const u8 {
    return switch (self._type) {
        .sine => "sine",
        .square => "square",
        .sawtooth => "sawtooth",
        .triangle => "triangle",
        .custom => "custom",
    };
}

pub fn setType(self: *OscillatorNode, value: []const u8, _: *Execution) !void {
    self._type = OscillatorType.fromString(value);
}

pub fn getFrequency(self: *OscillatorNode) ?*AudioParam.AudioParam {
    return self._frequency;
}

pub fn getDetune(self: *OscillatorNode) ?*AudioParam.AudioParam {
    return self._detune;
}

pub fn start(self: *OscillatorNode) void {
    self._started = true;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OscillatorNode);

    pub const Meta = struct {
        pub const name = "OscillatorNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"type" = bridge.accessor(OscillatorNode.getType, OscillatorNode.setType, .{});
    pub const frequency = bridge.accessor(OscillatorNode.getFrequency, null, .{});
    pub const detune = bridge.accessor(OscillatorNode.getDetune, null, .{});
    pub const start = bridge.function(OscillatorNode.start, .{});
};
