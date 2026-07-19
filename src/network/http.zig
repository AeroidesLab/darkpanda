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
const posix = std.posix;

const Config = @import("../Config.zig");
const ClientProfile = @import("../ClientProfile.zig");
const wreq = @import("../sys/wreq_transport.zig");

const log = @import("darkpanda").log;

pub const WaitFd = extern struct {
    fd: posix.socket_t,
    events: c_short,
    revents: c_short,
};
pub const WriteFunction = *const fn ([*]const u8, usize, usize, *anyopaque) callconv(.c) usize;
pub const writefunc_error: usize = std.math.maxInt(u32);
pub const WsFrameType = enum { text, binary, cont, close, ping, pong };

const Error = anyerror;

pub const Method = enum(u8) {
    GET = 0,
    PUT = 1,
    POST = 2,
    DELETE = 3,
    HEAD = 4,
    OPTIONS = 5,
    PATCH = 6,
    PROPFIND = 7,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,

    pub const Param = struct {
        key: []const u8,
        value: []const u8,
    };

    // The header value up to the first ';', trimmed (e.g. "attachment" for a
    // Content-Disposition, "text/html" for a Content-Type).
    pub fn firstValue(self: Header) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.value, ';') orelse self.value.len;
        return std.mem.trim(u8, self.value[0..end], " \t");
    }

    // Iterates the `; key=value` parameters that follow the header's first value.
    pub fn params(self: Header) ParamIterator {
        const start = std.mem.indexOfScalar(u8, self.value, ';') orelse self.value.len;
        return .{ .rest = self.value[start..] };
    }

    // Returns the (unquoted) value of the first non-empty `key=` parameter, if any.
    pub fn param(self: Header, key: []const u8) ?[]const u8 {
        var it = self.params();
        while (it.next()) |p| {
            if (p.value.len > 0 and std.ascii.eqlIgnoreCase(p.key, key)) {
                return p.value;
            }
        }
        return null;
    }

    pub const ParamIterator = struct {
        rest: []const u8,

        pub fn next(self: *ParamIterator) ?Param {
            while (self.rest.len > 0 and self.rest[0] == ';') {
                self.rest = self.rest[1..];
                const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse self.rest.len;
                const segment = self.rest[0..end];
                self.rest = self.rest[end..];

                const eq = std.mem.indexOfScalar(u8, segment, '=') orelse continue;
                const key = std.mem.trim(u8, segment[0..eq], " \t");
                if (key.len == 0) continue;

                var value = std.mem.trim(u8, segment[eq + 1 ..], " \t");
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }
                return .{ .key = key, .value = value };
            }
            return null;
        }
    };
};

/// Fetch Metadata values are computed by the browser layer from the target and
/// initiator URLs.  Keeping this wire-oriented structure in the transport
/// makes the emitted order deterministic without
/// making the transport depend on DOM/frame types.
pub const HeaderRequestContext = struct {
    pub const Destination = enum {
        document,
        iframe,
        image,
        style,
        script,
        worker,
        empty,

        fn value(self: Destination) []const u8 {
            return switch (self) {
                .document => "document",
                .iframe => "iframe",
                .image => "image",
                .style => "style",
                .script => "script",
                .worker => "worker",
                .empty => "empty",
            };
        }
    };

    pub const Mode = enum {
        navigate,
        no_cors,
        cors,
        same_origin,

        fn value(self: Mode) []const u8 {
            return switch (self) {
                .navigate => "navigate",
                .no_cors => "no-cors",
                .cors => "cors",
                .same_origin => "same-origin",
            };
        }
    };

    pub const Site = enum {
        none,
        same_origin,
        same_site,
        cross_site,

        fn value(self: Site) []const u8 {
            return switch (self) {
                .none => "none",
                .same_origin => "same-origin",
                .same_site => "same-site",
                .cross_site => "cross-site",
            };
        }
    };

    pub const Priority = enum {
        none,
        navigation,
        image,
        style,
        script,
        worker,
        fetch,
    };

    destination: Destination,
    mode: Mode,
    site: Site,
    trustworthy_target: bool,
    user_activation: bool = false,
    origin: ?[]const u8 = null,
    referrer: ?[]const u8 = null,
    priority: Priority = .none,
};

const HeaderNode = struct {
    data: [:0]u8,
    next: ?*HeaderNode = null,
};

