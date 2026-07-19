// Copyright (C) 2026 DarkPanda contributors
//
// Versioned dynamic binding for the Rust wreq transport.  The DLL boundary is
// intentional: wreq's private BoringSSL must not be linked into the main
// executable, which also contains V8/WebCrypto's BoringSSL symbols.

const std = @import("std");
const builtin = @import("builtin");
const module_path = @import("module_path.zig");

pub const abi_version: u32 = 5;
pub const default_event_capacity: u32 = 256;
pub const max_event_capacity: u32 = 65_536;
pub const profile_default: u32 = 0;
pub const profile_chrome_124: u32 = 124;
pub const profile_chrome_149: u32 = 149;
pub const option_insecure_skip_tls_verify: u64 = 1 << 0;
pub const option_custom_dns: u64 = 1 << 1;
pub const request_option_config_override: u64 = 1 << 0;
pub const request_option_insecure_skip_tls_verify: u64 = 1 << 1;
pub const request_option_follow_redirects: u64 = 1 << 2;

pub const WebSocketMessageType = enum(u32) {
    text = 1,
    binary = 2,
    close = 3,
};

/// The subset of Network/Handles initialization that can fail before the
/// first request. App runs this before V8 is initialized so a missing library,
/// ABI/symbol mismatch, invalid proxy, certificate-store failure, or transport
/// construction failure cannot force an initialize/dispose/reinitialize V8
/// cycle in the same process.
pub const PreflightOptions = struct {
    explicit_path: ?[]const u8 = null,
    proxy_url: []const u8 = "",
    event_capacity: u32 = default_event_capacity,
    profile_id: u32 = profile_chrome_149,
    tls_verify: bool = true,
    /// LF-separated IP-literal endpoints. Empty preserves system DNS.
    dns_nameservers: []const u8 = "",
};

pub const Status = enum(i32) {
    ok = 0,
    empty = 1,
    invalid_argument = -1,
    not_found = -2,
    invalid_state = -3,
    shutting_down = -4,
    internal_error = -5,
    panic = -6,
    overflow = -7,
    out_of_memory = -8,
};

pub const Error = error{
    InvalidArgument,
    NotFound,
    InvalidState,
    ShuttingDown,
    InternalError,
    RustPanic,
    Overflow,
    OutOfMemory,
    UnknownStatus,
    MissingSymbol,
    AbiVersionMismatch,
};

pub const ByteSlice = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    pub fn from(data: []const u8) ByteSlice {
        return .{
            .ptr = if (data.len == 0) null else data.ptr,
            .len = data.len,
        };
    }

    pub fn bytes(self: ByteSlice) []const u8 {
        if (self.len == 0) return "";
        return self.ptr.?[0..self.len];
    }
};

pub const Header = extern struct {
    name: ByteSlice,
    value: ByteSlice,
};

pub const Options = extern struct {
    struct_size: u32 = @sizeOf(Options),
    abi_version: u32 = abi_version,
    flags: u64 = 0,
    proxy_url: ByteSlice = .{ .ptr = null, .len = 0 },
    event_capacity: u32 = 0,
    profile_id: u32 = profile_default,
    reserved32: u32 = 0,
    /// Optional LF-separated IP-literal endpoints. The feature flag and view
    /// must agree so an invalid custom-DNS configuration fails closed.
    dns_nameservers: ByteSlice = .{ .ptr = null, .len = 0 },

    pub fn init(proxy_url: []const u8, event_capacity: u32, profile_id: u32, tls_verify: bool) Options {
        return .{
            .flags = if (tls_verify) 0 else option_insecure_skip_tls_verify,
            .proxy_url = .from(proxy_url),
            .event_capacity = event_capacity,
            .profile_id = profile_id,
        };
    }

    pub fn setDnsNameservers(self: *Options, endpoints: []const u8) void {
        self.dns_nameservers = .from(endpoints);
        if (endpoints.len == 0) {
            self.flags &= ~option_custom_dns;
        } else {
            self.flags |= option_custom_dns;
        }
    }
};

pub const Request = extern struct {
    struct_size: u32,
    abi_version: u32,
    method: ByteSlice,
    url: ByteSlice,
    headers: ?[*]const Header,
    header_count: usize,
    body: ByteSlice,
    timeout_ms: u64,
    flags: u64,
    proxy_url: ByteSlice,

    pub fn init(method: []const u8, url: []const u8, headers: []const Header, body: []const u8, timeout_ms: u64) Request {
        return .{
            .struct_size = @sizeOf(Request),
            .abi_version = abi_version,
            .method = .from(method),
            .url = .from(url),
            .headers = if (headers.len == 0) null else headers.ptr,
            .header_count = headers.len,
            .body = .from(body),
            .timeout_ms = timeout_ms,
            .flags = 0,
            .proxy_url = .from(""),
        };
    }

    pub fn initWithConfig(
        method: []const u8,
        url: []const u8,
        headers: []const Header,
        body: []const u8,
        timeout_ms: u64,
        proxy_url: []const u8,
        tls_verify: bool,
    ) Request {
        var request = init(method, url, headers, body, timeout_ms);
        request.flags = request_option_config_override |
            (if (tls_verify) @as(u64, 0) else request_option_insecure_skip_tls_verify);
        request.proxy_url = .from(proxy_url);
        return request;
    }
};

