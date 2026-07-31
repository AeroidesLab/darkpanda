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
const render_pipeline = @import("render_pipeline.zig");
const brave_farbling = @import("brave_farbling.zig");

const Execution = js.Execution;

/// AudioBuffer — 持有渲染后的 PCM 样本。
/// getChannelData 返回一个 Float32Array 视图(首次调用时创建并缓存)。
/// Brave farbling 在 getChannelData 返回前对样本应用 BALANCED fudge_factor。
pub const AudioBuffer = @This();

_number_of_channels: u32,
_length: u32,
_sample_rate: f32,
/// 每个通道的样本数据(owned by arena)
_samples: []f32,
/// 缓存的 JS Float32Array(每通道一个),lazy 创建
_cached_arrays: []?js.ArrayBufferRef(.float32).Global,
/// Brave farbling helper(BALANCED 模式,默认启用)
_farbling: ?brave_farbling.BraveAudioFarblingHelper = null,

pub fn init(
    allocator: std.mem.Allocator,
    number_of_channels: u32,
    length: u32,
    sample_rate: f32,
) !AudioBuffer {
    const samples = try allocator.alloc(f32, @as(usize, number_of_channels) * @as(usize, length));
    @memset(samples, 0.0);
    const cached = try allocator.alloc(?js.ArrayBufferRef(.float32).Global, number_of_channels);
    for (cached) |*c| c.* = null;
    return .{
        ._number_of_channels = number_of_channels,
        ._length = length,
        ._sample_rate = sample_rate,
        ._samples = samples,
        ._cached_arrays = cached,
    };
}

/// 从已有的渲染结果创建(单通道)。
/// 默认启用 Brave BALANCED farbling,每次用随机 token 使结果不可复现。
pub fn fromRendered(allocator: std.mem.Allocator, samples: []f32, sample_rate: f32) !AudioBuffer {
    const cached = try allocator.alloc(?js.ArrayBufferRef(.float32).Global, 1);
    cached[0] = null;
    var token_high: u64 = 0;
    var token_low: u64 = 0;
    token_high = std.crypto.random.int(u64);
    token_low = std.crypto.random.int(u64);
    return .{
        ._number_of_channels = 1,
        ._length = @intCast(samples.len),
        ._sample_rate = sample_rate,
        ._samples = samples,
        ._cached_arrays = cached,
        ._farbling = brave_farbling.BraveAudioFarblingHelper.from_token(
            .{ .high = token_high, .low = token_low },
            .balanced,
        ),
    };
}

pub fn getNumberOfChannels(self: *const AudioBuffer) u32 {
    return self._number_of_channels;
}

pub fn getLength(self: *const AudioBuffer) u32 {
    return self._length;
}

pub fn getSampleRate(self: *const AudioBuffer) f32 {
    return self._sample_rate;
}

/// 返回 channel 0 的 Float32Array。每次调用返回同一个缓存的数组对象
/// (匹配 Chromium AudioBuffer.getChannelData 的语义)。
pub fn getChannelData(self: *AudioBuffer, channel: u32, exec: *Execution) !js.Object {
    if (channel >= self._number_of_channels) {
        return error.IndexSizeError;
    }
    const local = exec.js.local orelse return error.InvalidStateError;

    // 如果已缓存,返回缓存的 local 视图
    if (self._cached_arrays[channel]) |global| {
        const arr = global.local(local);
        return .{ .local = local, .handle = @ptrCast(arr.handle) };
    }

    // 创建新的 Float32Array 并拷贝数据
    const len = @as(usize, self._length);
    const arr = local.createTypedArray(.float32, len);
    const slice = arr.slice();
    const offset = @as(usize, channel) * len;

    // Brave farbling: 在 getChannelData 返回前对样本应用 fudge_factor
    // (对应 Brave 在 AudioBuffer::getChannelData 处的注入)。
    if (self._farbling) |helper| {
        helper.farble_audio_channel(self._samples[offset .. offset + len]);
    }

    @memcpy(slice, self._samples[offset .. offset + len]);

    // 持久化缓存
    self._cached_arrays[channel] = try arr.persist();
    return .{ .local = local, .handle = @ptrCast(arr.handle) };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioBuffer);

    pub const Meta = struct {
        pub const name = "AudioBuffer";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const sampleRate = bridge.accessor(AudioBuffer.getSampleRate, null, .{});
    pub const length = bridge.accessor(AudioBuffer.getLength, null, .{});
    pub const numberOfChannels = bridge.accessor(AudioBuffer.getNumberOfChannels, null, .{});
    pub const getChannelData = bridge.function(AudioBuffer.getChannelData, .{});
};
