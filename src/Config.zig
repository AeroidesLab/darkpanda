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
const log = lp.log;
const builtin = @import("builtin");

const Locale = @import("Locale.zig");
const ClientProfile = @import("ClientProfile.zig");

const Storage = @import("storage/Storage.zig");

const Allocator = std.mem.Allocator;

// TCP keepalive parameters applied to accepted CDP connections.
// Detection window ≈ IDLE + CNT * INTVL = 4 + 3*2 = 10s.
pub const CDP_KEEPALIVE_IDLE_S: c_int = 4;
pub const CDP_KEEPALIVE_INTVL_S: c_int = 2;
pub const CDP_KEEPALIVE_CNT: c_int = 3;

const Config = @This();

/// Browser/embedder configuration intentionally kept out of the standalone
/// command line. FFI and tests construct this type directly; the public CLI is
/// limited to the five serve parameters below.
pub const CoreOptions = struct {
    proxy_bearer_token: ?[:0]const u8 = null,
    proxy: ?[:0]const u8 = null,
    wreq_dns_nameservers: ?[]const u8 = null,
    http_max_concurrent: u8 = 40,
    http_max_host_open: u8 = 6,
    http_timeout: u31 = 5000,
    http_connect_timeout: u31 = 0,
    http_max_response_size: ?usize = null,
    ws_max_concurrent: u8 = 8,
    tls_verify_host: bool = true,
    log_level: ?log.Level = null,
    log_format: ?log.Format = null,
    log_filter_scopes: std.ArrayList(log.FilterRule) = .empty,
    locale: ?[:0]const u8 = null,
    timezone: ?[:0]const u8 = null,
    client_profile: ClientProfile.Id = ClientProfile.target_default,
    user_agent_suffix: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    storage_engine: ?Storage.EngineType = null,
    storage_sqlite_path: ?[:0]const u8 = null,
    disable_subframes: bool = false,
    disable_workers: bool = false,
    enable_external_stylesheets: bool = false,
    v8_flags_unsafe: ?[]const u8 = null,
    v8_max_heap_mb: ?u32 = null,
    watchdog_ms: ?u32 = null,
};

/// The standalone executable is only a CDP server. Keep its command surface
/// explicit so removed fetch/agent/MCP options cannot survive through a
/// generic parser or accidentally become supported again.
pub const ServeOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9222,
    profile: ClientProfile.Id = ClientProfile.target_default,
    timeout: ?u31 = null,
    proxy: ?[:0]const u8 = null,
};

pub const RunMode = enum { help, serve, version };
pub const Mode = union(RunMode) {
    help: RunMode,
    serve: ServeOptions,
    version: void,
};

mode: Mode,
exec_name: []const u8,
core: CoreOptions,
http_headers: HttpHeaders,

fn modeNeedsHttp(mode: Mode) bool {
    return switch (mode) {
        .serve => true,
        .help, .version => false,
    };
}

pub fn init(allocator: Allocator, exec_name: []const u8, mode: Mode) !Config {
    var core: CoreOptions = .{};
    switch (mode) {
        .serve => |opts| {
            core.client_profile = opts.profile;
            core.http_timeout = opts.timeout orelse core.http_timeout;
            core.proxy = opts.proxy;
        },
        else => {},
    }
    return initCore(allocator, exec_name, mode, core);
}

pub fn initCore(allocator: Allocator, exec_name: []const u8, mode: Mode, core: CoreOptions) !Config {
    var config = Config{
        .mode = mode,
        .exec_name = exec_name,
        .core = core,
        .http_headers = undefined,
    };
    if (modeNeedsHttp(mode)) {
        try Locale.validateTimeZone(config.timeZone());
        try validateClientProfileTransport(config.clientProfile(), builtin.os.tag);
        config.http_headers = try HttpHeaders.init(allocator, &config);
    }
    return config;
}

/// HTTP is always wreq's Chrome149 emulation on every supported platform.
/// Refuse an application identity that would split JS/HTTP from TLS/HTTP2.
pub fn validateClientProfileTransport(profile: ClientProfile.Id, _: std.Target.Os.Tag) !void {
    if (profile != .chrome149) {
        return error.ClientProfileTransportMismatch;
    }
}

