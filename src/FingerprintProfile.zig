// Copyright (C) 2026 DarkPanda contributors
//
// A fingerprint profile is resolved before any browser or network consumer
// sees it.  This module owns and validates that resolved value; consumers must
// not independently pick a UA, locale, display, graphics, or transport preset.

const std = @import("std");
const Locale = @import("Locale.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema_version: u16 = 2;
pub const max_profile_bytes: usize = 64 * 1024;
pub const max_json_depth: usize = 16;
pub const max_json_value_bytes: usize = 4096;

pub const chrome149_catalog_id = "chrome-149.0.7827.203-windows-x64";
pub const chrome149_full_version = "149.0.7827.203";
pub const chrome149_v8_version = "14.9.207.35";
pub const chrome149_transport_profile_id = "wreq-6.0.0-rc.29/chrome149/windows-x64";

/// This manifest is the catalog-owned network identity.  Its digest must be
/// updated when a dependency, emulation profile, target OS/architecture, TLS
/// backend, or advertised HTTP protocol changes.
pub const chrome149_transport_manifest =
    "transport=wreq@6.0.0-rc.29\n" ++
    "wreq-util=3.0.0-rc.14\n" ++
    "emulation=Chrome149\n" ++
    "os=Windows\n" ++
    "arch=x86_64\n" ++
    "tls=BoringSSL\n" ++
    "http=2,1.1\n";
pub const chrome149_transport_manifest_digest =
    "a4f151202d8303f6523d0e2114cb7dd1bc0b771adb3fceab9b96baf9ae9fcdaa";

const chrome149_user_agent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ++
    "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";
const chrome149_app_version =
    "5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ++
    "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";

pub const BrowserFamily = enum {
    chrome,
};

pub const OperatingSystem = enum {
    windows,
};

pub const WindowState = enum {
    normal,
    minimized,
    maximized,
    fullscreen,
};

/// Configured Canvas identity. This is an observable selection owned by the
/// resolved profile, not a runtime driver or GPU-attestation result.
pub const CanvasBackendKind = enum {
    skia,
    fake,
};

pub const ProvenanceSource = enum {
    legacy_catalog,
    manual,
    apify_projection,
    scrapfly_projection,
};

pub const Brand = struct {
    brand: []const u8,
    version: []const u8,
};

pub const BrowserIdentity = struct {
    catalog_id: []const u8,
    family: BrowserFamily,
    os: OperatingSystem,
    full_version: []const u8,
    v8_version: []const u8,
    user_agent: []const u8,
    app_version: []const u8,
    brands: []const Brand,
    full_version_list: []const Brand,
    ua_platform: []const u8,
    platform_version: []const u8,
    architecture: []const u8,
    bitness: []const u8,
    mobile: bool,
    wow64: bool,
    model: []const u8,
    form_factors: []const []const u8,
};

pub const LocaleIdentity = struct {
    locale: []const u8,
    languages: []const []const u8,
    accept_language: []const u8,
    timezone: []const u8,
};

/// A touch count is not a standalone scalar.  When it is non-zero, all of the
/// corresponding observable API/CSS capabilities must be selected together.
pub const TouchCapabilityBundle = struct {
    bundle_id: []const u8,
    touch_event_api: bool,
    touch_event_handlers: bool,
    pointer_event_api: bool,
    css_any_pointer_coarse: bool,
};

pub const NavigatorIdentity = struct {
    platform: []const u8,
    device_memory: u8,
    hardware_concurrency: u16,
    max_touch_points: u8,
    touch_capabilities: ?TouchCapabilityBundle,
};

pub const DisplayIdentity = struct {
    screen_width: u32,
    screen_height: u32,
    avail_width: u32,
    avail_height: u32,
    screen_x: i32,
    screen_y: i32,
    outer_width: u32,
    outer_height: u32,
    inner_width: u32,
    inner_height: u32,
    device_pixel_ratio: f64,
    color_depth: u8,
    pixel_depth: u8,
    window_state: WindowState,
};

pub const GraphicsIdentity = struct {
    bundle_id: []const u8,
    canvas_backend: CanvasBackendKind,
    profile_seed: u64,
    canvas_seed: u64,
};

pub const NetworkIdentity = struct {
    transport_profile_id: []const u8,
    manifest_digest: []const u8,
};

pub const Provenance = struct {
    source: ProvenanceSource,
    dataset: ?[]const u8,
    generator_version: ?[]const u8,
    model: ?[]const u8,
    source_record_digest: ?[]const u8,
};

pub const ResolvedFingerprintProfile = struct {
    browser: BrowserIdentity,
    locale: LocaleIdentity,
    navigator: NavigatorIdentity,
    display: DisplayIdentity,
    graphics: GraphicsIdentity,
    network: NetworkIdentity,
    provenance: Provenance,
    observable_digest: [Sha256.digest_length]u8,

    pub fn observableDigestHex(self: *const ResolvedFingerprintProfile) [Sha256.digest_length * 2]u8 {
        return hexLower(self.observable_digest);
    }
};

/// Owns every non-static slice reachable from `profile`.  Callers receive only
/// a const view, and replace the whole object to change a resolved profile.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    profile: ResolvedFingerprintProfile,

    pub fn parseJson(allocator: Allocator, input: []const u8) !Owned {
        try preflightJson(allocator, input);

        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();

        const raw = try std.json.parseFromSliceLeaky(
            RawProfile,
            arena.allocator(),
            input,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
                .ignore_unknown_fields = false,
                .max_value_len = max_json_value_bytes,
            },
        );
        const profile = try resolveAndValidate(raw, allocator);
        return .{ .arena = arena, .profile = profile };
    }

    pub fn legacyChrome149Windows(allocator: Allocator) !Owned {
        return parseJson(allocator, legacy_chrome149_windows_json);
    }

    /// Resolve the legacy CLI inputs into the same catalog-owned Chrome 149
    /// identity. The returned profile owns copies of every caller-provided
    /// locale slice, so browser/worker consumers can safely borrow one
    /// immutable value for the whole App lifetime.
    pub fn legacyChrome149WindowsWithLocale(
        allocator: Allocator,
        application_locale: []const u8,
        languages: []const []const u8,
        accept_language: []const u8,
        timezone: ?[]const u8,
    ) !Owned {
        var owned = try legacyChrome149Windows(allocator);
        errdefer owned.deinit();

        const arena = owned.arena.allocator();
        const locale_copy = try arena.dupe(u8, application_locale);
        const language_copies = try arena.alloc([]const u8, languages.len);
        for (languages, 0..) |language, index| {
            language_copies[index] = try arena.dupe(u8, language);
        }
        const accept_language_copy = try arena.dupe(u8, accept_language);
        const timezone_copy = if (timezone) |value|
            try arena.dupe(u8, value)
        else
            owned.profile.locale.timezone;

        const raw_locale: RawLocale = .{
            .locale = locale_copy,
            .languages = language_copies,
            .acceptLanguage = accept_language_copy,
            .timezone = timezone_copy,
        };
        try validateLocale(raw_locale, allocator);

        owned.profile.locale = .{
            .locale = raw_locale.locale,
            .languages = raw_locale.languages,
            .accept_language = raw_locale.acceptLanguage,
            .timezone = raw_locale.timezone,
        };
        owned.profile.observable_digest = computeObservableDigest(&owned.profile);
        return owned;
    }

    pub fn get(self: *const Owned) *const ResolvedFingerprintProfile {
        return &self.profile;
    }

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// External datasets are evidence for a projection, never authorities for the
/// engine build or transport.  A future importer for Apify or Scrapfly must be
/// an explicitly named operation and may only populate these projection-owned
/// groups.  It must then resolve against the local catalog through this module.
pub const ProjectionBoundary = struct {
    pub const projection_owned_groups = [_][]const u8{
        "locale",
        "navigator",
        "display",
        "graphics",
    };
    pub const catalog_owned_groups = [_][]const u8{
        "browser.fullVersion",
        "browser.v8Version",
        "browser.userAgent",
        "browser.brands",
        "browser.fullVersionList",
        "network.transportProfileId",
        "network.manifestDigest",
    };
    pub const graphics_projection_fields = [_][]const u8{
        "graphics.bundleId",
        "graphics.canvasBackend",
        "graphics.profileSeed",
        "graphics.canvasSeed",
    };
};

