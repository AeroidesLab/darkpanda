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
const BaseAudioContext = @import("BaseAudioContext.zig");
const OscillatorNode = @import("OscillatorNode.zig");
const DynamicsCompressorNode = @import("DynamicsCompressorNode.zig");
const AnalyserNode = @import("AnalyserNode.zig");
const BiquadFilterNode = @import("BiquadFilterNode.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const OfflineAudioCompletionEvent = @import("../event/OfflineAudioCompletionEvent.zig");

const Execution = js.Execution;

/// OfflineAudioContext — 简化实现,支持 fp_audio 探针所需的最小 API 子集。
///
/// 支持的调用链:
///   new OfflineAudioContext(channels, length, sampleRate)
///   ctx.createOscillator() → OscillatorNode
///   ctx.createDynamicsCompressor() → DynamicsCompressorNode
///   ctx.destination → AudioDestinationNode
///   node.connect(otherNode)  (no-op,图在渲染时重建)
///   osc.start()
///   ctx.startRendering() → Promise<AudioBuffer>
///   buf.getChannelData(0) → Float32Array
pub const OfflineAudioContext = @This();

_proto: *BaseAudioContext,
_number_of_channels: u32,
_length: u32,

/// 创建的 oscillator 节点(用于渲染时查找参数)
_oscillators: std.ArrayList(*OscillatorNode.OscillatorNode),
/// 创建的 compressor 节点
_compressors: std.ArrayList(*DynamicsCompressorNode.DynamicsCompressorNode),
_analysers: std.ArrayList(*AnalyserNode),
_on_complete: ?js.Function.Global = null,

allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    number_of_channels: u32,
    length: u32,
) OfflineAudioContext {
    return .{
        ._number_of_channels = number_of_channels,
        ._length = length,
        ._proto = undefined,
        ._oscillators = .{},
        ._compressors = .{},
        ._analysers = .{},
        .allocator = allocator,
    };
}

pub fn deinit(self: *OfflineAudioContext) void {
    self._oscillators.deinit(self.allocator);
    self._compressors.deinit(self.allocator);
    self._analysers.deinit(self.allocator);
}

pub fn asBaseAudioContext(self: *OfflineAudioContext) *BaseAudioContext {
    return self._proto;
}

pub fn getLength(self: *const OfflineAudioContext) u32 {
    return self._length;
}

/// 创建 OscillatorNode 并记录到图中
pub fn createOscillator(self: *OfflineAudioContext, exec: *const Execution) !*OscillatorNode.OscillatorNode {
    const osc = try OscillatorNode.init(self._proto, exec);
    try self._oscillators.append(self.allocator, osc);
    return osc;
}

/// 创建 DynamicsCompressorNode 并记录到图中
pub fn createDynamicsCompressor(
    self: *OfflineAudioContext,
    exec: *const Execution,
) !*DynamicsCompressorNode.DynamicsCompressorNode {
    const comp = try DynamicsCompressorNode.init(self._proto, exec);
    try self._compressors.append(self.allocator, comp);
    return comp;
}

pub fn createAnalyser(self: *OfflineAudioContext, exec: *const Execution) !*AnalyserNode {
    const analyser = try AnalyserNode.init(self._proto, exec);
    try self._analysers.append(self.allocator, analyser);
    return analyser;
}

pub fn createBiquadFilter(self: *OfflineAudioContext, exec: *const Execution) !*BiquadFilterNode {
    return BiquadFilterNode.init(self._proto, exec);
}

pub fn getOnComplete(self: *const OfflineAudioContext) ?js.Function.Global {
    return self._on_complete;
}

pub fn setOnComplete(self: *OfflineAudioContext, callback: ?js.Function.Global) void {
    self._on_complete = callback;
}

const RenderingTask = struct {
    context: *OfflineAudioContext,
    exec: *Execution,
    buffer: *AudioBuffer.AudioBuffer,
    resolver: js.PromiseResolver.Global,

    fn finish(self: *RenderingTask) void {
        self.resolver.release();
        self.exec._factory.destroy(self);
    }

    fn cancelled(raw: *anyopaque) void {
        const self: *RenderingTask = @ptrCast(@alignCast(raw));
        self.finish();
    }

    fn run(raw: *anyopaque) !?u32 {
        const self: *RenderingTask = @ptrCast(@alignCast(raw));
        defer self.finish();
        if (self.exec.isShuttingDown()) return null;

        const previous_local = self.exec.js.local;
        defer self.exec.js.local = previous_local;
        var scope: js.Local.Scope = undefined;
        self.exec.js.localScope(&scope);
        defer scope.deinit();
        self.exec.js.local = &scope.local;

        self.context._proto._state = .closed;
        const completion = try OfflineAudioCompletionEvent.initTrusted(self.buffer, self.exec.page);
        try self.exec.dispatch(
            self.context._proto.asEventTarget(),
            completion.asEvent(),
            self.context._on_complete,
            .{ .context = "OfflineAudioContext" },
        );
        self.resolver.local(&scope.local).resolve("OfflineAudioContext.startRendering", self.buffer);
        return null;
    }
};