pub fn deinit(self: *const Config, allocator: Allocator) void {
    if (modeNeedsHttp(self.mode)) {
        self.http_headers.deinit(allocator);
    }
}

pub fn interactive(self: *const Config) bool {
    return switch (self.mode) {
        .serve => true,
        else => unreachable,
    };
}

pub fn tlsVerifyHost(self: *const Config) bool {
    return self.core.tls_verify_host;
}

pub fn disableSubframes(self: *const Config) bool {
    return self.core.disable_subframes;
}

pub fn disableWorkers(self: *const Config) bool {
    return self.core.disable_workers;
}

pub fn watchdogMs(self: *const Config) ?u32 {
    const ms = self.core.watchdog_ms orelse 30000;
    return if (ms == 0) null else ms;
}

pub fn enableExternalStylesheets(self: *const Config) bool {
    return self.core.enable_external_stylesheets;
}

pub fn v8Flags(self: *const Config) ?[]const u8 {
    return self.core.v8_flags_unsafe;
}

pub fn v8MaxHeapMb(self: *const Config) ?u32 {
    return self.core.v8_max_heap_mb;
}

pub fn httpProxy(self: *const Config) ?[:0]const u8 {
    return self.core.proxy;
}

pub fn wreqDnsNameservers(self: *const Config) ?[]const u8 {
    return self.core.wreq_dns_nameservers;
}

pub fn proxyBearerToken(self: *const Config) ?[:0]const u8 {
    return self.core.proxy_bearer_token;
}

pub fn httpMaxConcurrent(self: *const Config) u8 {
    return self.core.http_max_concurrent;
}

pub fn httpMaxHostOpen(self: *const Config) u8 {
    return self.core.http_max_host_open;
}

pub fn httpConnectTimeout(self: *const Config) u31 {
    return self.core.http_connect_timeout;
}

pub fn httpTimeout(self: *const Config) u31 {
    return self.core.http_timeout;
}

pub fn httpMaxRedirects(_: *const Config) u8 {
    return 10;
}

pub fn httpMaxResponseSize(self: *const Config) ?usize {
    return self.core.http_max_response_size;
}

pub fn wsMaxConcurrent(self: *const Config) u8 {
    return self.core.ws_max_concurrent;
}

pub fn logLevel(self: *const Config) ?log.Level {
    return self.core.log_level;
}

pub fn logFormat(self: *const Config) ?log.Format {
    return self.core.log_format;
}

pub fn logFilterScopes(self: *const Config) std.ArrayList(log.FilterRule) {
    return self.core.log_filter_scopes;
}

pub fn userAgentSuffix(self: *const Config) ?[]const u8 {
    return self.core.user_agent_suffix;
}

pub fn userAgent(self: *const Config) ?[]const u8 {
    return self.core.user_agent;
}

pub fn clientProfile(self: *const Config) ClientProfile.Id {
    return self.core.client_profile;
}

/// Application locale shared by Navigator, Accept-Language and ICU/V8 Intl.
/// The canonical, owned form is stored in `http_headers.locale_profile`.
pub fn requestedLocale(self: *const Config) []const u8 {
    return self.core.locale orelse Locale.default_application_locale;
}

/// Null means that ICU/V8 detects and follows the host system timezone.
pub fn timeZone(self: *const Config) ?[:0]const u8 {
    return self.core.timezone;
}

pub fn port(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.port,
        else => unreachable,
    };
}

pub fn advertiseHost(self: *const Config) []const u8 {
    return switch (self.mode) {
        .serve => |opts| opts.host,
        else => unreachable,
    };
}

pub fn maxConnections(_: *const Config) u16 {
    return 16;
}

pub fn maxPendingConnections(_: *const Config) u31 {
    return 128;
}

pub fn cdpMaxMessageSize(_: *const Config) u32 {
    return 1024 * 1024;
}

pub fn cdpMaxHTTPMessageSize(_: *const Config) u14 {
    return 4096;
}

pub fn storageEngine(self: *const Config) ?Storage.EngineType {
    return self.core.storage_engine;
}

pub fn storageSqlitePath(self: *const Config) ?[:0]const u8 {
    return self.core.storage_sqlite_path;
}