pub const EventKind = enum(u32) {
    headers = 1,
    data = 2,
    done = 3,
    err = 4,
    cancelled = 5,
    websocket_open = 6,
    websocket_text = 7,
    websocket_binary = 8,
    websocket_close = 9,
};

pub const HttpVersion = enum(u32) {
    unknown = 0,
    http_09 = 9,
    http_10 = 10,
    http_11 = 11,
    http_2 = 20,
    http_3 = 30,
};

pub const Event = extern struct {
    kind: u32,
    http_version: u32,
    request_id: u64,
    status_code: u16,
    reserved16: u16,
    reserved32: u32,
    encoded_body_size: u64,
    decoded_body_size: u64,
    headers: ?[*]const Header,
    header_count: usize,
    data: ByteSlice,

    pub fn eventKind(self: *const Event) ?EventKind {
        return std.meta.intToEnum(EventKind, self.kind) catch null;
    }

    pub fn responseHeaders(self: *const Event) []const Header {
        if (self.header_count == 0) return &.{};
        return self.headers.?[0..self.header_count];
    }
};

const OpaqueTransport = opaque {};

const CreateFn = *const fn (*?*OpaqueTransport) callconv(.c) i32;
const CreateWithOptionsFn = *const fn (*const Options, *?*OpaqueTransport) callconv(.c) i32;
const FreeFn = *const fn (?*OpaqueTransport) callconv(.c) void;
const SubmitFn = *const fn (*OpaqueTransport, *const Request, *u64) callconv(.c) i32;
const WebSocketSendFn = *const fn (*OpaqueTransport, u64, u32, ByteSlice, u16) callconv(.c) i32;
const CancelFn = *const fn (*OpaqueTransport, u64) callconv(.c) i32;
const PollEventFn = *const fn (*OpaqueTransport, u32, *?*Event) callconv(.c) i32;
const WakeupFn = *const fn (*OpaqueTransport) callconv(.c) i32;
const HeadersAckFn = *const fn (*OpaqueTransport, u64) callconv(.c) i32;
const EventFreeFn = *const fn (?*Event) callconv(.c) void;
const VersionFn = *const fn () callconv(.c) ?[*:0]const u8;
const AbiVersionFn = *const fn () callconv(.c) u32;

