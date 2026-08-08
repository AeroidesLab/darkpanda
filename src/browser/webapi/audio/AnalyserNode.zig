// Copyright (C) 2026 Lightpanda contributors

const std = @import("std");
const js = @import("../../js/js.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioNode = @import("AudioNode.zig");

const AnalyserNode = @This();

_proto: *AudioNode,
_fft_size: u32 = 2048,
_min_decibels: f64 = -100,
_max_decibels: f64 = -30,
_smoothing_time_constant: f64 = 0.8,
_rendered_samples: ?[]const f32 = null,

pub fn init(context: *BaseAudioContext, exec: *const js.Execution) !*AnalyserNode {
    return exec._factory.audioNode(context, AnalyserNode{ ._proto = undefined });
}

pub fn getFftSize(self: *const AnalyserNode) u32 {
    return self._fft_size;
}

pub fn getFrequencyBinCount(self: *const AnalyserNode) u32 {
    return self._fft_size / 2;
}

pub fn getMinDecibels(self: *const AnalyserNode) f64 {
    return self._min_decibels;
}

pub fn getMaxDecibels(self: *const AnalyserNode) f64 {
    return self._max_decibels;
}

pub fn getSmoothingTimeConstant(self: *const AnalyserNode) f64 {
    return self._smoothing_time_constant;
}

pub fn getFloatFrequencyData(self: *AnalyserNode, destination: js.TypedArray(f32)) void {
    const values = @constCast(destination.values);
    @memset(values, -std.math.inf(f32));
    const samples = self._rendered_samples orelse return;
    const bins = @min(values.len, self.getFrequencyBinCount());
    const size: usize = @intCast(self._fft_size);
    if (samples.len < size) return;
    const input = samples[samples.len - size ..];
    for (0..bins) |bin| {
        var real: f64 = 0;
        var imaginary: f64 = 0;
        for (input, 0..) |sample, index| {
            const phase = 2 * std.math.pi * @as(f64, @floatFromInt(bin * index)) / @as(f64, @floatFromInt(size));
            const window = 0.42 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(size - 1))) +
                0.08 * @cos(4 * std.math.pi * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(size - 1)));
            real += @as(f64, sample) * window * @cos(phase);
            imaginary -= @as(f64, sample) * window * @sin(phase);
        }
        const magnitude = @sqrt(real * real + imaginary * imaginary) / @as(f64, @floatFromInt(size));
        const decibels = if (magnitude > 0) 20 * @log10(magnitude) else self._min_decibels;
        values[bin] = @floatCast(std.math.clamp(decibels, self._min_decibels, self._max_decibels));
    }
}

pub fn getFloatTimeDomainData(self: *AnalyserNode, destination: js.TypedArray(f32)) void {
    const values = @constCast(destination.values);
    @memset(values, 0);
    const samples = self._rendered_samples orelse return;
    const count = @min(values.len, samples.len);
    @memcpy(values[0..count], samples[samples.len - count ..]);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnalyserNode);

    pub const Meta = struct {
        pub const name = "AnalyserNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const fftSize = bridge.accessor(AnalyserNode.getFftSize, null, .{});
    pub const frequencyBinCount = bridge.accessor(AnalyserNode.getFrequencyBinCount, null, .{});
    pub const minDecibels = bridge.accessor(AnalyserNode.getMinDecibels, null, .{});
    pub const maxDecibels = bridge.accessor(AnalyserNode.getMaxDecibels, null, .{});
    pub const smoothingTimeConstant = bridge.accessor(AnalyserNode.getSmoothingTimeConstant, null, .{});
    pub const getFloatFrequencyData = bridge.function(AnalyserNode.getFloatFrequencyData, .{ .required_args = 1 });
    pub const getFloatTimeDomainData = bridge.function(AnalyserNode.getFloatTimeDomainData, .{ .required_args = 1 });
};
