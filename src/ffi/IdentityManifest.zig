// Copyright (C) 2026 DarkPanda contributors
//
// Machine-readable evidence tying the one resolved fingerprint to its actual
// consumers. This is deliberately not a TLS attestation: wreq exposes its
// build/version and selected numeric emulation preset, but neither wreq nor
// BoringSSL exposes a cryptographic proof of the loaded TLS implementation.

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("darkpanda");
const App = lp.App;
const Browser = lp.Browser;
const FingerprintProfile = lp.FingerprintProfile;
const js = lp.js;

const Allocator = std.mem.Allocator;

const ProfileReport = struct {
    schemaVersion: u16,
    catalogId: []const u8,
    observableDigest: []const u8,
    browserFullVersion: []const u8,
    declaredV8Version: []const u8,
    transportProfileId: []const u8,
    transportManifestDigest: []const u8,
};

const JavascriptRuntimeReport = struct {
    actualV8Version: []const u8,
    icuApplicationLocale: []const u8,
    icuTimeZone: []const u8,
    configureIcuAccepted: bool,
    numericIcuVersionAvailable: bool,
    consumedProfileFields: []const []const u8,
};

const HeaderReport = struct {
    source: []const u8,
    userAgent: []const u8,
    acceptLanguage: []const u8,
    secChUa: []const u8,
    secChUaMobile: []const u8,
    secChUaPlatform: []const u8,
    wreqDefaultHeadersDisabled: bool,
    consumedProfileFields: []const []const u8,
};

const CanvasReport = struct {
    selectionSource: []const u8,
    configuredBackend: []const u8,
    configuredProfileSeed: []const u8,
    configuredCanvasSeed: []const u8,
    actualDriverQueried: bool,
    runtimeBackendAttested: bool,
    gpuAttested: bool,
    implementationBoundary: []const u8,
};

const TlsReport = struct {
    backendClaim: []const u8,
    claimSource: []const u8,
    runtimeAttested: bool,
    note: []const u8,
};

const TransportConsumption = struct {
    directInputs: []const []const u8,
    transportProfileIdPassedDirectly: bool,
    manifestDigestPassedDirectly: bool,
    catalogMapping: []const u8,
};

const TransportReport = struct {
    backend: []const u8,
    libraryVersion: []const u8,
    wreqAbiVersion: ?u32,
    configuredNumericProfileId: ?u32,
    emulationPresetClaim: ?[]const u8,
    emulationPresetRuntimeQueried: bool,
    consumption: TransportConsumption,
    tls: TlsReport,
};

const ConsistencyReport = struct {
    v8VersionMatchesCatalog: bool,
    icuConfigurationMatchesProfile: bool,
    httpHeadersMatchProfile: bool,
    transportManifestValidatedDuringProfileResolution: bool,
    transportBackendMatchesCatalog: bool,
    wreqDependencyVersionsMatchCatalog: bool,
    configuredWreqProfileIdMatchesCatalog: bool,
    allNonTlsAttestedChecksPass: bool,
    tlsRuntimeAttested: bool,
};

const Report = struct {
    reportSchemaVersion: u16,
    target: []const u8,
    profile: ProfileReport,
    javascriptRuntime: JavascriptRuntimeReport,
    httpHeaders: HeaderReport,
    canvas: CanvasReport,
    transport: TransportReport,
    consistency: ConsistencyReport,
};

const javascript_consumed_fields = [_][]const u8{
    "browser.v8Version",
    "locale.locale",
    "locale.timezone",
};
const header_consumed_fields = [_][]const u8{
    "browser.userAgent",
    "browser.brands",
    "browser.mobile",
    "browser.uaPlatform",
    "locale.acceptLanguage",
};
const transport_direct_inputs = [_][]const u8{
    "numeric profileId=149",
    "ordered request headers supplied by DarkPanda",
    "proxy URL",
    "TLS verification policy",
};