pub const Headers = struct {
    headers: ?*HeaderNode,

    pub fn init(user_agent: [:0]const u8) !Headers {
        return initWithAcceptLanguage(user_agent, Config.HttpHeaders.accept_language);
    }

    pub fn initWithAcceptLanguage(
        user_agent: [:0]const u8,
        accept_language_header: [:0]const u8,
    ) !Headers {
        const profile = ClientProfile.get(ClientProfile.target_default);
        return initWithProfile(user_agent, accept_language_header, &profile);
    }

    /// Base request headers in the same relative order as the selected
    /// browser profile. wreq receives `.default_headers(false)`, so this list
    /// is the authoritative HTTP identity rather than an overlay.
    pub fn initWithProfile(
        user_agent: [:0]const u8,
        accept_language_header: [:0]const u8,
        profile: *const ClientProfile.Data,
    ) !Headers {
        var self: Headers = .{ .headers = null };
        errdefer self.deinit();

        try self.add(profile.sec_ch_ua_header);
        try self.add(profile.sec_ch_ua_mobile_header);
        try self.add(profile.sec_ch_ua_platform_header);
        try self.add(user_agent);
        try self.add(profile.accept_encoding_header);
        // Always add Accept-Language. Omitting it triggers bot-protection on
        // some CDNs (Akamai) when Accept-Encoding is present.
        try self.add(accept_language_header);
        return self;
    }

    /// Complete Chrome-style request headers for a resource request. Chromium
    /// 149's services/network/sec_header_helpers.cc emits Fetch Metadata only
    /// for potentially trustworthy targets and represents an empty fetch
    /// destination as the literal value "empty".
    pub fn initRequest(
        allocator: std.mem.Allocator,
        user_agent: [:0]const u8,
        accept_language_header: [:0]const u8,
        profile: *const ClientProfile.Data,
        context: HeaderRequestContext,
    ) !Headers {
        var self: Headers = .{ .headers = null };
        errdefer self.deinit();

        try self.add(profile.sec_ch_ua_header);
        try self.add(profile.sec_ch_ua_mobile_header);
        try self.add(profile.sec_ch_ua_platform_header);

        const navigation = context.mode == .navigate;
        if (profile.id == .chrome149 and navigation) {
            try self.add("Upgrade-Insecure-Requests: 1");
        }
        try self.add(user_agent);
        if (navigation) {
            try self.add(profile.navigation_accept_header);
        } else switch (context.destination) {
            // Chrome 149's image loader advertises every image codec enabled
            // by the selected browser profile.  Keep this separate from the
            // generic */* resource header: it is observable both on the wire
            // and by servers doing content negotiation.
            .image => try self.add("Accept: image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"),
            .style => try self.add("Accept: text/css,*/*;q=0.1"),
            else => try self.add("Accept: */*"),
        }

        if (context.origin) |origin| {
            try self.addNameValue(allocator, "Origin", origin);
        }

        // Chromium adds these in services/network after trustworthiness and
        // initiator/redirect-chain classification. Lightpanda's legacy profile
        // deliberately does not claim Chromium Fetch Metadata behavior.
        if (profile.id == .chrome149 and context.trustworthy_target) {
            try self.addNameValue(allocator, "Sec-Fetch-Site", context.site.value());
            try self.addNameValue(allocator, "Sec-Fetch-Mode", context.mode.value());
            if (context.user_activation) try self.add("Sec-Fetch-User: ?1");
            try self.addNameValue(allocator, "Sec-Fetch-Dest", context.destination.value());
        }

        if (context.referrer) |referrer| {
            try self.addNameValue(allocator, "Referer", referrer);
        }
        try self.add(profile.accept_encoding_header);
        try self.add(accept_language_header);

        if (profile.id == .chrome149) switch (context.priority) {
            .none => {},
            .navigation => if (profile.navigation_priority_header) |priority| try self.add(priority),
            // Blink starts ordinary images at LOWEST.  Chromium's HTTP
            // priority serialization maps that incremental request to the
            // exact RFC 9218 field value below (there is deliberately no
            // manufactured urgency value).
            .image => try self.add("Priority: i"),
            .style => try self.add("Priority: u=0"),
            .script => try self.add("Priority: u=1"),
            .worker => try self.add("Priority: u=1"),
            .fetch => try self.add("Priority: u=3"),
        };
        return self;
    }

    /// Top-level document navigation header set.  Header ordering is kept
    /// explicit because the wreq OrigHeaderMap preserves this sequence on the
    /// wire for both HTTP/1.1 and HTTP/2.
    pub fn initNavigation(
        user_agent: [:0]const u8,
        accept_language_header: [:0]const u8,
        profile: *const ClientProfile.Data,
        root_browser_navigation: bool,
    ) !Headers {
        return initRequest(
            std.heap.page_allocator,
            user_agent,
            accept_language_header,
            profile,
            .{
                .destination = .document,
                .mode = .navigate,
                .site = if (root_browser_navigation) .none else .cross_site,
                .trustworthy_target = root_browser_navigation,
                .user_activation = root_browser_navigation,
                .priority = .navigation,
            },
        );
    }

    pub fn deinit(self: *const Headers) void {
        var node = self.headers;
        while (node) |current| {
            node = current.next;
            std.heap.c_allocator.free(current.data);
            std.heap.c_allocator.destroy(current);
        }
    }

    pub fn add(self: *Headers, header: [*c]const u8) !void {
        const value = try std.heap.c_allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(header))));
        errdefer std.heap.c_allocator.free(value);
        const new_node = try std.heap.c_allocator.create(HeaderNode);
        new_node.* = .{ .data = value };

        const head = self.headers orelse {
            self.headers = new_node;
            return;
        };
        var tail = head;
        while (tail.next) |next| tail = next;
        tail.next = new_node;
    }

    fn addNameValue(self: *Headers, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const header = try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ name, value }, 0);
        defer allocator.free(header);
        try self.add(header);
    }

    // Adds `header` ("Name: Value"), replacing any existing header with the
    // same case-insensitive name. Caller-supplied headers (CDP
    // Network.setExtraHTTPHeaders) must override built-in defaults like
    // User-Agent; replacing in place also preserves Chromium-style ordering.
    pub fn set(self: *Headers, header: [*c]const u8) !void {
        const new = parseHeader(std.mem.span(@as([*:0]const u8, @ptrCast(header)))) orelse {
            // No colon: nothing to match against, fall back to append.
            return self.add(header);
        };

        var rebuilt: Headers = .{ .headers = null };
        errdefer rebuilt.deinit();

        var replaced = false;
        var node = self.headers;
        while (node) |n| : (node = n.*.next) {
            const data = @as([*:0]const u8, @ptrCast(n.*.data));
            if (parseHeader(std.mem.span(data))) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.name, new.name)) {
                    if (!replaced) {
                        try rebuilt.add(header);
                        replaced = true;
                    }
                    continue;
                }
            }
            try rebuilt.add(data);
        }
        if (!replaced) {
            try rebuilt.add(header);
        }

        self.deinit();
        self.* = rebuilt;
    }

    pub fn parseHeader(header_str: []const u8) ?Header {
        const colon_pos = std.mem.indexOfScalar(u8, header_str, ':') orelse return null;

        const name = std.mem.trim(u8, header_str[0..colon_pos], " \t");
        const value = std.mem.trim(u8, header_str[colon_pos + 1 ..], " \t");

        return .{ .name = name, .value = value };
    }

    pub fn iterator(self: Headers) HeaderIterator {
        return .{ .request = .{ .header = self.headers } };
    }
};

// Response headers can come from wreq or from an injected/cache-owned list.
// Request headers use the browser-owned linked list above.
pub const HeaderIterator = union(enum) {
    response: ResponseHeaderIterator,
    request: RequestHeaderIterator,
    list: ListHeaderIterator,

    pub fn next(self: *HeaderIterator) ?Header {
        switch (self.*) {
            inline else => |*it| return it.next(),
        }
    }

    pub fn collect(self: *HeaderIterator, allocator: std.mem.Allocator) !std.ArrayList(Header) {
        var list: std.ArrayList(Header) = .empty;

        while (self.next()) |hdr| {
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, hdr.name),
                .value = try allocator.dupe(u8, hdr.value),
            });
        }

        return list;
    }

    const ResponseHeaderIterator = struct {
        conn: *const Connection,
        wreq_index: usize = 0,

        pub fn next(self: *ResponseHeaderIterator) ?Header {
            if (self.conn._wreq_response) |*owned| {
                const event = owned.get();
                const headers = event.responseHeaders();
                if (self.wreq_index >= headers.len) return null;
                const header = headers[self.wreq_index];
                self.wreq_index += 1;
                return .{ .name = header.name.bytes(), .value = header.value.bytes() };
            }
            return null;
        }
    };

    const RequestHeaderIterator = struct {
        header: ?*HeaderNode,

        pub fn next(self: *RequestHeaderIterator) ?Header {
            const h = self.header orelse return null;
            self.header = h.next;
            return Headers.parseHeader(h.data);
        }
    };

    const ListHeaderIterator = struct {
        index: usize = 0,
        list: []const Header,

        pub fn next(self: *ListHeaderIterator) ?Header {
            const idx = self.index;
            if (idx == self.list.len) {
                return null;
            }
            self.index = idx + 1;
            return self.list[idx];
        }
    };
};

const HeaderValue = struct {
    value: []const u8,
    amount: usize,
};