/// Page lifecycle wait target used by the browser Runner and FFI actions.
/// This remains a browser type even though the standalone `fetch` CLI was
/// removed.
pub const WaitUntil = enum {
    load,
    domcontentloaded,
    networkalmostidle,
    networkidle,
    done,
};

/// Pre-formatted HTTP headers for reuse across Http and Client.
/// Must be initialized with an allocator that outlives all HTTP connections.
pub const HttpHeaders = struct {
    // Kept for low-level callers which do not have a Config. Browser requests
    // use locale_profile.accept_language_header instead.
    pub const accept_language: [:0]const u8 = Locale.default_accept_language_header;

    user_agent: [:0]const u8, // User agent value (e.g. "DarkPanda/1.0")
    user_agent_header: [:0]const u8,
    owns_user_agent: bool,
    client_profile: ClientProfile.Id,
    profile: ClientProfile.Data,
    locale_profile: Locale.Profile,

    proxy_bearer_header: ?[:0]const u8,

    pub fn init(allocator: Allocator, config: *const Config) !HttpHeaders {
        const locale_profile = try Locale.Profile.init(allocator, config.requestedLocale());
        errdefer locale_profile.deinit(allocator);

        const client_profile = config.clientProfile();
        const profile = ClientProfile.get(client_profile);

        const user_agent: [:0]const u8 = if (config.userAgent()) |ua|
            try allocator.dupeZ(u8, ua)
        else if (config.userAgentSuffix()) |suffix|
            try std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ profile.user_agent, suffix }, 0)
        else
            profile.user_agent;
        errdefer if (config.userAgent() != null or config.userAgentSuffix() != null) allocator.free(user_agent);

        const user_agent_header = try std.fmt.allocPrintSentinel(allocator, "User-Agent: {s}", .{user_agent}, 0);
        errdefer allocator.free(user_agent_header);

        const proxy_bearer_header: ?[:0]const u8 = if (config.proxyBearerToken()) |token|
            try std.fmt.allocPrintSentinel(allocator, "Proxy-Authorization: Bearer {s}", .{token}, 0)
        else
            null;

        return .{
            .user_agent = user_agent,
            .user_agent_header = user_agent_header,
            .owns_user_agent = config.userAgent() != null or config.userAgentSuffix() != null,
            .client_profile = client_profile,
            .profile = profile,
            .locale_profile = locale_profile,
            .proxy_bearer_header = proxy_bearer_header,
        };
    }

    pub fn deinit(self: *const HttpHeaders, allocator: Allocator) void {
        if (self.proxy_bearer_header) |hdr| {
            allocator.free(hdr);
        }
        self.locale_profile.deinit(allocator);
        allocator.free(self.user_agent_header);
        if (self.owns_user_agent) {
            allocator.free(self.user_agent);
        }
    }
};

test "Config: explicit Chrome149 profile drives HTTP identity" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .profile = .chrome149,
    } });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(ClientProfile.Id.chrome149, config.http_headers.client_profile);
    try std.testing.expectEqualStrings(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
        config.http_headers.user_agent,
    );
    try std.testing.expectEqualStrings("149.0.7827.201", config.http_headers.profile.ua_full_version);
    try std.testing.expectEqualStrings("Google Chrome", config.http_headers.profile.brands[0].brand);
    try std.testing.expectEqualStrings("149", config.http_headers.profile.brands[0].version);
    try std.testing.expectEqualStrings("149.0.7827.201", config.http_headers.profile.full_version_list[0].version);
}

test "Config: wreq rejects a DarkPanda application profile on every platform" {
    try std.testing.expectError(
        error.ClientProfileTransportMismatch,
        validateClientProfileTransport(.darkpanda, .windows),
    );
    try validateClientProfileTransport(.chrome149, .windows);
    try std.testing.expectError(
        error.ClientProfileTransportMismatch,
        validateClientProfileTransport(.darkpanda, .linux),
    );
}

test "Config: explicit wreq DNS nameservers are shared network policy" {
    const endpoints = "127.0.0.1:5353\n[::1]:5353";
    var config = try Config.initCore(std.testing.allocator, "test", .{ .serve = .{} }, .{
        .client_profile = .chrome149,
        .wreq_dns_nameservers = endpoints,
    });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(endpoints, config.wreqDnsNameservers().?);
}