const RawBrand = Brand;

const RawBrowser = struct {
    catalogId: []const u8,
    family: BrowserFamily,
    os: OperatingSystem,
    fullVersion: []const u8,
    v8Version: []const u8,
    userAgent: []const u8,
    appVersion: []const u8,
    brands: []const RawBrand,
    fullVersionList: []const RawBrand,
    uaPlatform: []const u8,
    platformVersion: []const u8,
    architecture: []const u8,
    bitness: []const u8,
    mobile: bool,
    wow64: bool,
    model: []const u8,
    formFactors: []const []const u8,
};

const RawLocale = struct {
    locale: []const u8,
    languages: []const []const u8,
    acceptLanguage: []const u8,
    timezone: []const u8,
};

const RawTouchCapabilityBundle = struct {
    bundleId: []const u8,
    touchEventApi: bool,
    touchEventHandlers: bool,
    pointerEventApi: bool,
    cssAnyPointerCoarse: bool,
};

const RawNavigator = struct {
    platform: []const u8,
    deviceMemory: u8,
    hardwareConcurrency: u16,
    maxTouchPoints: u8,
    touchCapabilities: ?RawTouchCapabilityBundle,
};

const RawDisplay = struct {
    screenWidth: u32,
    screenHeight: u32,
    availWidth: u32,
    availHeight: u32,
    screenX: i32,
    screenY: i32,
    outerWidth: u32,
    outerHeight: u32,
    innerWidth: u32,
    innerHeight: u32,
    devicePixelRatio: f64,
    colorDepth: u8,
    pixelDepth: u8,
    windowState: WindowState,
};

const RawGraphics = struct {
    bundleId: []const u8,
    canvasBackend: CanvasBackendKind,
    profileSeed: []const u8,
    canvasSeed: []const u8,
};

const RawNetwork = struct {
    transportProfileId: []const u8,
    manifestDigest: []const u8,
};

const RawProvenance = struct {
    source: ProvenanceSource,
    dataset: ?[]const u8 = null,
    generatorVersion: ?[]const u8 = null,
    model: ?[]const u8 = null,
    sourceRecordDigest: ?[]const u8 = null,
};

const RawProfile = struct {
    schemaVersion: u16,
    browser: RawBrowser,
    locale: RawLocale,
    navigator: RawNavigator,
    display: RawDisplay,
    graphics: RawGraphics,
    network: RawNetwork,
    provenance: RawProvenance,
};

fn preflightJson(allocator: Allocator, input: []const u8) !void {
    if (input.len == 0 or input.len > max_profile_bytes) return error.ProfileTooLarge;

    var scanner = std.json.Scanner.initCompleteInput(allocator, input);
    defer scanner.deinit();

    var depth: usize = 0;
    while (true) {
        const token = try scanner.next();
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > max_json_depth) return error.ProfileTooDeep;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.SyntaxError;
                depth -= 1;
            },
            .end_of_document => break,
            else => {},
        }
    }
    if (depth != 0) return error.SyntaxError;
}