pub const AuthChallenge = struct {
    const Source = enum { server, proxy };
    const Scheme = enum { basic, digest };

    status: u16,
    source: ?Source,
    scheme: ?Scheme,
    realm: ?[]const u8,

    pub fn parse(status: u16, source: Source, value: []const u8) !AuthChallenge {
        var ac: AuthChallenge = .{
            .status = status,
            .source = source,
            .realm = null,
            .scheme = null,
        };

        const challenge_value = std.mem.trim(u8, value, std.ascii.whitespace[0..]);
        const pos = std.mem.indexOfPos(u8, challenge_value, 0, " ") orelse challenge_value.len;
        const _scheme = challenge_value[0..pos];
        if (std.ascii.eqlIgnoreCase(_scheme, "basic")) {
            ac.scheme = .basic;
        } else if (std.ascii.eqlIgnoreCase(_scheme, "digest")) {
            ac.scheme = .digest;
        } else {
            return error.UnknownAuthChallengeScheme;
        }

        return ac;
    }
};

pub const ResponseHead = struct {
    // Matches Mime.parse's 255-byte cap
    pub const MAX_CONTENT_TYPE_LEN = 255;

    status: u16,
    url: [*c]const u8,
    redirect_count: u32,
    _content_type_len: usize = 0,
    _content_type: [MAX_CONTENT_TYPE_LEN]u8 = undefined,
    // this is normally an empty list, but if the response is being injected
    // than it'll be populated. It isn't meant to be used directly, but should
    // be used through the transfer.responseHeaderIterator() which abstracts
    // whether the headers are from a live response or injected.
    _injected_headers: []const Header = &.{},

    pub fn contentType(self: *ResponseHead) ?[]u8 {
        if (self._content_type_len == 0) {
            return null;
        }
        return self._content_type[0..self._content_type_len];
    }
};

