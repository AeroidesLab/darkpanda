//! fp_audio 渲染管线 — 把 PeriodicWave + Oscillator + DynamicsCompressor 组合,
//! 复刻 Chromium Web Audio 的 OfflineAudioContext 渲染流程。
//!
//! 移植自 fp_audio_chromium/src/main.rs 的 render_fp_audio。

const std = @import("std");
const periodic_wave = @import("periodic_wave.zig");
const oscillator = @import("oscillator.zig");
const dynamics_compressor = @import("dynamics_compressor.zig");

pub const RENDER_QUANTUM: usize = 128;

/// 渲染参数
pub const RenderParams = struct {
    length: usize = 5000,
    sample_rate: f32 = 44100.0,
    freq: f32 = 1000.0,
    threshold: f32 = -50.0,
    knee: f32 = 40.0,
    ratio: f32 = 12.0,
    attack: f32 = 0.0,
    release: f32 = 0.2,
    /// 是否应用 DynamicsCompressor (false = 仅 oscillator 直通)
    use_compressor: bool = true,
};

/// 渲染完整管线,返回 channel 0 样本([]f32)。caller 拥有内存。
pub fn render_fp_audio(allocator: std.mem.Allocator, p: RenderParams) ![]f32 {
    // 1) sine wavetable
    var pw = periodic_wave.PeriodicWave.init(allocator, p.sample_rate);
    defer pw.deinit();
    try pw.generate_sine_tables();

    // 2) oscillator
    var osc = oscillator.Oscillator.init(&pw, p.freq, 0.0);

    // 3) compressor (2 通道)
    var comp = try dynamics_compressor.DynamicsCompressor.init(allocator, p.sample_rate, 2);
    defer comp.deinit();
    comp.set_parameter(dynamics_compressor.DynamicsCompressor.PARAM_THRESHOLD, p.threshold);
    comp.set_parameter(dynamics_compressor.DynamicsCompressor.PARAM_KNEE, p.knee);
    comp.set_parameter(dynamics_compressor.DynamicsCompressor.PARAM_RATIO, p.ratio);
    comp.set_parameter(dynamics_compressor.DynamicsCompressor.PARAM_ATTACK, p.attack);
    comp.set_parameter(dynamics_compressor.DynamicsCompressor.PARAM_RELEASE, p.release);

    // 4) 按 render quantum (128) 分块渲染,长度向上取整到 128 倍数
    const render_length = ((p.length + RENDER_QUANTUM - 1) / RENDER_QUANTUM) * RENDER_QUANTUM;
    var output = try allocator.alloc(f32, render_length);
    errdefer allocator.free(output);

    var osc_block = try allocator.alloc(f32, RENDER_QUANTUM);
    defer allocator.free(osc_block);
    var comp_block = try allocator.alloc(f32, RENDER_QUANTUM);
    defer allocator.free(comp_block);

    var rendered: usize = 0;
    while (rendered < render_length) {
        const block_size = @min(RENDER_QUANTUM, render_length - rendered);
        osc.process_block(block_size, osc_block[0..block_size]);
        if (p.use_compressor) {
            comp.process(osc_block[0..block_size], comp_block[0..block_size]);
            @memcpy(output[rendered .. rendered + block_size], comp_block[0..block_size]);
        } else {
            @memcpy(output[rendered .. rendered + block_size], osc_block[0..block_size]);
        }
        rendered += block_size;
    }
    // 截断到实际长度
    return output[0..p.length];
}

/// 计算 fp_audio = sum(|x|),用 f64 累加
pub fn compute_fp_audio(samples: []const f32) f64 {
    var s: f64 = 0.0;
    for (samples) |v| {
        s += @as(f64, @floatCast(@abs(v)));
    }
    return s;
}
