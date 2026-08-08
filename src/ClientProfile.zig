// Copyright (C) 2026 DarkPanda contributors
//
// A browser identity is a single unit.  HTTP headers and JavaScript-visible
// Navigator values must never pick their own versions or brands independently.

const builtin = @import("builtin");

pub const chrome149_full_version = "149.0.7827.201";
pub const chrome149_chromium_revision = "6a7b3dbec3b2ca25877c2553b5473b2f277ef644";
pub const chrome149_v8_version = "14.9.207.35";

pub const Id = enum(u32) {
    darkpanda = 1,
    chrome149 = 149,
};

/// Every supported platform uses wreq's Chrome149 TLS/HTTP2 emulation. Keep
/// the default JavaScript/HTTP identity on that same profile as well.
pub const target_default: Id = .chrome149;

// Keep the browser catalog and legacy transport adapter on one Web-exposed
// brand shape. This lets NavigatorUAData borrow either source without copying
// or maintaining a second structurally-identical ABI type.
pub const Brand = @import("FingerprintProfile.zig").Brand;

pub const Data = struct {
    id: Id,
    user_agent: [:0]const u8,
    app_version: []const u8,
    vendor: []const u8,
    product: []const u8,
    navigator_platform: []const u8,

    brands: []const Brand,
    full_version_list: []const Brand,
    mobile: bool,
    ua_platform: []const u8,
    ua_full_version: []const u8,
    architecture: []const u8,
    bitness: []const u8,
    model: []const u8,
    platform_version: []const u8,
    wow64: bool,
    form_factors: []const []const u8,

    sec_ch_ua_header: [:0]const u8,
    sec_ch_ua_mobile_header: [:0]const u8,
    sec_ch_ua_platform_header: [:0]const u8,
    navigation_accept_header: [:0]const u8,
    accept_encoding_header: [:0]const u8,
    navigation_priority_header: ?[:0]const u8,
};

const desktop_form_factors = [_][]const u8{"Desktop"};

// Chrome's reduced UA and low-entropy brands intentionally expose only the
// major version.  High entropy values retain the release tuple that owns the
// bundled V8 14.9 build.
const chrome149_brands = [_]Brand{
    .{ .brand = "Google Chrome", .version = "149" },
    .{ .brand = "Chromium", .version = "149" },
    .{ .brand = "Not)A;Brand", .version = "24" },
};
const chrome149_full_versions = [_]Brand{
    .{ .brand = "Google Chrome", .version = chrome149_full_version },
    .{ .brand = "Chromium", .version = chrome149_full_version },
    .{ .brand = "Not)A;Brand", .version = "24.0.0.0" },
};

const darkpanda_brands = [_]Brand{
    .{ .brand = "DarkPanda", .version = "1" },
};
const darkpanda_full_versions = [_]Brand{
    .{ .brand = "DarkPanda", .version = "1.0.0.0" },
};

const chrome149_windows: Data = .{
    .id = .chrome149,
    .user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
    .app_version = "5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
    .vendor = "Google Inc.",
    .product = "Gecko",
    .navigator_platform = "Win32",
    .brands = &chrome149_brands,
    .full_version_list = &chrome149_full_versions,
    .mobile = false,
    .ua_platform = "Windows",
    .ua_full_version = chrome149_full_version,
    .architecture = "x86",
    .bitness = "64",
    .model = "",
    // Chromium 149 reads Windows.Foundation.UniversalApiContract here.  The
    // stable profile uses its source fallback instead of inventing an OS build
    // number; callers still receive a source-grounded Windows value.
    .platform_version = "19.0.0",
    .wow64 = false,
    .form_factors = &desktop_form_factors,
    // Chromium's client-hint constants are lowercase and wreq deliberately
    // preserves the supplied spelling for HTTP/1.1.
    .sec_ch_ua_header = "sec-ch-ua: \"Google Chrome\";v=\"149\", \"Chromium\";v=\"149\", \"Not)A;Brand\";v=\"24\"",
    .sec_ch_ua_mobile_header = "sec-ch-ua-mobile: ?0",
    .sec_ch_ua_platform_header = "sec-ch-ua-platform: \"Windows\"",
    .navigation_accept_header = "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    .accept_encoding_header = "Accept-Encoding: gzip, deflate, br, zstd",
    .navigation_priority_header = "Priority: u=0, i",
};

fn darkpandaData() Data {
    const navigator_platform, const ua_platform = switch (builtin.os.tag) {
        .macos => .{ "MacIntel", "macOS" },
        .windows => .{ "Win32", "Windows" },
        .linux => .{ "Linux x86_64", "Linux" },
        .freebsd => .{ "FreeBSD", "FreeBSD" },
        else => .{ "Unknown", "Unknown" },
    };
    const architecture = switch (builtin.cpu.arch) {
        .x86, .x86_64 => "x86",
        .aarch64, .aarch64_be, .arm, .armeb => "arm",
        else => "",
    };
    const bitness = switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .aarch64_be, .powerpc64, .powerpc64le, .riscv64 => "64",
        else => "32",
    };

    return .{
        .id = .darkpanda,
        .user_agent = "DarkPanda/1.0",
        .app_version = "1.0",
        .vendor = "",
        .product = "Gecko",
        .navigator_platform = navigator_platform,
        .brands = &darkpanda_brands,
        .full_version_list = &darkpanda_full_versions,
        .mobile = false,
        .ua_platform = ua_platform,
        .ua_full_version = "1.0.0.0",
        .architecture = architecture,
        .bitness = bitness,
        .model = "",
        .platform_version = "",
        .wow64 = false,
        .form_factors = &desktop_form_factors,
        .sec_ch_ua_header = "sec-ch-ua: \"DarkPanda\";v=\"1\"",
        .sec_ch_ua_mobile_header = "sec-ch-ua-mobile: ?0",
        .sec_ch_ua_platform_header = switch (builtin.os.tag) {
            .macos => "sec-ch-ua-platform: \"macOS\"",
            .windows => "sec-ch-ua-platform: \"Windows\"",
            .linux => "sec-ch-ua-platform: \"Linux\"",
            .freebsd => "sec-ch-ua-platform: \"FreeBSD\"",
            else => "sec-ch-ua-platform: \"Unknown\"",
        },
        .navigation_accept_header = "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        .accept_encoding_header = "Accept-Encoding: gzip, deflate, br, zstd",
        .navigation_priority_header = null,
    };
}

pub fn get(id: Id) Data {
    return switch (id) {
        .darkpanda => darkpandaData(),
        .chrome149 => chrome149_windows,
    };
}

pub fn fromInt(value: u32) ?Id {
    return switch (value) {
        1 => .darkpanda,
        149 => .chrome149,
        else => null,
    };
}

test "Chrome149 profile is internally version coherent" {
    const std = @import("std");
    const profile = get(.chrome149);
    try std.testing.expectEqualStrings("149.0.7827.201", profile.ua_full_version);
    try std.testing.expectEqualStrings("149.0.7827.201", profile.full_version_list[0].version);
    try std.testing.expect(std.mem.indexOf(u8, profile.user_agent, "Chrome/149.0.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile.sec_ch_ua_header, "\"Google Chrome\";v=\"149\"") != null);
}