pub const Connection = struct {
    // Browser HTTP request state mirrored for the wreq backend. These are
    // borrowed only until Handles.add(): the Rust ABI deep-copies them before
    // submit returns. Response HEADERS stay owned here until the connection is
    // released/reset so existing Response/HeaderIterator APIs remain stable.
    _wreq_request_id: u64 = 0,
    _wreq_url: [:0]const u8 = "",
    _wreq_method: Method = .GET,
    _wreq_body: []const u8 = "",
    _wreq_headers: ?*HeaderNode = null,
    _wreq_cookies: ?[*:0]const u8 = null,
    _wreq_timeout_ms: u64 = 0,
    _wreq_proxy: ?[:0]const u8 = null,
    _wreq_tls_verify: bool = true,
    _wreq_dns_nameservers: []const u8 = "",
    _wreq_follow_location: bool = false,
    _wreq_write_callback: WriteFunction = discardBody,
    _wreq_write_context: ?*anyopaque = null,
    _wreq_response: ?wreq.OwnedEvent = null,
    in_use: bool,
    transport: Transport,
    node: std.DoublyLinkedList.Node = .{},
    debug_remove_err: ?anyerror = null,
    debug_added: u8 = 0,
    debug_removed: u8 = 0,

    pub const Transport = union(enum) {
        none, // used for cases that manage their own connection
        http: *@import("../browser/HttpClient.zig").Transfer,
        websocket: *@import("../browser/webapi/net/WebSocket.zig"),
    };

    pub fn init(config: *const Config) !Connection {
        var self = Connection{ .in_use = false, .transport = .none };
        try self.reset(config);
        return self;
    }

    pub fn deinit(self: *const Connection) void {
        @constCast(self).clearWreqResponse();
    }

    pub fn setURL(self: *const Connection, url: [:0]const u8) !void {
        @constCast(self)._wreq_url = url;
    }

    pub fn setTimeout(self: *const Connection, timeout_ms: u32) !void {
        @constCast(self)._wreq_timeout_ms = timeout_ms;
    }

    // Method behavior and redirect policy are carried explicitly to wreq.
    pub fn setMethod(self: *const Connection, method: Method) !void {
        @constCast(self)._wreq_method = method;
    }

    pub fn setBody(self: *const Connection, body: []const u8) !void {
        @constCast(self)._wreq_body = body;
    }

    pub fn setGetMode(self: *const Connection) !void {
        @constCast(self)._wreq_body = "";
    }

    pub fn setHeaders(self: *const Connection, headers: *Headers) !void {
        @constCast(self)._wreq_headers = headers.headers;
    }

    pub fn setCookies(self: *const Connection, cookies: [*c]const u8) !void {
        @constCast(self)._wreq_cookies = @ptrCast(cookies);
    }

    pub fn setPrivate(_: *const Connection, _: *anyopaque) !void {}

    pub fn setProxyCredentials(_: *const Connection, _: [:0]const u8) !void {
        return error.DynamicProxyCredentialsUnsupported;
    }

    pub fn setCredentials(_: *const Connection, _: [:0]const u8) !void {
        return error.DynamicServerCredentialsUnsupported;
    }

    pub fn setWriteCallback(
        self: *Connection,
        comptime data_cb: WriteFunction,
    ) !void {
        return self.setWriteCallbackData(data_cb, self);
    }

    /// Install a body callback with an explicit opaque context.
    pub fn setWriteCallbackData(
        self: *Connection,
        comptime data_cb: WriteFunction,
        data: *anyopaque,
    ) !void {
        self._wreq_write_callback = data_cb;
        self._wreq_write_context = data;
    }

    pub fn reset(self: *Connection, config: *const Config) !void {
        self.clearWreqResponse();
        self.transport = .none;
        self._wreq_request_id = 0;
        self._wreq_url = "";
        self._wreq_method = .GET;
        self._wreq_body = "";
        self._wreq_headers = null;
        self._wreq_cookies = null;
        self._wreq_timeout_ms = config.httpTimeout();
        self._wreq_proxy = config.httpProxy();
        self._wreq_tls_verify = config.tlsVerifyHost();
        self._wreq_dns_nameservers = config.wreqDnsNameservers() orelse "";
        self._wreq_follow_location = false;
        self._wreq_write_callback = discardBody;
        self._wreq_write_context = null;
    }

    fn discardBody(_: [*]const u8, count: usize, len: usize, _: *anyopaque) callconv(.c) usize {
        return count * len;
    }

    pub fn setProxy(self: *const Connection, proxy: ?[:0]const u8) !void {
        @constCast(self)._wreq_proxy = proxy;
    }

    pub fn setFollowLocation(self: *const Connection, follow: bool) !void {
        @constCast(self)._wreq_follow_location = follow;
    }

    pub fn setTlsVerify(self: *const Connection, verify: bool, _: bool) !void {
        @constCast(self)._wreq_tls_verify = verify;
    }

    pub fn getEffectiveUrl(self: *const Connection) ![*c]const u8 {
        return @ptrCast(self._wreq_url.ptr);
    }

    pub fn getConnectCode(_: *const Connection) !u16 {
        return 0;
    }

    pub fn getResponseCode(self: *const Connection) !u16 {
        if (self._wreq_response) |*owned| return owned.get().status_code;
        return 0;
    }

    pub fn getRedirectCount(_: *const Connection) !u32 {
        return 0;
    }

    pub fn getConnectHeader(self: *const Connection, name: [:0]const u8, index: usize) ?HeaderValue {
        return self.getWreqResponseHeader(name, index);
    }

    pub fn getResponseHeader(self: *const Connection, name: [:0]const u8, index: usize) ?HeaderValue {
        return self.getWreqResponseHeader(name, index);
    }

    fn getWreqResponseHeader(self: *const Connection, name: []const u8, index: usize) ?HeaderValue {
        const owned = if (self._wreq_response) |*event| event else return null;
        const headers = owned.get().responseHeaders();
        var amount: usize = 0;
        var selected: ?[]const u8 = null;
        for (headers) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name.bytes(), name)) continue;
            if (amount == index) selected = header.value.bytes();
            amount += 1;
        }
        return .{ .amount = amount, .value = selected orelse return null };
    }

    // These are headers that may not be send to the users for inteception.
    pub fn secretHeaders(_: *const Connection, headers: *Headers, http_headers: *const Config.HttpHeaders) !void {
        if (http_headers.proxy_bearer_header) |hdr| {
            try headers.add(hdr);
        }
    }

    pub fn request(self: *const Connection, http_headers: *const Config.HttpHeaders) !u16 {
        var header_list = try Headers.initWithProfile(
            http_headers.user_agent_header,
            http_headers.locale_profile.accept_language_header,
            &http_headers.profile,
        );
        defer header_list.deinit();
        try self.secretHeaders(&header_list, http_headers);
        try self.setHeaders(&header_list);
        return self.performWithWreqPath(null);
    }

    // Synchronous transfer that adds no request headers. request() injects the
    // browser User-Agent / sec-ch-ua machinery meant for page fetches; callers
    // that manage their own connection use this leaner path.
    pub fn perform(self: *const Connection) !u16 {
        return self.performWithWreqPath(null);
    }

    /// Synchronous utility-client transfer on an isolated wreq transport.
    /// `explicit_wreq_transport_path` follows the same precedence/validation as
    /// Handles: explicit absolute path, environment override, module-adjacent.
    pub fn performWithWreqPath(
        self: *const Connection,
        explicit_wreq_transport_path: ?[]const u8,
    ) !u16 {
        return @constCast(self).performWreqSync(explicit_wreq_transport_path);
    }

    fn performWreqSync(self: *Connection, explicit_wreq_transport_path: ?[]const u8) !u16 {
        const allocator = std.heap.c_allocator;

        var api = try wreq.Api.openConfigured(allocator, explicit_wreq_transport_path);
        defer api.close();

        var options = wreq.Options.init(
            if (self._wreq_proxy) |proxy| proxy else "",
            wreq.default_event_capacity,
            wreq.profile_chrome_149,
            self._wreq_tls_verify,
        );
        options.setDnsNameservers(self._wreq_dns_nameservers);
        var transport = try api.createWithOptions(&options);
        defer transport.deinit();

        var request_headers: std.ArrayList(wreq.Header) = .empty;
        defer request_headers.deinit(allocator);
        try appendWreqRequestHeaders(self, &request_headers, allocator);

        var wreq_request = wreq.Request.initWithConfig(
            methodName(self._wreq_method),
            self._wreq_url,
            request_headers.items,
            self._wreq_body,
            self._wreq_timeout_ms,
            if (self._wreq_proxy) |proxy| proxy else "",
            self._wreq_tls_verify,
        );
        if (self._wreq_follow_location) {
            wreq_request.flags |= wreq.request_option_follow_redirects;
        }
        const request_id = try transport.submit(&wreq_request);
        self._wreq_request_id = request_id;
        defer self._wreq_request_id = 0;

        var terminal = false;
        defer if (!terminal) transport.cancel(request_id) catch {};

        var response_status: ?u16 = null;
        var timer = std.time.Timer.start() catch null;
        const timeout_ns = std.math.mul(
            u64,
            self._wreq_timeout_ms,
            std.time.ns_per_ms,
        ) catch std.math.maxInt(u64);

        while (true) {
            var poll_timeout_ms: u32 = 250;
            if (self._wreq_timeout_ms != 0) {
                if (timer) |*clock| {
                    const elapsed_ns = clock.read();
                    if (elapsed_ns >= timeout_ns) return error.OperationTimedout;
                    const remaining_ms = @max(
                        @as(u64, 1),
                        (timeout_ns - elapsed_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
                    );
                    poll_timeout_ms = @intCast(@min(remaining_ms, @as(u64, poll_timeout_ms)));
                }
            }

            var owned = (try transport.poll(poll_timeout_ms)) orelse continue;
            defer owned.deinit();
            const event = owned.get();
            if (event.request_id != request_id) return error.WreqInvalidEvent;

            switch (event.eventKind() orelse return error.WreqInvalidEvent) {
                .headers => {
                    response_status = event.status_code;
                    try transport.acknowledgeHeaders(request_id);
                },
                .data => {
                    const data = event.data.bytes();
                    if (data.len == 0) continue;
                    const context = self._wreq_write_context orelse @as(*anyopaque, @ptrCast(self));
                    const written = self._wreq_write_callback(data.ptr, 1, data.len, context);
                    if (written != data.len) return error.WriteError;
                },
                .done => {
                    terminal = true;
                    return response_status orelse error.WreqMissingResponseHeaders;
                },
                .err => return mapWreqRequestError(event.data.bytes()),
                .cancelled => return error.AbortedByCallback,
                .websocket_open,
                .websocket_text,
                .websocket_binary,
                .websocket_close,
                => return error.WreqInvalidEvent,
            }
        }
    }

    fn clearWreqResponse(self: *Connection) void {
        if (self._wreq_response) |*event| event.deinit();
        self._wreq_response = null;
    }
};