fn resolveAndValidate(raw: RawProfile, scratch: Allocator) !ResolvedFingerprintProfile {
    if (raw.schemaVersion != schema_version) return error.UnsupportedSchemaVersion;
    try validateBrowser(raw.browser);
    try validateLocale(raw.locale, scratch);
    try validateNavigator(raw.navigator, raw.browser);
    try validateDisplay(raw.display);
    const graphics = try validateGraphics(raw.graphics);
    try validateNetwork(raw.network);
    try validateProvenance(raw.provenance);

    var profile: ResolvedFingerprintProfile = .{
        .browser = .{
            .catalog_id = raw.browser.catalogId,
            .family = raw.browser.family,
            .os = raw.browser.os,
            .full_version = raw.browser.fullVersion,
            .v8_version = raw.browser.v8Version,
            .user_agent = raw.browser.userAgent,
            .app_version = raw.browser.appVersion,
            .brands = raw.browser.brands,
            .full_version_list = raw.browser.fullVersionList,
            .ua_platform = raw.browser.uaPlatform,
            .platform_version = raw.browser.platformVersion,
            .architecture = raw.browser.architecture,
            .bitness = raw.browser.bitness,
            .mobile = raw.browser.mobile,
            .wow64 = raw.browser.wow64,
            .model = raw.browser.model,
            .form_factors = raw.browser.formFactors,
        },
        .locale = .{
            .locale = raw.locale.locale,
            .languages = raw.locale.languages,
            .accept_language = raw.locale.acceptLanguage,
            .timezone = raw.locale.timezone,
        },
        .navigator = .{
            .platform = raw.navigator.platform,
            .device_memory = raw.navigator.deviceMemory,
            .hardware_concurrency = raw.navigator.hardwareConcurrency,
            .max_touch_points = raw.navigator.maxTouchPoints,
            .touch_capabilities = if (raw.navigator.touchCapabilities) |touch| .{
                .bundle_id = touch.bundleId,
                .touch_event_api = touch.touchEventApi,
                .touch_event_handlers = touch.touchEventHandlers,
                .pointer_event_api = touch.pointerEventApi,
                .css_any_pointer_coarse = touch.cssAnyPointerCoarse,
            } else null,
        },
        .display = .{
            .screen_width = raw.display.screenWidth,
            .screen_height = raw.display.screenHeight,
            .avail_width = raw.display.availWidth,
            .avail_height = raw.display.availHeight,
            .screen_x = raw.display.screenX,
            .screen_y = raw.display.screenY,
            .outer_width = raw.display.outerWidth,
            .outer_height = raw.display.outerHeight,
            .inner_width = raw.display.innerWidth,
            .inner_height = raw.display.innerHeight,
            .device_pixel_ratio = raw.display.devicePixelRatio,
            .color_depth = raw.display.colorDepth,
            .pixel_depth = raw.display.pixelDepth,
            .window_state = raw.display.windowState,
        },
        .graphics = .{
            .bundle_id = raw.graphics.bundleId,
            .canvas_backend = raw.graphics.canvasBackend,
            .profile_seed = graphics.profile_seed,
            .canvas_seed = graphics.canvas_seed,
        },
        .network = .{
            .transport_profile_id = raw.network.transportProfileId,
            .manifest_digest = raw.network.manifestDigest,
        },
        .provenance = .{
            .source = raw.provenance.source,
            .dataset = raw.provenance.dataset,
            .generator_version = raw.provenance.generatorVersion,
            .model = raw.provenance.model,
            .source_record_digest = raw.provenance.sourceRecordDigest,
        },
        .observable_digest = undefined,
    };
    profile.observable_digest = computeObservableDigest(&profile);
    return profile;
}

fn validateBrowser(browser: RawBrowser) !void {
    if (!std.mem.eql(u8, browser.catalogId, chrome149_catalog_id) or
        browser.family != .chrome or browser.os != .windows)
    {
        return error.UnsupportedBrowserCatalog;
    }
    if (!std.mem.eql(u8, browser.fullVersion, chrome149_full_version) or
        !std.mem.eql(u8, browser.v8Version, chrome149_v8_version))
    {
        return error.BrowserBuildMismatch;
    }
    if (!std.mem.eql(u8, browser.userAgent, chrome149_user_agent) or
        !std.mem.eql(u8, browser.appVersion, chrome149_app_version))
    {
        return error.UserAgentMismatch;
    }
    if (!std.mem.eql(u8, browser.uaPlatform, "Windows") or
        !std.mem.eql(u8, browser.platformVersion, "19.0.0") or
        !std.mem.eql(u8, browser.architecture, "x86") or
        !std.mem.eql(u8, browser.bitness, "64") or
        browser.mobile or browser.wow64 or browser.model.len != 0)
    {
        return error.UserAgentMetadataMismatch;
    }

    const expected_brands = [_]RawBrand{
        .{ .brand = "Google Chrome", .version = "149" },
        .{ .brand = "Chromium", .version = "149" },
        .{ .brand = "Not)A;Brand", .version = "24" },
    };
    const expected_full_versions = [_]RawBrand{
        .{ .brand = "Google Chrome", .version = chrome149_full_version },
        .{ .brand = "Chromium", .version = chrome149_full_version },
        .{ .brand = "Not)A;Brand", .version = "24.0.0.0" },
    };
    if (!brandsEqual(browser.brands, &expected_brands) or
        !brandsEqual(browser.fullVersionList, &expected_full_versions))
    {
        return error.UserAgentClientHintsMismatch;
    }
    if (browser.formFactors.len != 1 or
        !std.mem.eql(u8, browser.formFactors[0], "Desktop"))
    {
        return error.UserAgentClientHintsMismatch;
    }
}

fn brandsEqual(actual: []const RawBrand, expected: []const RawBrand) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |a, e| {
        if (!std.mem.eql(u8, a.brand, e.brand) or
            !std.mem.eql(u8, a.version, e.version)) return false;
    }
    return true;
}

fn validateLocale(locale: RawLocale, scratch: Allocator) !void {
    if (locale.languages.len == 0 or locale.languages.len > 10) {
        return error.InvalidLanguages;
    }
    if (!std.mem.eql(u8, locale.locale, locale.languages[0])) {
        return error.LocaleLanguageMismatch;
    }

    for (locale.languages, 0..) |language, i| {
        try validateCanonicalLocale(scratch, language);
        for (locale.languages[0..i]) |previous| {
            if (std.mem.eql(u8, previous, language)) return error.DuplicateLanguage;
        }
    }
    try validateCanonicalLocale(scratch, locale.locale);
    try validateAcceptLanguage(locale.acceptLanguage, locale.languages);
    try validateText(locale.timezone, 1, 255);
    try Locale.validateTimeZone(locale.timezone);
}

fn validateCanonicalLocale(scratch: Allocator, value: []const u8) !void {
    const canonical = Locale.canonicalizeApplicationLocale(scratch, value) catch
        return error.InvalidLocale;
    defer scratch.free(canonical);
    if (!std.mem.eql(u8, value, canonical)) return error.NonCanonicalLocale;
}