pub fn printUsageAndExit(self: *const Config, help_for: RunMode, success: bool) void {
    const exec_name = self.exec_name;
    const Help = @import("help.zon");
    const comptimePrint = std.fmt.comptimePrint;

    switch (help_for) {
        // Requested help for everything.
        .help => {
            const template = comptimePrint(
                \\{s}
                \\
            , .{Help.general});
            std.debug.print(template, .{exec_name});
        },
        .serve => {
            const template = comptimePrint(
                \\{s}
                \\
            , .{Help.serve});
            std.debug.print(template, .{exec_name});
        },
        .version => {
            const template = Help.version ++ "\n";
            std.debug.print(template, .{exec_name});
        },
    }

    if (success) {
        return std.process.cleanExit();
    }
    std.process.exit(1);
}

pub fn parseArgs(allocator: Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const raw_exec_name = args.next() orelse "darkpanda";
    const exec_name = try allocator.dupe(u8, std.fs.path.basename(raw_exec_name));
    const first = args.next() orelse return .init(allocator, exec_name, .{ .serve = .{} });

    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        const requested = args.next() orelse "help";
        const tag = std.meta.stringToEnum(RunMode, requested) orelse return error.UnknownCommand;
        if (args.next() != null) return error.UnexpectedArgument;
        return .init(allocator, exec_name, .{ .help = tag });
    }

    if (std.mem.eql(u8, first, "version")) {
        if (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                if (args.next() != null) return error.UnexpectedArgument;
                return .init(allocator, exec_name, .{ .help = .version });
            }
            return error.UnknownOption;
        }
        return .init(allocator, exec_name, .{ .version = {} });
    }

    var opts: ServeOptions = .{};
    var pending: ?[]const u8 = if (std.mem.eql(u8, first, "serve")) null else first;
    while (pending orelse args.next()) |arg| {
        pending = null;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            if (args.next() != null) return error.UnexpectedArgument;
            return .init(allocator, exec_name, .{ .help = .serve });
        }
        if (!std.mem.startsWith(u8, arg, "--")) return error.UnexpectedArgument;

        const equals = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (equals) |i| arg[0..i] else arg;
        const value = if (equals) |i| arg[i + 1 ..] else args.next() orelse return error.MissingArgument;
        if (value.len == 0) return error.MissingArgument;

        if (std.mem.eql(u8, name, "--host")) {
            opts.host = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, name, "--port")) {
            opts.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, name, "--profile")) {
            opts.profile = std.meta.stringToEnum(ClientProfile.Id, value) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, name, "--timeout")) {
            opts.timeout = std.fmt.parseInt(u31, value, 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, name, "--proxy")) {
            opts.proxy = try allocator.dupeZ(u8, value);
        } else {
            return error.UnknownOption;
        }
    }

    return .init(allocator, exec_name, .{ .serve = opts });
}

pub fn validateUserAgent(ua: []const u8) !void {
    for (ua) |c| {
        if (!std.ascii.isPrint(c)) {
            return error.NonPrintable;
        }
    }

    if (std.ascii.indexOfIgnoreCase(ua, "mozilla") != null) {
        return error.Reserved;
    }
}

/// Tag names of a Zig enum, so a command's allowed values can't drift from the
/// enum it sets.
pub fn tagNames(comptime E: type) []const []const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, &names) |f, *n| n.* = f.name;
    const frozen = names;
    return &frozen;
}

/// `<a|b|c>` ghost-text hint built from the same enum's tag names.
pub fn tagHint(comptime E: type) []const u8 {
    var s: []const u8 = "<";
    for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        s = s ++ (if (i == 0) f.name else "|" ++ f.name);
    }
    return s ++ ">";
}

/// JSON array `["a","b","c"]` representation of the enum tag names.
pub fn tagJsonArray(comptime E: type) []const u8 {
    var s: []const u8 = "[";
    for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        s = s ++ (if (i == 0) "\"" else ",\"") ++ f.name ++ "\"";
    }
    return s ++ "]";
}