pub const Handles = struct {
    wreq_api: wreq.Api,
    wreq_transport: wreq.Transport,
    wreq_requests: std.AutoHashMapUnmanaged(u64, *Connection) = .empty,
    wreq_completions: std.ArrayList(MultiMessage) = .empty,

    const allocator = std.heap.c_allocator;

    pub const MultiMessage = struct {
        conn: *Connection,
        err: ?Error,
    };

    pub fn init(
        config: *const Config,
        explicit_wreq_transport_path: ?[]const u8,
    ) !Handles {
        var api = try wreq.Api.openConfigured(allocator, explicit_wreq_transport_path);
        errdefer api.close();

        const proxy = if (config.httpProxy()) |value| value else "";
        var options = wreq.Options.init(
            proxy,
            wreq.default_event_capacity,
            wreq.profile_chrome_149,
            config.tlsVerifyHost(),
        );
        options.setDnsNameservers(config.wreqDnsNameservers() orelse "");
        var transport = try api.createWithOptions(&options);
        errdefer transport.deinit();

        log.info(.http, "wreq transport initialized", .{
            .version = api.version(),
            .profile = wreq.profile_chrome_149,
            .proxy = config.httpProxy() != null,
            .tls_verify = config.tlsVerifyHost(),
        });

        return .{
            .wreq_api = api,
            .wreq_transport = transport,
        };
    }

    pub fn deinit(self: *Handles) void {
        // The transport owns worker tasks, while response HEADERS events are
        // owned by their Connection. Drop every event before unloading the
        // DLL, even if a caller tears Handles down without first draining all
        // completions.
        var request_it = self.wreq_requests.valueIterator();
        while (request_it.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            conn._wreq_request_id = 0;
            conn.clearWreqResponse();
        }
        for (self.wreq_completions.items) |completion| {
            completion.conn._wreq_request_id = 0;
            completion.conn.clearWreqResponse();
        }

        self.wreq_transport.deinit();
        self.wreq_requests.deinit(allocator);
        self.wreq_completions.deinit(allocator);
        self.wreq_api.close();
    }

    pub fn add(self: *Handles, conn: *const Connection) !void {
        switch (conn.transport) {
            .http => try self.addWreq(@constCast(conn)),
            .websocket => try self.addWreqWebSocket(@constCast(conn)),
            .none => return error.InvalidConnectionTransport,
        }
    }

    pub fn remove(self: *Handles, conn: *const Connection) !void {
        switch (conn.transport) {
            .http, .websocket => self.removeWreq(@constCast(conn)),
            .none => return error.InvalidConnectionTransport,
        }
    }

    pub fn perform(self: *Handles) !c_int {
        try self.drainWreqEvents();
        const total = self.wreq_requests.count();
        return @intCast(@min(total, @as(usize, std.math.maxInt(c_int))));
    }

    pub fn poll(self: *Handles, extra_fds: []WaitFd, timeout_ms: c_int) !void {
        if (extra_fds.len != 0) return error.ExternalPollDescriptorsUnsupported;
        _ = try self.pollOneWreqEvent(@intCast(@max(timeout_ms, 0)));
        try self.drainWreqEvents();
    }

    // Thread-safe wake of a transport poll when the worker inbox changes.
    pub fn wakeup(self: *Handles) !void {
        return self.wreq_transport.wakeup();
    }

    pub fn readMessage(self: *Handles) !?MultiMessage {
        if (self.wreq_completions.items.len > 0) {
            return self.wreq_completions.orderedRemove(0);
        }

        return null;
    }

    fn addWreq(self: *Handles, conn: *Connection) !void {
        conn.clearWreqResponse();
        conn._wreq_request_id = 0;

        var request_headers: std.ArrayList(wreq.Header) = .empty;
        defer request_headers.deinit(allocator);
        try appendWreqRequestHeaders(conn, &request_headers, allocator);

        var request = wreq.Request.initWithConfig(
            methodName(conn._wreq_method),
            conn._wreq_url,
            request_headers.items,
            conn._wreq_body,
            conn._wreq_timeout_ms,
            if (conn._wreq_proxy) |proxy| proxy else "",
            conn._wreq_tls_verify,
        );
        if (conn._wreq_follow_location) {
            request.flags |= wreq.request_option_follow_redirects;
        }
        const transport = &self.wreq_transport;
        const request_id = try transport.submit(&request);
        errdefer transport.cancel(request_id) catch {};

        try self.wreq_requests.putNoClobber(allocator, request_id, conn);
        conn._wreq_request_id = request_id;
    }

    fn addWreqWebSocket(self: *Handles, conn: *Connection) !void {
        conn.clearWreqResponse();
        conn._wreq_request_id = 0;

        var request_headers: std.ArrayList(wreq.Header) = .empty;
        defer request_headers.deinit(allocator);
        try appendWreqRequestHeaders(conn, &request_headers, allocator);

        const request = wreq.Request.initWithConfig(
            "GET",
            conn._wreq_url,
            request_headers.items,
            "",
            conn._wreq_timeout_ms,
            if (conn._wreq_proxy) |proxy| proxy else "",
            conn._wreq_tls_verify,
        );
        const transport = &self.wreq_transport;
        const request_id = try transport.submitWebSocket(&request);
        errdefer transport.cancelWebSocket(request_id) catch {};

        try self.wreq_requests.putNoClobber(allocator, request_id, conn);
        conn._wreq_request_id = request_id;
    }

    pub fn sendWebSocket(
        self: *Handles,
        conn: *Connection,
        frame_type: WsFrameType,
        data: []const u8,
        close_code: u16,
    ) !void {
        if (conn.transport != .websocket or conn._wreq_request_id == 0) {
            return error.InvalidConnectionTransport;
        }
        const message_type: wreq.WebSocketMessageType = switch (frame_type) {
            .text => .text,
            .binary => .binary,
            .close => .close,
            else => return error.InvalidWebSocketFrameType,
        };
        try self.wreq_transport.sendWebSocket(
            conn._wreq_request_id,
            message_type,
            data,
            close_code,
        );
    }

    fn removeWreq(self: *Handles, conn: *Connection) void {
        const request_id = conn._wreq_request_id;
        conn._wreq_request_id = 0;

        if (request_id != 0 and self.wreq_requests.remove(request_id)) {
            const cancel_result = switch (conn.transport) {
                .websocket => self.wreq_transport.cancelWebSocket(request_id),
                else => self.wreq_transport.cancel(request_id),
            };
            cancel_result catch |err| switch (err) {
                error.NotFound => {}, // the terminal event won the race
                else => log.warn(.http, "cancel wreq request", .{
                    .request_id = request_id,
                    .err = err,
                }),
            };
        }

        // A terminal event can be converted to MultiMessage by makeRequest's
        // opportunistic perform(), then be cancelled by owner teardown before
        // processMessages gets to it. Remove that queued raw Connection pointer
        // so it can never become a late-event UAF.
        var index: usize = 0;
        while (index < self.wreq_completions.items.len) {
            if (self.wreq_completions.items[index].conn == conn) {
                _ = self.wreq_completions.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    fn pollOneWreqEvent(self: *Handles, timeout_ms: u32) !bool {
        var owned = (try self.wreq_transport.poll(timeout_ms)) orelse return false;
        var retained = false;
        defer if (!retained) owned.deinit();
        try self.handleWreqEvent(&owned, &retained);
        return true;
    }

    fn drainWreqEvents(self: *Handles) !void {
        // A wake marker is deliberately reported by the C ABI as EMPTY. Probe
        // once more after an empty result so an event queued immediately behind
        // that marker is handled in the same browser tick.
        var consecutive_empty: u8 = 0;
        while (consecutive_empty < 2) {
            if (try self.pollOneWreqEvent(0)) {
                consecutive_empty = 0;
            } else {
                consecutive_empty += 1;
            }
        }
    }

    // `retained` is set at the exact ownership-transfer point so poll-level
    // cleanup remains correct even if a later ACK/completion operation fails.
    fn handleWreqEvent(self: *Handles, owned: *wreq.OwnedEvent, retained: *bool) !void {
        const event = owned.get();
        const request_id = event.request_id;
        const kind = event.eventKind() orelse {
            if (self.wreq_requests.get(request_id)) |conn| {
                try self.failWreqRequest(request_id, conn, error.WreqInvalidEvent);
            }
            return;
        };

        const conn = self.wreq_requests.get(request_id) orelse {
            // removeWreq already detached the Connection. Cancelling is both a
            // backpressure release for an unacknowledged HEADERS event and a
            // guarantee that no more DATA will be produced for this id.
            self.wreq_transport.cancel(request_id) catch {};
            return;
        };
        if (conn._wreq_request_id != request_id) {
            _ = self.wreq_requests.remove(request_id);
            self.wreq_transport.cancel(request_id) catch {};
            return;
        }

        switch (kind) {
            .headers => {
                if (conn.transport != .http) {
                    try self.failWreqRequest(request_id, conn, error.WreqInvalidEvent);
                    return;
                }
                if (conn._wreq_response != null) {
                    try self.failWreqRequest(request_id, conn, error.WreqDuplicateHeaders);
                    return;
                }

                switch (conn.transport) {
                    .http => |transfer| transfer.noteResponseStart(event.http_version),
                    else => {},
                }

                // Keep the DLL allocation alive: all existing response access
                // APIs return borrowed slices into this event.
                conn._wreq_response = owned.*;
                owned.* = undefined;
                retained.* = true;

                self.wreq_transport.acknowledgeHeaders(request_id) catch |err| {
                    log.err(.http, "acknowledge wreq response headers", .{
                        .request_id = request_id,
                        .err = err,
                    });
                    try self.failWreqRequest(request_id, conn, error.WreqHeadersAckFailed);
                };
                return;
            },
            .data => {
                if (conn.transport != .http) {
                    try self.failWreqRequest(request_id, conn, error.WreqInvalidEvent);
                    return;
                }
                const data = event.data.bytes();
                if (data.len == 0) return;

                const context = conn._wreq_write_context orelse @as(*anyopaque, @ptrCast(conn));
                const written = conn._wreq_write_callback(data.ptr, 1, data.len, context);
                if (written != data.len) {
                    try self.failWreqRequest(request_id, conn, error.WriteError);
                }
                return;
            },
            .done => {
                if (conn.transport != .http) {
                    try self.failWreqRequest(request_id, conn, error.WreqInvalidEvent);
                    return;
                }
                switch (conn.transport) {
                    .http => |transfer| {
                        transfer.noteResponseEnd();
                        transfer.noteBodySizes(
                            event.encoded_body_size,
                            event.decoded_body_size,
                        );
                    },
                    else => {},
                }
                _ = self.wreq_requests.remove(request_id);
                conn._wreq_request_id = 0;
                try self.queueWreqCompletion(conn, null);
                return;
            },
            .err => {
                const detail = event.data.bytes();
                const mapped = mapWreqRequestError(detail);
                log.err(.http, "wreq request failed", .{
                    .request_id = request_id,
                    .url = conn._wreq_url,
                    .detail = detail,
                    .mapped = mapped,
                });
                _ = self.wreq_requests.remove(request_id);
                conn._wreq_request_id = 0;
                try self.queueWreqCompletion(conn, mapped);
                return;
            },
            .cancelled => {
                _ = self.wreq_requests.remove(request_id);
                conn._wreq_request_id = 0;
                try self.queueWreqCompletion(conn, error.AbortedByCallback);
                return;
            },
            .websocket_open => {
                const ws = switch (conn.transport) {
                    .websocket => |value| value,
                    else => {
                        try self.failWreqRequest(request_id, conn, error.WreqInvalidEvent);
                        return;
                    },
                };
                if (event.status_code != 101) {
                    try self.failWreqRequest(request_id, conn, error.WreqInvalidEvent);
                    return;
                }
                var protocol: ?[]const u8 = null;
                for (event.responseHeaders()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name.bytes(), "sec-websocket-protocol")) {
                        protocol = header.value.bytes();
                        break;
                    }
                }
                ws.wreqConnected(protocol) catch |err| {
                    if (self.wreq_requests.get(request_id) != null) {
                        try self.failWreqRequest(request_id, conn, err);
                    }
                };
                return;
            },
            .websocket_text, .websocket_binary => {
                const ws = switch (conn.transport) {
                    .websocket => |value| value,
                    else => {
                        try self.failWreqRequest(request_id, conn, error.WreqInvalidEvent);
                        return;
                    },
                };
                const frame_type: WsFrameType = if (kind == .websocket_text) .text else .binary;
                ws.wreqMessage(event.data.bytes(), frame_type) catch |err| {
                    if (self.wreq_requests.get(request_id) != null) {
                        try self.failWreqRequest(request_id, conn, err);
                    }
                };
                return;
            },
            .websocket_close => {
                const ws = switch (conn.transport) {
                    .websocket => |value| value,
                    else => {
                        try self.failWreqRequest(request_id, conn, error.WreqInvalidEvent);
                        return;
                    },
                };
                ws.wreqClose(event.status_code, event.data.bytes()) catch |err| {
                    try self.failWreqRequest(request_id, conn, err);
                    return;
                };
                _ = self.wreq_requests.remove(request_id);
                conn._wreq_request_id = 0;
                try self.queueWreqCompletion(conn, null);
                return;
            },
        }
    }

    fn failWreqRequest(self: *Handles, request_id: u64, conn: *Connection, err: anyerror) !void {
        _ = self.wreq_requests.remove(request_id);
        if (conn._wreq_request_id == request_id) conn._wreq_request_id = 0;
        self.wreq_transport.cancel(request_id) catch |cancel_err| switch (cancel_err) {
            error.NotFound => {},
            else => log.warn(.http, "cancel failed wreq request", .{
                .request_id = request_id,
                .err = cancel_err,
            }),
        };
        try self.queueWreqCompletion(conn, err);
    }

    fn queueWreqCompletion(self: *Handles, conn: *Connection, err: ?anyerror) !void {
        // Exactly one terminal MultiMessage per Connection. This also protects
        // against a locally-synthesized WriteError racing Rust's CANCELLED.
        for (self.wreq_completions.items) |completion| {
            if (completion.conn == conn) return;
        }
        try self.wreq_completions.append(allocator, .{ .conn = conn, .err = err });
    }
};

fn appendWreqRequestHeaders(
    conn: *const Connection,
    request_headers: *std.ArrayList(wreq.Header),
    allocator: std.mem.Allocator,
) !void {
    var has_accept_encoding = false;
    var node = conn._wreq_headers;
    while (node) |header_node| : (node = header_node.*.next) {
        const raw = std.mem.span(@as([*:0]const u8, @ptrCast(header_node.*.data)));
        const header = Headers.parseHeader(raw) orelse continue;
        has_accept_encoding = has_accept_encoding or std.ascii.eqlIgnoreCase(header.name, "accept-encoding");
        try request_headers.append(allocator, .{
            .name = .from(header.name),
            .value = .from(header.value),
        });
    }

    // wreq is asked to use the exact caller header set, so add the
    // Chrome 149 encoding set explicitly when it was not overridden.
    if (!has_accept_encoding) {
        try request_headers.append(allocator, .{
            .name = .from("Accept-Encoding"),
            .value = .from("gzip, deflate, br, zstd"),
        });
    }

    if (conn._wreq_cookies) |cookies_ptr| {
        const cookies = std.mem.span(cookies_ptr);
        if (cookies.len > 0) {
            try request_headers.append(allocator, .{
                .name = .from("Cookie"),
                .value = .from(cookies),
            });
        }
    }
}

fn methodName(method: Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .PUT => "PUT",
        .POST => "POST",
        .DELETE => "DELETE",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
        .PATCH => "PATCH",
        .PROPFIND => "PROPFIND",
    };
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

// The transport ABI exposes a UTF-8 diagnostic rather than a structured error
// code. Map
// stable categories onto the errors the browser already understands and keep
// the exact text in the log above for diagnostics.
fn mapWreqRequestError(detail: []const u8) anyerror {
    if (containsAsciiIgnoreCase(detail, "timed out") or containsAsciiIgnoreCase(detail, "timeout")) {
        return error.OperationTimedout;
    }
    if (containsAsciiIgnoreCase(detail, "ip policy blocked")) return error.CouldntConnect;
    if (containsAsciiIgnoreCase(detail, "dns") or containsAsciiIgnoreCase(detail, "resolve")) {
        return error.CouldntResolveHost;
    }
    if (containsAsciiIgnoreCase(detail, "certificate") or containsAsciiIgnoreCase(detail, "tls")) {
        return error.SslConnectError;
    }
    if (containsAsciiIgnoreCase(detail, "connect")) return error.CouldntConnect;
    if (containsAsciiIgnoreCase(detail, "http2") or containsAsciiIgnoreCase(detail, "http/2")) {
        return error.Http2;
    }
    return error.WreqRequestFailed;
}

// ── Unit tests for opensocketCallback ────────────────────────────────────────

const testing = @import("../testing.zig");

test "Header.firstValue" {
    try testing.expectEqualSlices(u8, "attachment", (Header{ .name = "Content-Disposition", .value = "attachment" }).firstValue());
    // firstValue trims but preserves case (callers compare case-insensitively).
    try testing.expectEqualSlices(u8, "ATTACHMENT", (Header{ .name = "Content-Disposition", .value = "  ATTACHMENT ; filename=a.csv" }).firstValue());
    try testing.expectEqualSlices(u8, "text/html", (Header{ .name = "Content-Type", .value = "text/html; charset=utf-8" }).firstValue());
    try testing.expectEqualSlices(u8, "", (Header{ .name = "X", .value = "" }).firstValue());
}

test "Header.param" {
    const h: Header = .{ .name = "Content-Disposition", .value = "attachment; filename=\"r e.csv\"; filename*=UTF-8''e.txt" };
    try testing.expectEqualSlices(u8, "r e.csv", h.param("filename").?);
    try testing.expectEqualSlices(u8, "r e.csv", h.param("FILENAME").?);
    try testing.expectEqualSlices(u8, "UTF-8''e.txt", h.param("filename*").?);
    try testing.expect(h.param("missing") == null);
    // A bare value with no parameters has nothing to return.
    try testing.expect((Header{ .name = "Content-Disposition", .value = "attachment" }).param("filename") == null);
    // Empty values are skipped.
    try testing.expect((Header{ .name = "Content-Disposition", .value = "attachment; filename=\"\"" }).param("filename") == null);
}

fn findHeader(headers: Headers, name: []const u8) struct { count: usize, value: []const u8 } {
    var count: usize = 0;
    var value: []const u8 = "";
    var it = headers.iterator();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            count += 1;
            value = h.value;
        }
    }
    return .{ .count = count, .value = value };
}