fn validateAcceptLanguage(value: []const u8, languages: []const []const u8) !void {
    try validateText(value, 1, 512);
    var entries = std.mem.splitScalar(u8, value, ',');
    var index: usize = 0;
    while (entries.next()) |entry| : (index += 1) {
        // Chrome's network Accept-Language preference and
        // navigator.languages are related, but they are not required to have
        // identical cardinality.  For example a browser started with
        // --lang=en-US can expose ["en-US"] while still sending
        // "en-US,en;q=0.9".  Require every JS-visible language as an ordered
        // prefix, then permit additional valid HTTP language ranges.
        if (index >= 10) return error.AcceptLanguageMismatch;
        if (index == 0) {
            if (!std.mem.eql(u8, entry, languages[0])) {
                return error.AcceptLanguageMismatch;
            }
            continue;
        }

        const separator = std.mem.indexOf(u8, entry, ";q=") orelse
            return error.AcceptLanguageMismatch;
        const language_range = entry[0..separator];
        if (!validLanguageRange(language_range)) return error.AcceptLanguageMismatch;
        if (index < languages.len and !std.mem.eql(u8, language_range, languages[index])) {
            return error.AcceptLanguageMismatch;
        }

        var expected_buf: [80]u8 = undefined;
        const quality: u8 = @intCast(10 - index);
        const expected = std.fmt.bufPrint(
            &expected_buf,
            "0.{d}",
            .{quality},
        ) catch return error.AcceptLanguageMismatch;
        if (!std.mem.eql(u8, entry[separator + 3 ..], expected)) {
            return error.AcceptLanguageMismatch;
        }
    }
    if (index < languages.len) return error.AcceptLanguageMismatch;
}

fn validLanguageRange(value: []const u8) bool {
    if (value.len == 0 or value.len > 63) return false;
    if (std.mem.eql(u8, value, "*")) return true;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-') continue;
        return false;
    }
    return true;
}

fn validateNavigator(navigator: RawNavigator, browser: RawBrowser) !void {
    if (!std.mem.eql(u8, navigator.platform, "Win32") or
        browser.os != .windows)
    {
        return error.NavigatorPlatformMismatch;
    }
    switch (navigator.deviceMemory) {
        2, 4, 8, 16, 32 => {},
        else => return error.InvalidDeviceMemory,
    }
    if (navigator.hardwareConcurrency == 0 or navigator.hardwareConcurrency > 256) {
        return error.InvalidHardwareConcurrency;
    }
    if (navigator.maxTouchPoints > 32) return error.InvalidMaxTouchPoints;

    if (navigator.maxTouchPoints == 0) {
        if (navigator.touchCapabilities != null) return error.TouchCapabilityMismatch;
        return;
    }
    const touch = navigator.touchCapabilities orelse
        return error.TouchCapabilityBundleRequired;
    try validateIdentifier(touch.bundleId, 1, 256);
    if (!touch.touchEventApi or !touch.touchEventHandlers or
        !touch.pointerEventApi or !touch.cssAnyPointerCoarse)
    {
        return error.IncompleteTouchCapabilityBundle;
    }
}

fn validateDisplay(display: RawDisplay) !void {
    if (display.screenWidth == 0 or display.screenHeight == 0 or
        display.availWidth == 0 or display.availHeight == 0 or
        display.outerWidth == 0 or display.outerHeight == 0 or
        display.innerWidth == 0 or display.innerHeight == 0)
    {
        return error.InvalidDisplayGeometry;
    }
    if (display.availWidth > display.screenWidth or
        display.availHeight > display.screenHeight)
    {
        return error.InvalidAvailableGeometry;
    }
    // Maximized/fullscreen/window-manager states are platform dependent.  The
    // inner <= outer invariant is only asserted for an ordinary normal window.
    if (display.windowState == .normal and
        (display.innerWidth > display.outerWidth or
            display.innerHeight > display.outerHeight))
    {
        return error.InvalidNormalWindowGeometry;
    }
    // screenX/screenY deliberately accept negative multi-monitor coordinates.
    if (!std.math.isFinite(display.devicePixelRatio) or
        display.devicePixelRatio <= 0 or display.devicePixelRatio > 16)
    {
        return error.InvalidDevicePixelRatio;
    }
    if (display.colorDepth == 0 or display.colorDepth > 64 or
        display.pixelDepth != display.colorDepth)
    {
        return error.InvalidDisplayDepth;
    }
}

const ParsedGraphics = struct {
    profile_seed: u64,
    canvas_seed: u64,
};

fn validateGraphics(graphics: RawGraphics) !ParsedGraphics {
    try validateIdentifier(graphics.bundleId, 1, 256);
    return .{
        .profile_seed = try parseCanonicalHexU64(graphics.profileSeed),
        .canvas_seed = try parseCanonicalHexU64(graphics.canvasSeed),
    };
}

/// JSON numbers above 2^53 are not portable through Python/JavaScript. Seeds
/// therefore use exactly 16 lowercase hexadecimal digits with no 0x prefix.
fn parseCanonicalHexU64(value: []const u8) !u64 {
    if (value.len != 16) return error.InvalidCanvasSeed;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
            return error.InvalidCanvasSeed;
        }
    }
    return std.fmt.parseUnsigned(u64, value, 16) catch error.InvalidCanvasSeed;
}

fn validateNetwork(network: RawNetwork) !void {
    if (!std.mem.eql(u8, network.transportProfileId, chrome149_transport_profile_id) or
        !std.mem.eql(u8, network.manifestDigest, chrome149_transport_manifest_digest))
    {
        return error.TransportCatalogMismatch;
    }
    try validateLowerHexDigest(network.manifestDigest);

    var actual: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(chrome149_transport_manifest, &actual, .{});
    const actual_hex = hexLower(actual);
    if (!std.mem.eql(u8, &actual_hex, chrome149_transport_manifest_digest)) {
        return error.TransportManifestDigestMismatch;
    }
}