/// startRendering — 同步渲染管线,返回 resolved Promise<AudioBuffer>。
///
/// 对于 fp_audio 探针的标准图(oscillator → compressor → destination),
/// 直接调用 render_pipeline.render_fp_audio。
/// 如果没有 compressor,回退到仅 oscillator 渲染(无压缩)。
pub fn startRendering(self: *OfflineAudioContext, exec: *Execution) !js.Promise {
    const local = exec.js.local orelse return error.InvalidStateError;
    if (self._proto._state != .suspended) return local.rejectPromise(.{ .generic_error = "Cannot start rendering more than once" });
    self._proto._state = .running;

    // 从已创建节点重建图:取第一个 oscillator 和第一个 compressor
    const osc = if (self._oscillators.items.len > 0) self._oscillators.items[0] else null;
    const comp = if (self._compressors.items.len > 0) self._compressors.items[0] else null;

    // 渲染参数 — 从 AudioParam 读取 .value
    const params = render_pipeline.RenderParams{
        .length = self._length,
        .sample_rate = self._proto._sample_rate,
        .freq = if (osc) |o| if (o._frequency) |f| f._value else 1000.0 else 1000.0,
        .threshold = if (comp) |c| if (c._threshold) |t| t._value else -50.0 else -50.0,
        .knee = if (comp) |c| if (c._knee) |k| k._value else 40.0 else 40.0,
        .ratio = if (comp) |c| if (c._ratio) |r| r._value else 12.0 else 12.0,
        .attack = if (comp) |c| if (c._attack) |a| a._value else 0.0 else 0.0,
        .release = if (comp) |c| if (c._release) |rl| rl._value else 0.2 else 0.2,
        .use_compressor = comp != null,
    };

    // 同步渲染
    const samples = render_pipeline.render_fp_audio(self.allocator, params) catch {
        return local.rejectPromise(.{ .generic_error = "Failed to render audio" });
    };

    // 创建 AudioBuffer
    const buf = exec._factory.create(AudioBuffer.fromRendered(self.allocator, samples, self._proto._sample_rate) catch {
        return local.rejectPromise(.{ .generic_error = "Failed to create AudioBuffer" });
    }) catch {
        return local.rejectPromise(.{ .generic_error = "Failed to create AudioBuffer" });
    };

    for (self._analysers.items) |analyser| analyser._rendered_samples = samples;

    const resolver = local.createPromiseResolver();
    const promise = resolver.promise();
    const persisted = try resolver.persist();
    errdefer persisted.release();
    const task = try exec._factory.create(RenderingTask{
        .context = self,
        .exec = exec,
        .buffer = buf,
        .resolver = persisted,
    });
    errdefer exec._factory.destroy(task);
    try exec.js.scheduler.add(task, RenderingTask.run, 0, .{
        .name = "OfflineAudioContext.complete",
        .finalizer = RenderingTask.cancelled,
    });
    return promise;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OfflineAudioContext);

    pub const Meta = struct {
        pub const name = "OfflineAudioContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(OfflineAudioContext.construct, .{});
    pub const length = bridge.accessor(OfflineAudioContext.getLength, null, .{});
    pub const oncomplete = bridge.accessor(OfflineAudioContext.getOnComplete, OfflineAudioContext.setOnComplete, .{});
    pub const createOscillator = bridge.function(OfflineAudioContext.createOscillator, .{});
    pub const createDynamicsCompressor = bridge.function(OfflineAudioContext.createDynamicsCompressor, .{});
    pub const createAnalyser = bridge.function(OfflineAudioContext.createAnalyser, .{});
    pub const createBiquadFilter = bridge.function(OfflineAudioContext.createBiquadFilter, .{});
    pub const startRendering = bridge.function(OfflineAudioContext.startRendering, .{
        .receiver_mode = .reject_promise,
    });
};

/// 构造函数:接收 (numberOfChannels, length, sampleRate)
fn construct(
    number_of_channels: u32,
    length: u32,
    sample_rate: f32,
    exec: *Execution,
) !*OfflineAudioContext {
    const allocator = exec.arena;
    const ctx = try exec._factory.baseAudioContext(sample_rate, OfflineAudioContext.init(
        allocator,
        number_of_channels,
        length,
    ));
    return ctx;
}

const testing = @import("../../../testing.zig");
test "WebApi: OfflineAudioContext" {
    try testing.htmlRunner("audio/offline_audio_context.html", .{ .timeout_ms = 5000 });
}