test "Headers.set replaces an existing header instead of duplicating it" {
    var headers = try Headers.init("User-Agent: DarkPanda/1.0");
    defer headers.deinit();

    try headers.set("User-Agent: Custom/1.0");

    const ua = findHeader(headers, "User-Agent");
    try testing.expectEqual(@as(usize, 1), ua.count);
    try testing.expectString("Custom/1.0", ua.value);
}

test "Headers.set matches header names case-insensitively" {
    var headers = try Headers.init("User-Agent: DarkPanda/1.0");
    defer headers.deinit();

    try headers.set("user-agent: Custom/1.0");

    const ua = findHeader(headers, "User-Agent");
    try testing.expectEqual(@as(usize, 1), ua.count);
    try testing.expectString("Custom/1.0", ua.value);
}

test "Headers.set adds a new header and preserves defaults" {
    var headers = try Headers.init("User-Agent: DarkPanda/1.0");
    defer headers.deinit();

    try headers.set("X-Custom: yes");

    try testing.expectEqual(@as(usize, 1), findHeader(headers, "X-Custom").count);
    try testing.expectEqual(@as(usize, 1), findHeader(headers, "User-Agent").count);
    try testing.expectEqual(@as(usize, 1), findHeader(headers, "Accept-Language").count);
}

test "Headers.initWithAcceptLanguage uses the application locale exactly once" {
    var headers = try Headers.initWithAcceptLanguage(
        "User-Agent: DarkPanda/1.0",
        "Accept-Language: fr-CA,fr;q=0.9",
    );
    defer headers.deinit();

    const language = findHeader(headers, "Accept-Language");
    try testing.expectEqual(@as(usize, 1), language.count);
    try testing.expectString("fr-CA,fr;q=0.9", language.value);
}

