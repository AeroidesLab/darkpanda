//! DynamicsCompressor — 忠实移植 dynamics_compressor.cc。
//!
//! 精度策略严格对齐 Chromium 源码:
//!   - audio_utilities::DecibelsToLinear / LinearToDecibels: f32 (powf/log10f)
//!   - audio_utilities::DiscreteTimeConstantForSampleRate: 接收 double,内部
//!     `fdlibm::exp(-1/(sample_rate*time_constant))`,结果 double。Chromium 把
//!     它赋给 metering_release_k_(float),所以这里 f64 计算后转 f32。
//!   - KneeCurve: `exp(static_cast<double>(-k*(x-threshold)))` — **double exp**,
//!     再转回 float。Rust 用 f64::exp。
//!   - post_warp_compressor_gain: `sin(static_cast<double>(kPiOverTwo*gain))`
//!     — **double sin**,再转回 float。
//!   - linear_post_gain: `fdlibm::powf(1/Saturate(1,k), 0.6f)` — f32 powf。
//!   - scaled_desired_gain: `fdlibm::asinf(desired_gain)/kPiOverTwoFloat` — f32 asin。
//!   - attack envelope_rate: `fdlibm::powf(x, 1/attack_frames)` — f32 powf。
//! 单通道输入内部按 2 通道处理(两路相同),detector 取 max(|L|,|R|) = |mono|。
//!
//! 移植自 fp_audio_chromium/src/dynamics_compressor.rs。

const std = @import("std");

// audio_utilities.cc — 这些函数全部在 f32 域:
inline fn decibels_to_linear(db: f32) f32 {
    return std.math.pow(f32, 10.0, 0.05 * db);
}
inline fn linear_to_decibels(linear: f32) f32 {
    return 20.0 * @log10(linear);
}
/// Chromium 的 DiscreteTimeConstantForSampleRate 签名是 double,double,
/// 内部 `fdlibm::exp(-1/(sample_rate*time_constant))`(double exp),
/// 返回 double。调用方把它赋给 float metering_release_k_,所以这里 f64
/// 计算后转 f32。
inline fn discrete_time_constant_for_sample_rate(
    time_constant: f64,
    sample_rate: f64,
) f32 {
    return @floatCast(1.0 - @exp(-1.0 / (sample_rate * time_constant)));
}

// dynamics_compressor.cc 常量
const METERING_RELEASE_TIME_CONSTANT: f32 = 0.325;
const PRE_DELAY: f32 = 0.006;
const RELEASE_ZONE1: f32 = 0.09;
const RELEASE_ZONE2: f32 = 0.16;
const RELEASE_ZONE3: f32 = 0.42;
const RELEASE_ZONE4: f32 = 0.98;
const A_BASE: f32 = 0.9999999999999998 * RELEASE_ZONE1 +
    1.8432219684323923e-16 * RELEASE_ZONE2 -
    1.9373394351676423e-16 * RELEASE_ZONE3 +
    8.824516011816245e-18 * RELEASE_ZONE4;
const B_BASE: f32 = -1.5788320352845888 * RELEASE_ZONE1 +
    2.3305837032074286 * RELEASE_ZONE2 -
    0.9141194204840429 * RELEASE_ZONE3 +
    0.1623677525612032 * RELEASE_ZONE4;
const C_BASE: f32 = 0.5334142869106424 * RELEASE_ZONE1 -
    1.272736789213631 * RELEASE_ZONE2 +
    0.9258856042207512 * RELEASE_ZONE3 -
    0.18656310191776226 * RELEASE_ZONE4;
const D_BASE: f32 = 0.08783463138207234 * RELEASE_ZONE1 -
    0.1694162967925622 * RELEASE_ZONE2 +
    0.08588057951595272 * RELEASE_ZONE3 -
    0.00429891410546283 * RELEASE_ZONE4;
const E_BASE: f32 = -0.042416883008123074 * RELEASE_ZONE1 +
    0.1115693827987602 * RELEASE_ZONE2 -
    0.09764676325265872 * RELEASE_ZONE3 +
    0.028494263462021576 * RELEASE_ZONE4;
const SAT_RELEASE_TIME: f32 = 0.0025;
const MAX_PRE_DELAY_FRAMES: usize = 1024;
const MAX_PRE_DELAY_FRAMES_MASK: usize = MAX_PRE_DELAY_FRAMES - 1;
const DEFAULT_PRE_DELAY_FRAMES: usize = 256;
const NUMBER_OF_DIVISION_FRAMES: usize = 32;
const PI_OVER_TWO: f32 = std.math.pi / 2.0;

inline fn ensure_finite(x: f32, default: f32) f32 {
    if (std.math.isNan(x) or std.math.isInf(x)) {
        return default;
    }
    return x;
}