pub const Api = struct {
    lib: std.DynLib,
    create_fn: CreateFn,
    create_with_options_fn: CreateWithOptionsFn,
    free_fn: FreeFn,
    submit_fn: SubmitFn,
    websocket_submit_fn: SubmitFn,
    websocket_send_fn: WebSocketSendFn,
    websocket_cancel_fn: CancelFn,
    cancel_fn: CancelFn,
    poll_event_fn: PollEventFn,
    wakeup_fn: WakeupFn,
    headers_ack_fn: HeadersAckFn,
    event_free_fn: EventFreeFn,
    version_fn: VersionFn,
    abi_version_fn: AbiVersionFn,

    pub fn open(path: []const u8) !Api {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();

        const self: Api = .{
            .lib = lib,
            .create_fn = try lookup(&lib, CreateFn, "wreq_transport_create"),
            .create_with_options_fn = try lookup(&lib, CreateWithOptionsFn, "wreq_transport_create_with_options"),
            .free_fn = try lookup(&lib, FreeFn, "wreq_transport_free"),
            .submit_fn = try lookup(&lib, SubmitFn, "wreq_transport_submit"),
            .websocket_submit_fn = try lookup(&lib, SubmitFn, "wreq_transport_websocket_submit"),
            .websocket_send_fn = try lookup(&lib, WebSocketSendFn, "wreq_transport_websocket_send"),
            .websocket_cancel_fn = try lookup(&lib, CancelFn, "wreq_transport_websocket_cancel"),
            .cancel_fn = try lookup(&lib, CancelFn, "wreq_transport_cancel"),
            .poll_event_fn = try lookup(&lib, PollEventFn, "wreq_transport_poll_event"),
            .wakeup_fn = try lookup(&lib, WakeupFn, "wreq_transport_wakeup"),
            .headers_ack_fn = try lookup(&lib, HeadersAckFn, "wreq_transport_headers_ack"),
            .event_free_fn = try lookup(&lib, EventFreeFn, "wreq_transport_event_free"),
            .version_fn = try lookup(&lib, VersionFn, "wreq_transport_version"),
            .abi_version_fn = try lookup(&lib, AbiVersionFn, "wreq_transport_abi_version"),
        };

        if (self.abi_version_fn() != abi_version) return error.AbiVersionMismatch;
        return self;
    }

    pub fn openAdjacent(allocator: std.mem.Allocator) !Api {
        const path = try module_path.adjacentPathAlloc(allocator, libraryName());
        defer allocator.free(path);
        return open(path);
    }

    /// Resolve the transport for every supported host:
    /// explicit absolute path, environment override, then module adjacency.
    pub fn openConfigured(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !Api {
        if (explicit_path) |path| {
            if (!std.fs.path.isAbsolute(path)) return error.WreqTransportPathMustBeAbsolute;
            return open(path);
        }

        const configured_path = std.process.getEnvVarOwned(
            allocator,
            "DARKPANDA_WREQ_LIBRARY",
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound, error.InvalidWtf8 => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer if (configured_path) |path| allocator.free(path);

        if (configured_path) |path| {
            if (!std.fs.path.isAbsolute(path)) return error.WreqTransportPathMustBeAbsolute;
            return open(path);
        }
        return openAdjacent(allocator);
    }

    pub fn close(self: *Api) void {
        self.lib.close();
        self.* = undefined;
    }

    pub fn version(self: *const Api) []const u8 {
        const raw = self.version_fn() orelse return "";
        return std.mem.span(raw);
    }

    pub fn create(self: *Api) !Transport {
        var raw: ?*OpaqueTransport = null;
        try expectOk(self.create_fn(&raw));
        return self.wrapTransport(raw orelse return error.InternalError);
    }

    pub fn createWithOptions(self: *Api, options: *const Options) !Transport {
        var raw: ?*OpaqueTransport = null;
        try expectOk(self.create_with_options_fn(options, &raw));
        return self.wrapTransport(raw orelse return error.InternalError);
    }

    fn wrapTransport(self: *const Api, raw: *OpaqueTransport) Transport {
        return .{
            .raw = raw,
            .free_fn = self.free_fn,
            .submit_fn = self.submit_fn,
            .websocket_submit_fn = self.websocket_submit_fn,
            .websocket_send_fn = self.websocket_send_fn,
            .websocket_cancel_fn = self.websocket_cancel_fn,
            .cancel_fn = self.cancel_fn,
            .poll_event_fn = self.poll_event_fn,
            .wakeup_fn = self.wakeup_fn,
            .headers_ack_fn = self.headers_ack_fn,
            .event_free_fn = self.event_free_fn,
        };
    }
};

pub const Transport = struct {
    raw: *OpaqueTransport,
    free_fn: FreeFn,
    submit_fn: SubmitFn,
    websocket_submit_fn: SubmitFn,
    websocket_send_fn: WebSocketSendFn,
    websocket_cancel_fn: CancelFn,
    cancel_fn: CancelFn,
    poll_event_fn: PollEventFn,
    wakeup_fn: WakeupFn,
    headers_ack_fn: HeadersAckFn,
    event_free_fn: EventFreeFn,

    pub fn deinit(self: *Transport) void {
        self.free_fn(self.raw);
        self.* = undefined;
    }

    pub fn submit(self: *Transport, request: *const Request) !u64 {
        var request_id: u64 = 0;
        try expectOk(self.submit_fn(self.raw, request, &request_id));
        return request_id;
    }

    pub fn submitWebSocket(self: *Transport, request: *const Request) !u64 {
        var request_id: u64 = 0;
        try expectOk(self.websocket_submit_fn(self.raw, request, &request_id));
        return request_id;
    }

    pub fn sendWebSocket(
        self: *Transport,
        request_id: u64,
        message_type: WebSocketMessageType,
        data: []const u8,
        close_code: u16,
    ) !void {
        try expectOk(self.websocket_send_fn(
            self.raw,
            request_id,
            @intFromEnum(message_type),
            .from(data),
            close_code,
        ));
    }

    pub fn cancelWebSocket(self: *Transport, request_id: u64) !void {
        try expectOk(self.websocket_cancel_fn(self.raw, request_id));
    }

    pub fn cancel(self: *Transport, request_id: u64) !void {
        try expectOk(self.cancel_fn(self.raw, request_id));
    }

    pub fn acknowledgeHeaders(self: *Transport, request_id: u64) !void {
        try expectOk(self.headers_ack_fn(self.raw, request_id));
    }

    pub fn wakeup(self: *Transport) !void {
        try expectOk(self.wakeup_fn(self.raw));
    }

    pub fn poll(self: *Transport, timeout_ms: u32) !?OwnedEvent {
        var raw: ?*Event = null;
        const status = self.poll_event_fn(self.raw, timeout_ms, &raw);
        if (status == @intFromEnum(Status.empty)) return null;
        try expectOk(status);
        return .{ .event_free_fn = self.event_free_fn, .raw = raw orelse return error.InternalError };
    }
};

pub const OwnedEvent = struct {
    event_free_fn: EventFreeFn,
    raw: *Event,

    pub fn get(self: *const OwnedEvent) *const Event {
        return self.raw;
    }

    pub fn deinit(self: *OwnedEvent) void {
        self.event_free_fn(self.raw);
        self.* = undefined;
    }
};

pub fn preflight(allocator: std.mem.Allocator, options: PreflightOptions) !void {
    var api = try Api.openConfigured(allocator, options.explicit_path);
    defer api.close();

    var create_options = Options.init(
        options.proxy_url,
        options.event_capacity,
        options.profile_id,
        options.tls_verify,
    );
    create_options.setDnsNameservers(options.dns_nameservers);
    var transport = try api.createWithOptions(&create_options);
    transport.deinit();
}

fn lookup(lib: *std.DynLib, comptime T: type, name: [:0]const u8) Error!T {
    return lib.lookup(T, name) orelse error.MissingSymbol;
}

fn expectOk(raw: i32) Error!void {
    const status = std.meta.intToEnum(Status, raw) catch return error.UnknownStatus;
    return switch (status) {
        .ok => {},
        .empty => error.InvalidState,
        .invalid_argument => error.InvalidArgument,
        .not_found => error.NotFound,
        .invalid_state => error.InvalidState,
        .shutting_down => error.ShuttingDown,
        .internal_error => error.InternalError,
        .panic => error.RustPanic,
        .overflow => error.Overflow,
        .out_of_memory => error.OutOfMemory,
    };
}

pub fn libraryName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "wreq.dll",
        .macos => "libwreq.dylib",
        else => "libwreq.so",
    };
}