test "Chrome149 navigation identity headers are unique and ordered" {
    const profile = ClientProfile.get(.chrome149);
    var headers = try Headers.initNavigation(
        "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
        "Accept-Language: en-US,en;q=0.9",
        &profile,
        true,
    );
    defer headers.deinit();

    const expected_names = [_][]const u8{
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-platform",
        "Upgrade-Insecure-Requests",
        "User-Agent",
        "Accept",
        "Sec-Fetch-Site",
        "Sec-Fetch-Mode",
        "Sec-Fetch-User",
        "Sec-Fetch-Dest",
        "Accept-Encoding",
        "Accept-Language",
        "Priority",
    };
    var index: usize = 0;
    var it = headers.iterator();
    while (it.next()) |header| : (index += 1) {
        try testing.expect(index < expected_names.len);
        try testing.expect(std.ascii.eqlIgnoreCase(expected_names[index], header.name));
        if (index < 3) try testing.expectString(expected_names[index], header.name);
    }
    try testing.expectEqual(expected_names.len, index);

    try testing.expectEqual(@as(usize, 1), findHeader(headers, "User-Agent").count);
    try testing.expectEqual(@as(usize, 1), findHeader(headers, "Sec-CH-UA").count);
    try testing.expectEqual(@as(usize, 1), findHeader(headers, "Sec-CH-UA-Mobile").count);
    try testing.expectEqual(@as(usize, 1), findHeader(headers, "Sec-CH-UA-Platform").count);
    try testing.expectString(
        "\"Google Chrome\";v=\"149\", \"Chromium\";v=\"149\", \"Not)A;Brand\";v=\"24\"",
        findHeader(headers, "Sec-CH-UA").value,
    );
    try testing.expectString("?0", findHeader(headers, "Sec-CH-UA-Mobile").value);
    try testing.expectString("\"Windows\"", findHeader(headers, "Sec-CH-UA-Platform").value);
}

