//! PeriodicWaveImpl — 复刻 periodic_wave.cc,生成 band-limited sine wavetables。
//!
//! 全部用 f32 运算,匹配 Chromium 149 的 float 语义。
//!
//! FFT 实现用 `fft` 模块的手写 radix-2 复数 IFFT(含 1/N 缩放),
//! 匹配 Chromium 149 PFFFT 的 DoInverseFFT 行为。
//!
//! 移植自 chromium_src_periodic_wave.cc + fft_frame_pffft.cc。

const std = @import("std");
const fft = @import("fft.zig");

// periodic_wave.cc 常量
const NUMBER_OF_OCTAVE_BANDS: usize = 3;
const MAX_PERIODIC_WAVE_SIZE: usize = 16384;
const CENTS_PER_RANGE: f32 = 1200.0 / @as(f32, @floatFromInt(NUMBER_OF_OCTAVE_BANDS)); // 400

pub const PeriodicWave = struct {
    sample_rate: f32,
    periodic_wave_size: usize,
    lowest_fundamental_frequency: f32,
    rate_scale: f32,
    number_of_ranges: usize,
    /// 每个 range 一张表,长度 = periodic_wave_size
    band_limited_tables: std.ArrayList([]f32),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32) PeriodicWave {
        const periodic_wave_size: usize = if (sample_rate <= 24000.0)
            2048
        else if (sample_rate <= 88200.0)
            4096
        else
            MAX_PERIODIC_WAVE_SIZE;
        const max_partials = periodic_wave_size / 2;
        const nyquist = 0.5 * sample_rate;
        const lowest_fundamental_frequency = nyquist / @as(f32, @floatFromInt(max_partials));
        const rate_scale = @as(f32, @floatFromInt(periodic_wave_size)) / sample_rate;
        const number_of_ranges = @as(usize, @intFromFloat(@round(
            0.5 + @as(f32, @floatFromInt(NUMBER_OF_OCTAVE_BANDS)) * @log2(@as(f32, @floatFromInt(periodic_wave_size))),
        )));

        return .{
            .sample_rate = sample_rate,
            .periodic_wave_size = periodic_wave_size,
            .lowest_fundamental_frequency = lowest_fundamental_frequency,
            .rate_scale = rate_scale,
            .number_of_ranges = number_of_ranges,
            .band_limited_tables = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PeriodicWave) void {
        for (self.band_limited_tables.items) |table| {
            self.allocator.free(table);
        }
        self.band_limited_tables.deinit(self.allocator);
    }

    fn number_of_partials_for_range(self: *const PeriodicWave, range_index: usize) usize {
        const cents_to_cull = @as(f32, @floatFromInt(range_index)) * CENTS_PER_RANGE;
        const culling_scale = std.math.pow(f32, 2.0, -cents_to_cull / 1200.0);
        return @intFromFloat(culling_scale * @as(f32, @floatFromInt(self.periodic_wave_size / 2)));
    }

    /// 生成 sine 波的全部 band-limited tables。
    ///
    /// 复刻 `PeriodicWaveImpl::CreateBandLimitedTables` + `GenerateBasicWaveform(SINE)`:
    ///   - sine 的 Fourier 系数:real[n]=0, imag[1]=1, 其余 0。
    ///   - packed 格式(half_size):real[i]=real_data[i]*scale, imag[i]=-imag_data[i]*scale
    ///   - 清掉超出 number_of_partials 的 bin,清 DC。
    ///   - 调 `fft.inverse_fft`(PFFFT,含 1/fft_size 缩放)生成时域表。
    ///   - range 0 计算峰值,normalization_scale = 1/max_value。
    pub fn generate_sine_tables(self: *PeriodicWave) !void {
        const fft_size = self.periodic_wave_size;
        const half_size = fft_size / 2;

        var normalization_scale: f32 = 0.5; // disable_normalization=false 默认值

        for (0..self.number_of_ranges) |range_index| {
            // GenerateBasicWaveform(SINE): real[n]=0, imag[1]=1, 其余 0
            // CreateBandLimitedTables: scale=fft_size, real[i]=real_data[i]*scale, imag[i]=-imag_data[i]*scale
            const real = try self.allocator.alloc(f32, half_size);
            const imag = try self.allocator.alloc(f32, half_size);
            defer self.allocator.free(real);
            defer self.allocator.free(imag);

            @memset(real, 0.0);
            @memset(imag, 0.0);

            const scale = @as(f32, @floatFromInt(fft_size));
            const partials = self.number_of_partials_for_range(range_index);

            // sine: imag_data[1] = 1, 其余 0
            // imag[1] = -imag_data[1] * scale = -scale
            if (partials >= 1) {
                imag[1] = -scale;
            }

            // 清掉超出 number_of_partials 的 bin
            const number_of_components = half_size;
            const cull_start = @min(number_of_components, partials + 1);
            for (cull_start..half_size) |i| {
                real[i] = 0.0;
                imag[i] = 0.0;
            }

            // Clear DC-offset
            real[0] = 0.0;
            imag[0] = 0.0;

            // inverse FFT 生成时域表 (PFFFT,含 1/fft_size 缩放)
            const data = try self.allocator.alloc(f32, fft_size);
            fft.inverse_fft(real, imag, data);

            // 归一化:range 0 计算峰值
            if (range_index == 0) {
                var max_value: f32 = 0.0;
                for (data) |v| {
                    const av = @abs(v);
                    if (av > max_value) {
                        max_value = av;
                    }
                }
                if (max_value != 0.0) {
                    normalization_scale = 1.0 / max_value;
                }
            }

            for (data) |*v| {
                v.* *= normalization_scale;
            }
            try self.band_limited_tables.append(self.allocator, data);
        }
    }

    /// 返回 (lower_table, higher_table, interpolation_factor)
    pub fn wave_data_for_frequency(
        self: *const PeriodicWave,
        fundamental_frequency: f32,
    ) struct { lower: []const f32, higher: []const f32, interp: f32 } {
        const ff = @abs(fundamental_frequency);
        const ratio = if (ff > 0.0)
            ff / self.lowest_fundamental_frequency
        else
            0.5;
        const cents_above_lowest = @log2(ratio) * 1200.0;
        var pitch_range = 1.0 + cents_above_lowest / CENTS_PER_RANGE;
        if (pitch_range < 0.0) {
            pitch_range = 0.0;
        }
        const max_pr = @as(f32, @floatFromInt(self.number_of_ranges - 1));
        if (pitch_range > max_pr) {
            pitch_range = max_pr;
        }

        const range_index1 = @as(usize, @intFromFloat(pitch_range));
        const range_index2 = if (range_index1 < self.number_of_ranges - 1)
            range_index1 + 1
        else
            range_index1;

        const lower = self.band_limited_tables.items[range_index2];
        const higher = self.band_limited_tables.items[range_index1];
        const interp = pitch_range - @as(f32, @floatFromInt(range_index1));
        return .{ .lower = lower, .higher = higher, .interp = interp };
    }
};
