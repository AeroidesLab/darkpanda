//! PFFFT FFI — 调用 C 编译的 PFFFT 库,精确复刻 Brave 149 的 FFT 行为。
//!
//! Brave 149 用 PFFFT(real-to-complex FFT),DoInverseFFT 末尾乘 1/fft_size。
//! 这里直接调用 PFFFT 的 C 实现,确保 100% 浮点行为一致。
//!
//! 移植自 fft_frame_pffft.cc 的 DoInverseFFT。

const std = @import("std");

const c = @cImport({
    @cDefine("_USE_MATH_DEFINES", "");
    @cInclude("math.h");
    @cInclude("pffft.h");
});

/// PFFFT 的 DoInverseFFT: 输入 packed real/imag (half_size 个复数),
/// 输出时域 N 点实序列,末尾乘 1/fft_size。
///
/// 复刻 fft_frame_pffft.cc 的 FFTFrame::DoInverseFFT:
///   1. Pack real/imag 到 interleaved complex (PFFFT 内部格式)
///   2. pffft_transform_ordered (PFFFT_BACKWARD, 无缩放)
///   3. Vsmul(data, 1/fft_size)
pub fn inverse_fft(real: []const f32, imag: []const f32, out: []f32) void {
    const n = out.len;
    const half_size = n / 2;
    std.debug.assert(real.len >= half_size);
    std.debug.assert(imag.len >= half_size);
    std.debug.assert(std.math.isPowerOfTwo(n));
    std.debug.assert(n >= 32); // PFFFT 最小 size = 32

    const setup = c.pffft_new_setup(@as(c_int, @intCast(n)), c.PFFFT_REAL);
    std.debug.assert(setup != null);
    defer c.pffft_destroy_setup(setup);

    // PFFFT 要求 16 字节对齐的输入/输出缓冲区
    const alloc = std.heap.page_allocator;
    const fft_data = alloc.alignedAlloc(f32, .@"16", n) catch unreachable;
    defer alloc.free(fft_data);
    const work = alloc.alignedAlloc(f32, .@"16", n) catch unreachable;
    defer alloc.free(work);
    const aligned_out = alloc.alignedAlloc(f32, .@"16", n) catch unreachable;
    defer alloc.free(aligned_out);

    // Pack real/imag 到 interleaved complex (PFFFT 内部格式)
    // fft_frame_pffft.cc: fft_data[2k] = real[k], fft_data[2k+1] = imag[k]
    for (0..half_size) |k| {
        fft_data[2 * k] = real[k];
        fft_data[2 * k + 1] = imag[k];
    }

    // PFFFT_BACKWARD (无缩放)
    c.pffft_transform_ordered(setup, fft_data.ptr, aligned_out.ptr, work.ptr, c.PFFFT_BACKWARD);

    // Vsmul(data, 1/fft_size) — PFFFT 的缩放
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(n));
    for (0..n) |i| {
        out[i] = aligned_out[i] * scale;
    }
}