fn expectHeaderNames(headers: Headers, expected: []const []const u8) !void {
    var index: usize = 0;
    var it = headers.iterator();
    while (it.next()) |header| : (index += 1) {
        try testing.expect(index < expected.len);
        try testing.expectString(expected[index], header.name);
    }
    try testing.expectEqual(expected.len, index);
}

test "Chrome149 same-origin classic script headers preserve context and order" {
    const profile = ClientProfile.get(.chrome149);
    var headers = try Headers.initRequest(
        testing.allocator,
        "User-Agent: Chrome149",
        "Accept-Language: en-US,en;q=0.9",
        &profile,
        .{
            .destination = .script,
            .mode = .no_cors,
            .site = .same_origin,
            .trustworthy_target = true,
            .referrer = "https://app.example/page",
            .priority = .script,
        },
    );
    defer headers.deinit();

    try expectHeaderNames(headers, &.{
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-platform",
        "User-Agent",
        "Accept",
        "Sec-Fetch-Site",
        "Sec-Fetch-Mode",
        "Sec-Fetch-Dest",
        "Referer",
        "Accept-Encoding",
        "Accept-Language",
        "Priority",
    });
    try testing.expectString("*/*", findHeader(headers, "Accept").value);
    try testing.expectString("same-origin", findHeader(headers, "Sec-Fetch-Site").value);
    try testing.expectString("no-cors", findHeader(headers, "Sec-Fetch-Mode").value);
    try testing.expectString("script", findHeader(headers, "Sec-Fetch-Dest").value);
    try testing.expectEqual(@as(usize, 0), findHeader(headers, "Origin").count);
}

test "Chrome149 same-origin image headers match Chromium 149" {
    const profile = ClientProfile.get(.chrome149);
    var headers = try Headers.initRequest(
        testing.allocator,
        "User-Agent: Chrome149",
        "Accept-Language: en-US,en;q=0.9",
        &profile,
        .{
            .destination = .image,
            .mode = .no_cors,
            .site = .same_origin,
            .trustworthy_target = true,
            .referrer = "https://app.example/page",
            .priority = .image,
        },
    );
    defer headers.deinit();

    try testing.expectString(
        "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
        findHeader(headers, "Accept").value,
    );
    try testing.expectString("same-origin", findHeader(headers, "Sec-Fetch-Site").value);
    try testing.expectString("no-cors", findHeader(headers, "Sec-Fetch-Mode").value);
    try testing.expectString("image", findHeader(headers, "Sec-Fetch-Dest").value);
    try testing.expectString("https://app.example/page", findHeader(headers, "Referer").value);
    try testing.expectString("i", findHeader(headers, "Priority").value);
    try testing.expectEqual(@as(usize, 0), findHeader(headers, "Origin").count);
}

test "Chrome149 cross-origin fetch and XHR header shape" {
    const profile = ClientProfile.get(.chrome149);
    var headers = try Headers.initRequest(
        testing.allocator,
        "User-Agent: Chrome149",
        "Accept-Language: en-US,en;q=0.9",
        &profile,
        .{
            .destination = .empty,
            .mode = .cors,
            .site = .cross_site,
            .trustworthy_target = true,
            .origin = "https://app.example",
            .referrer = "https://app.example/",
            .priority = .fetch,
        },
    );
    defer headers.deinit();

    try testing.expectString("https://app.example", findHeader(headers, "Origin").value);
    try testing.expectString("cross-site", findHeader(headers, "Sec-Fetch-Site").value);
    try testing.expectString("cors", findHeader(headers, "Sec-Fetch-Mode").value);
    try testing.expectString("empty", findHeader(headers, "Sec-Fetch-Dest").value);
    try testing.expectString("u=3", findHeader(headers, "Priority").value);
}

test "Chrome149 iframe and classic worker use distinct destinations" {
    const profile = ClientProfile.get(.chrome149);
    var iframe = try Headers.initRequest(
        testing.allocator,
        "User-Agent: Chrome149",
        "Accept-Language: en-US,en;q=0.9",
        &profile,
        .{
            .destination = .iframe,
            .mode = .navigate,
            .site = .same_site,
            .trustworthy_target = true,
            .priority = .navigation,
        },
    );
    defer iframe.deinit();
    try testing.expectString("iframe", findHeader(iframe, "Sec-Fetch-Dest").value);
    try testing.expectEqual(@as(usize, 0), findHeader(iframe, "Sec-Fetch-User").count);

    var worker = try Headers.initRequest(
        testing.allocator,
        "User-Agent: Chrome149",
        "Accept-Language: en-US,en;q=0.9",
        &profile,
        .{
            .destination = .worker,
            .mode = .same_origin,
            .site = .same_origin,
            .trustworthy_target = true,
            .priority = .worker,
        },
    );
    defer worker.deinit();
    try testing.expectString("worker", findHeader(worker, "Sec-Fetch-Dest").value);
    try testing.expectString("same-origin", findHeader(worker, "Sec-Fetch-Mode").value);
}

test "Fetch Metadata is omitted for an untrustworthy target" {
    const profile = ClientProfile.get(.chrome149);
    var headers = try Headers.initRequest(
        testing.allocator,
        "User-Agent: Chrome149",
        "Accept-Language: en-US,en;q=0.9",
        &profile,
        .{
            .destination = .empty,
            .mode = .cors,
            .site = .cross_site,
            .trustworthy_target = false,
        },
    );
    defer headers.deinit();
    try testing.expectEqual(@as(usize, 0), findHeader(headers, "Sec-Fetch-Site").count);
    try testing.expectEqual(@as(usize, 0), findHeader(headers, "Sec-Fetch-Mode").count);
    try testing.expectEqual(@as(usize, 0), findHeader(headers, "Sec-Fetch-Dest").count);
}
