//! BraveAudioFarblingHelper — 忠实移植 brave/brave-core 的
//! `third_party/blink/renderer/platform/brave_audio_farbling_helper.{h,cc}`。
//!
//! Brave 在 `AudioBuffer::getChannelData` / `copyFromChannel` 处注入 farbling:
//!   BRAVE_AUDIOBUFFER_GETCHANNELDATA → BraveSessionCache::FarbleAudioChannel(dst)
//! Stytch 的 fp_audio = sum(|buf.getChannelData(0)|) 正好命中这条路径,
//! 所以渲染出的 buffer 在被 JS 读取时会被本 helper 按 fudge_factor 改写。
//!
//! 对应 C++ 字段映射:
//!   fudge_factor_  ← 0.999 + ((fudge / maxUInt64AsDouble) / 1000),  fudge = token.high
//!   seed_          ← token.low
//!   max_           ← (level == BraveFarblingLevel::MAXIMUM)
//!
//! BALANCED: dst[i] = dst[i] * fudge_factor_;
//! MAXIMUM : v = seed_; v = lfsr_next(v); dst[i] = (v / maxUInt64) / 10;
//!
//! 移植自 fp_audio_chromium/src/brave_audio_farbling_helper.rs。

const std = @import("std");

/// `maxUInt64AsDouble` — 对应 C++ `static_cast<double>(UINT64_MAX)`。
pub const MAX_UINT64_AS_DOUBLE: f64 = @floatFromInt(std.math.maxInt(u64));

/// Brave 的 64-bit Galois LFSR,逐位复刻
/// `brave_audio_farbling_helper.cc` 匿名命名空间里的 `lfsr_next`:
/// ```cpp
/// inline uint64_t lfsr_next(uint64_t v) {
///   return ((v >> 1) | (((v << 62) ^ (v << 61)) & (~(~zero << 63) << 62)));
/// }
/// ```
/// 逐位推演 feedback mask:
///   ~zero                      = 0xFFFF_FFFF_FFFF_FFFF
///   ~zero << 63                = 0x8000_0000_0000_0000
///   ~(~zero << 63)             = 0x7FFF_FFFF_FFFF_FFFF
///   (~(~0 << 63) << 62)        = 0x4000_0000_0000_0000   (bit62)
pub fn lfsr_next(v: u64) u64 {
    const FEEDBACK_MASK: u64 = 0x4000_0000_0000_0000;
    return (v >> 1) | (((v << 62) ^ (v << 61)) & FEEDBACK_MASK);
}

/// `BraveFarblingLevel` — 对应 `brave_shields::mojom::FarblingLevel`。
pub const BraveFarblingLevel = enum {
    /// 标准档:逐样本乘 fudge_factor。
    balanced,
    /// 最强档:整段缓冲区替换为 LFSR 伪随机噪声。
    maximum,
};

/// Brave 会话级 farbling token(128 位 = base::Token)。
/// `high()` 派生 fudge_factor,`low()` 作为 MAXIMUM 档 LFSR 种子。
pub const FarblingToken = struct {
    high: u64,
    low: u64,
};

/// `BraveAudioFarblingHelper` — 对应 C++ class `BraveAudioFarblingHelper`。
pub const BraveAudioFarblingHelper = struct {
    fudge_factor: f64,
    seed: u64,
    max: bool,

    /// 按 Brave 会话缓存的派生方式构造 helper。
    pub fn from_token(token: FarblingToken, level: BraveFarblingLevel) BraveAudioFarblingHelper {
        const fudge = token.high;
        const fudge_factor = 0.999 + (@as(f64, @floatFromInt(fudge)) / MAX_UINT64_AS_DOUBLE) / 1000.0;
        const seed = token.low;
        const max = level == .maximum;
        return .{
            .fudge_factor = fudge_factor,
            .seed = seed,
            .max = max,
        };
    }

    /// 仅供日志/诊断返回 fudge_factor。
    pub fn fudge_factor_val(self: *const BraveAudioFarblingHelper) f64 {
        return self.fudge_factor;
    }

    /// `FarbleAudioChannel(base::span<float> dst)` — 对应 C++ 实现:
    /// ```cpp
    /// if (max_) {
    ///   uint64_t v = seed_;
    ///   for (auto& value : dst) {
    ///     v = lfsr_next(v);
    ///     value = (v / maxUInt64AsDouble) / 10;
    ///   }
    /// } else {
    ///   for (auto& value : dst) {
    ///     value = value * fudge_factor_;
    ///   }
    /// }
    /// ```
    /// 原地改写 buffer。
    pub fn farble_audio_channel(self: *const BraveAudioFarblingHelper, dst: []f32) void {
        if (self.max) {
            var v = self.seed;
            for (dst) |*value| {
                v = lfsr_next(v);
                value.* = @floatCast(@as(f64, @floatFromInt(v)) / MAX_UINT64_AS_DOUBLE / 10.0);
            }
        } else {
            const ff: f32 = @floatCast(self.fudge_factor);
            for (dst) |*value| {
                value.* *= ff;
            }
        }
    }
};
