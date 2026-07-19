// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("darkpanda");

const Config = @import("Config.zig");
const Snapshot = @import("browser/js/Snapshot.zig");
const Platform = @import("browser/js/Platform.zig");
const Storage = @import("storage/Storage.zig");
const Network = @import("network/Network.zig");
const wreq = @import("sys/wreq_transport.zig");
const Watchdog = @import("Watchdog.zig");
const FingerprintProfile = @import("FingerprintProfile.zig");
const CanvasBackendProvider = @import("browser/canvas_backend/Provider.zig");
pub const ArenaPool = @import("ArenaPool.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const App = @This();

pub const InitOptions = struct {
    wreq_transport_path: ?[]const u8 = null,
    /// When null, Pages retain the CLI/environment selection path. Embedders
    /// pass an explicit mechanics policy so Canvas is preflighted before V8.
    canvas_backend_options: ?CanvasBackendProvider.Options = null,
    /// Complete, strict schema-v2 profile supplied by an embedder. App owns
    /// the parsed graph; the caller may release the JSON after init returns.
    fingerprint_profile_json: ?[]const u8 = null,
};

network: Network,
config: *const Config,
storage: Storage,
platform: Platform,
snapshot: Snapshot,
watchdog: Watchdog,
allocator: Allocator,
arena_pool: ArenaPool,
// The sole owner of the resolved browser identity. Browsers, Pages and Worker
// executions only retain const borrows into this App-lifetime allocation.
fingerprint_profile: ?FingerprintProfile.Owned,
canvas_backend_options: ?CanvasBackendProvider.Options,
canvas_backend_library_path: ?[]u8,

pub fn init(allocator: Allocator, config: *const Config) !*App {
    return initWithOptions(allocator, config, .{});
}

pub fn initWithOptions(allocator: Allocator, config: *const Config, options: InitOptions) !*App {
    const custom_fingerprint = options.fingerprint_profile_json != null;
    if (custom_fingerprint and config.clientProfile() != .chrome149) {
        return error.FingerprintClientProfileConflict;
    }

    var fingerprint_profile: ?FingerprintProfile.Owned = if (options.fingerprint_profile_json) |json|
        try FingerprintProfile.Owned.parseJson(allocator, json)
    else if (config.clientProfile() == .chrome149) blk: {
        const locale_profile = &config.http_headers.locale_profile;
        const header_prefix = "Accept-Language: ";
        if (!std.mem.startsWith(u8, locale_profile.accept_language_header, header_prefix)) {
            return error.FingerprintLocaleConflict;
        }
        break :blk try FingerprintProfile.Owned.legacyChrome149WindowsWithLocale(
            allocator,
            locale_profile.application_locale,
            locale_profile.languages(),
            locale_profile.accept_language_header[header_prefix.len..],
            config.timeZone(),
        );
    } else null;
    errdefer if (fingerprint_profile) |*profile| profile.deinit();

    const resolved_profile = if (fingerprint_profile) |*profile| profile.get() else null;
    if (resolved_profile) |profile| {
        const locale_profile = &config.http_headers.locale_profile;
        if (!std.mem.eql(u8, profile.locale.locale, locale_profile.application_locale)) {
            return error.FingerprintLocaleConflict;
        }
        // The legacy adapter derives its language list from Config. A custom
        // strict profile may carry a longer, already-validated list; browser
        // and HTTP consumers read that list from the resolved profile while
        // ICU only consumes the application locale above.
        if (!custom_fingerprint and
            !stringSlicesEqual(profile.locale.languages, locale_profile.languages()))
        {
            return error.FingerprintLocaleConflict;
        }
        const configured_timezone = config.timeZone() orelse "Etc/UTC";
        if (!std.mem.eql(u8, profile.locale.timezone, configured_timezone)) {
            return error.FingerprintTimeZoneConflict;
        }
    }

    // V8 cannot be initialized again after DisposePlatform. Exercise the full
    // Windows wreq load/ABI/create path first, so configuration or transport
    // failures leave the process eligible for a corrected Runtime.start call.
    try wreq.preflight(allocator, .{
        .explicit_path = options.wreq_transport_path,
        .proxy_url = if (config.httpProxy()) |proxy| proxy else "",
        .event_capacity = wreq.default_event_capacity,
        .profile_id = wreq.profile_chrome_149,
        .tls_verify = config.tlsVerifyHost(),
        .dns_nameservers = config.wreqDnsNameservers() orelse "",
    });

    if (options.canvas_backend_options) |canvas_options| {
        var canvas_preflight = try CanvasBackendProvider.init(allocator, canvas_options);
        canvas_preflight.deinit();
    }

    var canvas_backend_options = options.canvas_backend_options;
    var canvas_backend_library_path: ?[]u8 = null;
    if (canvas_backend_options) |*canvas_options| {
        if (canvas_options.library_path) |path| {
            canvas_backend_library_path = try allocator.dupe(u8, path);
            canvas_options.library_path = canvas_backend_library_path;
        }
    }
    errdefer if (canvas_backend_library_path) |path| allocator.free(path);

    const platform = try Platform.initWithLocale(
        config.v8Flags(),
        config.http_headers.locale_profile.application_locale,
        if (resolved_profile != null) config.timeZone() orelse "Etc/UTC" else config.timeZone(),
    );
    errdefer platform.deinit();

    const snapshot = try Snapshot.load();
    errdefer snapshot.deinit();

    var storage = try Storage.init(allocator, config);
    errdefer storage.deinit(allocator);

    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .config = config,
        .allocator = allocator,
        .platform = platform,
        .snapshot = snapshot,
        .storage = storage,
        .network = undefined,
        .arena_pool = undefined,
        .watchdog = .init(config.watchdogMs()),
        .fingerprint_profile = fingerprint_profile,
        .canvas_backend_options = canvas_backend_options,
        .canvas_backend_library_path = canvas_backend_library_path,
    };
    try app.watchdog.start();
    errdefer app.watchdog.deinit();

    app.network = try Network.initWithOptions(allocator, app, config, .{
        .wreq_transport_path = options.wreq_transport_path,
    });
    errdefer app.network.deinit();

    app.arena_pool = ArenaPool.init(allocator, .{});
    errdefer app.arena_pool.deinit();

    return app;
}

pub fn shutdown(self: *const App) bool {
    return self.network.shutdown.load(.acquire);
}

pub fn resolvedFingerprint(self: *const App) ?*const FingerprintProfile.ResolvedFingerprintProfile {
    if (self.fingerprint_profile) |*profile| return profile.get();
    return null;
}

pub fn deinit(self: *App) void {
    const allocator = self.allocator;
    // All browsers are gone by now, so the entry list is empty; this just
    // stops the checker thread.
    self.watchdog.deinit();
    self.network.deinit();
    self.snapshot.deinit();
    self.platform.deinit();
    self.arena_pool.deinit();
    self.storage.deinit(allocator);
    if (self.fingerprint_profile) |*profile| profile.deinit();
    if (self.canvas_backend_library_path) |path| allocator.free(path);

    allocator.destroy(self);
}

fn stringSlicesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}
