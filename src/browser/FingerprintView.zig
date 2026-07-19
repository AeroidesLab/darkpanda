// Copyright (C) 2026 DarkPanda contributors
//
// A small read-only adapter for Web API consumers. Chrome 149 reads the
// resolved fingerprint owned by App. The legacy Lightpanda branch remains so
// non-Windows builds keep their existing public configuration until a native
// catalog profile is added for those targets. Navigator and WorkerNavigator
// both use this adapter, preventing per-global identity constants.

const App = @import("../App.zig");
const Brand = @import("../FingerprintProfile.zig").Brand;

pub const NavigatorIdentity = struct {
    user_agent: []const u8,
    app_version: []const u8,
    vendor: []const u8,
    product: []const u8,
    platform: []const u8,
    language: []const u8,
    languages: []const []const u8,
    device_memory: f64,
    hardware_concurrency: u32,
    max_touch_points: u32,

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
};

pub fn navigator(app: *const App) NavigatorIdentity {
    const legacy = &app.config.http_headers.profile;
    if (app.resolvedFingerprint()) |profile| {
        return .{
            .user_agent = profile.browser.user_agent,
            .app_version = profile.browser.app_version,
            .vendor = legacy.vendor,
            .product = legacy.product,
            .platform = profile.navigator.platform,
            .language = profile.locale.locale,
            .languages = profile.locale.languages,
            .device_memory = @floatFromInt(profile.navigator.device_memory),
            .hardware_concurrency = profile.navigator.hardware_concurrency,
            .max_touch_points = profile.navigator.max_touch_points,
            .brands = profile.browser.brands,
            .full_version_list = profile.browser.full_version_list,
            .mobile = profile.browser.mobile,
            .ua_platform = profile.browser.ua_platform,
            .ua_full_version = profile.browser.full_version,
            .architecture = profile.browser.architecture,
            .bitness = profile.browser.bitness,
            .model = profile.browser.model,
            .platform_version = profile.browser.platform_version,
            .wow64 = profile.browser.wow64,
            .form_factors = profile.browser.form_factors,
        };
    }

    // Compatibility for targets whose legacy ClientProfile does not yet have
    // a resolved catalog entry. These defaults live in one adapter rather
    // than being repeated by every Window/Worker Navigator getter.
    const locale = &app.config.http_headers.locale_profile;
    return .{
        .user_agent = legacy.user_agent,
        .app_version = legacy.app_version,
        .vendor = legacy.vendor,
        .product = legacy.product,
        .platform = legacy.navigator_platform,
        .language = locale.application_locale,
        .languages = locale.languages(),
        .device_memory = 8,
        .hardware_concurrency = 4,
        .max_touch_points = 0,
        .brands = legacy.brands,
        .full_version_list = legacy.full_version_list,
        .mobile = legacy.mobile,
        .ua_platform = legacy.ua_platform,
        .ua_full_version = legacy.ua_full_version,
        .architecture = legacy.architecture,
        .bitness = legacy.bitness,
        .model = legacy.model,
        .platform_version = legacy.platform_version,
        .wow64 = legacy.wow64,
        .form_factors = legacy.form_factors,
    };
}