fn validateProvenance(provenance: RawProvenance) !void {
    if (provenance.dataset) |value| try validateIdentifier(value, 1, 256);
    if (provenance.generatorVersion) |value| try validateIdentifier(value, 1, 128);
    if (provenance.model) |value| try validateIdentifier(value, 1, 128);
    if (provenance.sourceRecordDigest) |value| try validateLowerHexDigest(value);

    switch (provenance.source) {
        .legacy_catalog => {
            if (provenance.dataset == null) return error.IncompleteProvenance;
        },
        .manual => {},
        .apify_projection => {
            if (provenance.dataset == null or provenance.generatorVersion == null or
                provenance.sourceRecordDigest == null)
            {
                return error.IncompleteProjectionProvenance;
            }
        },
        .scrapfly_projection => {
            if (provenance.dataset == null or provenance.generatorVersion == null or
                provenance.model == null or provenance.sourceRecordDigest == null)
            {
                return error.IncompleteProjectionProvenance;
            }
        },
    }
}

fn validateIdentifier(value: []const u8, min: usize, max: usize) !void {
    try validateText(value, min, max);
}

fn validateText(value: []const u8, min: usize, max: usize) !void {
    if (value.len < min or value.len > max or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidText;
    }
    for (value) |byte| {
        if (byte == 0 or byte == '\r' or byte == '\n' or byte < 0x20 or byte == 0x7f) {
            return error.InvalidText;
        }
    }
}

fn validateLowerHexDigest(value: []const u8) !void {
    if (value.len != Sha256.digest_length * 2) return error.InvalidDigest;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
            return error.InvalidDigest;
        }
    }
}

/// Stable binary TLV serialization in an explicit field order.  Provenance is
/// intentionally excluded because it does not change a browser observation.
pub fn computeObservableDigest(profile: *const ResolvedFingerprintProfile) [Sha256.digest_length]u8 {
    var digest = ObservableDigest.init();
    digest.string("format", "darkpanda-resolved-fingerprint-observables-v1");

    digest.string("browser.catalog_id", profile.browser.catalog_id);
    digest.string("browser.family", @tagName(profile.browser.family));
    digest.string("browser.os", @tagName(profile.browser.os));
    digest.string("browser.full_version", profile.browser.full_version);
    digest.string("browser.v8_version", profile.browser.v8_version);
    digest.string("browser.user_agent", profile.browser.user_agent);
    digest.string("browser.app_version", profile.browser.app_version);
    digest.brands("browser.brands", profile.browser.brands);
    digest.brands("browser.full_version_list", profile.browser.full_version_list);
    digest.string("browser.ua_platform", profile.browser.ua_platform);
    digest.string("browser.platform_version", profile.browser.platform_version);
    digest.string("browser.architecture", profile.browser.architecture);
    digest.string("browser.bitness", profile.browser.bitness);
    digest.boolean("browser.mobile", profile.browser.mobile);
    digest.boolean("browser.wow64", profile.browser.wow64);
    digest.string("browser.model", profile.browser.model);
    digest.strings("browser.form_factors", profile.browser.form_factors);

    digest.string("locale.locale", profile.locale.locale);
    digest.strings("locale.languages", profile.locale.languages);
    digest.string("locale.accept_language", profile.locale.accept_language);
    digest.string("locale.timezone", profile.locale.timezone);

    digest.string("navigator.platform", profile.navigator.platform);
    digest.unsigned("navigator.device_memory", profile.navigator.device_memory);
    digest.unsigned("navigator.hardware_concurrency", profile.navigator.hardware_concurrency);
    digest.unsigned("navigator.max_touch_points", profile.navigator.max_touch_points);
    if (profile.navigator.touch_capabilities) |touch| {
        digest.boolean("navigator.touch.present", true);
        digest.string("navigator.touch.bundle_id", touch.bundle_id);
        digest.boolean("navigator.touch.touch_event_api", touch.touch_event_api);
        digest.boolean("navigator.touch.touch_event_handlers", touch.touch_event_handlers);
        digest.boolean("navigator.touch.pointer_event_api", touch.pointer_event_api);
        digest.boolean("navigator.touch.css_any_pointer_coarse", touch.css_any_pointer_coarse);
    } else {
        digest.boolean("navigator.touch.present", false);
    }

    digest.unsigned("display.screen_width", profile.display.screen_width);
    digest.unsigned("display.screen_height", profile.display.screen_height);
    digest.unsigned("display.avail_width", profile.display.avail_width);
    digest.unsigned("display.avail_height", profile.display.avail_height);
    digest.signed("display.screen_x", profile.display.screen_x);
    digest.signed("display.screen_y", profile.display.screen_y);
    digest.unsigned("display.outer_width", profile.display.outer_width);
    digest.unsigned("display.outer_height", profile.display.outer_height);
    digest.unsigned("display.inner_width", profile.display.inner_width);
    digest.unsigned("display.inner_height", profile.display.inner_height);
    digest.float64("display.device_pixel_ratio", profile.display.device_pixel_ratio);
    digest.unsigned("display.color_depth", profile.display.color_depth);
    digest.unsigned("display.pixel_depth", profile.display.pixel_depth);
    digest.string("display.window_state", @tagName(profile.display.window_state));

    digest.string("graphics.bundle_id", profile.graphics.bundle_id);
    digest.string("graphics.canvas_backend", @tagName(profile.graphics.canvas_backend));
    digest.unsigned("graphics.profile_seed", profile.graphics.profile_seed);
    digest.unsigned("graphics.canvas_seed", profile.graphics.canvas_seed);
    digest.string("network.transport_profile_id", profile.network.transport_profile_id);
    digest.string("network.manifest_digest", profile.network.manifest_digest);
    return digest.final();
}