test "wreq transport C ABI layouts on 64-bit targets" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ByteSlice));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Options));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Options, "proxy_url"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(Options, "profile_id"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Options, "dns_nameservers"));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(Request));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Request, "method"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Request, "body"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(Request, "timeout_ms"));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(Request, "proxy_url"));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Event));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Event, "encoded_body_size"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Event, "decoded_body_size"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Event, "headers"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Event, "data"));
}

test "empty byte slices do not require a non-null pointer" {
    const slice = ByteSlice.from("");
    try std.testing.expectEqual(@as(usize, 0), slice.len);
    try std.testing.expectEqual(@as(usize, 0), slice.bytes().len);
}

test "extensible request and options initialize their ABI prefixes" {
    const options = Options.init("", 32, profile_chrome_149, true);
    try std.testing.expectEqual(@as(u32, @sizeOf(Options)), options.struct_size);
    try std.testing.expectEqual(abi_version, options.abi_version);
    try std.testing.expectEqual(@as(u64, 0), options.flags);

    var custom_dns = options;
    custom_dns.setDnsNameservers("[::1]:5353\n1.1.1.1");
    try std.testing.expect(custom_dns.flags & option_custom_dns != 0);
    try std.testing.expectEqualStrings("[::1]:5353\n1.1.1.1", custom_dns.dns_nameservers.bytes());
    custom_dns.setDnsNameservers("");
    try std.testing.expect(custom_dns.flags & option_custom_dns == 0);

    const request = Request.init("GET", "https://example.test/", &.{}, "", 2500);
    try std.testing.expectEqual(@as(u32, @sizeOf(Request)), request.struct_size);
    try std.testing.expectEqual(abi_version, request.abi_version);
    try std.testing.expectEqual(@as(u64, 2500), request.timeout_ms);

    const configured = Request.initWithConfig(
        "GET",
        "https://example.test/",
        &.{},
        "",
        2500,
        "http://proxy.test:8080",
        false,
    );
    try std.testing.expect(configured.flags & request_option_config_override != 0);
    try std.testing.expect(configured.flags & request_option_insecure_skip_tls_verify != 0);
    try std.testing.expectEqualStrings("http://proxy.test:8080", configured.proxy_url.bytes());

    var redirecting = configured;
    redirecting.flags |= request_option_follow_redirects;
    try std.testing.expect(redirecting.flags & request_option_follow_redirects != 0);
}

test "adjacent lookup is based on the containing module" {
    const directory = try module_path.directoryPathAlloc(std.testing.allocator);
    defer std.testing.allocator.free(directory);
    try std.testing.expect(std.fs.path.isAbsolute(directory));
}