pub fn build(allocator: Allocator, app: *const App, browser: *const Browser) ![]u8 {
    const profile = app.resolvedFingerprint() orelse
        return error.ResolvedFingerprintUnavailable;
    const headers = browser.http_client.identityEvidence();
    const transport = browser.http_client.transportEvidence();
    const actual_v8 = std.mem.span(js.v8.v8__V8__GetVersion());
    var observable_digest = profile.observableDigestHex();
    var canvas_profile_seed_buffer: [16]u8 = undefined;
    const canvas_profile_seed = try std.fmt.bufPrint(
        &canvas_profile_seed_buffer,
        "{x:0>16}",
        .{profile.graphics.profile_seed},
    );
    var canvas_seed_buffer: [16]u8 = undefined;
    const canvas_seed = try std.fmt.bufPrint(
        &canvas_seed_buffer,
        "{x:0>16}",
        .{profile.graphics.canvas_seed},
    );

    const v8_matches = std.mem.eql(u8, actual_v8, profile.browser.v8_version);
    const icu_matches = std.mem.eql(
        u8,
        app.config.http_headers.locale_profile.application_locale,
        profile.locale.locale,
    ) and std.mem.eql(
        u8,
        app.config.timeZone() orelse "Etc/UTC",
        profile.locale.timezone,
    );
    const headers_match = std.mem.eql(u8, headers.user_agent, profile.browser.user_agent) and
        std.mem.eql(u8, headers.accept_language, profile.locale.accept_language) and
        std.mem.eql(u8, headers.sec_ch_ua_mobile, if (profile.browser.mobile) "?1" else "?0") and
        std.mem.eql(u8, headers.sec_ch_ua_platform, "\"Windows\"");

    const backend_matches = std.mem.eql(u8, transport.backend, "wreq");
    const version_matches = backend_matches and
        std.mem.indexOf(u8, transport.library_version, "wreq/6.0.0-rc.29") != null and
        std.mem.indexOf(u8, transport.library_version, "wreq-util/3.0.0-rc.14") != null;
    const configured_profile_id_matches = transport.wreq_profile_id == 149;
    const non_tls_all = v8_matches and icu_matches and headers_match and
        backend_matches and version_matches and configured_profile_id_matches;

    const report: Report = .{
        // Version 2 adds the configured Canvas selection while preserving the
        // distinction between profile configuration and runtime attestation.
        .reportSchemaVersion = 2,
        .target = @tagName(builtin.os.tag),
        .profile = .{
            .schemaVersion = FingerprintProfile.schema_version,
            .catalogId = profile.browser.catalog_id,
            .observableDigest = &observable_digest,
            .browserFullVersion = profile.browser.full_version,
            .declaredV8Version = profile.browser.v8_version,
            .transportProfileId = profile.network.transport_profile_id,
            .transportManifestDigest = profile.network.manifest_digest,
        },
        .javascriptRuntime = .{
            .actualV8Version = actual_v8,
            .icuApplicationLocale = profile.locale.locale,
            .icuTimeZone = profile.locale.timezone,
            .configureIcuAccepted = true,
            // The current V8 binding exposes ConfigureICU success and the
            // actual V8 version, not ICU's numeric library version.
            .numericIcuVersionAvailable = false,
            .consumedProfileFields = &javascript_consumed_fields,
        },
        .httpHeaders = .{
            .source = "ResolvedFingerprintProfile",
            .userAgent = headers.user_agent,
            .acceptLanguage = headers.accept_language,
            .secChUa = headers.sec_ch_ua,
            .secChUaMobile = headers.sec_ch_ua_mobile,
            .secChUaPlatform = headers.sec_ch_ua_platform,
            .wreqDefaultHeadersDisabled = true,
            .consumedProfileFields = &header_consumed_fields,
        },
        .canvas = .{
            .selectionSource = "ResolvedFingerprintProfile.graphics",
            .configuredBackend = @tagName(profile.graphics.canvas_backend),
            .configuredProfileSeed = canvas_profile_seed,
            .configuredCanvasSeed = canvas_seed,
            // The Runtime-level manifest has no Page surface and therefore
            // cannot truthfully report Provider.actualDriver or a live GPU.
            .actualDriverQueried = false,
            .runtimeBackendAttested = false,
            .gpuAttested = false,
            .implementationBoundary = "configured selection only; dynamic Canvas uses the Chromium M149 Skia CPU backend through ABI v5, not Chrome GPU raster/antialiasing; actual driver and fallback outcome are not queried",
        },
        .transport = .{
            .backend = transport.backend,
            .libraryVersion = transport.library_version,
            .wreqAbiVersion = transport.wreq_abi_version,
            .configuredNumericProfileId = transport.wreq_profile_id,
            .emulationPresetClaim = transport.emulation_preset,
            // wreq's current ABI accepts the configured numeric ID but does
            // not expose a getter for the selected internal Profile enum.
            .emulationPresetRuntimeQueried = false,
            .consumption = .{
                .directInputs = &transport_direct_inputs,
                // These catalog strings are validated by DarkPanda and map to
                // numeric profile 149. They are intentionally not presented
                // as values wreq itself parses or consumes.
                .transportProfileIdPassedDirectly = false,
                .manifestDigestPassedDirectly = false,
                .catalogMapping = "validated transportProfileId/manifestDigest -> numeric profileId 149",
            },
            .tls = .{
                .backendClaim = "BoringSSL",
                .claimSource = "resolved catalog + pinned wreq build manifest",
                .runtimeAttested = false,
                .note = "build/catalog claim only; no cryptographic runtime TLS attestation API is available",
            },
        },
        .consistency = .{
            .v8VersionMatchesCatalog = v8_matches,
            .icuConfigurationMatchesProfile = icu_matches,
            .httpHeadersMatchProfile = headers_match,
            .transportManifestValidatedDuringProfileResolution = true,
            .transportBackendMatchesCatalog = backend_matches,
            .wreqDependencyVersionsMatchCatalog = version_matches,
            .configuredWreqProfileIdMatchesCatalog = configured_profile_id_matches,
            .allNonTlsAttestedChecksPass = non_tls_all,
            .tlsRuntimeAttested = false,
        },
    };
    return std.json.Stringify.valueAlloc(allocator, report, .{});
}