const ObservableDigest = struct {
    hash: Sha256,

    fn init() ObservableDigest {
        return .{ .hash = Sha256.init(.{}) };
    }

    fn begin(self: *ObservableDigest, name: []const u8, payload_len: u64) void {
        self.rawUnsigned(name.len);
        self.hash.update(name);
        self.rawUnsigned(payload_len);
    }

    fn string(self: *ObservableDigest, name: []const u8, value: []const u8) void {
        self.begin(name, value.len);
        self.hash.update(value);
    }

    fn boolean(self: *ObservableDigest, name: []const u8, value: bool) void {
        self.begin(name, 1);
        self.hash.update(if (value) &.{1} else &.{0});
    }

    fn unsigned(self: *ObservableDigest, name: []const u8, value: anytype) void {
        self.begin(name, 8);
        self.rawUnsigned(@intCast(value));
    }

    fn signed(self: *ObservableDigest, name: []const u8, value: anytype) void {
        self.begin(name, 8);
        const widened: i64 = @intCast(value);
        self.rawUnsigned(@bitCast(widened));
    }

    fn float64(self: *ObservableDigest, name: []const u8, value: f64) void {
        self.begin(name, 8);
        self.rawUnsigned(@bitCast(value));
    }

    fn strings(self: *ObservableDigest, name: []const u8, values: []const []const u8) void {
        self.begin(name, values.len);
        self.rawUnsigned(values.len);
        for (values) |value| {
            self.rawUnsigned(value.len);
            self.hash.update(value);
        }
    }

    fn brands(self: *ObservableDigest, name: []const u8, values: []const Brand) void {
        self.begin(name, values.len);
        self.rawUnsigned(values.len);
        for (values) |value| {
            self.rawUnsigned(value.brand.len);
            self.hash.update(value.brand);
            self.rawUnsigned(value.version.len);
            self.hash.update(value.version);
        }
    }

    fn rawUnsigned(self: *ObservableDigest, value: u64) void {
        var bytes: [8]u8 = undefined;
        for (&bytes, 0..) |*byte, i| {
            const shift: u6 = @intCast((7 - i) * 8);
            byte.* = @truncate(value >> shift);
        }
        self.hash.update(&bytes);
    }

    fn final(self: *ObservableDigest) [Sha256.digest_length]u8 {
        var out: [Sha256.digest_length]u8 = undefined;
        self.hash.final(&out);
        return out;
    }
};

fn hexLower(bytes: [Sha256.digest_length]u8) [Sha256.digest_length * 2]u8 {
    const alphabet = "0123456789abcdef";
    var out: [Sha256.digest_length * 2]u8 = undefined;
    for (bytes, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub const legacy_chrome149_windows_json =
    \\{
    \\  "schemaVersion": 2,
    \\  "browser": {
    \\    "catalogId": "chrome-149.0.7827.203-windows-x64",
    \\    "family": "chrome",
    \\    "os": "windows",
    \\    "fullVersion": "149.0.7827.203",
    \\    "v8Version": "14.9.207.35",
    \\    "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
    \\    "appVersion": "5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
    \\    "brands": [
    \\      {"brand":"Google Chrome","version":"149"},
    \\      {"brand":"Chromium","version":"149"},
    \\      {"brand":"Not)A;Brand","version":"24"}
    \\    ],
    \\    "fullVersionList": [
    \\      {"brand":"Google Chrome","version":"149.0.7827.203"},
    \\      {"brand":"Chromium","version":"149.0.7827.203"},
    \\      {"brand":"Not)A;Brand","version":"24.0.0.0"}
    \\    ],
    \\    "uaPlatform": "Windows",
    \\    "platformVersion": "19.0.0",
    \\    "architecture": "x86",
    \\    "bitness": "64",
    \\    "mobile": false,
    \\    "wow64": false,
    \\    "model": "",
    \\    "formFactors": ["Desktop"]
    \\  },
    \\  "locale": {
    \\    "locale": "en-US",
    \\    "languages": ["en-US", "en"],
    \\    "acceptLanguage": "en-US,en;q=0.9",
    \\    "timezone": "Etc/UTC"
    \\  },
    \\  "navigator": {
    \\    "platform": "Win32",
    \\    "deviceMemory": 8,
    \\    "hardwareConcurrency": 8,
    \\    "maxTouchPoints": 0,
    \\    "touchCapabilities": null
    \\  },
    \\  "display": {
    \\    "screenWidth": 1920,
    \\    "screenHeight": 1080,
    \\    "availWidth": 1920,
    \\    "availHeight": 1040,
    \\    "screenX": -1920,
    \\    "screenY": 0,
    \\    "outerWidth": 1296,
    \\    "outerHeight": 839,
    \\    "innerWidth": 1280,
    \\    "innerHeight": 720,
    \\    "devicePixelRatio": 1,
    \\    "colorDepth": 24,
    \\    "pixelDepth": 24,
    \\    "windowState": "normal"
    \\  },
    \\  "graphics": {
    \\    "bundleId":"angle-d3d11-generic-v1",
    \\    "canvasBackend":"skia",
    \\    "profileSeed":"445050524f46494c",
    \\    "canvasSeed":"445043414e564153"
    \\  },
    \\  "network": {
    \\    "transportProfileId": "wreq-6.0.0-rc.29/chrome149/windows-x64",
    \\    "manifestDigest": "a4f151202d8303f6523d0e2114cb7dd1bc0b771adb3fceab9b96baf9ae9fcdaa"
    \\  },
    \\  "provenance": {
    \\    "source": "legacy_catalog",
    \\    "dataset": "darkpanda/chrome-build-catalog",
    \\    "generatorVersion": "1",
    \\    "model": null,
    \\    "sourceRecordDigest": null
    \\  }
    \\}
;

fn replaceOnce(
    allocator: Allocator,
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const start = std.mem.indexOf(u8, input, needle) orelse return error.TestNeedleMissing;
    const output = try allocator.alloc(u8, input.len - needle.len + replacement.len);
    @memcpy(output[0..start], input[0..start]);
    @memcpy(output[start .. start + replacement.len], replacement);
    @memcpy(output[start + replacement.len ..], input[start + needle.len ..]);
    return output;
}

test "legacy Chrome149 Windows profile is exact, owned, and digest-stable" {
    const allocator = std.testing.allocator;
    var first = try Owned.legacyChrome149Windows(allocator);
    defer first.deinit();
    var second = try Owned.legacyChrome149Windows(allocator);
    defer second.deinit();

    const profile = first.get();
    try std.testing.expectEqualStrings(chrome149_full_version, profile.browser.full_version);
    try std.testing.expectEqualStrings(chrome149_v8_version, profile.browser.v8_version);
    try std.testing.expectEqual(@as(u8, 8), profile.navigator.device_memory);
    try std.testing.expectEqual(@as(i32, -1920), profile.display.screen_x);
    try std.testing.expectEqual(CanvasBackendKind.skia, profile.graphics.canvas_backend);
    try std.testing.expectEqual(@as(u64, 0x4450_5052_4f46_494c), profile.graphics.profile_seed);
    try std.testing.expectEqual(@as(u64, 0x4450_4341_4e56_4153), profile.graphics.canvas_seed);
    try std.testing.expectEqualSlices(u8, &profile.observable_digest, &second.get().observable_digest);
    try std.testing.expectEqualSlices(
        u8,
        &profile.observable_digest,
        &computeObservableDigest(profile),
    );
}

test "legacy locale and timezone inputs resolve once into an owned profile" {
    const allocator = std.testing.allocator;
    const languages = [_][]const u8{ "zh-Hans-CN", "zh" };
    var owned = try Owned.legacyChrome149WindowsWithLocale(
        allocator,
        "zh-Hans-CN",
        &languages,
        "zh-Hans-CN,zh;q=0.9",
        "Asia/Shanghai",
    );
    defer owned.deinit();

    const profile = owned.get();
    try std.testing.expectEqualStrings("zh-Hans-CN", profile.locale.locale);
    try std.testing.expectEqualStrings("zh", profile.locale.languages[1]);
    try std.testing.expectEqualStrings("zh-Hans-CN,zh;q=0.9", profile.locale.accept_language);
    try std.testing.expectEqualStrings("Asia/Shanghai", profile.locale.timezone);
    try std.testing.expectEqualStrings("Desktop", profile.browser.form_factors[0]);
    try std.testing.expectEqualSlices(
        u8,
        &profile.observable_digest,
        &computeObservableDigest(profile),
    );
}

test "strict JSON rejects unknown fields, duplicate fields, size, and depth" {
    const allocator = std.testing.allocator;

    const unknown = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"schemaVersion\": 2,",
        "\"schemaVersion\": 2, \"unknown\": true,",
    );
    defer allocator.free(unknown);
    try std.testing.expectError(error.UnknownField, Owned.parseJson(allocator, unknown));

    const duplicate = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"schemaVersion\": 2,",
        "\"schemaVersion\": 2, \"schemaVersion\": 2,",
    );
    defer allocator.free(duplicate);
    try std.testing.expectError(error.DuplicateField, Owned.parseJson(allocator, duplicate));

    const oversized = try allocator.alloc(u8, max_profile_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.ProfileTooLarge, Owned.parseJson(allocator, oversized));

    const too_deep = "[" ** (max_json_depth + 1) ++ "0" ++ "]" ** (max_json_depth + 1);
    try std.testing.expectError(error.ProfileTooDeep, Owned.parseJson(allocator, too_deep));
}

