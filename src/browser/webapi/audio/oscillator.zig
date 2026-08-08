//! OscillatorHandler — 复刻 oscillator_handler.cc 的 KRate 标量路径。
//!
//! 恒定频率走 ProcessKRateScalar 分支,virtual_read_index 累加 wrap。
//!
//! 关键精度细节(对齐 Chromium 源码):
//!   - virtual_read_index 是 **double**(Chromium `double virtual_read_index`),
//!     不是 float。这是 1e-4 级样本偏差的主要来源:float 累加 5000 步会丢精度。
//!   - inv_periodic_wave_size 也是 **double**(`1.0 / periodic_wave_size`)。
//!   - incr 是 float(`frequency * rate_scale`)。
//!   - 插值本身在 float 域(static_cast<float>(virtual_read_index) - read_index_0)。
//!
//! 移植自 fp_audio_chromium/src/oscillator.rs。

const periodic_wave = @import("periodic_wave.zig");

pub const Oscillator = struct {
    pw: *const periodic_wave.PeriodicWave,
    clamped_frequency: f32,
    virtual_read_index: f64,

    pub fn init(pw: *const periodic_wave.PeriodicWave, frequency: f32, detune: f32) Oscillator {
        const detune_scale = std_math_powf(2.0, detune / 1200.0);
        const freq = frequency * detune_scale;
        const nyquist = pw.sample_rate / 2.0;
        const clamped = @min(@abs(freq), nyquist);
        return .{
            .pw = pw,
            .clamped_frequency = clamped,
            .virtual_read_index = 0.0,
        };
    }

    /// 生成 num_samples 个样本 (KRate, 频率不变),写入 out。
    /// 复刻 OscillatorHandler::ProcessKRateScalar 的线性插值路径。
    pub fn process_block(self: *Oscillator, num_samples: usize, out: []f32) void {
        const pw_size = self.pw.periodic_wave_size;
        // Chromium: const double inv_periodic_wave_size = 1.0 / periodic_wave_size;
        const inv_pw_size: f64 = 1.0 / @as(f64, @floatFromInt(pw_size));
        const read_index_mask = pw_size - 1;

        const wave = self.pw.wave_data_for_frequency(self.clamped_frequency);
        const lower = wave.lower;
        const higher = wave.higher;
        const table_interp = wave.interp;
        // Chromium: const float incr = frequency * rate_scale;
        const incr: f32 = self.clamped_frequency * self.pw.rate_scale;

        var v_index: f64 = self.virtual_read_index;

        if (incr == 0) {
            @memset(out[0..num_samples], 0);
            return;
        }

        // ponytail: two-point interpolation also covers sub-21.5Hz input;
        // port Chromium's higher-order path only if low-frequency audio fidelity
        // becomes observable outside fingerprint probes.
        for (0..num_samples) |k| {
            const read_index_0 = @as(usize, @intCast(@as(u64, @intFromFloat(v_index)))) & read_index_mask;
            const read_index_1 = (read_index_0 + 1) & read_index_mask;
            const s1_lower = lower[read_index_0];
            const s2_lower = lower[read_index_1];
            const s1_higher = higher[read_index_0];
            const s2_higher = higher[read_index_1];
            const interp_factor: f32 = @as(f32, @floatCast(v_index)) - @as(f32, @floatFromInt(read_index_0));
            const sample_higher = s1_higher + interp_factor * (s2_higher - s1_higher);
            const sample_lower = s1_lower + interp_factor * (s2_lower - s1_lower);
            out[k] = sample_higher + table_interp * (sample_lower - sample_higher);
            v_index += @as(f64, incr);
            v_index -= @floor(v_index * inv_pw_size) * @as(f64, @floatFromInt(pw_size));
        }
        self.virtual_read_index = v_index;
    }
};

// Zig std 没有 powf(f32) 的直接别名,用 std.math.pow
fn std_math_powf(base: f32, exp: f32) f32 {
    return std.math.pow(f32, base, exp);
}

const std = @import("std");