/// x86 FTZ:subnormal f32 清零
inline fn flush_denormal(f: f32) f32 {
    // f32 normal 最小值 ~1.175e-38,subnormal 更小
    if (f != 0.0 and @abs(f) < 1.17549435e-38) {
        return 0.0;
    }
    return f;
}

pub const DynamicsCompressor = struct {
    sample_rate: f32,
    parameters: [6]f32,
    detector_average: f32,
    compressor_gain: f32,
    metering_release_k: f32,
    metering_gain: f32,
    last_pre_delay_frames: usize,
    pre_delay_buffers: [][]f32,
    pre_delay_read_index: usize,
    pre_delay_write_index: usize,
    db_max_attack_compression_diff: f32,
    // 静态曲线参数
    ratio: f32,
    slope: f32,
    linear_threshold: f32,
    db_threshold: f32,
    db_knee: f32,
    knee_threshold: f32,
    db_knee_threshold: f32,
    db_yknee_threshold: f32,
    knee: f32,

    allocator: std.mem.Allocator,

    // parameter id
    pub const PARAM_THRESHOLD: usize = 0;
    pub const PARAM_KNEE: usize = 1;
    pub const PARAM_RATIO: usize = 2;
    pub const PARAM_ATTACK: usize = 3;
    pub const PARAM_RELEASE: usize = 4;
    pub const PARAM_REDUCTION: usize = 5;

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32, number_of_channels: usize) !DynamicsCompressor {
        const pre_delay_buffers = try allocator.alloc([]f32, number_of_channels);
        for (pre_delay_buffers) |*buf| {
            buf.* = try allocator.alloc(f32, MAX_PRE_DELAY_FRAMES);
            @memset(buf.*, 0.0);
        }
        var c = DynamicsCompressor{
            .sample_rate = sample_rate,
            .parameters = [_]f32{0.0} ** 6,
            .detector_average = 0.0,
            .compressor_gain = 1.0,
            .metering_release_k = discrete_time_constant_for_sample_rate(
                @floatCast(METERING_RELEASE_TIME_CONSTANT),
                @floatCast(sample_rate),
            ),
            .metering_gain = 1.0,
            .last_pre_delay_frames = DEFAULT_PRE_DELAY_FRAMES,
            .pre_delay_buffers = pre_delay_buffers,
            .pre_delay_read_index = 0,
            .pre_delay_write_index = DEFAULT_PRE_DELAY_FRAMES,
            .db_max_attack_compression_diff = -1.0,
            .ratio = -1.0,
            .slope = -1.0,
            .linear_threshold = -1.0,
            .db_threshold = -1.0,
            .db_knee = -1.0,
            .knee_threshold = -1.0,
            .db_knee_threshold = -1.0,
            .db_yknee_threshold = -1.0,
            .knee = -1.0,
            .allocator = allocator,
        };
        c.initialize_parameters();
        return c;
    }

    pub fn deinit(self: *DynamicsCompressor) void {
        for (self.pre_delay_buffers) |buf| {
            self.allocator.free(buf);
        }
        self.allocator.free(self.pre_delay_buffers);
    }

    fn initialize_parameters(self: *DynamicsCompressor) void {
        self.parameters[PARAM_THRESHOLD] = -24.0;
        self.parameters[PARAM_KNEE] = 30.0;
        self.parameters[PARAM_RATIO] = 12.0;
        self.parameters[PARAM_ATTACK] = 0.003;
        self.parameters[PARAM_RELEASE] = 0.250;
        self.parameters[PARAM_REDUCTION] = 0.0;
    }

    pub fn set_parameter(self: *DynamicsCompressor, param_id: usize, value: f32) void {
        self.parameters[param_id] = value;
    }

    // 静态曲线
    fn knee_curve(self: *const DynamicsCompressor, x: f32, k: f32) f32 {
        if (x < self.linear_threshold) {
            return x;
        }
        // Chromium: linear_threshold_ + (1 - exp(double(-k*(x-threshold)))) / k
        //   -k * (x - linear_threshold_) 全部是 float 运算,结果 float,
        //   再 static_cast<double> 后用 double exp,最后转回 float。
        const exponent_f32: f32 = -k * (x - self.linear_threshold);
        const term: f32 = @floatCast(1.0 - @exp(@as(f64, exponent_f32)));
        return self.linear_threshold + term / k;
    }

    fn saturate(self: *const DynamicsCompressor, x: f32, k: f32) f32 {
        if (x < self.knee_threshold) {
            return self.knee_curve(x, k);
        }
        const db_x = linear_to_decibels(x);
        const db_y = self.db_yknee_threshold + self.slope * (db_x - self.db_knee_threshold);
        return decibels_to_linear(db_y);
    }

    fn k_at_slope(self: *const DynamicsCompressor, desired_slope: f32) f32 {
        const db_x = self.db_threshold + self.db_knee;
        const x = decibels_to_linear(db_x);
        var x2: f32 = 1.0;
        var db_x2: f32 = 0.0;
        if (!(x < self.linear_threshold)) {
            x2 = x * 1.001;
            db_x2 = linear_to_decibels(x2);
        }
        var min_k: f32 = 0.1;
        var max_k: f32 = 10000.0;
        var k: f32 = 5.0;
        var slope: f32 = 1.0;
        for (0..15) |_| {
            if (!(x < self.linear_threshold)) {
                const db_y = linear_to_decibels(self.knee_curve(x, k));
                const db_y2 = linear_to_decibels(self.knee_curve(x2, k));
                slope = (db_y2 - db_y) / (db_x2 - db_x);
            }
            if (slope < desired_slope) {
                max_k = k;
            } else {
                min_k = k;
            }
            k = @sqrt(min_k * max_k);
        }
        return k;
    }

    fn update_static_curve_parameters(
        self: *DynamicsCompressor,
        db_threshold: f32,
        db_knee: f32,
        ratio: f32,
    ) f32 {
        if (db_threshold != self.db_threshold or db_knee != self.db_knee or ratio != self.ratio) {
            self.db_threshold = db_threshold;
            self.linear_threshold = decibels_to_linear(db_threshold);
            self.db_knee = db_knee;
            self.ratio = ratio;
            self.slope = 1.0 / ratio;
            const k = self.k_at_slope(1.0 / ratio);
            self.db_knee_threshold = db_threshold + db_knee;
            self.knee_threshold = decibels_to_linear(self.db_knee_threshold);
            self.db_yknee_threshold = linear_to_decibels(self.knee_curve(self.knee_threshold, k));
            self.knee = k;
        }
        return self.knee;
    }

    fn set_pre_delay_time(self: *DynamicsCompressor, pre_delay_time: f32) void {
        var pre_delay_frames: usize = @intFromFloat(pre_delay_time * self.sample_rate);
        if (pre_delay_frames > MAX_PRE_DELAY_FRAMES - 1) {
            pre_delay_frames = MAX_PRE_DELAY_FRAMES - 1;
        }
        if (self.last_pre_delay_frames != pre_delay_frames) {
            self.last_pre_delay_frames = pre_delay_frames;
            for (self.pre_delay_buffers) |*buf| {
                @memset(buf.*, 0.0);
            }
            self.pre_delay_read_index = 0;
            self.pre_delay_write_index = pre_delay_frames;
        }
    }

    /// 处理单通道 source,返回单通道 destination(写入 out)。
    /// 源码 number_of_channels=2,source_bus 可能 1 通道(上混)。
    /// 这里单通道按 2 通道处理(两路相同),detector 取 max=|mono|,输出取第 0 路。
    pub fn process(self: *DynamicsCompressor, source: []const f32, out: []f32) void {
        const frames_to_process = source.len;
        const db_threshold = self.parameters[PARAM_THRESHOLD];
        const db_knee = self.parameters[PARAM_KNEE];
        const ratio = self.parameters[PARAM_RATIO];
        const attack_time = self.parameters[PARAM_ATTACK];
        const release_time = self.parameters[PARAM_RELEASE];

        const k = self.update_static_curve_parameters(db_threshold, db_knee, ratio);
        const linear_post_gain = std.math.pow(f32, 1.0 / self.saturate(1.0, k), 0.6);

        const attack_frames = @max(attack_time, 0.001) * self.sample_rate;
        const release_frames = self.sample_rate * release_time;
        const sat_release_frames = SAT_RELEASE_TIME * self.sample_rate;

        const a = release_frames * A_BASE;
        const b = release_frames * B_BASE;
        const c = release_frames * C_BASE;
        const d = release_frames * D_BASE;
        const e = release_frames * E_BASE;

        self.set_pre_delay_time(PRE_DELAY);

        const number_of_divisions = frames_to_process / NUMBER_OF_DIVISION_FRAMES;
        var frame_index: usize = 0;

        for (0..number_of_divisions) |_| {
            self.detector_average = ensure_finite(self.detector_average, 1.0);
            const desired_gain = self.detector_average;
            // Chromium: fdlibm::asinf(desired_gain) / kPiOverTwoFloat — f32 asin
            const scaled_desired_gain = std.math.asin(desired_gain) / PI_OVER_TWO;

            const is_releasing = scaled_desired_gain > self.compressor_gain;
            // 对齐 Chromium 的分支结构:先按 scaled_desired_gain==0 确定
            // db_compression_diff,再统一走 is_releasing 分支计算 envelope_rate。
            const db_compression_diff = if (scaled_desired_gain == 0.0)
                if (is_releasing) @as(f32, -1.0) else @as(f32, 1.0)
            else
                linear_to_decibels(self.compressor_gain / scaled_desired_gain);

            const envelope_rate: f32 = blk: {
                if (is_releasing) {
                    // Release 模式:db_compression_diff 应为负 dB
                    self.db_max_attack_compression_diff = -1.0;
                    const dcd = ensure_finite(db_compression_diff, -1.0);
                    var x = dcd;
                    x = @max(@min(x, 0.0), -12.0);
                    x = 0.25 * (x + 12.0);
                    const x2 = x * x;
                    const x3 = x2 * x;
                    const x4 = x2 * x2;
                    const calc_release_frames = a + b * x + c * x2 + d * x3 + e * x4;
                    const db_per_frame = 5.0 / calc_release_frames;
                    break :blk decibels_to_linear(db_per_frame);
                } else {
                    // Attack 模式:db_compression_diff 应为正 dB
                    const dcd = ensure_finite(db_compression_diff, 1.0);
                    if (self.db_max_attack_compression_diff == -1.0 or
                        self.db_max_attack_compression_diff < dcd)
                    {
                        self.db_max_attack_compression_diff = dcd;
                    }
                    const db_eff_atten_diff = @max(@as(f32, 0.5), self.db_max_attack_compression_diff);
                    const x = 0.25 / db_eff_atten_diff;
                    break :blk 1.0 - std.math.pow(f32, x, 1.0 / attack_frames);
                }
            };

            // inner loop: 32 帧
            var pre_delay_read_index = self.pre_delay_read_index;
            var pre_delay_write_index = self.pre_delay_write_index;
            var detector_average = self.detector_average;
            var compressor_gain = self.compressor_gain;

            for (0..NUMBER_OF_DIVISION_FRAMES) |_| {
                // 单通道:|source[frame_index]|
                const undelayed_source = source[frame_index];
                self.pre_delay_buffers[0][pre_delay_write_index] = undelayed_source;
                self.pre_delay_buffers[1][pre_delay_write_index] = undelayed_source;
                const abs_undelayed = @abs(undelayed_source);
                const compressor_input = abs_undelayed;

                const scaled_input = compressor_input;
                const abs_input = @abs(scaled_input);
                const shaped_input = self.saturate(abs_input, k);
                const attenuation: f32 = if (abs_input <= 0.0001)
                    1.0
                else
                    shaped_input / abs_input;
                const db_attenuation = @max(@as(f32, 2.0), -linear_to_decibels(attenuation));
                const db_per_frame = db_attenuation / sat_release_frames;
                const sat_release_rate = decibels_to_linear(db_per_frame) - 1.0;
                const is_release = attenuation > detector_average;
                const rate: f32 = if (is_release) sat_release_rate else 1.0;
                detector_average += (attenuation - detector_average) * rate;
                detector_average = @min(detector_average, 1.0);
                detector_average = ensure_finite(detector_average, 1.0);

                if (envelope_rate < 1.0) {
                    compressor_gain += (scaled_desired_gain - compressor_gain) * envelope_rate;
                } else {
                    compressor_gain *= envelope_rate;
                    compressor_gain = @min(compressor_gain, 1.0);
                }

                // Chromium: sin(static_cast<double>(kPiOverTwoFloat * compressor_gain))
                // kPiOverTwoFloat * compressor_gain 是 float 乘法,结果 float,
                // 再 static_cast<double> 后用 double sin,最后转回 float。
                const angle_f32: f32 = PI_OVER_TWO * compressor_gain;
                const post_warp_compressor_gain: f32 = @floatCast(@sin(@as(f64, angle_f32)));
                const total_gain = linear_post_gain * post_warp_compressor_gain;

                // metering
                const db_real_gain = linear_to_decibels(post_warp_compressor_gain);
                if (db_real_gain < self.metering_gain) {
                    self.metering_gain = db_real_gain;
                } else {
                    self.metering_gain += (db_real_gain - self.metering_gain) * self.metering_release_k;
                }

                out[frame_index] = self.pre_delay_buffers[0][pre_delay_read_index] * total_gain;

                frame_index += 1;
                pre_delay_read_index = (pre_delay_read_index + 1) & MAX_PRE_DELAY_FRAMES_MASK;
                pre_delay_write_index = (pre_delay_write_index + 1) & MAX_PRE_DELAY_FRAMES_MASK;
            }

            self.pre_delay_read_index = pre_delay_read_index;
            self.pre_delay_write_index = pre_delay_write_index;
            self.detector_average = flush_denormal(detector_average);
            self.compressor_gain = flush_denormal(compressor_gain);
        }

        self.parameters[PARAM_REDUCTION] = self.metering_gain;
    }
};