test "schema v2 requires canonical Canvas identity hex strings" {
    const allocator = std.testing.allocator;

    const old_schema = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"schemaVersion\": 2",
        "\"schemaVersion\": 1",
    );
    defer allocator.free(old_schema);
    try std.testing.expectError(error.UnsupportedSchemaVersion, Owned.parseJson(allocator, old_schema));

    const missing_backend = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"canvasBackend\":\"skia\",\n",
        "",
    );
    defer allocator.free(missing_backend);
    try std.testing.expectError(error.MissingField, Owned.parseJson(allocator, missing_backend));

    const missing_profile_seed = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"profileSeed\":\"445050524f46494c\",\n",
        "",
    );
    defer allocator.free(missing_profile_seed);
    try std.testing.expectError(error.MissingField, Owned.parseJson(allocator, missing_profile_seed));

    const missing_canvas_seed = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"profileSeed\":\"445050524f46494c\",\n    \"canvasSeed\":\"445043414e564153\"",
        "\"profileSeed\":\"445050524f46494c\"",
    );
    defer allocator.free(missing_canvas_seed);
    try std.testing.expectError(error.MissingField, Owned.parseJson(allocator, missing_canvas_seed));

    const unsupported_backend = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"canvasBackend\":\"skia\"",
        "\"canvasBackend\":\"gpu\"",
    );
    defer allocator.free(unsupported_backend);
    try std.testing.expectError(error.InvalidEnumTag, Owned.parseJson(allocator, unsupported_backend));

    const uppercase = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "445050524f46494c",
        "445050524F46494C",
    );
    defer allocator.free(uppercase);
    try std.testing.expectError(error.InvalidCanvasSeed, Owned.parseJson(allocator, uppercase));

    const prefixed = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "445050524f46494c",
        "0x445050524f4649",
    );
    defer allocator.free(prefixed);
    try std.testing.expectError(error.InvalidCanvasSeed, Owned.parseJson(allocator, prefixed));

    const short = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "445050524f46494c",
        "445050524f46494",
    );
    defer allocator.free(short);
    try std.testing.expectError(error.InvalidCanvasSeed, Owned.parseJson(allocator, short));

    const non_hex = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "445050524f46494c",
        "445050524f46494g",
    );
    defer allocator.free(non_hex);
    try std.testing.expectError(error.InvalidCanvasSeed, Owned.parseJson(allocator, non_hex));
}

test "Canvas backend and seeds are observable profile identity" {
    const allocator = std.testing.allocator;
    var skia = try Owned.legacyChrome149Windows(allocator);
    defer skia.deinit();

    const fake_json = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"canvasBackend\":\"skia\"",
        "\"canvasBackend\":\"fake\"",
    );
    defer allocator.free(fake_json);
    const seeded_json = try replaceOnce(
        allocator,
        fake_json,
        "445043414e564153",
        "000000000000002a",
    );
    defer allocator.free(seeded_json);
    var fake = try Owned.parseJson(allocator, seeded_json);
    defer fake.deinit();

    try std.testing.expectEqual(CanvasBackendKind.fake, fake.get().graphics.canvas_backend);
    try std.testing.expectEqual(@as(u64, 42), fake.get().graphics.canvas_seed);
    try std.testing.expect(!std.mem.eql(
        u8,
        &skia.get().observable_digest,
        &fake.get().observable_digest,
    ));

    var only_seed_changed = skia.get().*;
    only_seed_changed.graphics.canvas_seed +%= 1;
    const seed_digest = computeObservableDigest(&only_seed_changed);
    try std.testing.expect(!std.mem.eql(u8, &skia.get().observable_digest, &seed_digest));
}

test "Chrome build, UA metadata, and transport are catalog-owned" {
    const allocator = std.testing.allocator;
    const wrong_v8 = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "14.9.207.35",
        "14.9.207.36",
    );
    defer allocator.free(wrong_v8);
    try std.testing.expectError(error.BrowserBuildMismatch, Owned.parseJson(allocator, wrong_v8));

    const wrong_bitness = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"bitness\": \"64\"",
        "\"bitness\": \"32\"",
    );
    defer allocator.free(wrong_bitness);
    try std.testing.expectError(error.UserAgentMetadataMismatch, Owned.parseJson(allocator, wrong_bitness));

    const wrong_transport = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        chrome149_transport_profile_id,
        "wreq-untrusted/chrome149/windows-x64",
    );
    defer allocator.free(wrong_transport);
    try std.testing.expectError(error.TransportCatalogMismatch, Owned.parseJson(allocator, wrong_transport));
}

test "locale and Accept-Language must be one coherent identity" {
    const allocator = std.testing.allocator;

    // Chrome may expose only its application locale to JavaScript while the
    // HTTP preference keeps a language fallback. The header must start with
    // every navigator language, but is allowed to contain extra ranges.
    const shorter_navigator_languages = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"languages\": [\"en-US\", \"en\"]",
        "\"languages\": [\"en-US\"]",
    );
    defer allocator.free(shorter_navigator_languages);
    var chrome_lang_split = try Owned.parseJson(allocator, shorter_navigator_languages);
    defer chrome_lang_split.deinit();
    try std.testing.expectEqual(@as(usize, 1), chrome_lang_split.get().locale.languages.len);
    try std.testing.expectEqualStrings(
        "en-US,en;q=0.9",
        chrome_lang_split.get().locale.accept_language,
    );

    const mismatch = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"acceptLanguage\": \"en-US,en;q=0.9\"",
        "\"acceptLanguage\": \"fr-FR,fr;q=0.9\"",
    );
    defer allocator.free(mismatch);
    try std.testing.expectError(error.AcceptLanguageMismatch, Owned.parseJson(allocator, mismatch));

    const noncanonical = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"locale\": \"en-US\"",
        "\"locale\": \"EN-us\"",
    );
    defer allocator.free(noncanonical);
    try std.testing.expectError(error.LocaleLanguageMismatch, Owned.parseJson(allocator, noncanonical));
}

test "Windows memory, touch bundles, normal windows, and finite DPR are validated" {
    const allocator = std.testing.allocator;
    const bad_memory = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"deviceMemory\": 8",
        "\"deviceMemory\": 12",
    );
    defer allocator.free(bad_memory);
    try std.testing.expectError(error.InvalidDeviceMemory, Owned.parseJson(allocator, bad_memory));

    const missing_touch = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"maxTouchPoints\": 0",
        "\"maxTouchPoints\": 10",
    );
    defer allocator.free(missing_touch);
    try std.testing.expectError(error.TouchCapabilityBundleRequired, Owned.parseJson(allocator, missing_touch));

    const invalid_normal = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"innerWidth\": 1280",
        "\"innerWidth\": 1400",
    );
    defer allocator.free(invalid_normal);
    try std.testing.expectError(error.InvalidNormalWindowGeometry, Owned.parseJson(allocator, invalid_normal));

    const infinite = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"devicePixelRatio\": 1",
        "\"devicePixelRatio\": 1e9999",
    );
    defer allocator.free(infinite);
    try std.testing.expectError(error.InvalidDevicePixelRatio, Owned.parseJson(allocator, infinite));
}

test "Windows memory 32 and a complete touch bundle are accepted" {
    const allocator = std.testing.allocator;
    const memory_32 = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"deviceMemory\": 8",
        "\"deviceMemory\": 32",
    );
    defer allocator.free(memory_32);
    const touch_count = try replaceOnce(
        allocator,
        memory_32,
        "\"maxTouchPoints\": 0",
        "\"maxTouchPoints\": 10",
    );
    defer allocator.free(touch_count);
    const touch_profile = try replaceOnce(
        allocator,
        touch_count,
        "\"touchCapabilities\": null",
        "\"touchCapabilities\":{" ++
            "\"bundleId\":\"windows-precision-touch-v1\"," ++
            "\"touchEventApi\":true," ++
            "\"touchEventHandlers\":true," ++
            "\"pointerEventApi\":true," ++
            "\"cssAnyPointerCoarse\":true}",
    );
    defer allocator.free(touch_profile);

    var owned = try Owned.parseJson(allocator, touch_profile);
    defer owned.deinit();
    try std.testing.expectEqual(@as(u8, 32), owned.get().navigator.device_memory);
    try std.testing.expectEqual(@as(u8, 10), owned.get().navigator.max_touch_points);
    try std.testing.expect(owned.get().navigator.touch_capabilities != null);
}

test "inner versus outer bounds are only imposed on normal windows" {
    const allocator = std.testing.allocator;
    const wide_inner = try replaceOnce(
        allocator,
        legacy_chrome149_windows_json,
        "\"innerWidth\": 1280",
        "\"innerWidth\": 1400",
    );
    defer allocator.free(wide_inner);
    const maximized = try replaceOnce(
        allocator,
        wide_inner,
        "\"windowState\": \"normal\"",
        "\"windowState\": \"maximized\"",
    );
    defer allocator.free(maximized);

    var owned = try Owned.parseJson(allocator, maximized);
    defer owned.deinit();
    try std.testing.expectEqual(WindowState.maximized, owned.get().display.window_state);
}

test "observable digest excludes provenance and includes display changes" {
    const allocator = std.testing.allocator;
    var owned = try Owned.legacyChrome149Windows(allocator);
    defer owned.deinit();

    var changed = owned.get().*;
    changed.provenance.source = .manual;
    const provenance_digest = computeObservableDigest(&changed);
    try std.testing.expectEqualSlices(u8, &owned.get().observable_digest, &provenance_digest);

    changed.display.screen_x = -100;
    const display_digest = computeObservableDigest(&changed);
    try std.testing.expect(!std.mem.eql(u8, &owned.get().observable_digest, &display_digest));
}
