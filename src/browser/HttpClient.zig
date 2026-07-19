// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const builtin = @import("builtin");

const ArenaPool = @import("../ArenaPool.zig");
const Notification = @import("../Notification.zig");
const timestamp = @import("../datetime.zig").timestamp;

const URL = @import("URL.zig");
const ClientProfile = @import("../ClientProfile.zig");
const HttpProfile = @import("HttpProfile.zig");
const CookieJar = @import("webapi/storage/Cookie.zig").Jar;

const http = @import("../network/http.zig");
const Network = @import("../network/Network.zig");

const CDP = @import("../cdp/CDP.zig");
const Inbox = @import("../Inbox.zig");
const Watchdog = @import("../Watchdog.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

const TrackConnFailurePoint = enum {
    set_private,
    add,
};

// Keep fault injection and its fake pool hook out of production Client
// layouts. Tests use this to exercise the real trackConn rollback and the
// delayed ready_queue ownership handoff without calling either native
// transport with a fabricated Connection.
const TrackConnTestState = if (builtin.is_test) struct {
    failure: ?TrackConnFailurePoint = null,
    release_ctx: ?*anyopaque = null,
    release_callback: ?*const fn (*anyopaque, *http.Connection) void = null,
} else void;

fn monotonicMicroseconds() u64 {
    const ts = @import("../datetime.zig").timespec();
    return @as(u64, @intCast(ts.sec)) * std.time.us_per_s +
        @as(u64, @intCast(@divTrunc(ts.nsec, std.time.ns_per_us)));
}

pub const Method = http.Method;
pub const Header = http.Header;
pub const Headers = http.Headers;
pub const ResponseHead = http.ResponseHead;
pub const HeaderIterator = http.HeaderIterator;
pub const HeaderRequestContext = http.HeaderRequestContext;
const CachedResponse = @import("../network/cache/Cache.zig").CachedResponse;

/// Referrer Policy's eight effective policies. `default` is resolved by the
/// caller to Chrome 149's strict-origin-when-cross-origin default, so a
/// redirect always carries a concrete policy just like net::URLRequest.
pub const ReferrerPolicy = enum {
    no_referrer,
    no_referrer_when_downgrade,
    origin,
    origin_when_cross_origin,
    same_origin,
    strict_origin,
    strict_origin_when_cross_origin,
    unsafe_url,
};

pub const default_referrer_policy: ReferrerPolicy = .strict_origin_when_cross_origin;

/// Security origin of the environment settings object which initiated a
/// request.  This is deliberately independent from the environment's base or
/// creation URL: a blob: Worker has a blob: base URL while retaining its
/// creator's tuple origin, and a data: Worker has an explicit opaque origin.
pub const RequestOrigin = union(enum) {
    /// Compatibility state for request call sites which have not yet been
    /// migrated. It preserves the old initiator_url-derived behaviour.
    legacy_derive_from_initiator_url,
    /// Browser-initiated operation with no requestor. This is observably
    /// different from an opaque requestor (`Sec-Fetch-Site: none`).
    none,
    /// Canonical serialized HTTP(S) tuple origin.
    tuple: []const u8,
    /// Unique opaque origin. The identity itself is intentionally not
    /// serialized; when an Origin header is required its value is `null`.
    @"opaque",

    pub fn dupe(self: RequestOrigin, allocator: Allocator) !RequestOrigin {
        return switch (self) {
            .tuple => |origin| .{ .tuple = try allocator.dupe(u8, origin) },
            else => self,
        };
    }
};

/// Convert an unrelaxed Context security-origin key to the network-facing
/// tagged representation without confusing an opaque UUID with a missing
/// requestor. Frames handle DarkPanda's leading `!` document.domain marker
/// separately because the relaxed access-control key is not the network
/// origin serialized by Fetch.
pub fn requestOriginFromSecurityKey(key: []const u8) RequestOrigin {
    if (std.mem.startsWith(u8, key, "!") or std.mem.indexOf(u8, key, "://") == null) {
        return .@"opaque";
    }
    return .{ .tuple = key };
}

pub fn requestOriginFromRelaxableSecurityKey(
    key: []const u8,
    committed_origin: ?[]const u8,
) RequestOrigin {
    if (std.mem.startsWith(u8, key, "!")) {
        return if (committed_origin) |origin| .{ .tuple = origin } else .@"opaque";
    }
    return requestOriginFromSecurityKey(key);
}

/// HTML's "obtain a site" for the tuple-origin forms currently supported by
/// the network stack. Ports never participate; private PSL rules do.
pub fn obtainSchemefulSite(allocator: Allocator, origin: []const u8) !?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return null;
    const raw_scheme = origin[0..scheme_end];
    const scheme = if (std.ascii.eqlIgnoreCase(raw_scheme, "ws"))
        "http"
    else if (std.ascii.eqlIgnoreCase(raw_scheme, "wss"))
        "https"
    else if (std.ascii.eqlIgnoreCase(raw_scheme, "http"))
        "http"
    else if (std.ascii.eqlIgnoreCase(raw_scheme, "https"))
        "https"
    else
        return null;
    const raw_host = URL.getOriginHostname(origin);
    if (raw_host.len == 0) return null;
    const host = try std.ascii.allocLowerString(allocator, raw_host);
    const site_host = URL.domainAndRegistry(host) orelse host;
    return try std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, site_host });
}

/// Schemeful site inherited by an environment settings object for SameSite
/// cookie calculations. This remains separate from RequestOrigin: a data:
/// Worker inherits its creator's SiteForCookies while its request initiator is
/// opaque, making its subresource cookie context cross-site.
pub const SiteForCookies = union(enum) {
    /// Compatibility path for Request literals which still use cookie_origin.
    legacy_from_cookie_origin,
    null_site,
    schemeful_site: []const u8,

    pub fn dupe(self: SiteForCookies, allocator: Allocator) !SiteForCookies {
        return switch (self) {
            .schemeful_site => |site| .{ .schemeful_site = try allocator.dupe(u8, site) },
            else => self,
        };
    }
};

/// Browser-facing inputs needed to derive Fetch Metadata and referrer/origin
/// headers. Callers pass semantic request state, never precomputed header
/// strings, so every resource path follows the same policy.
pub const RequestContext = struct {
    pub const Credentials = enum { omit, same_origin, include };

    destination: HeaderRequestContext.Destination,
    mode: HeaderRequestContext.Mode,
    request_origin: RequestOrigin = .legacy_derive_from_initiator_url,
    initiator_url: ?[:0]const u8 = null,
    top_level_url: ?[:0]const u8 = null,
    referrer_url: ?[]const u8 = null,
    referrer_policy: ReferrerPolicy = default_referrer_policy,
    user_activation: bool = false,
    method: Method = .GET,
    has_body: bool = false,
    credentials: Credentials = .same_origin,
    priority: ?HeaderRequestContext.Priority = null,
};

/// Resource Timing is deliberately reported through an opaque sink rather
/// than importing Frame/Page/Performance into the transport. The values are
/// captured at the actual request lifecycle boundaries and consumed before
/// the Transfer arena is released.
pub const ResourceTimingInitiator = enum {
    iframe,
    img,
    script,
    fetch,
    xmlhttprequest,
    link,
    other,

    pub fn string(self: ResourceTimingInitiator) []const u8 {
        return switch (self) {
            .iframe => "iframe",
            .img => "img",
            .script => "script",
            .fetch => "fetch",
            .xmlhttprequest => "xmlhttprequest",
            .link => "link",
            .other => "other",
        };
    }
};

pub const ResourceTimingInfo = struct {
    name: []const u8,
    start_time_us: u64,
    request_start_us: u64,
    response_start_us: u64,
    response_end_us: u64,
    next_hop_protocol: []const u8,
    transfer_size: u64,
    encoded_body_size: u64,
    decoded_body_size: u64,
    response_status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
};

pub const ResourceTimingSink = struct {
    context: *anyopaque,
    execution_context: *anyopaque,
    initiator: ResourceTimingInitiator,
    record: *const fn (
        context: *anyopaque,
        execution_context: *anyopaque,
        initiator: ResourceTimingInitiator,
        info: ResourceTimingInfo,
    ) anyerror!void,
};

pub const CacheLayer = @import("../network/layer/CacheLayer.zig");
pub const InterceptionLayer = @import("../network/layer/InterceptionLayer.zig");
pub const DeferringLayer = @import("../network/layer/DeferringLayer.zig");

// This is loosely tied to a browser Frame. Loading all the <scripts>, doing
// XHR requests, and loading imports all happens through here. Sine the app
// currently supports 1 browser and 1 frame at-a-time, we only have 1 Client and
// re-use it from frame to frame. This allows connection-pool reuse.
//
pub const Client = @This();

// Count of active ws requests
ws_active: usize = 0,

// Count of active http requests
http_active: usize = 0,

// Shared asynchronous wreq handle set.
handles: http.Handles,

// Connections currently submitted to wreq.
in_use: std.DoublyLinkedList = .{},

// Connections whose removal is deferred during event processing.
dirty: std.DoublyLinkedList = .{},

// Whether we're currently processing transport events.
performing: bool = false,

// Watchdog instrumentation for this client's worker thread. Wraps the poll
// in perform (and the background-task wait in Runner) so the watchdog can
// tell "parked, waiting for work" from "stuck between waits". Registered
// with App.watchdog by Browser.init.
heartbeat: Watchdog.Heartbeat = .{},

// Use to generate the next request ID
next_request_id: u32 = 0,

// Every currently-alive Transfer indexed by its id. Maintained so cross-
// component code (CDP intercept state, future scheduling/debugging) can
// look up a transfer by id without holding a *Transfer that might dangle.
// Inserted in Client.request, removed in Transfer.deinit. The pointer is
// only valid for the lifetime of the entry.
transfers: std.AutoHashMapUnmanaged(u32, *Transfer) = .empty,

// When handles has no more available easys, requests get queued.
queue: std.DoublyLinkedList = .{},

// A queue for things that MUST happen on the next tick.
next_tick_queue: std.DoublyLinkedList = .{},
next_tick_count: usize = 0,

// Queue is for Transfers that have no connection. ready_queue is for connections
// that were initiated when performing == true and thus need to wait until
// performing == false before being added. I'm hoping this is temporary and that
// we can unify the two queues. But HTTP is being changed a lot right now, and
// I'm trying to minimize the surface area.
ready_queue: std.DoublyLinkedList = .{},

_track_conn_test: TrackConnTestState = if (builtin.is_test) .{} else {},

// The main app allocator
allocator: Allocator,

network: *Network,

arena_pool: *ArenaPool,

// The current proxy. Callers can change it, changeProxy(null) restores
// from config. May point either at `http_proxy_owned` (a caller-supplied
// dupe) or at the config string (which we must not free).
http_proxy: ?[:0]const u8 = null,

// When a caller (e.g. CDP) supplies a proxy, we have to dupe it to take ownership
// which we'll be responsible for freeing.
http_proxy_owned: ?[:0]const u8 = null,

// track if the client use a proxy for connections.
// We can't use http_proxy because we want also to track proxy configured via
// CDP.
use_proxy: bool,

// Current TLS verification state, applied per-connection in makeRequest.
tls_verify: bool = true,

// User agent override set via CDP Emulation.setUserAgentOverride.
// When set, takes precedence over the config's http_headers values.
// Both fields are allocated from self.allocator when set, null otherwise.
user_agent_override: ?[:0]const u8 = null,
user_agent_header_override: ?[:0]const u8 = null,

// C-string/header-syntax adapter derived from App's immutable resolved
// profile. null keeps the legacy Lightpanda Config path.
resolved_http_profile: ?HttpProfile.Owned = null,

// The CDP layer we dispatch inbox messages to. Set in CDP.init for
// `serve` mode; null in all other modes. Since this is set early, BEFORE the
// CDP socket is registered with the network thread, we also have the
// `cdp_link_active` boolean.
cdp: ?*CDP = null,

// True iff a producer (Server.handleConnection, after the worker
// handshake completes) has registered the CDP socket with the Network
// thread and Network will wake wreq when it pushes to the inbox. perform
// uses this — NOT `cdp != null` — to decide whether to block in poll
// without any in-flight HTTP
// work. cdp is set in CDP.init, well before the link is wired; tests
// and the pre-handshake window have a cdp but no producer, so polling
// there would just eat the timeout waiting for a wakeup that's never
// coming.
cdp_link_active: bool = false,

// CDP messages parsed off the WS socket by the Network thread land
// here. perform drains the inbox at each safe point and dispatches
// via cdp.onMessage / onPing / onClose / onDisconnect. Always present
// even in non-CDP mode — the empty-queue drain is one mutex lock plus
// a linked-list head check, cheaper than nullability everywhere.
inbox: Inbox,

max_response_size: usize,

blocking_requests: std.AutoHashMapUnmanaged(u32, u32) = .empty,

cache_layer: CacheLayer,
interception_layer: InterceptionLayer,
deferring_layer: DeferringLayer,
entry_layer: Layer,

pub const Layer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (*anyopaque, *Transfer) anyerror!void,
    };

    pub fn request(self: Layer, transfer: *Transfer) !void {
        return self.vtable.request(self.ptr, transfer);
    }
};

fn layerWith(self: anytype, next: Layer) Layer {
    self.next = next;
    return self.layer();
}

pub const NextTickNode = struct {
    pub const Run =
        *const fn (*Transfer, ?*anyopaque) void;
    pub const Abort = *const fn (?*anyopaque) void;

    node: std.DoublyLinkedList.Node = .{},
    ctx: ?*anyopaque,
    run: Run,
    abort: ?Abort = null,
};

pub fn init(self: *Client, allocator: Allocator, network: *Network, cdp: ?*CDP) !void {
    var resolved_http_profile: ?HttpProfile.Owned = if (network.app.resolvedFingerprint()) |resolved|
        try HttpProfile.Owned.init(allocator, resolved, &network.config.http_headers.profile)
    else
        null;
    errdefer if (resolved_http_profile) |*profile| profile.deinit(allocator);

    var handles = try http.Handles.init(
        network.config,
        network.wreq_transport_path,
    );
    errdefer handles.deinit();

    const http_proxy = network.config.httpProxy();

    self.* = Client{
        .handles = handles,
        .network = network,
        .allocator = allocator,
        .cdp = cdp,
        .inbox = .{},

        .use_proxy = http_proxy != null,
        .http_proxy = http_proxy,
        .tls_verify = network.config.tlsVerifyHost(),
        .resolved_http_profile = resolved_http_profile,
        .max_response_size = network.config.httpMaxResponseSize() orelse std.math.maxInt(u32),

        .cache_layer = .{},
        .interception_layer = .{},
        .deferring_layer = .{ .allocator = allocator, .network = network },
        .entry_layer = undefined,
        .arena_pool = &network.app.arena_pool,
    };

    var next = self.layer();

    next = layerWith(&self.cache_layer, next);

    if (network.config.mode == .serve) {
        next = layerWith(&self.interception_layer, next);
    }

    next = layerWith(&self.deferring_layer, next);

    self.entry_layer = next;
}

pub fn deinit(self: *Client) void {
    self.abort();

    if (comptime IS_DEBUG) {
        lp.assert(
            self.next_tick_count == 0,
            "next_tick_count must be 0",
            .{ .value = self.next_tick_count },
        );
    }

    self.handles.deinit();

    self.clearUserAgentOverride();
    if (self.resolved_http_profile) |*profile| profile.deinit(self.allocator);
    if (self.http_proxy_owned) |owned| {
        self.allocator.free(owned);
    }

    self.deferring_layer.deinit();
    self.blocking_requests.deinit(self.allocator);
    self.transfers.deinit(self.allocator);
    self.inbox.deinit(self.arena_pool);
}

// Look up a live transfer by its id. Returns null if the transfer has been
// destroyed. Use this — rather than holding *Transfer across yields — for
// any code path that's interleaved with the request lifecycle (CDP
// continueRequest/fulfill/abort, async cleanups).
pub fn findTransfer(self: *Client, id: u32) ?*Transfer {
    return self.transfers.get(id);
}

/// Cancel the live request associated with an operation-owned stable identity.
/// Layers are allowed to replace Request.ctx with wrapper callback contexts,
/// so cancellation_context is deliberately immutable across the layer chain.
/// Lookup happens on the owning Client thread; the map entry is removed before
/// Transfer.deinit releases its arena, avoiding retained raw Transfer pointers.
pub fn abortCancellationContext(
    self: *Client,
    cancellation_context: *anyopaque,
    err: anyerror,
) bool {
    var found: ?*Transfer = null;
    var it = self.transfers.valueIterator();
    while (it.next()) |entry| {
        const transfer = entry.*;
        if (transfer.req.cancellation_context == cancellation_context) {
            found = transfer;
            break;
        }
    }

    const transfer = found orelse return false;
    transfer.abort(err);
    // abort may synchronously remove/free transfer.  Never access it here.
    return true;
}

pub fn layer(self: *Client) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = _request },
    };
}

// Set a user agent override. Both the raw UA string and the pre-formatted
// "User-Agent: <ua>" header string are allocated from self.allocator.
pub fn setUserAgentOverride(self: *Client, ua: []const u8) !void {
    self.clearUserAgentOverride();
    const override = try self.allocator.dupeZ(u8, ua);
    errdefer self.allocator.free(override);
    const header = try std.fmt.allocPrintSentinel(self.allocator, "User-Agent: {s}", .{ua}, 0);
    self.user_agent_override = override;
    self.user_agent_header_override = header;
}

// Clear any user agent override, restoring the default from config.
pub fn clearUserAgentOverride(self: *Client) void {
    if (self.user_agent_override) |ua| {
        self.allocator.free(ua);
        self.user_agent_override = null;
    }
    if (self.user_agent_header_override) |uah| {
        self.allocator.free(uah);
        self.user_agent_header_override = null;
    }
}

// Enable TLS verification on all connections.
pub fn setTlsVerify(self: *Client, verify: bool) !void {
    // Remove inflight connections check on enable TLS b/c chromiumoxide calls
    // the command during navigate and Curl seems to accept it...

    var it = self.in_use.first;
    while (it) |node| : (it = node.next) {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        try conn.setTlsVerify(verify, self.use_proxy);
    }

    it = self.ready_queue.first;
    while (it) |node| : (it = node.next) {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        try conn.setTlsVerify(verify, self.use_proxy);
    }

    self.tls_verify = verify;
}

// Restrictive since a transport-wide proxy change must not race in-flight work.
// For now, this restriction is ok, since it's only called by CDP on
// createBrowserContext, at which point, if we do have an active connection,
// that's probably a bug (a previous abort failed?). But if we need to call this
// Per-request overrides remain available through Connection.setProxy.
pub fn changeProxy(self: *Client, proxy: ?[:0]const u8) !void {
    try self.ensureNoActiveConnection();

    // Free any previously-duped proxy before we overwrite http_proxy.
    if (self.http_proxy_owned) |owned| {
        self.allocator.free(owned);
        self.http_proxy_owned = null;
    }

    // Reset to the config default; if dupeZ below fails, http_proxy is
    // left pointing at this rather than at the freed dup.
    self.http_proxy = self.network.config.httpProxy();

    if (proxy) |p| {
        const owned = try self.allocator.dupeZ(u8, p);
        self.http_proxy_owned = owned;
        self.http_proxy = owned;
    }
    self.use_proxy = self.http_proxy != null;
}

pub fn newHeaders(self: *const Client) !http.Headers {
    const identity = self.requestIdentity();
    const ua_header = self.user_agent_header_override orelse identity.user_agent_header;
    return http.Headers.initWithProfile(
        ua_header,
        identity.accept_language_header,
        identity.profile,
    );
}

/// Build the full ordered header set for a browser resource request.
pub fn newRequestHeaders(
    self: *const Client,
    target_url: [:0]const u8,
    context: RequestContext,
) !http.Headers {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();

    const target_origin = try URL.getOrigin(allocator, target_url);
    const legacy_without_initiator = context.request_origin == .legacy_derive_from_initiator_url and
        context.initiator_url == null;
    const request_origin: RequestOrigin = switch (context.request_origin) {
        .legacy_derive_from_initiator_url => if (context.initiator_url) |initiator|
            if (try URL.getOrigin(allocator, initiator)) |origin|
                .{ .tuple = origin }
            else
                .@"opaque"
        else
            .none,
        else => context.request_origin,
    };
    const site = try requestOriginSite(allocator, request_origin, target_url, target_origin);

    const cross_origin = site != .same_origin;
    const unsafe_method = context.method != .GET and context.method != .HEAD;
    const send_origin = unsafe_method or (context.mode == .cors and cross_origin);
    const origin: ?[]const u8 = if (!send_origin)
        null
    else switch (request_origin) {
        .tuple => |tuple| tuple,
        .@"opaque" => "null",
        // Preserve the legacy null-initiator serialization while allowing an
        // explicit `.none` to mean a genuinely browser-initiated request.
        .none => if (legacy_without_initiator) "null" else null,
        .legacy_derive_from_initiator_url => unreachable,
    };
    const referrer = try requestReferrerWithPolicy(
        allocator,
        context.referrer_url,
        target_url,
        target_origin,
        context.referrer_policy,
    );

    // Retained in the semantic model even where Chrome149 does not emit an
    // extra header: credentials controls cookie/CORS handling, top-level URL
    // feeds isolation/storage policy, and body presence affects framing.
    _ = context.credentials;
    _ = context.top_level_url;
    _ = context.has_body;

    const priority: HeaderRequestContext.Priority = context.priority orelse switch (context.destination) {
        .document, .iframe => .navigation,
        .image => .image,
        .style => .style,
        .script => .script,
        .worker => .worker,
        .empty => .fetch,
    };
    const identity = self.requestIdentity();
    const ua_header = self.user_agent_header_override orelse identity.user_agent_header;
    return http.Headers.initRequest(
        self.allocator,
        ua_header,
        identity.accept_language_header,
        identity.profile,
        .{
            .destination = context.destination,
            .mode = context.mode,
            .site = site,
            .trustworthy_target = isPotentiallyTrustworthy(target_url),
            .user_activation = context.user_activation,
            .origin = origin,
            .referrer = referrer,
            .priority = priority,
        },
    );
}

pub fn newNavigationHeaders(self: *const Client, root_browser_navigation: bool) !http.Headers {
    const identity = self.requestIdentity();
    const ua_header = self.user_agent_header_override orelse identity.user_agent_header;
    return http.Headers.initNavigation(
        ua_header,
        identity.accept_language_header,
        identity.profile,
        root_browser_navigation,
    );
}

const RequestIdentity = struct {
    user_agent: [:0]const u8,
    user_agent_header: [:0]const u8,
    accept_language_header: [:0]const u8,
    profile: *const ClientProfile.Data,
};

fn requestIdentity(self: *const Client) RequestIdentity {
    if (self.resolved_http_profile) |*resolved| {
        return .{
            .user_agent = resolved.user_agent,
            .user_agent_header = resolved.user_agent_header,
            .accept_language_header = resolved.accept_language_header,
            .profile = &resolved.profile,
        };
    }
    const legacy = &self.network.config.http_headers;
    return .{
        .user_agent = legacy.user_agent,
        .user_agent_header = legacy.user_agent_header,
        .accept_language_header = legacy.locale_profile.accept_language_header,
        .profile = &legacy.profile,
    };
}

pub const IdentityEvidence = struct {
    user_agent: []const u8,
    accept_language: []const u8,
    sec_ch_ua: []const u8,
    sec_ch_ua_mobile: []const u8,
    sec_ch_ua_platform: []const u8,
};

/// Exact values serialized by newHeaders/newRequestHeaders/newNavigationHeaders
/// before wreq receives them with default_headers(false).
pub fn identityEvidence(self: *const Client) IdentityEvidence {
    const identity = self.requestIdentity();
    return .{
        .user_agent = identity.user_agent,
        .accept_language = headerValue(identity.accept_language_header),
        .sec_ch_ua = headerValue(identity.profile.sec_ch_ua_header),
        .sec_ch_ua_mobile = headerValue(identity.profile.sec_ch_ua_mobile_header),
        .sec_ch_ua_platform = headerValue(identity.profile.sec_ch_ua_platform_header),
    };
}

pub const TransportEvidence = struct {
    backend: []const u8,
    library_version: []const u8,
    wreq_abi_version: ?u32,
    wreq_profile_id: ?u32,
    emulation_preset: ?[]const u8,
};

pub fn transportEvidence(self: *const Client) TransportEvidence {
    return .{
        .backend = "wreq",
        .library_version = self.handles.wreq_api.version(),
        .wreq_abi_version = @import("../sys/wreq_transport.zig").abi_version,
        .wreq_profile_id = @import("../sys/wreq_transport.zig").profile_chrome_149,
        .emulation_preset = "Chrome149",
    };
}

fn headerValue(header: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, header, ':') orelse return header;
    var start = colon + 1;
    while (start < header.len and (header[start] == ' ' or header[start] == '\t')) start += 1;
    return header[start..];
}

pub fn requestOriginSite(
    allocator: Allocator,
    request_origin: RequestOrigin,
    target_url: [:0]const u8,
    target_origin: ?[]const u8,
) !HeaderRequestContext.Site {
    const source_origin = switch (request_origin) {
        .none => return .none,
        .@"opaque" => return .cross_site,
        .tuple => |origin| origin,
        // Callers which need legacy derivation resolve it before entering this
        // helper. Treat an accidentally unexpanded value as no requestor so it
        // cannot acquire tuple-origin authority.
        .legacy_derive_from_initiator_url => return .none,
    };
    const destination_origin = target_origin orelse return .cross_site;
    if (std.mem.eql(u8, source_origin, destination_origin)) return .same_origin;

    const source_url = try allocator.dupeZ(u8, source_origin);
    if (!std.ascii.eqlIgnoreCase(URL.getProtocol(source_url), URL.getProtocol(target_url))) {
        return .cross_site;
    }
    const source_host = URL.getHostname(source_url);
    const destination_host = URL.getHostname(target_url);
    if (source_host.len == 0 or destination_host.len == 0) return .cross_site;
    if (isIpLiteral(source_host) or isIpLiteral(destination_host)) {
        return if (std.ascii.eqlIgnoreCase(source_host, destination_host)) .same_site else .cross_site;
    }
    return if (std.ascii.eqlIgnoreCase(
        URL.domainAndRegistry(source_host) orelse source_host,
        URL.domainAndRegistry(destination_host) orelse destination_host,
    )) .same_site else .cross_site;
}

/// Compare an HTTP(S) target with an explicit request origin. Opaque and
/// missing origins are never same-origin with a tuple target.
pub fn requestOriginIsSameOrigin(
    allocator: Allocator,
    request_origin: RequestOrigin,
    target_url: [:0]const u8,
) !bool {
    const source_origin = switch (request_origin) {
        .tuple => |origin| origin,
        .none, .@"opaque" => return false,
        .legacy_derive_from_initiator_url => return false,
    };
    const target_origin = (try URL.getOrigin(allocator, target_url)) orelse return false;
    return std.mem.eql(u8, source_origin, target_origin);
}

/// Resolve the compatibility origin carried by older Request call sites.
/// `cookie_origin` was historically the only immutable initiator URL retained
/// on Request, so it is the least surprising authority for Resource Timing
/// until every caller supplies an explicit RequestOrigin.
fn resolvedResourceTimingOrigin(
    allocator: Allocator,
    request_origin: RequestOrigin,
    legacy_initiator_url: [:0]const u8,
) !RequestOrigin {
    return switch (request_origin) {
        .legacy_derive_from_initiator_url => if (try URL.getOrigin(allocator, legacy_initiator_url)) |origin|
            .{ .tuple = origin }
        else
            .@"opaque",
        else => request_origin,
    };
}

fn serializedRequestOrigin(request_origin: RequestOrigin) ?[]const u8 {
    return switch (request_origin) {
        .tuple => |origin| origin,
        .@"opaque" => "null",
        .none => null,
        .legacy_derive_from_initiator_url => unreachable,
    };
}

fn resourceTimingRedirectTaintsOrigin(
    allocator: Allocator,
    request_origin: RequestOrigin,
    current_url: [:0]const u8,
    new_url: [:0]const u8,
) !bool {
    if (request_origin == .none) return false;
    if (try requestOriginIsSameOrigin(allocator, request_origin, current_url)) return false;

    const current_origin = (try URL.getOrigin(allocator, current_url)) orelse return true;
    const new_origin = (try URL.getOrigin(allocator, new_url)) orelse return true;
    return !std.mem.eql(u8, current_origin, new_origin);
}

/// Chromium parses Timing-Allow-Origin as an HTTP comma list (including
/// commas protected by quoted list members), then compares each raw member
/// with the serialized request origin. ValuesIterator deliberately retains the
/// quotes; a quoted origin therefore does not compare equal. A wildcard is
/// meaningful only when the request has an initiator.
fn timingAllowOriginHeaderPasses(raw: []const u8, serialized_origin: ?[]const u8) bool {
    const origin = serialized_origin orelse return false;
    var item_start: usize = 0;
    var in_quotes = false;
    var escaped = false;
    var index: usize = 0;
    while (index <= raw.len) : (index += 1) {
        const at_end = index == raw.len;
        if (!at_end) {
            const byte = raw[index];
            if (in_quotes and escaped) {
                escaped = false;
                continue;
            }
            if (in_quotes and byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') {
                in_quotes = !in_quotes;
                continue;
            }
            if (byte != ',' or in_quotes) continue;
        }

        const item = std.mem.trim(u8, raw[item_start..index], " \t");
        if (std.mem.eql(u8, item, "*") or std.mem.eql(u8, item, origin)) {
            return true;
        }
        item_start = index + 1;
    }
    return false;
}

/// HttpResponseHeaders::GetNormalizedHeader joins repeated field values with
/// exactly `, `. Keep that normalization separate from ValuesIterator-style
/// parsing: quote/escape state must span physical field boundaries.
fn combineHttpHeaderValues(
    allocator: Allocator,
    values: []const []const u8,
) ![]const u8 {
    if (values.len == 0) return "";
    if (values.len == 1) return values[0];

    var total_len: usize = 2 * (values.len - 1);
    for (values) |value| total_len = try std.math.add(usize, total_len, value.len);

    const combined = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (values, 0..) |value, index| {
        if (index != 0) {
            @memcpy(combined[offset..][0..2], ", ");
            offset += 2;
        }
        @memcpy(combined[offset..][0..value.len], value);
        offset += value.len;
    }
    return combined;
}

fn combinedResponseHeaderValue(
    allocator: Allocator,
    conn: *const http.Connection,
    name: [:0]const u8,
) !?[]const u8 {
    const first = conn.getResponseHeader(name, 0) orelse return null;
    if (first.amount <= 1) return first.value;

    const values = try allocator.alloc([]const u8, first.amount);
    for (values, 0..) |*value, index| {
        value.* = (conn.getResponseHeader(name, index) orelse return error.MissingResponseHeaderValue).value;
    }
    return try combineHttpHeaderValues(allocator, values);
}

fn timingAllowFailedAfterHop(
    already_failed: bool,
    response_same_origin: bool,
    tao_header_passed: bool,
) bool {
    return already_failed or !(response_same_origin or tao_header_passed);
}

/// Access-Control-Allow-Origin is not a list header. This helper is used only
/// after confirming the request was made in CORS mode; an ACAO header on an
/// opaque no-cors response therefore cannot expose response details.
fn accessControlAllowOriginPasses(
    raw: []const u8,
    serialized_origin: ?[]const u8,
    credentials_include: bool,
) bool {
    const origin = serialized_origin orelse return false;
    const value = std.mem.trim(u8, raw, " \t");
    if (std.mem.eql(u8, value, "*")) return !credentials_include;
    return std.mem.eql(u8, value, origin);
}

fn resourceTimingResponseDetailsAllowed(
    response_same_origin: bool,
    request_uses_cors_mode: bool,
    credentials_include: bool,
    access_control_allow_origin: ?[]const u8,
    access_control_allow_origin_count: usize,
    access_control_allow_credentials: ?[]const u8,
    access_control_allow_credentials_count: usize,
    serialized_origin: ?[]const u8,
) bool {
    if (response_same_origin) return true;
    if (!request_uses_cors_mode or access_control_allow_origin_count != 1) return false;
    if (!accessControlAllowOriginPasses(
        access_control_allow_origin orelse return false,
        serialized_origin,
        credentials_include,
    )) return false;
    if (!credentials_include) return true;

    // Fetch's CORS credentials check is byte-case-sensitive: a credentialed
    // response needs one exact `Access-Control-Allow-Credentials: true` field.
    if (access_control_allow_credentials_count != 1) return false;
    const value = std.mem.trim(
        u8,
        access_control_allow_credentials orelse return false,
        " \t",
    );
    return std.mem.eql(u8, value, "true");
}

/// Mirrors ResourceResponse::GetFilteredHttpContentEncoding in Chromium 149.
/// Multiple physical fields normalize to a comma-separated value in Chromium,
/// so they are reported as `multiple` even when the first field has no comma.
fn filteredHttpContentEncoding(raw: ?[]const u8, field_count: usize) []const u8 {
    const value = std.mem.trim(u8, raw orelse return "", " \t");
    if (value.len == 0 and field_count <= 1) return "";
    if (field_count > 1 or std.mem.indexOfScalar(u8, value, ',') != null) return "multiple";
    if (std.ascii.eqlIgnoreCase(value, "br")) return "br";
    if (std.ascii.eqlIgnoreCase(value, "dcb")) return "dcb";
    if (std.ascii.eqlIgnoreCase(value, "dcz")) return "dcz";
    if (std.ascii.eqlIgnoreCase(value, "deflate")) return "deflate";
    if (std.ascii.eqlIgnoreCase(value, "gzip")) return "gzip";
    if (std.ascii.eqlIgnoreCase(value, "zstd")) return "zstd";
    return "@unknown";
}

const supported_javascript_mime_types = [_][]const u8{
    "application/ecmascript",
    "application/javascript",
    "application/x-ecmascript",
    "application/x-javascript",
    "text/ecmascript",
    "text/javascript",
    "text/javascript1.0",
    "text/javascript1.1",
    "text/javascript1.2",
    "text/javascript1.3",
    "text/javascript1.4",
    "text/javascript1.5",
    "text/jscript",
    "text/livescript",
    "text/x-ecmascript",
    "text/x-javascript",
};

const supported_image_mime_types = [_][]const u8{
    "image/jpeg",
    "image/pjpeg",
    "image/jpg",
    "image/webp",
    "image/png",
    "image/apng",
    "image/gif",
    "image/bmp",
    "image/vnd.microsoft.icon",
    "image/x-icon",
    "image/x-xbitmap",
    "image/x-png",
    "image/avif",
};

const unsupported_text_mime_types = [_][]const u8{
    "text/calendar",
    "text/x-calendar",
    "text/x-vcalendar",
    "text/vcalendar",
    "text/vcard",
    "text/x-vcard",
    "text/directory",
    "text/ldif",
    "text/qif",
    "text/x-qif",
    "text/x-csv",
    "text/x-vcf",
    "text/rtf",
    "text/comma-separated-values",
    "text/csv",
    "text/tab-separated-values",
    "text/tsv",
    "text/ofx",
    "text/vnd.sun.j2me.app-descriptor",
    "text/x-ms-iqy",
    "text/x-ms-odc",
    "text/x-ms-rqy",
    "text/x-ms-contact",
};

const supported_non_image_mime_types = [_][]const u8{
    "image/svg+xml",
    "application/xml",
    "application/atom+xml",
    "application/rss+xml",
    "application/xhtml+xml",
    "application/json",
    "message/rfc822",
    "multipart/related",
    "multipart/x-mixed-replace",
};

// media::IsSupportedMediaMimeType is build/codec dependent. These are the
// stable container MIME types supported by Chromium's ordinary desktop
// builds; codec-specific acceptance is not represented by contentType.
const supported_media_mime_types = [_][]const u8{
    "audio/aac",
    "audio/flac",
    "audio/mp4",
    "audio/mpeg",
    "audio/ogg",
    "audio/wav",
    "audio/webm",
    "audio/x-m4a",
    "audio/x-wav",
    "video/mp4",
    "video/ogg",
    "video/webm",
    "video/x-m4v",
};

fn mimeTypeIn(comptime values: anytype, mime_type: []const u8) bool {
    inline for (values) |value| {
        if (std.mem.eql(u8, value, mime_type)) return true;
    }
    return false;
}

fn isValidMimeEssence(essence: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, essence, '/') orelse return false;
    if (slash == 0 or slash + 1 == essence.len) return false;
    if (std.mem.indexOfScalarPos(u8, essence, slash + 1, '/') != null) return false;

    for (essence) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~', '/' => {},
            else => return false,
        }
    }
    return true;
}

fn parseMimeEssence(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    var end: usize = 0;
    while (end < trimmed.len) : (end += 1) {
        switch (trimmed[end]) {
            ';', ' ', '\t', '(' => break,
            else => {},
        }
    }
    const essence = trimmed[0..end];
    return if (isValidMimeEssence(essence)) essence else null;
}

/// Equivalent to Blink ExtractMIMETypeFromMediaType for the ASCII response
/// header path: HTTP comma-list parsing (last valid member wins), parameter
/// removal, and lowercase normalization.
fn extractMimeTypeFromMediaType(allocator: Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return "";
    const lower = try std.ascii.allocLowerString(allocator, raw);

    var last_valid: []const u8 = "";
    var item_start: usize = 0;
    var in_quotes = false;
    var escaped = false;
    var index: usize = 0;
    while (index <= lower.len) : (index += 1) {
        const at_end = index == lower.len;
        if (!at_end) {
            const byte = lower[index];
            if (in_quotes and escaped) {
                escaped = false;
                continue;
            }
            if (in_quotes and byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') {
                in_quotes = !in_quotes;
                continue;
            }
            if (byte != ',' or in_quotes) continue;
        }

        if (parseMimeEssence(lower[item_start..index])) |essence| last_valid = essence;
        item_start = index + 1;
    }
    return last_valid;
}

fn isJsonMimeType(mime_type: []const u8) bool {
    if (std.mem.eql(u8, mime_type, "application/json") or
        std.mem.eql(u8, mime_type, "text/json")) return true;
    const slash = std.mem.indexOfScalar(u8, mime_type, '/') orelse return false;
    return slash + 1 < mime_type.len and std.mem.endsWith(u8, mime_type[slash + 1 ..], "+json");
}

fn isXmlMimeType(mime_type: []const u8) bool {
    if (std.mem.eql(u8, mime_type, "text/xml") or
        std.mem.eql(u8, mime_type, "application/xml")) return true;
    return std.mem.startsWith(u8, mime_type, "application/") and
        std.mem.endsWith(u8, mime_type, "+xml");
}

fn isSupportedMimeType(mime_type: []const u8) bool {
    if (mimeTypeIn(supported_image_mime_types, mime_type) or
        mimeTypeIn(supported_non_image_mime_types, mime_type) or
        mimeTypeIn(supported_javascript_mime_types, mime_type) or
        mimeTypeIn(supported_media_mime_types, mime_type)) return true;
    if (std.mem.startsWith(u8, mime_type, "text/")) {
        return !mimeTypeIn(unsupported_text_mime_types, mime_type);
    }
    return std.mem.startsWith(u8, mime_type, "application/") and
        std.mem.endsWith(u8, mime_type, "+json");
}

/// Blink MinimizedMIMEType, applied after ExtractMIMETypeFromMediaType.
fn minimizedResourceTimingContentType(allocator: Allocator, raw: []const u8) ![]const u8 {
    const mime_type = try extractMimeTypeFromMediaType(allocator, raw);
    if (mimeTypeIn(supported_javascript_mime_types, mime_type)) return "text/javascript";
    if (isJsonMimeType(mime_type)) return "application/json";
    if (std.mem.eql(u8, mime_type, "image/svg+xml")) return "image/svg+xml";
    if (isXmlMimeType(mime_type)) return "application/xml";
    return if (isSupportedMimeType(mime_type)) mime_type else "";
}

fn cookieSameSiteContext(
    allocator: Allocator,
    request_origin: RequestOrigin,
    site_for_cookies: SiteForCookies,
    target_url: [:0]const u8,
) !?bool {
    const site = switch (site_for_cookies) {
        .legacy_from_cookie_origin => return null,
        .null_site => return false,
        .schemeful_site => |value| value,
    };
    // Chromium requires both the SiteForCookies and the request initiator to
    // be same-site with the target for a strict subresource cookie context.
    // An opaque initiator therefore remains cross-site even when it inherited
    // a non-null SiteForCookies from its creator (notably data: Workers).
    const target_origin = try URL.getOrigin(allocator, target_url);
    const initiator_relation = try requestOriginSite(
        allocator,
        request_origin,
        target_url,
        target_origin,
    );
    if (initiator_relation != .same_origin and initiator_relation != .same_site) return false;

    const cookie_site_relation = try requestOriginSite(
        allocator,
        .{ .tuple = site },
        target_url,
        target_origin,
    );
    return cookie_site_relation == .same_origin or cookie_site_relation == .same_site;
}

fn isIpLiteral(host: []const u8) bool {
    if (host.len == 0) return false;
    if (host[0] == '[' or std.mem.indexOfScalar(u8, host, ':') != null) return true;
    var dots: usize = 0;
    for (host) |c| switch (c) {
        '0'...'9' => {},
        '.' => dots += 1,
        else => return false,
    };
    return dots == 3;
}

fn isPotentiallyTrustworthy(url: [:0]const u8) bool {
    const protocol = URL.getProtocol(url);
    if (std.ascii.eqlIgnoreCase(protocol, "https:") or
        std.ascii.eqlIgnoreCase(protocol, "wss:")) return true;
    if (!std.ascii.eqlIgnoreCase(protocol, "http:") and
        !std.ascii.eqlIgnoreCase(protocol, "ws:")) return false;

    const host = URL.getHostname(url);
    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.endsWithIgnoreCase(host, ".localhost") or
        std.ascii.eqlIgnoreCase(host, "[::1]") or
        std.ascii.eqlIgnoreCase(host, "::1")) return true;
    return std.mem.startsWith(u8, host, "127.");
}

pub fn requestReferrer(
    allocator: Allocator,
    referrer_url: ?[]const u8,
    target_url: [:0]const u8,
    target_origin: ?[]const u8,
) !?[]const u8 {
    return requestReferrerWithPolicy(
        allocator,
        referrer_url,
        target_url,
        target_origin,
        default_referrer_policy,
    );
}

/// Implements Chromium's URLRequestJob::ComputeReferrerForPolicy for the URL
/// forms handled by this browser. The input is deliberately the *currently
/// selected* referrer: redirect processing feeds the result of one hop into
/// the next, so cross-origin granularity can never be regained later in a
/// chain.
pub fn requestReferrerWithPolicy(
    allocator: Allocator,
    referrer_url: ?[]const u8,
    target_url: [:0]const u8,
    target_origin: ?[]const u8,
    policy: ReferrerPolicy,
) !?[]const u8 {
    const referrer = referrer_url orelse return null;
    const referrer_z = try allocator.dupeZ(u8, referrer);
    const source_origin = (try URL.getOrigin(allocator, referrer_z)) orelse return null;
    var sanitized_referrer: [:0]const u8 = referrer_z;
    if (URL.getUsername(sanitized_referrer).len > 0 or URL.getPassword(sanitized_referrer).len > 0) {
        sanitized_referrer = try URL.setPassword(sanitized_referrer, "", allocator);
        sanitized_referrer = try URL.setUsername(sanitized_referrer, "", allocator);
    }
    const same_origin = if (target_origin) |destination_origin|
        std.mem.eql(u8, source_origin, destination_origin)
    else
        false;
    const downgrade = std.ascii.eqlIgnoreCase(URL.getProtocol(referrer_z), "https:") and
        !std.ascii.eqlIgnoreCase(URL.getProtocol(target_url), "https:");

    const fragment = std.mem.indexOfScalar(u8, sanitized_referrer, '#') orelse sanitized_referrer.len;
    const stripped = sanitized_referrer[0..fragment];
    const origin_only = try originReferrer(allocator, source_origin);
    const full = if (stripped.len > 4096) origin_only else stripped;

    return switch (policy) {
        .no_referrer => null,
        .no_referrer_when_downgrade => if (downgrade) null else full,
        .origin => origin_only,
        .origin_when_cross_origin => if (same_origin) full else origin_only,
        .same_origin => if (same_origin) full else null,
        .strict_origin => if (downgrade) null else origin_only,
        .strict_origin_when_cross_origin => if (same_origin)
            full
        else if (downgrade)
            null
        else
            origin_only,
        .unsafe_url => full,
    };
}

fn originReferrer(allocator: Allocator, origin: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, origin, "/")) return origin;
    return std.fmt.allocPrint(allocator, "{s}/", .{origin});
}

/// Referrer-Policy response headers use the last recognized comma-separated
/// token. Unknown tokens do not erase an earlier valid policy.
fn referrerPolicyFromHeader(value: []const u8) ?ReferrerPolicy {
    var result: ?ReferrerPolicy = null;
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        const parsed: ?ReferrerPolicy = if (std.ascii.eqlIgnoreCase(token, "no-referrer"))
            .no_referrer
        else if (std.ascii.eqlIgnoreCase(token, "no-referrer-when-downgrade"))
            .no_referrer_when_downgrade
        else if (std.ascii.eqlIgnoreCase(token, "origin"))
            .origin
        else if (std.ascii.eqlIgnoreCase(token, "origin-when-cross-origin"))
            .origin_when_cross_origin
        else if (std.ascii.eqlIgnoreCase(token, "same-origin"))
            .same_origin
        else if (std.ascii.eqlIgnoreCase(token, "strict-origin"))
            .strict_origin
        else if (std.ascii.eqlIgnoreCase(token, "strict-origin-when-cross-origin"))
            .strict_origin_when_cross_origin
        else if (std.ascii.eqlIgnoreCase(token, "unsafe-url"))
            .unsafe_url
        else
            null;
        if (parsed) |policy| result = policy;
    }
    return result;
}

fn removeHeader(headers: *Headers, allocator: Allocator, name: []const u8) !void {
    var rebuilt: Headers = .{ .headers = null };
    errdefer rebuilt.deinit();

    var iterator = headers.iterator();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) continue;
        const line = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}: {s}",
            .{ header.name, header.value },
            0,
        );
        try rebuilt.add(line);
    }

    headers.deinit();
    headers.* = rebuilt;
}

pub fn getUserAgent(self: *const Client) [:0]const u8 {
    return self.user_agent_override orelse self.requestIdentity().user_agent;
}

pub fn abort(self: *Client) void {
    // Snapshot before killing: kill() -> deinit removes entries from
    // self.transfers, which would invalidate a live iterator.
    var snapshot = std.ArrayList(*Transfer).initCapacity(self.allocator, self.transfers.count()) catch @panic("OOM");
    defer snapshot.deinit(self.allocator);
    var it = self.transfers.valueIterator();
    while (it.next()) |t| {
        snapshot.appendAssumeCapacity(t.*);
    }

    for (snapshot.items) |t| {
        t.kill();
    }

    // After the kill loop, every internal list should drain itself via
    // each transfer's deinit:
    //   - self.transfers : transfers.remove(self.id)
    //   - self.queue     : unlinked if _queued is set
    //   - self.in_use / self.ready_queue : via removeConn
    //   - self.dirty     : drained at end of each perform; nothing left here
    // Any non-empty list means a transfer escaped cleanup — assert so we
    // catch the regression rather than silently leaking on next use.
    if (comptime IS_DEBUG) {
        std.debug.assert(self.transfers.size == 0);
        std.debug.assert(self.queue.first == null);
        std.debug.assert(self.in_use.first == null);
        std.debug.assert(self.ready_queue.first == null);
        std.debug.assert(self.dirty.first == null);
    }
}

// Kill every transfer + websocket owned by `owner`. Used when the owner
// (Frame / WorkerGlobalScope) is being torn down. After this returns,
// every WebSocket is fully gone; HTTP transfers that were mid-perform may
// still be on `owner.transfers` (Transfer.kill defers their deinit), but
// they've been unlinked from the owner list via kill()'s deferred branch
// so the owner is free to die.
pub fn abortOwner(self: *Client, owner: *Owner) void {
    self.abortRequests(owner);
    var n = owner.websockets.first;
    while (n) |node| {
        n = node.next;
        const ws: *@import("webapi/net/WebSocket.zig") = @fieldParentPtr("_owner_node", node);
        ws.kill();
    }
    if (comptime IS_DEBUG) {
        std.debug.assert(owner.websockets.first == null);
    }
}

// Permanently close an execution-context owner before aborting its current
// work. Retained detached realms can still call cached Web APIs, so the guard
// must live below those wrappers as a final no-I/O boundary.
pub fn retireOwner(self: *Client, owner: *Owner) void {
    owner.accepting_requests = false;
    self.abortOwner(owner);
}

// HTTP-only variant. WebSockets survive (they're cross-document by
// design). Used by the navigation path that aborts in-flight resource
// loads for a frame but lets its WebSockets keep running.
pub fn abortRequests(_: *Client, owner: *Owner) void {
    var n = owner.transfers.first;
    while (n) |node| {
        n = node.next;
        const t: *Transfer = @fieldParentPtr("owner_node", node);
        t.kill();
    }
    // owner.transfers may still have entries: Transfer.kill defers
    // (flags `aborted` + noops callbacks) when called mid-perform and
    // only fully deinits later via processOneMessage. The deferred-branch
    // unlinks the node and clears Transfer.owner, so by the time the
    // owner itself is freed, no orphan transfer points at it.
}

// What CDP messages drainInbox is allowed to dispatch this tick.
//   .all       — outer event loop (Runner.tick). Safe to dispatch
//                everything; the JS stack is empty.
//   .sync_wait — reachable from inside a JS callback (syncRequest,
//                waitForImport). The JS callstack above us holds
//                refs to page / session / V8 state; dispatching a
//                command that frees that state would UAF on unwind.
//                Cherry-pick only Fetch interception responses
const DrainMode = enum { all, sync_wait };

pub fn tick(self: *Client, timeout_ms: u32, mode: DrainMode) !void {
    if (self.inbox.terminated) {
        return error.ClientDisconnected;
    }

    try self.drainNextTickQueue();
    try self.drainQueue();
    try self.perform(@intCast(timeout_ms));
    // perform/processMessages just released a batch of connections back to
    // the pool. Drain again so queued transfers can use them this tick
    // instead of waiting for the next runner iteration.
    try self.drainQueue();
    // Dispatch CDP messages here, not inside perform: perform recurses
    // via processOneMessage's redirect path (perform → processMessages
    // → processOneMessage → perform), and dispatching CDP from that
    // nested call would fire CDP handlers mid-redirect, defeating the
    // "safe points only" guarantee.
    try self.drainInbox(mode);
}

pub fn runNextTick(
    self: *Client,
    transfer: *Transfer,
    ctx: ?*anyopaque,
    params: struct { run: NextTickNode.Run, abort: ?NextTickNode.Abort = null },
) !void {
    transfer._next_tick_node = .{ .ctx = ctx, .run = params.run, .abort = params.abort };

    self.next_tick_count += 1;
    self.next_tick_queue.append(&transfer._next_tick_node.?.node);
}

fn cancelNextTick(self: *Client, transfer: *Transfer) void {
    if (transfer._next_tick_node) |*ntn| {
        self.next_tick_queue.remove(&ntn.node);
        self.next_tick_count -= 1;

        if (ntn.abort) |abort_cb| {
            abort_cb(ntn.ctx);
        }
    }
}

fn drainNextTickQueue(self: *Client) !void {
    var remaining = self.next_tick_count;
    while (remaining > 0) : (remaining -= 1) {
        const node = self.next_tick_queue.popFirst() orelse break;
        defer self.next_tick_count -= 1;
        const n: *NextTickNode = @fieldParentPtr("node", node);

        const transfer: *Transfer = @fieldParentPtr(
            "_next_tick_node",
            @as(*?NextTickNode, @ptrCast(n)),
        );

        const ntn = n.*;
        transfer._next_tick_node = null;
        ntn.run(transfer, ntn.ctx);
    }
}

fn drainQueue(self: *Client) !void {
    while (self.queue.popFirst()) |queue_node| {
        const transfer: *Transfer = @fieldParentPtr("_node", queue_node);
        const conn = self.network.getConnection() orelse {
            self.queue.prepend(queue_node);
            return;
        };
        // Bridge state to .created so a failure inside makeRequest before
        // any commit cleans up via the abort below. makeRequest flips to
        // .inflight on a successful trackConn.
        transfer.state = .created;
        self.makeRequest(conn, transfer) catch |err| {
            if (transfer.state == .created) {
                transfer.abort(err);
            }
            return err;
        };
    }
}

// last layer
pub fn _request(_: *anyopaque, transfer: *Transfer) !void {
    return transfer.client.process(transfer);
}

// HttpClient takes ownership of req.headers; do not pair with
// `errdefer headers.deinit()`
pub fn request(self: *Client, req: Request, owner: ?*Owner) !void {
    _ = try self.requestT(req, owner);
}

// Like `request`, but returns the created `*Transfer`. The caller does not own
// the returned `*Transfer` and must thus use it with care. From the moment this
// function is entered, the HttpClient owns `req` — specifically `req.headers`
// On success, transfer.deinit eventually frees it. On any failure path inside
// this function, we free it before returning the error.
fn requestT(self: *Client, req: Request, owner: ?*Owner) !*Transfer {
    if (owner) |o| {
        if (!o.accepting_requests) {
            // Client owns req (specifically req.headers) from function entry.
            req.deinit();
            if (req.unstarted_callback) |cb| cb(req.ctx);
            return error.ContextShuttingDown;
        }
    }

    const arena = self.arena_pool.acquire(.small, "Request.arena") catch |err| {
        req.headers.deinit();
        if (req.unstarted_callback) |cb| cb(req.ctx);
        return err;
    };

    const transfer = blk: {
        errdefer {
            req.headers.deinit();
            if (req.unstarted_callback) |cb| cb(req.ctx);
            self.arena_pool.release(arena);
        }

        var owned = req;
        // Most of the time, the req data will outlive the transfer. But not
        // always. The most problematic case is with a QueuedNavigation which
        // is freed quite quickly and would definetly not survive a queued
        // request.
        //
        // These are all small, so duping them into the transfer's arena is
        // cheap and can solve some nasty UAF.
        owned.url = try arena.dupeZ(u8, req.url);
        owned.cookie_origin = try arena.dupeZ(u8, req.cookie_origin);
        owned.request_origin = try req.request_origin.dupe(arena);
        owned.site_for_cookies = try req.site_for_cookies.dupe(arena);
        if (req.credentials) |c| {
            owned.credentials = try arena.dupeZ(u8, c);
        }

        // The body can be larger, so callers can signal, via the
        // `body_outlives_request` flag that they guarantee that the body
        // will outlive the transfer (and thus doesn't need to be duped)
        if (req.body) |b| {
            if (req.body_outlives_request == false) {
                owned.body = try arena.dupe(u8, b);
            }

            // wreq receives only the browser-authored header set and does not
            // synthesize an Expect header for large request bodies.
        }

        const t = try arena.create(Transfer);
        var blob_token: ?BlobToken = null;
        errdefer if (blob_token) |token| token.release();

        // Resolve blob: URLs while the request is created, not when the
        // synthetic response happens on the next tick. Chromium does the
        // equivalent by resolving a BlobURLToken in DedicatedWorker::Start.
        // That token deliberately survives URL.revokeObjectURL() so an
        // already-started fetch/Worker load remains valid.
        if (std.mem.startsWith(u8, owned.url, "blob:")) {
            if (owner) |o| {
                if (o.blob_releaser) |releaser| {
                    if (o.blob_urls) |blob_urls| {
                        if (blob_urls.acquire(owned.url)) |blob| {
                            blob_token = .{
                                .blob = blob,
                                .body = blob._slice,
                                .content_type = blob._mime,
                                .releaser = releaser,
                            };
                        }
                    }
                }
            }
        }

        t.* = .{
            .req = owned,
            .client = self,
            .arena = arena,
            .id = self.incrReqId(),
            .start_time = timestamp(.monotonic),
            .timing_start_us = monotonicMicroseconds(),
            .resource_timing_name = owned.url,
            .blob_token = blob_token,
            // owner is set AFTER we've actually appended to the owner list,
            // so transfer.deinit's `if (self.owner)` branch only fires when
            // we're truly linked. Otherwise we'd try to remove a node from
            // a list it was never in.
            .owner = null,
            .owner_node = .{},
        };
        break :blk t;
    };

    // From here, transfer owns req+arena. Any subsequent failure flows
    // through transfer.deinit (or transfer.abort), which handles headers
    // via req.deinit. Do NOT free headers directly past this point.

    // Register for id-based lookup. putNoClobber would fail if request_id
    // collides (i.e. we've wrapped through 2^32 requests and the old
    // transfer is still alive — practically never).
    self.transfers.putNoClobber(self.allocator, transfer.id, transfer) catch |err| {
        if (transfer.req.unstarted_callback) |cb| cb(transfer.req.ctx);
        transfer.deinit();
        return err;
    };

    if (owner) |o| {
        o.addTransfer(transfer);
        transfer.owner = o;
    }

    // From this point forward, the transfer owns `req` and `arena`. If the
    // layer chain fails before any layer commits the transfer to an external
    // owner (queue / multi handle / pending interception), we clean up here
    // via transfer.abort which fires error_callback and deinits. `.created`
    // means no commit happened — anything else is held by an owner that
    // will clean up.

    // Synthetic schemes never touch the network or the layer chain — they skip
    // cache/interception and deliver on the next tick
    if (Synthetic.isSynthetic(req.url)) {
        // The 2nd transfer is the callback context. We don't actually use it,
        // we're just sticking transfer in there to have something.
        self.runNextTick(transfer, null, .{ .run = Synthetic.run }) catch |err| {
            if (transfer.state == .created) {
                transfer.abort(err);
            }
            return err;
        };
        return transfer;
    }

    self.entry_layer.request(transfer) catch |err| {
        if (transfer.state == .created) {
            transfer.abort(err);
        }
        return err;
    };

    return transfer;
}

// Non-network URL schemes whose response is synthesized in-process rather than
// fetched, think blob data URLs.
const Synthetic = struct {
    const data_url = @import("data_url.zig");

    fn isSynthetic(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "data:") or std.mem.startsWith(u8, url, "blob:");
    }

    fn run(transfer: *Transfer, _: ?*anyopaque) void {
        // prevents a callback that triggers a navigation queue from killing
        // this transfer from under us.
        transfer.state = .completing;
        defer transfer.deinit();

        const fulfilled = build(transfer) catch |err| {
            transfer.req.error_callback(transfer.req.ctx, err);
            return;
        };
        deliver(&transfer.req, &fulfilled) catch |err| {
            transfer.req.error_callback(transfer.req.ctx, err);
        };
    }

    fn build(transfer: *Transfer) !FulfilledResponse {
        const arena = transfer.arena;
        const url = transfer.req.url;

        var body: []const u8 = "";
        var content_type: []const u8 = "";

        if (std.mem.startsWith(u8, url, "data:")) {
            const parsed = try data_url.parse(arena, url);
            content_type = parsed.content_type;
            body = parsed.body;
        } else {
            // Captured synchronously when Client.request was called. This is
            // a strong reference, analogous to Chromium's BlobURLToken, so a
            // later revoke or creator-global teardown cannot race this load.
            const token = transfer.blob_token orelse return error.BlobNotFound;
            content_type = token.content_type;
            body = token.body;
        }

        // A blob with no type yields no Content-Type header.
        const headers = if (content_type.len > 0) blk: {
            const h = try arena.alloc(http.Header, 1);
            h[0] = .{ .name = "content-type", .value = content_type };
            break :blk h;
        } else &[_]http.Header{};

        return .{
            .url = url,
            .body = body,
            .status = 200,
            .headers = headers,
        };
    }

    fn deliver(req: *Request, fulfilled: *const FulfilledResponse) !void {
        const response = Response.fromFulfilled(req.ctx, fulfilled);
        if (req.start_callback) |cb| {
            try cb(response);
        }

        const result = try req.header_callback(response);
        if (result == .abort) {
            return error.Abort;
        }

        if (fulfilled.body) |b| {
            if (b.len > 0) {
                try req.data_callback(response, b);
            }
        }
        try req.done_callback(req.ctx);
    }
};

const SyncContext = struct {
    allocator: Allocator,
    completion: union(enum) {
        in_progress: void,
        done: void,
        err: anyerror,
        shutdown: void,
    } = .in_progress,

    status: u16 = 0,
    body: std.ArrayList(u8),

    fn headerCallback(response: Response) anyerror!HeaderResult {
        const self: *SyncContext = @ptrCast(@alignCast(response.ctx));
        lp.assert(response.status() != null, "HttpClient.SyncRequest.headerCallback", .{ .value = response.status() });
        self.status = response.status().?;
        if (response.contentLength()) |cl| {
            try self.body.ensureTotalCapacity(self.allocator, cl);
        }
        return .proceed;
    }

    fn dataCallback(response: Response, data: []const u8) anyerror!void {
        const self: *SyncContext = @ptrCast(@alignCast(response.ctx));
        try self.body.appendSlice(self.allocator, data);
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .done;
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .{ .err = err };
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *SyncContext = @ptrCast(@alignCast(ctx));
        self.completion = .shutdown;
    }
};

pub fn syncRequest(self: *Client, allocator: Allocator, req: Request) !SyncResponse {
    if (self.inbox.terminated) {
        // request() takes ownership of req.headers on every path; we return
        // before calling it, so free the owned request headers here.
        req.headers.deinit();
        return error.ClientDisconnected;
    }

    var sync_ctx = SyncContext{ .allocator = allocator, .body = .empty };
    errdefer sync_ctx.body.deinit(allocator);

    const expected_id = self.nextReqId();
    const frame_id = req.frame_id;
    try self.blocking_requests.putNoClobber(self.allocator, frame_id, expected_id);
    defer _ = self.blocking_requests.remove(frame_id);

    var r = req;
    r.ctx = &sync_ctx;
    r.header_callback = SyncContext.headerCallback;
    r.data_callback = SyncContext.dataCallback;
    r.done_callback = SyncContext.doneCallback;
    r.error_callback = SyncContext.errorCallback;
    r.shutdown_callback = SyncContext.shutdownCallback;
    const transfer = try self.requestT(r, null);

    while (sync_ctx.completion == .in_progress) {
        self.tick(200, .sync_wait) catch |err| {
            if (sync_ctx.completion == .in_progress) {
                // tick failed for a reason unrelated to our transfer (likely OOM or
                // client disconnect). transfer.req.ctx points at &sync_ctx on this
                // stack — abort to sever that reference before we return
                transfer.abort(err);
            }
            return err;
        };
        if (sync_ctx.completion == .in_progress and self.inbox.contains(isSyncWaitInterrupt)) {
            // A teardown/close command is queued but sync_wait can't dispatch
            // it mid-parse (it would free the Page/Frame this stack holds).
            // Abort the blocking fetch so the parser unwinds to the next safe
            // drain and the command runs there, instead of stalling for the
            // full per-request timeout per blocking script.
            transfer.abort(error.SyncWaitInterrupted);
        }
    }

    switch (sync_ctx.completion) {
        .in_progress => @panic("Impossible to be in progress here."),
        .done, .shutdown => return .{
            .status = sync_ctx.status,
            .body = sync_ctx.body,
        },
        .err => |e| return e,
    }
}

// Above, request will not process if there's an interception request. In such
// cases, the interceptor is expected to call resume to continue the transfer
// or transfer.abort() to abort it.
fn process(self: *Client, transfer: *Transfer) !void {
    // Never mutate the transport request map recursively while processing an
    // event; re-entrant requests are queued for the next drain.
    if (self.performing == false) {
        if (self.network.getConnection()) |conn| {
            return self.makeRequest(conn, transfer);
        }
    }

    self.queue.append(&transfer._node);
    transfer.state = .queued;
}

pub fn nextReqId(self: *Client) u32 {
    return self.next_request_id +% 1;
}

pub fn incrReqId(self: *Client) u32 {
    const id = self.next_request_id +% 1;
    self.next_request_id = id;
    return id;
}

// Same restriction as changeProxy. Should be ok since this is only called on
// BrowserContext deinit.
pub fn restoreOriginalProxy(self: *Client) !void {
    try self.ensureNoActiveConnection();

    self.http_proxy = self.network.config.httpProxy();
    self.use_proxy = self.http_proxy != null;
}

fn makeRequest(self: *Client, conn: *http.Connection, transfer: *Transfer) anyerror!void {
    conn.debug_added = 0;
    conn.debug_removed = 0;
    conn.debug_remove_err = null;
    {
        // Reset per-response state for retries (auth challenge, queue).
        const auth = transfer._auth_challenge;
        transfer.reset();
        transfer._auth_challenge = auth;

        // conn is locally held during configure; we don't write it to
        // `transfer._conn` until trackConn commits it to the multi
        // handle. If configureConn fails, release the conn back to the
        // pool — `transfer.state` stays `.created`, and the caller
        // (Client.request's errdefer or drainQueue's catch) aborts
        // the transfer.
        errdefer self.releaseConn(conn);

        try transfer.configureConn(conn);
    }

    // As soon as trackConn succeeds, the multi handle owns the transfer's
    // lifecycle. perform/processMessages will eventually invoke completion
    // callbacks and call transfer.deinit.
    transfer.noteRequestStart();
    self.trackConn(conn) catch |err| {
        self.releaseConn(conn);
        return err;
    };
    transfer._conn = conn;
    transfer.state = .inflight;

    if (transfer.req.start_callback) |cb| {
        cb(Response.fromTransfer(transfer)) catch |err| {
            // We're now committed to the multi. transfer.abort fires the
            // error_callback and tears down (removeConn handles the
            // already-in-multi case via the dirty queue).
            transfer.abort(err);
            return err;
        };
    }

    // Start the request (and move along any other request). This used to call
    // self.perform(0) but that can also execute callbacks. Normally, that
    // wouldn't be so bad. But the event drain can synchronously fire callbacks for the
    // request we JUST added, which we do not want (it results in incorrect
    // execution).
    self.performing = true;
    defer self.performing = false;
    _ = try self.handles.perform();
}

fn perform(self: *Client, timeout_ms: c_int) anyerror!void {
    const running = blk: {
        self.performing = true;
        defer self.performing = false;

        break :blk try self.handles.perform();
    };

    // Process dirty connections — return them to Network pool.
    while (self.dirty.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        self.handles.remove(conn) catch |err| {
            lp.assert(false, "multi_remove_handle", .{
                .err = err,
                .in_use = conn.in_use,
                .added = conn.debug_added,
                .removed = conn.debug_removed,
                .remove_err = conn.debug_remove_err,
            });
        };
        conn.debug_removed = 2;
        self.releaseConn(conn);
    }

    while (self.ready_queue.popFirst()) |node| {
        const conn: *http.Connection = @fieldParentPtr("node", node);
        // A request created re-entrantly during handles.perform can be retired
        // by its owner before this delayed backend commit. New teardown logic
        // removes such nodes synchronously, but keep this guard as the final
        // no-I/O boundary for an already-aborted Transfer.
        if (conn.transport == .http and conn.transport.http.state == .aborted) {
            const transfer = conn.transport.http;
            self.ready_queue.prepend(&conn.node);
            transfer.deinit();
            continue;
        }
        self.trackConn(conn) catch |err| {
            self.failReadyTrackConn(conn, err);
            continue;
        };
    }

    // We just processed completions; their done_callbacks may have
    // scheduled microtasks (JS continuations) or queued new transfers.
    // Return without polling so the caller (_tick) can run macrotasks
    // and re-evaluate. Otherwise we'd sleep on cdp_link_active for up
    // to timeout_ms while pending JS work sits idle.
    const processed_messages = try self.processMessages();
    if (processed_messages) {
        return;
    }

    // Poll for HTTP I/O. The Network thread wakes wreq whenever it pushes to
    // our inbox, so we return promptly even with no requests in flight
    // — but ONLY if a producer is actually wired up. `cdp_link_active`
    // is set by Server.handleConnection once network.registerCdp has
    // returned; in tests (which never register) and during the
    // pre-handshake window the flag stays false and we don't waste a
    // poll timeout waiting for a wakeup that won't arrive.
    if (running > 0 or self.cdp_link_active) {
        // when cdp_link_active == true, the network thread will unblock this
        // by calling wakup on our multi.
        self.heartbeat.enterWait();
        defer self.heartbeat.exitWait();
        try self.handles.poll(&.{}, timeout_ms);
    }

    _ = try self.processMessages();
}

// Drain any CDP messages the Network thread pushed into our inbox
// and dispatch them via the cdp_client callbacks. Returns
// error.ClientDisconnected if the inbox surfaced a disconnect message,
// so the worker loop can tear down the connection. Called from tick
// only — NOT from perform, because perform recurses through
// processOneMessage's redirect path.
fn drainInbox(self: *Client, mode: DrainMode) !void {
    const cdp = self.cdp orelse return;
    while (true) {
        const msg = switch (mode) {
            .all => self.inbox.pop(),
            .sync_wait => self.inbox.popIf(allowDuringSyncWait),
        } orelse return;

        defer msg.deinit(self.arena_pool);

        switch (msg.payload) {
            .cdp => |*c| cdp.onMessage(c) catch |err| {
                // A single malformed/failed dispatch shouldn't poison
                // the rest of the batch — log and continue.
                log.err(.cdp, "CDP dispatch", .{ .err = err });
            },
            .ping => |body| cdp.onPing(body),
            .close => {
                cdp.onClose();
                cdp.onDisconnect(null);
                self.inbox.terminated = true;
                return error.ClientDisconnected;
            },
            .disconnect => |err| {
                cdp.onDisconnect(err);
                self.inbox.terminated = true;
                return error.ClientDisconnected;
            },
        }
    }
}

// Predicate for Inbox.popIf during sync_wait drains. Always allows
// ping/close/disconnect (control frames must be observed). CDP data
// messages are filtered: only the four Fetch interception methods
// are safe to dispatch from inside a JS callback (they mutate
// transfer state via InterceptionLayer; they don't touch page /
// session / V8 state). The check is exact on the parsed `method`
// field — no substring matching against raw JSON.
//
// Every method listed here must be safe to dispatch with
// JS on the stack — meaning it must NO reach any other code
// path that frees Page/Session/Frame/Worker state the unwinding
// eval frame above us will dereference.
fn allowDuringSyncWait(msg: *Inbox.Message) bool {
    return switch (msg.payload) {
        .ping, .close, .disconnect => true,
        .cdp => |c| isFetchInterceptionMethod(c.input.method),
    };
}

fn isFetchInterceptionMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "Fetch.continueRequest") or
        std.mem.eql(u8, method, "Fetch.failRequest") or
        std.mem.eql(u8, method, "Fetch.fulfillRequest") or
        std.mem.eql(u8, method, "Fetch.continueWithAuth");
}

// True for inbox messages that mean "this page/connection is going away".
// syncRequest uses this to bail out of a blocking-script wait promptly
// rather than holding the worker for the per-request timeout while a
// teardown command sits undispatched behind the sync_wait allowlist.
fn isSyncWaitInterrupt(msg: *Inbox.Message) bool {
    return switch (msg.payload) {
        .close, .disconnect => true,
        .ping => false,
        .cdp => |c| isTeardownMethod(c.input.method),
    };
}

fn isTeardownMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "Target.closeTarget") or
        std.mem.eql(u8, method, "Target.disposeBrowserContext") or
        std.mem.eql(u8, method, "Page.close");
}

pub fn isRedirectStatus(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

fn processOneMessage(self: *Client, msg: http.Handles.MultiMessage, transfer: *Transfer) !bool {
    // Owner retirement can happen re-entrantly from another connection's
    // callback while this transfer is still inside Handles.perform(). In that
    // case kill() deliberately leaves the connection/Transfer alive until its
    // completion message arrives, but detachInPerform() has already severed
    // every pointer into the retired owner and replaced the request callbacks
    // with no-ops. Do not inspect response/auth/cookie/timing state here: those
    // fields may point into a Page or WorkerGlobalScope which is now gone.
    // Returning true hands the one remaining cleanup to processMessages(),
    // whose Transfer.deinit removes/releases _conn exactly once.
    if (transfer.state == .aborted) return true;

    // State at entry: .inflight = conn (multi just delivered a completion).
    // wreq stamps this at its DONE event; other backends conservatively use
    // the moment their completion message is observed.
    transfer.noteResponseEnd();

    const effective_err = msg.err;

    if (effective_err == null or effective_err.? == error.RecvError) {
        transfer.detectAuthChallenge(msg.conn);
    }

    // In case of auth challenge
    // TODO give a way to configure the number of auth retries.
    if (transfer._auth_challenge != null and transfer._tries < 10) {
        var wait_for_interception = false;
        transfer.req.notification.dispatch(
            .http_request_auth_required,
            &.{ .transfer = transfer, .wait_for_interception = &wait_for_interception },
        );
        if (wait_for_interception) {
            self.interception_layer.intercepted += 1;
            if (comptime IS_DEBUG) {
                log.debug(.http, "wait for auth interception", .{ .intercepted = self.interception_layer.intercepted });
            }

            // Whether or not this is a blocking request, we're not going
            // to process it now. We can end the transfer, which will
            // release the easy handle back into the pool. The transfer
            // is still valid/alive (just has no handle); park it for
            // continueWithAuth.
            self.removeConn(transfer._conn.?);
            transfer._conn = null;
            transfer.state = .{ .parked = .intercept_auth };
            return false;
        }
    }

    // Handle redirects: reuse the same connection to preserve TCP state.
    // A redirect status without a Location header is not a redirect, it's a
    // final response and falls through so its body is delivered.
    if (effective_err == null) {
        const status = try msg.conn.getResponseCode();
        if (isRedirectStatus(status)) {
            if (msg.conn.getResponseHeader("location", 0)) |location| switch (transfer.req.redirect) {
                .follow => {
                    // Fetch's timing allow failed flag is sticky across the
                    // redirect chain. Capture this hop before reset discards
                    // its headers and response URL.
                    transfer.noteResourceTimingRedirectHop(msg.conn);
                    try transfer.handleRedirect(location.value);

                    const conn = transfer._conn.?;

                    try self.handles.remove(conn);
                    conn.debug_removed = 3;
                    // Conn temporarily out of multi during reconfigure.
                    // _detached_conn lets processMessages release it if any of
                    // the steps below throw. State stays .inflight; _conn stays set
                    transfer._detached_conn = conn;

                    transfer.reset();
                    try transfer.configureConn(conn);
                    transfer.noteRequestStart();
                    try self.handles.add(conn);
                    conn.debug_added = 2;
                    transfer._detached_conn = null;

                    _ = try self.perform(0);

                    return false;
                },
                // error_callback surfaces this as a TypeError.
                .@"error" => {
                    transfer.state = .completing;
                    transfer.requestFailed(error.RedirectNotAllowed, true);
                    return true;
                },
                // Don't follow; fall through to deliver the 3xx as the final
                // response, which the fetch layer turns into an opaque redirect.
                .manual => {},
            };
        }
    }

    // Transfer is done (success or error). Caller (processMessages) owns deinit.
    // Return true = done (caller will deinit), false = continues (redirect/auth).

    // When the server closes the TLS onnection without a close_notify alert,
    // BoringSSL reports RecvError. If we already received valid HTTP headers,
    // this is a normal end-of-body (the connection closure signals the end
    // of the response per HTTP/1.1 when there is no Content-Length).
    // We must check this before endTransfer, which may reset the easy handle.
    const is_conn_close_recv = blk: {
        const err = effective_err orelse break :blk false;
        if (err != error.RecvError) break :blk false;
        const hdr = msg.conn.getResponseHeader("connection", 0) orelse break :blk true;
        break :blk std.ascii.eqlIgnoreCase(hdr.value, "close");
    };

    // Transition to .completing so re-entrant aborts from user callbacks
    // defer their teardown to processMessages. (_conn carries through
    // from .inflight; nothing to set here.)
    transfer.state = .completing;

    if (effective_err != null and !is_conn_close_recv) {
        transfer.requestFailed(transfer.res.callback_error orelse effective_err.?, true);
        return true;
    }

    if (!transfer.res.header_done_called) {
        // In case of request w/o data, we need to call the header done
        // callback now.
        const result = try transfer.headerDoneCallback(msg.conn);
        switch (result) {
            .proceed => {},
            .handled => return true,
            .abort => {
                transfer.requestFailed(error.Abort, true);
                return true;
            },
        }
    }

    const body = transfer.res.stream_buffer.items;

    // Replay buffered body through user's data_callback.
    if (body.len > 0) {
        try transfer.req.data_callback(Response.fromTransfer(transfer), body);

        if (transfer.state == .aborted) {
            transfer.requestFailed(error.Abort, true);
            return true;
        }
    }

    // release conn ASAP so that it's available; some done_callbacks
    // will load more resources. State stays .completing — the
    // processMessages caller still owns deinit.
    transfer.reportResourceTiming();
    self.removeConn(msg.conn);
    transfer._conn = null;

    try transfer.req.done_callback(transfer.req.ctx);

    return true;
}

fn processMessages(self: *Client) !bool {
    var processed = false;
    while (try self.handles.readMessage()) |msg| {
        switch (msg.conn.transport) {
            .http => |transfer| {
                const done = self.processOneMessage(msg, transfer) catch |err| blk: {
                    log.err(.http, "process_messages", .{ .err = err, .req = transfer });
                    // A redirect configure/add failure owns a Connection which
                    // has already left Handles but is still linked in Client.
                    // Sever both Transfer aliases before returning it to the
                    // pool; the trailing transfer.deinit must not remove and
                    // release the same Connection a second time.
                    if (self.takeDetachedRedirectConnection(transfer)) |c| self.releaseConn(c);

                    // Failure callbacks may navigate/close re-entrantly. Mark
                    // this as the processMessages-owned completion window so
                    // owner teardown defers the one Transfer.deinit below.
                    if (transfer.state != .aborted) transfer.state = .completing;
                    transfer.requestFailed(err, true);
                    break :blk true;
                };
                if (done) {
                    transfer.deinit();
                    processed = true;
                }
            },
            .websocket => |ws| {
                // ws_active will be decremented through the call to disconnected
                if (msg.err) |err| switch (err) {
                    error.GotNothing => ws.disconnected(null),
                    else => ws.disconnected(err),
                } else {
                    // Clean close - no error
                    ws.disconnected(null);
                }

                processed = true;
            },
            .none => unreachable,
        }
    }
    return processed;
}

fn takeDetachedRedirectConnection(self: *Client, transfer: *Transfer) ?*http.Connection {
    const conn = transfer._detached_conn orelse return null;
    lp.assert(transfer._conn == conn, "redirect detached connection alias", .{
        .transfer = transfer,
        .conn_addr = @intFromPtr(conn),
        .transfer_conn_addr = if (transfer._conn) |value| @intFromPtr(value) else 0,
    });
    lp.assert(conn.in_use, "redirect detached connection ownership", .{
        .transfer = transfer,
        .conn_addr = @intFromPtr(conn),
    });
    lp.assert(self.http_active > 0, "redirect detached active count", .{
        .transfer = transfer,
        .conn_addr = @intFromPtr(conn),
        .http_active = self.http_active,
    });

    self.in_use.remove(&conn.node);
    conn.in_use = false;
    self.http_active -= 1;
    transfer._conn = null;
    transfer._detached_conn = null;
    return conn;
}

/// Submit one complete WebSocket message to the native Windows wreq stream.
/// The DLL deep-copies the payload synchronously, so the WebSocket arena may
/// release its message storage as soon as this returns.
pub fn sendWebSocket(
    self: *Client,
    conn: *http.Connection,
    frame_type: http.WsFrameType,
    data: []const u8,
    close_code: u16,
) !void {
    try self.handles.sendWebSocket(conn, frame_type, data, close_code);
}

fn trackConnSetPrivate(self: *Client, conn: *http.Connection) !void {
    if (comptime builtin.is_test) {
        switch (self._track_conn_test.failure orelse return conn.setPrivate(conn)) {
            .set_private => return error.InjectedTrackConnSetPrivateFailure,
            // The add-stage test needs the logical setPrivate step to succeed,
            // but must not call the native backend with its fabricated handle.
            .add => return,
        }
    }
    try conn.setPrivate(conn);
}

fn trackConnAdd(self: *Client, conn: *http.Connection) !void {
    if (comptime builtin.is_test) {
        if (self._track_conn_test.failure == .add) {
            return error.InjectedTrackConnAddFailure;
        }
    }
    try self.handles.add(conn);
}

fn rollbackTrackConn(self: *Client, conn: *http.Connection) void {
    std.debug.assert(conn.in_use);
    self.in_use.remove(&conn.node);
    conn.in_use = false;
}

fn failReadyTrackConn(self: *Client, conn: *http.Connection, err: anyerror) void {
    // popFirst transferred the only list ownership to this function and
    // trackConn rolled back its failed in_use insertion. Restore ready_queue
    // membership before invoking owner cleanup so removeConn(false) has one
    // well-defined node to unlink and release.
    std.debug.assert(!conn.in_use);
    self.ready_queue.prepend(&conn.node);

    switch (conn.transport) {
        .http => |transfer| {
            std.debug.assert(transfer._conn == conn);
            defer transfer.deinit();

            if (transfer.state == .aborted) return;

            // Do not call transfer.abort here. Its error callback runs while
            // state is still .inflight; a re-entrant owner teardown could then
            // synchronously deinit the Transfer before abort's trailing
            // detachOrDeinit. The .completing window makes that teardown defer
            // to this function's single deinit, matching processMessages.
            transfer.state = .completing;
            transfer.requestFailed(err, true);
        },
        .websocket => |ws| {
            // disconnected marks the socket closed before scheduling events,
            // then teardownConn removes this ready_queue node, releases the
            // connection, clears WebSocket._conn and drops its owner/ref.
            ws.disconnected(err);
        },
        .none => {
            // Defensive cleanup for a malformed transport owner. A properly
            // configured HTTP/WS connection cannot reach this branch.
            self.ready_queue.remove(&conn.node);
            self.releaseConn(conn);
        },
    }
}

pub fn trackConn(self: *Client, conn: *http.Connection) !void {
    if (self.performing) {
        conn.in_use = false;
        self.ready_queue.append(&conn.node);
        return;
    }

    self.in_use.append(&conn.node);
    conn.in_use = true;
    // Preserve the explicit pre-submit failure point used by ownership tests.
    self.trackConnSetPrivate(conn) catch |err| {
        self.rollbackTrackConn(conn);
        return err;
    };
    self.trackConnAdd(conn) catch |err| {
        self.rollbackTrackConn(conn);
        return err;
    };
    conn.debug_added = 1;

    switch (conn.transport) {
        .http => self.http_active += 1,
        .websocket => self.ws_active += 1,
        else => unreachable,
    }
}

pub fn removeConn(self: *Client, conn: *http.Connection) void {
    if (conn.in_use == false) {
        self.ready_queue.remove(&conn.node);
        self.releaseConn(conn);
        return;
    }

    self.in_use.remove(&conn.node);
    conn.in_use = false;
    switch (conn.transport) {
        .http => self.http_active -= 1,
        .websocket => self.ws_active -= 1,
        else => unreachable,
    }
    if (self.handles.remove(conn)) {
        conn.debug_removed = 1;
        self.releaseConn(conn);
    } else |err| {
        // Can happen if we're in a perform() call, so we'll queue this
        // for cleanup later.
        conn.debug_remove_err = err;
        self.dirty.append(&conn.node);
    }
}

fn releaseConn(self: *Client, conn: *http.Connection) void {
    if (comptime builtin.is_test) {
        if (self._track_conn_test.release_callback) |callback| {
            callback(self._track_conn_test.release_ctx.?, conn);
            return;
        }
    }
    self.network.releaseConnection(conn);
}

fn ensureNoActiveConnection(self: *const Client) !void {
    if (self.http_active > 0 or self.ws_active > 0) {
        return error.InflightConnection;
    }
}

pub const HeaderResult = enum {
    /// Continue processing normally.
    proceed,
    /// Caller took ownership of the response; stop w/o error or abort.
    handled,
    /// Abort the Transfer,
    abort,
};

pub const Request = struct {
    pub const StartCallback = *const fn (response: Response) anyerror!void;
    pub const HeaderCallback = *const fn (response: Response) anyerror!HeaderResult;
    pub const DataCallback = *const fn (response: Response, data: []const u8) anyerror!void;
    pub const DoneCallback = *const fn (ctx: *anyopaque) anyerror!void;
    pub const ErrorCallback = *const fn (ctx: *anyopaque, err: anyerror) void;
    pub const ShutdownCallback = *const fn (ctx: *anyopaque) void;

    pub const ResourceType = enum {
        document,
        xhr,
        image,
        script,
        fetch,
        stylesheet,

        // Allowed Values: Document, Stylesheet, Image, Media, Font, Script,
        // TextTrack, XHR, Fetch, Prefetch, EventSource, WebSocket, Manifest,
        // SignedExchange, Ping, CSPViolationReport, Preflight, FedCM, Other
        // https://chromedevtools.github.io/devtools-protocol/tot/Network/#type-ResourceType
        pub fn string(self: ResourceType) []const u8 {
            return switch (self) {
                .document => "Document",
                .xhr => "XHR",
                .image => "Image",
                .script => "Script",
                .fetch => "Fetch",
                .stylesheet => "Stylesheet",
            };
        }
    };

    /// Isolate-free attribution consumed by embedder diagnostics. This is not
    /// derived from headers or an initiator URL, so a Dedicated Worker can
    /// publish it without retaining or crossing its creator Frame pointer.
    pub const InitiatorContext = enum {
        page,
        worker,
    };

    // Fetch request redirect mode. `.follow` keeps navigations, XHR and
    // internal requests transparently following redirects.
    pub const RedirectMode = enum { follow, manual, @"error" };

    frame_id: u32,
    loader_id: u32,
    /// Root FFI browsing context which owns frame_id. Frame.makeRequest fills
    /// this for page/subframe/Worker-entry requests; WorkerGlobalScope carries
    /// the immutable snapshot to its independent HTTP owner thread.
    root_frame_id: u32 = 0,
    initiator_context: InitiatorContext = .page,
    method: Method,
    url: [:0]const u8,
    headers: http.Headers,
    body: ?[]const u8 = null,
    cookie_jar: ?*CookieJar,
    cookie_origin: [:0]const u8,
    // Explicit cookie-context inputs for migrated callers. Legacy requests
    // retain the old cookie_origin-only path without a behavioural change.
    request_origin: RequestOrigin = .legacy_derive_from_initiator_url,
    site_for_cookies: SiteForCookies = .legacy_from_cookie_origin,
    resource_type: ResourceType,
    redirect: RedirectMode = .follow,
    credentials: ?[:0]const u8 = null,
    notification: *Notification,
    timeout_ms: u32 = 0,

    // Navigation requests carry the value selected for the current hop, not
    // the unsanitized creator URL. Each redirect applies `referrer_policy` to
    // this value and updates both the wire header and Document-facing state.
    // The boolean distinguishes an intentionally empty value from a request
    // which does not participate in browser referrer handling.
    selected_referrer: ?[]const u8 = null,
    referrer_policy: ReferrerPolicy = default_referrer_policy,
    referrer_managed: bool = false,

    // Optional owner-provided PerformanceResourceTiming destination. The
    // transport knows only this opaque callback and never imports a DOM type.
    resource_timing: ?ResourceTimingSink = null,

    // Requests that are internal to the browser and skip various layers,
    // these do not need to be deferred and skip user-facing layers.
    internal: bool = false,

    // When false, the caller does not guarantee that the body outlives the
    // transfer, and thus we'll need to dupe it.
    body_outlives_request: bool = false,

    // arbitrary data that can be associated with this request
    ctx: *anyopaque = undefined,

    // Immutable operation identity used for cancellation across layers which
    // replace ctx with their own callback wrappers.  It is compared only as an
    // opaque pointer and is never dereferenced by HttpClient.
    cancellation_context: ?*anyopaque = null,

    start_callback: ?StartCallback = null,
    header_callback: HeaderCallback = Noop.headerCallback,
    data_callback: DataCallback = Noop.dataCallback,
    done_callback: DoneCallback = Noop.doneCallback,
    error_callback: ErrorCallback = Noop.errorCallback,
    shutdown_callback: ?ShutdownCallback = null,

    // Called only if Client cannot create/commit a Transfer and therefore no
    // ordinary error_callback or owner-driven shutdown_callback can run.
    // Resource loaders with a separately-owned callback arena use this to
    // close the otherwise-unobservable pre-transfer lifetime hole.  It is a
    // distinct hook because existing callers may pair makeRequest errors with
    // their own cleanup and must not receive a new shutdown callback there.
    unstarted_callback: ?ShutdownCallback = null,

    pub fn getCookieString(self: *Request, arena: Allocator) !?[:0]const u8 {
        const jar = self.cookie_jar orelse return null;
        const same_site_override = try cookieSameSiteContext(
            arena,
            self.request_origin,
            self.site_for_cookies,
            self.url,
        );
        var aw: std.Io.Writer.Allocating = .init(arena);
        try jar.forRequest(self.url, &aw.writer, .{
            .is_http = true,
            .origin_url = self.cookie_origin,
            .is_navigation = self.resource_type == .document,
            .same_site_override = same_site_override,
        });
        if (aw.written().len == 0) {
            return null;
        }
        try aw.writer.writeByte(0);
        const written = aw.written();
        return written.ptr[0 .. written.len - 1 :0];
    }

    pub fn deinit(self: *const Request) void {
        self.headers.deinit();
    }
};

pub const FulfilledResponse = struct {
    status: u16,
    url: [:0]const u8,
    headers: []const http.Header,
    body: ?[]const u8,

    pub fn contentType(self: *const FulfilledResponse) ?[]const u8 {
        for (self.headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) return hdr.value;
        }
        return null;
    }
};

pub const StableResponse = struct {
    ctx: *anyopaque,
    status: u16,
    url: [:0]const u8,
    headers: []const http.Header,
    body: ?[]const u8,

    pub fn contentType(self: *const StableResponse) ?[]const u8 {
        for (self.headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) return hdr.value;
        }
        return null;
    }
};

pub const Response = struct {
    ctx: *anyopaque,
    inner: union(enum) {
        transfer: *Transfer,
        cached: *const CachedResponse,
        fulfilled: *const FulfilledResponse,
        stable: *const StableResponse,
    },

    pub fn fromTransfer(transfer: *Transfer) Response {
        return .{ .ctx = transfer.req.ctx, .inner = .{ .transfer = transfer } };
    }

    pub fn fromCached(ctx: *anyopaque, resp: *const CachedResponse) Response {
        return .{ .ctx = ctx, .inner = .{ .cached = resp } };
    }

    pub fn fromFulfilled(ctx: *anyopaque, fulfilled: *const FulfilledResponse) Response {
        return .{ .ctx = ctx, .inner = .{ .fulfilled = fulfilled } };
    }

    pub fn fromStable(stable: *const StableResponse) Response {
        return .{ .ctx = stable.ctx, .inner = .{ .stable = stable } };
    }

    pub fn status(self: Response) ?u16 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |rh| rh.status else null,
            .cached => |c| c.metadata.status,
            .fulfilled => |f| f.status,
            .stable => |s| s.status,
        };
    }

    pub fn contentType(self: Response) ?[]const u8 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |*rh| rh.contentType() else null,
            .cached => |c| c.metadata.content_type,
            .fulfilled => |f| f.contentType(),
            .stable => |s| s.contentType(),
        };
    }

    pub fn contentLength(self: Response) ?u32 {
        return switch (self.inner) {
            .transfer => |t| t.getContentLength(),
            .cached => |c| switch (c.data) {
                .buffer => |buf| @intCast(buf.len),
            },
            .fulfilled => |f| if (f.body) |b| @intCast(b.len) else null,
            .stable => |s| if (s.body) |b| @intCast(b.len) else null,
        };
    }

    pub fn redirectCount(self: Response) ?u32 {
        return switch (self.inner) {
            .transfer => |t| if (t.res.header) |rh| rh.redirect_count else null,
            .cached, .fulfilled, .stable => 0,
        };
    }

    /// Referrer selected for the final request in a redirect chain. Frame's
    /// Document.referrer consumes this exact value, keeping it identical to
    /// the final outgoing Referer header.
    pub fn selectedReferrer(self: Response) ?[]const u8 {
        return switch (self.inner) {
            .transfer => |t| t.req.selected_referrer,
            .cached, .fulfilled, .stable => null,
        };
    }

    pub fn url(self: Response) [:0]const u8 {
        return switch (self.inner) {
            .transfer => |t| t.req.url,
            .cached => |c| c.metadata.url,
            .fulfilled => |f| f.url,
            .stable => |s| s.url,
        };
    }

    pub fn headerIterator(self: Response) HeaderIterator {
        return switch (self.inner) {
            .transfer => |t| t.responseHeaderIterator(),
            .cached => |c| HeaderIterator{ .list = .{ .list = c.metadata.headers } },
            .fulfilled => |f| HeaderIterator{ .list = .{ .list = f.headers } },
            .stable => |s| HeaderIterator{ .list = .{ .list = s.headers } },
        };
    }

    pub fn abort(self: Response, err: anyerror) void {
        switch (self.inner) {
            .transfer => |t| t.abort(err),
            .cached, .fulfilled, .stable => {},
        }
    }

    pub fn format(self: Response, writer: *std.Io.Writer) !void {
        return switch (self.inner) {
            .transfer => |t| try t.format(writer),
            .cached => |c| try c.format(writer),
            .fulfilled => |f| try writer.print("fulfilled {s}", .{f.url}),
            .stable => |s| writer.print("stable {s}", .{s.url}),
        };
    }

    pub fn toStable(self: Response, arena: std.mem.Allocator) !StableResponse {
        const new_url = try arena.dupeZ(u8, self.url());

        var headers: std.ArrayListUnmanaged(http.Header) = .{};
        var it = self.headerIterator();
        while (it.next()) |hdr| {
            try headers.append(arena, .{
                .name = try arena.dupe(u8, hdr.name),
                .value = try arena.dupe(u8, hdr.value),
            });
        }

        return .{
            .ctx = self.ctx,
            .status = self.status() orelse 0,
            .url = new_url,
            .headers = headers.items,
            .body = null,
        };
    }
};

pub const SyncResponse = struct {
    status: u16,
    body: std.ArrayList(u8),

    pub fn deinit(self: *SyncResponse, allocator: Allocator) void {
        self.body.deinit(allocator);
    }
};

pub const Transfer = struct {
    id: u32 = 0,
    arena: Allocator,

    owner: ?*Owner,
    owner_node: std.DoublyLinkedList.Node = .{},

    // Strong reference captured synchronously for a blob: request. The
    // registry entry may be revoked before Synthetic.run executes.
    blob_token: ?BlobToken = null,

    // The transfer's lifecycle position. Source of truth for
    // "is this committed?" and "can we deinit synchronously?".
    // The conn the transfer holds (if any) is tracked separately
    // in `_conn` — orthogonal to state. See `State` below.
    state: State = .created,

    // Conn the transfer currently holds. Set when makeRequest commits
    // the conn to the multi handle; cleared by the "release ASAP" step
    // inside processOneMessage, by the auth-parking path, and by deinit.
    // Lifetime is decoupled from `state` on purpose: a single transition
    // shouldn't have to thread the conn pointer, and aborts in mid-flight
    // can let `deinit` find the conn via this field instead of carrying
    // it on every state variant.
    _conn: ?*http.Connection = null,

    req: Request,
    res: Transfer.Response = .{},
    client: *Client,

    start_time: u64,

    // Monotonic, high-resolution lifecycle timestamps used by Resource
    // Timing. start_time above is the existing coarse CDP timestamp.
    timing_start_us: u64 = 0,
    request_start_us: u64 = 0,

    // Resource Timing names the fetch's initial URL. req.url is intentionally
    // mutable across redirects, so retain this independent arena-owned view.
    resource_timing_name: ?[:0]const u8 = null,

    // Fetch timing allow failed flag. Unlike Transfer.Response this survives
    // reset(): one failed redirect hop keeps the final timing entry opaque.
    _resource_timing_tao_failed: bool = false,

    // Fetch's tainted-origin flag is updated after checking each redirect
    // response. Subsequent TAO/CORS checks serialize the initiator as `null`.
    _resource_timing_origin_tainted: bool = false,

    _notified_fail: bool = false,

    // Set when conn is temporarily detached from transfer during redirect
    // reconfiguration. Used by processMessages to release the orphaned conn
    // if reconfiguration fails. Transient inside the redirect path only.
    _detached_conn: ?*http.Connection = null,

    _auth_challenge: ?http.AuthChallenge = null,

    // number of times the transfer has been tried.
    // incremented by reset func.
    _tries: u8 = 0,
    _redirect_count: u8 = 0,

    // for when a Transfer is queued in the client.queue
    _node: std.DoublyLinkedList.Node = .{},

    // for when a Transfer is queued for the next tick.
    _next_tick_node: ?NextTickNode = null,

    // Debug canary: set on the first deinit, so that if a second deinit on the
    // same instance is called, we have a double free. The memory _could_ be
    // re-used, since the lack of a failure doesn't proove there's no UAF.
    _deinited: bool = false,

    pub const State = union(enum) {
        // Pre-commit. Only valid inside the request flow (Client.request
        // or a re-entry like continueTransfer / unpark) before any commit
        // point hands the transfer to an external owner. Client.request's
        // errdefer uses `.created` to decide whether to abort.
        created,

        // On client.queue, waiting for a pooled connection. `_node` is
        // linked into client.queue.
        queued,

        // Conn (in `_conn`) is submitted to wreq. processOneMessage will
        // eventually fire callbacks for us.
        inflight,

        // processOneMessage is running user callbacks. The conn may
        // still be in `_conn` (header/data phase) or have been cleared
        // by the "release ASAP" step before done_callback fires.
        completing,

        // External owner is holding the transfer paused. The owner is
        // responsible for resuming or terminating it.
        parked: ParkedBy,

        // detachInPerform ran; user callbacks are noop'd, owner link is
        // cleared, processOneMessage / processMessages will deinit on
        // exit. `_conn` (if any) is what `deinit` releases after completion.
        aborted,
    };

    pub const ParkedBy = enum {
        // CDP Fetch interception, request phase.
        intercept_request,

        // CDP auth challenge — processOneMessage stashed the transfer
        // waiting for continueWithAuth.
        intercept_auth,
    };

    // Layer-facing: park the transfer for an external owner. The caller
    // must be holding the transfer in the request flow (state == .created).
    pub fn park(self: *Transfer, by: ParkedBy) void {
        lp.assert(self.state == .created, "Transfer.park", .{ .state = self.state });
        self.state = .{ .parked = by };
    }

    // Layer-facing: take the transfer out of .parked and return it to
    // the request flow (.created). This assumes pre-inflight handling (i.e. the
    // transfer was in .created before being parked). This is true today, but
    // could become false if Request Interception ever supports the "response"
    // requestStage (although, to support this, I think the safety of transfers
    // post-perform would need to be improved),
    pub fn unpark(self: *Transfer) void {
        lp.assert(self.state == .parked, "Transfer.unpark", .{ .state = self.state });
        self.leaveIntercept();
        self.state = .created;
    }

    // Decrement the interception counter iff this transfer is currently
    // parked for CDP interception.
    fn leaveIntercept(self: *Transfer) void {
        if (self.state != .parked) {
            return;
        }
        switch (self.state.parked) {
            .intercept_request, .intercept_auth => {
                const intercept_layer = &self.client.interception_layer;
                lp.assert(intercept_layer.intercepted > 0, "Transfer.leaveIntercept", .{ .value = intercept_layer.intercepted });
                intercept_layer.intercepted -= 1;
            },
        }
    }

    pub fn deinit(self: *Transfer) void {
        if (comptime IS_DEBUG) {
            lp.assert(self._deinited == false, "Transfer.deinit", .{ .id = self.id });
            self._deinited = true;
        }
        self.leaveIntercept();
        if (self._conn) |c| {
            self.client.removeConn(c);
            self._conn = null;
        }

        // Unlink from client.queue if we were waiting for a handle.
        // Without this, deinit'ing a queued transfer (e.g. via owner-list
        // abort during navigation) leaves a dangling _node in the queue
        // that the next tick would submit to wreq → UAF.
        if (self.state == .queued) {
            self.client.queue.remove(&self._node);
        }

        // Drop the id→*Transfer index entry before freeing the memory.
        // Any concurrent CDP lookup by id will now see this transfer as gone.
        _ = self.client.transfers.remove(self.id);

        self.client.cancelNextTick(self);

        self.req.deinit();
        if (self.blob_token) |token| {
            token.release();
            self.blob_token = null;
        }
        if (self.owner) |o| {
            o.removeTransfer(self);
        }
        // The Transfer itself lives on this arena, so this must be last —
        // `self` is invalid memory after release.
        const arena_pool = self.client.arena_pool;
        const arena = self.arena;
        arena_pool.release(arena);
    }

    // Cancel this transfer with `err`. Fires error_callback once (latched
    // via _notified_fail), then either deinits synchronously or, if we're
    // mid-event processing, detaches and lets processOneMessage deinit later.
    //
    // This is the ONE entry point external callers should use to cancel
    // a transfer. Don't reach for kill() or requestFailed() directly —
    // they're internal helpers.
    pub fn abort(self: *Transfer, err: anyerror) void {
        self.requestFailed(err, true);
        self.detachOrDeinit();
    }

    // Abort a transfer that an external owner (CDP interception) is holding in a
    // .parked state. Unlike abort(), this is re-entrancy safe so that if
    // requestFailed causes a teardown/navigate, this won't be killed again
    // Mirrors InterceptionLayer.fulfillRequest. unpark asserts the transfer is
    // actually parked.
    pub fn abortParked(self: *Transfer, err: anyerror) void {
        self.unpark();
        self.state = .completing;
        defer self.deinit();
        self.requestFailed(err, true);
    }

    // Owner-driven teardown: fires shutdown_callback (not error_callback)
    // and otherwise behaves like abort. Called by Client.abortOwner /
    // abortRequests when a Frame / WGS is being torn down.
    fn kill(self: *Transfer) void {
        if (self.req.shutdown_callback) |cb| {
            cb(self.req.ctx);
        }
        self.detachOrDeinit();
    }

    // Decide whether to tear down now or defer until processOneMessage
    // eventually drains the in-flight request.
    //
    // Two states force deferral:
    //   * `.completing` — processOneMessage is currently processing
    //     this transfer. It will call `transfer.deinit` itself after the
    //     chain returns; deiniting here would double-free. This covers
    //     both the with-conn and post-release-ASAP windows.
    //   * `.inflight` while `client.performing` — the current wreq event may
    //     still reference us. Releasing the arena now would UAF.
    //
    // Otherwise (created / queued / parked / fully drained), there is
    // nothing left referencing this transfer and we can safely deinit
    // inline.
    fn detachOrDeinit(self: *Transfer) void {
        const must_defer = switch (self.state) {
            .completing => true,
            // Connections created re-entrantly while handles.perform is active
            // sit on ready_queue with in_use=false. They have not entered the
            // backend and are safe to deinit synchronously; deferring them
            // would let perform's ready drain submit work for a retired owner.
            .inflight => self.client.performing and
                (if (self._conn) |conn| conn.in_use else false),
            else => false,
        };
        if (must_defer) {
            self.detachInPerform();
        } else {
            self.deinit();
        }
    }

    // Deferred-cleanup path when we can't synchronously deinit.
    //
    // We:
    //   - transition state to `.aborted` so processOneMessage's
    //     normal-completion paths short-circuit when they next see
    //     this transfer,
    //   - noop every user callback so draining the in-flight response cannot
    //     re-enter user code,
    //   - unlink from owner.transfers and clear `owner` so the owning
    //     Frame/WGS can be freed while this transfer is still draining.
    //     transfer.deinit (called later by processOneMessage) sees
    //     `owner == null` and skips the list-remove that would otherwise
    //     UAF against a freed list.
    fn detachInPerform(self: *Transfer) void {
        // `_conn` (if any) rides through .aborted untouched; deinit
        // releases it once the transport completion is drained.
        self.state = .aborted;
        self.req.start_callback = null;
        self.req.shutdown_callback = null;
        self.req.header_callback = Noop.headerCallback;
        self.req.data_callback = Noop.dataCallback;
        self.req.done_callback = Noop.doneCallback;
        self.req.error_callback = Noop.errorCallback;
        if (self.owner) |o| {
            o.removeTransfer(self);
            self.owner = null;
        }
    }

    // Internal failure-notification helper. Latches via _notified_fail so
    // multiple paths racing to report the same failure only fire one
    // notification. Goes through transfer.req — so layer wrappers
    // (InterceptContext, CacheContext) see the failure and can propagate
    // it up the chain.
    //
    // Not part of the external API: callers cancelling a transfer should
    // use transfer.abort(err) instead, which goes through this and also
    // handles the deinit / detach side. The internal HttpClient flow uses
    // this directly (from processOneMessage) because it's already paired
    // with the natural processMessages → transfer.deinit handoff.
    //
    // execute_callback=true → fires error_callback. false → fires
    // shutdown_callback (used by Frame shutdown / WGS teardown).
    fn requestFailed(self: *Transfer, err: anyerror, comptime execute_callback: bool) void {
        if (self._notified_fail) return;
        self._notified_fail = true;

        if (execute_callback) {
            self.req.error_callback(self.req.ctx, err);
        } else if (self.req.shutdown_callback) |cb| {
            cb(self.req.ctx);
        }
    }

    fn configureConn(self: *Transfer, conn: *http.Connection) anyerror!void {
        const client = self.client;
        const req = &self.req;

        // Set callbacks and per-client settings on the pooled connection.
        try conn.setWriteCallback(Transfer.dataCallback);
        try conn.setFollowLocation(false);
        try conn.setProxy(client.http_proxy);
        try conn.setTlsVerify(client.tls_verify, client.use_proxy);

        try conn.setURL(req.url);
        try conn.setMethod(req.method);
        if (req.body) |b| {
            try conn.setBody(b);
        } else {
            try conn.setGetMode();
        }

        var header_list = req.headers;
        try conn.secretHeaders(&header_list, &client.network.config.http_headers);
        try conn.setHeaders(&header_list);

        // Add cookies from cookie jar.
        if (try self.req.getCookieString(self.arena)) |cookies| {
            try conn.setCookies(@ptrCast(cookies.ptr));
        }

        conn.transport = .{ .http = self };

        // Per-request timeout override (e.g. XHR timeout)
        if (req.timeout_ms > 0) {
            try conn.setTimeout(req.timeout_ms);
        }

        // add credentials
        if (req.credentials) |creds| {
            if (self._auth_challenge != null and self._auth_challenge.?.source == .proxy) {
                try conn.setProxyCredentials(creds);
            } else {
                try conn.setCredentials(creds);
            }
        }
    }

    pub fn reset(self: *Transfer) void {
        // Note: do NOT reset _auth_challenge or _redirect_count here. They
        // span retries — _auth_challenge tells makeRequest whether to use
        // setProxyCredentials vs setCredentials; _redirect_count caps the
        // total hops. The rest of the response state is per-attempt.
        self._notified_fail = false;
        self._tries += 1;
        self.res.stream_buffer.clearRetainingCapacity();
        self.res = .{ .stream_buffer = self.res.stream_buffer };
    }

    pub fn noteRequestStart(self: *Transfer) void {
        self.request_start_us = monotonicMicroseconds();
    }

    /// Called directly from the wreq HEADERS event, before body delivery.
    /// The protocol mapping follows Resource Timing's nextHopProtocol values.
    pub fn noteResponseStart(self: *Transfer, http_version: u32) void {
        if (self.res.response_start_us == 0) {
            self.res.response_start_us = monotonicMicroseconds();
        }
        if (http_version != 0) {
            self.res.next_hop_protocol = switch (http_version) {
                9 => "http/0.9",
                10 => "http/1.0",
                11 => "http/1.1",
                20 => "h2",
                30 => "h3",
                else => "",
            };
        }
    }

    pub fn noteResponseEnd(self: *Transfer) void {
        if (self.res.response_end_us == 0) {
            self.res.response_end_us = monotonicMicroseconds();
        }
    }

    /// Final body byte counts emitted by the Windows wreq backend. The
    /// encoded count is observed below transparent decompression; the decoded
    /// count is the byte stream delivered to the browser callbacks.
    pub fn noteBodySizes(
        self: *Transfer,
        encoded_body_size: u64,
        decoded_body_size: u64,
    ) void {
        self.res.encoded_body_size = encoded_body_size;
        self.res.decoded_body_size = decoded_body_size;
    }

    /// Header-only status view for privacy-minimized lifecycle diagnostics.
    /// Callers cannot reach response headers or body storage through this API.
    pub fn responseStatus(self: *const Transfer) ?u16 {
        return if (self.res.header) |head| head.status else null;
    }

    fn resourceTimingOrigin(self: *Transfer) RequestOrigin {
        return resolvedResourceTimingOrigin(
            self.arena,
            self.req.request_origin,
            self.req.cookie_origin,
        ) catch .none;
    }

    fn resourceTimingResponseIsSameOrigin(
        self: *Transfer,
        request_origin: RequestOrigin,
    ) bool {
        if (self._resource_timing_origin_tainted) return false;
        return requestOriginIsSameOrigin(
            self.arena,
            request_origin,
            self.req.url,
        ) catch false;
    }

    fn resourceTimingHeaderOrigin(
        self: *const Transfer,
        request_origin: RequestOrigin,
    ) RequestOrigin {
        return if (self._resource_timing_origin_tainted) .@"opaque" else request_origin;
    }

    fn responsePassesTimingAllowOrigin(
        self: *Transfer,
        conn: *const http.Connection,
        request_origin: RequestOrigin,
    ) bool {
        const serialized_origin = serializedRequestOrigin(request_origin);
        const combined_optional = combinedResponseHeaderValue(
            self.arena,
            conn,
            "timing-allow-origin",
        ) catch return false;
        const combined = combined_optional orelse return false;
        return timingAllowOriginHeaderPasses(combined, serialized_origin);
    }

    fn noteResourceTimingRedirectHop(
        self: *Transfer,
        conn: *const http.Connection,
    ) void {
        if (self.req.resource_timing == null or self._resource_timing_tao_failed) return;
        const request_origin = self.resourceTimingOrigin();
        const header_origin = self.resourceTimingHeaderOrigin(request_origin);
        self._resource_timing_tao_failed = timingAllowFailedAfterHop(
            false,
            self.resourceTimingResponseIsSameOrigin(request_origin),
            self.responsePassesTimingAllowOrigin(conn, header_origin),
        );
    }

    fn updateResourceTimingTaintForRedirect(self: *Transfer, new_url: [:0]const u8) void {
        if (self.req.resource_timing == null or self._resource_timing_origin_tainted) return;
        const request_origin = self.resourceTimingOrigin();
        self._resource_timing_origin_tainted = resourceTimingRedirectTaintsOrigin(
            self.arena,
            request_origin,
            self.req.url,
            new_url,
        ) catch true;
    }

    fn requestUsesCorsMode(self: *const Transfer) bool {
        var iterator = self.req.headers.iterator();
        while (iterator.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "sec-fetch-mode")) continue;
            return std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, " \t"), "cors");
        }
        return false;
    }

    fn responseDetailsAllowed(
        self: *const Transfer,
        conn: *const http.Connection,
        request_origin: RequestOrigin,
        response_same_origin: bool,
    ) bool {
        const allow_origin = conn.getResponseHeader("access-control-allow-origin", 0);
        const allow_credentials = conn.getResponseHeader("access-control-allow-credentials", 0);
        return resourceTimingResponseDetailsAllowed(
            response_same_origin,
            self.requestUsesCorsMode(),
            // Resource requests which persist a cookie jar are credentialed.
            // ScriptManager has not yet retained anonymous/use-credentials as
            // a Request field, so its legacy always-non-null jar is treated
            // conservatively as credentialed rather than overexposing details.
            self.req.cookie_jar != null,
            if (allow_origin) |value| value.value else null,
            if (allow_origin) |value| value.amount else 0,
            if (allow_credentials) |value| value.value else null,
            if (allow_credentials) |value| value.amount else 0,
            serializedRequestOrigin(request_origin),
        );
    }

    fn responseContentEncoding(conn: *const http.Connection) []const u8 {
        const header = conn.getResponseHeader("content-encoding", 0) orelse
            return filteredHttpContentEncoding(null, 0);
        return filteredHttpContentEncoding(header.value, header.amount);
    }

    fn resourceTimingName(self: *const Transfer) [:0]const u8 {
        return self.resource_timing_name orelse self.req.url;
    }

    fn reportResourceTiming(self: *Transfer) void {
        const sink = self.req.resource_timing orelse return;
        const status = if (self.res.header) |head| head.status else return;

        const conn = self._conn orelse return;
        const request_origin = self.resourceTimingOrigin();
        const header_origin = self.resourceTimingHeaderOrigin(request_origin);
        const response_same_origin = self.resourceTimingResponseIsSameOrigin(request_origin);
        const allow_timing_details = !self._resource_timing_tao_failed and
            (response_same_origin or self.responsePassesTimingAllowOrigin(conn, header_origin));
        const allow_response_details = self.responseDetailsAllowed(
            conn,
            header_origin,
            response_same_origin,
        );

        // Chrome 149 does not expose literal response-header bytes here. Blink
        // applies a fixed 300-byte header cost to a network response, while
        // encodedBodySize is the body before content decoding and
        // decodedBodySize is the delivered representation. wreq ABI v4 gives
        // us both exact counters.
        // TODO: CacheLayer must distinguish fresh-cache (transferSize=0) from
        // validated-cache (transferSize=300) without inventing network bytes.
        const decoded_body_size: u64 = self.res.decoded_body_size orelse self.res.bytes_received;
        const encoded_body_size: u64 = self.res.encoded_body_size orelse
            if (self.getContentLength()) |content_length|
                @as(u64, content_length)
            else
                decoded_body_size;
        const exposed_encoded_body_size = if (allow_timing_details) encoded_body_size else 0;
        const exposed_decoded_body_size = if (allow_timing_details) decoded_body_size else 0;
        const content_type = if (allow_response_details) blk: {
            const raw_optional = combinedResponseHeaderValue(
                self.arena,
                conn,
                "content-type",
            ) catch break :blk "";
            const raw = raw_optional orelse break :blk "";
            break :blk minimizedResourceTimingContentType(self.arena, raw) catch "";
        } else "";
        const content_encoding = if (allow_response_details) responseContentEncoding(conn) else "";
        sink.record(sink.context, sink.execution_context, sink.initiator, .{
            .name = self.resourceTimingName(),
            .start_time_us = self.timing_start_us,
            .request_start_us = self.request_start_us,
            .response_start_us = self.res.response_start_us,
            .response_end_us = self.res.response_end_us,
            .next_hop_protocol = if (allow_timing_details) self.res.next_hop_protocol else "",
            .transfer_size = if (allow_timing_details) encoded_body_size +| 300 else 0,
            .encoded_body_size = exposed_encoded_body_size,
            .decoded_body_size = exposed_decoded_body_size,
            .response_status = if (allow_response_details) status else 0,
            .content_type = content_type,
            .content_encoding = content_encoding,
        }) catch |err| {
            // Performance bookkeeping must never turn a successful network
            // request into a failed fetch/navigation.
            log.warn(.http, "resource timing sink", .{ .err = err, .url = self.req.url });
        };
    }

    fn buildResponseHeader(self: *Transfer, conn: *const http.Connection) !void {
        if (comptime IS_DEBUG) {
            std.debug.assert(self.res.header == null);
        }

        const url = try conn.getEffectiveUrl();

        const status: u16 = if (self._auth_challenge != null)
            407
        else
            try conn.getResponseCode();

        self.res.header = .{
            .url = url,
            .status = status,
            .redirect_count = self._redirect_count,
        };

        if (conn.getResponseHeader("content-type", 0)) |ct| {
            var hdr = &self.res.header.?;
            const value = ct.value;
            const len = @min(value.len, ResponseHead.MAX_CONTENT_TYPE_LEN);
            hdr._content_type_len = len;
            @memcpy(hdr._content_type[0..len], value[0..len]);
        }
    }

    pub fn format(self: *Transfer, writer: *std.Io.Writer) !void {
        const req = self.req;
        return writer.print("{s} {s}", .{ @tagName(req.method), req.url });
    }

    // `url` must have transfer-arena lifetime: it's stored as-is, not duped.
    pub fn updateURL(self: *Transfer, url: [:0]const u8) !void {
        self.req.url = url;
    }

    fn handleRedirect(transfer: *Transfer, location: []const u8) !void {
        const req = &transfer.req;
        const conn = transfer._conn.?;

        // retrieve cookies from the redirect's response.
        if (req.cookie_jar) |jar| {
            var i: usize = 0;
            while (conn.getResponseHeader("set-cookie", i)) |ct| : (i += 1) {
                try jar.populateFromResponse(transfer.req.url, ct.value);

                if (i >= ct.amount) {
                    break;
                }
            }
        }

        // HTTP-redirect fetch adopts the last valid policy token from the
        // redirect response before selecting the next hop's referrer.
        var policy_index: usize = 0;
        while (conn.getResponseHeader("referrer-policy", policy_index)) |header| {
            if (referrerPolicyFromHeader(header.value)) |policy| {
                req.referrer_policy = policy;
            }
            policy_index += 1;
            if (policy_index >= header.amount) break;
        }

        // base_url and location are borrowed; applyRedirectTarget resolves a
        // fresh arena-owned copy that gets stored in transfer.req.url.
        const base_url = try conn.getEffectiveUrl();
        const status = try conn.getResponseCode();
        try transfer.applyRedirectTarget(std.mem.span(base_url), location, status);
    }

    // Called above (in handleRedirect) and by a CDP fulfill request which redirects
    pub fn applyRedirectTarget(transfer: *Transfer, base: [:0]const u8, location: []const u8, status: u16) !void {
        const req = &transfer.req;
        const arena = transfer.arena;

        transfer._redirect_count += 1;
        if (transfer._redirect_count > transfer.client.network.config.httpMaxRedirects()) {
            return error.TooManyRedirects;
        }

        // resolve the redirect target.
        const url: [:0]const u8 = blk: {
            if (location.len == 0) {
                // Might seem silly, but URL.resovle will return location as-is
                // if empty, and location is borrowed from response storage.
                break :blk "";
            }

            const resolved = try URL.resolve(arena, base, location, .{});

            // RFC 7231 §7.1.2: if the Location value has no fragment, the redirect
            // inherits the fragment from the URI used to generate the request.
            // URL.resolve follows RFC 3986 §5.3, which drops the base fragment when
            // the relative ref has none, so we re-attach it here.
            if (URL.getHash(resolved).len == 0) {
                const original_hash = URL.getHash(transfer.req.url);
                if (original_hash.len != 0) {
                    break :blk try std.mem.joinZ(arena, "", &.{ resolved, original_hash });
                }
            }
            break :blk resolved;
        };

        transfer.updateResourceTimingTaintForRedirect(url);
        try transfer.updateURL(url);
        try transfer.updateReferrerForRedirect(url);
        // 301, 302, 303 → change to GET, drop body.
        // 307, 308 → keep method and body.
        if (status == 301 or status == 302 or status == 303) {
            req.method = .GET;
            req.body = null;
        }
    }

    fn updateReferrerForRedirect(self: *Transfer, target_url: [:0]const u8) !void {
        const req = &self.req;
        if (!req.referrer_managed) return;

        const target_origin = try URL.getOrigin(self.arena, target_url);
        const selected = try requestReferrerWithPolicy(
            self.arena,
            req.selected_referrer,
            target_url,
            target_origin,
            req.referrer_policy,
        );
        req.selected_referrer = selected;

        if (selected) |value| {
            const header = try std.fmt.allocPrintSentinel(self.arena, "Referer: {s}", .{value}, 0);
            try req.headers.set(header);
        } else {
            try removeHeader(&req.headers, self.arena, "Referer");
        }
    }

    fn detectAuthChallenge(transfer: *Transfer, conn: *const http.Connection) void {
        const status = conn.getResponseCode() catch return;
        const connect_status = conn.getConnectCode() catch return;

        if (status != 401 and status != 407 and connect_status != 401 and connect_status != 407) {
            transfer._auth_challenge = null;
            return;
        }

        if (conn.getResponseHeader("WWW-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .server, hdr.value) catch null;
        } else if (conn.getConnectHeader("WWW-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .server, hdr.value) catch null;
        } else if (conn.getResponseHeader("Proxy-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .proxy, hdr.value) catch null;
        } else if (conn.getConnectHeader("Proxy-Authenticate", 0)) |hdr| {
            transfer._auth_challenge = http.AuthChallenge.parse(status, .proxy, hdr.value) catch null;
        } else {
            transfer._auth_challenge = .{ .status = status, .source = null, .scheme = null, .realm = null };
        }
    }

    pub fn updateCredentials(self: *Transfer, userpwd: [:0]const u8) void {
        self.req.credentials = userpwd;
    }

    pub fn replaceRequestHeaders(self: *Transfer, allocator: Allocator, headers: []const http.Header) !void {
        self.req.headers.deinit();

        var buf: std.ArrayList(u8) = .empty;
        var new_headers = try self.client.newHeaders();
        for (headers) |hdr| {
            // Safe to re-use this buffer because Headers.add copies its value.
            defer buf.clearRetainingCapacity();
            try std.fmt.format(buf.writer(allocator), "{s}: {s}", .{ hdr.name, hdr.value });
            try buf.append(allocator, 0); // null terminated
            try new_headers.add(buf.items[0 .. buf.items.len - 1 :0]);
        }
        self.req.headers = new_headers;
    }

    // abortAuthChallenge is called when an auth challenge interception is
    // abort. We don't call self.releaseConn here b/c it has been done
    // before interception process.
    pub fn abortAuthChallenge(self: *Transfer) void {
        if (comptime IS_DEBUG) {
            log.debug(.http, "abort auth transfer", .{ .intercepted = self.client.interception_layer.intercepted });
        }

        // The transfer is still .parked(.intercept_auth)
        self.abortParked(error.AbortAuthChallenge);
    }

    // headerDoneCallback is called once the headers have been read.
    // It can be called either on dataCallback or once the request for those
    // w/o body.
    fn headerDoneCallback(transfer: *Transfer, conn: *const http.Connection) !HeaderResult {
        lp.assert(transfer.res.header_done_called == false, "Transfer.headerDoneCallback", .{});
        defer transfer.res.header_done_called = true;

        // wreq already stamped this at HEADERS. This is the fallback for a
        // backend that exposes response headers only at callback time.
        transfer.noteResponseStart(0);

        try transfer.buildResponseHeader(conn);

        if (transfer.req.cookie_jar) |jar| {
            var i: usize = 0;
            while (true) {
                const ct = conn.getResponseHeader("set-cookie", i);
                if (ct == null) break;
                jar.populateFromResponse(transfer.req.url, ct.?.value) catch |err| {
                    log.err(.http, "set cookie", .{ .err = err, .req = transfer });
                    return err;
                };
                i += 1;
                if (i >= ct.?.amount) break;
            }
        }

        if (transfer.getContentLength()) |cl| {
            if (cl > transfer.client.max_response_size) {
                return error.ResponseTooLarge;
            }
        }

        const result = transfer.req.header_callback(Client.Response.fromTransfer(transfer)) catch |err| {
            log.err(.http, "header_callback", .{ .err = err, .req = transfer });
            return err;
        };

        if (result == .proceed and transfer.state == .aborted) return .abort;
        return result;
    }

    fn dataCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) callconv(.c) usize {
        // wreq emits one contiguous chunk per DATA event.
        if (comptime IS_DEBUG) {
            std.debug.assert(chunk_count == 1);
        }

        const conn: *http.Connection = @ptrCast(@alignCast(data));
        var transfer = conn.transport.http;
        const res = &transfer.res;

        if (!res.first_data_received) {
            res.first_data_received = true;

            // Skip body for responses that will be retried (redirects, auth challenges).
            const status = conn.getResponseCode() catch |err| {
                log.err(.http, "getResponseCode", .{ .err = err, .source = "body callback" });
                return http.writefunc_error;
            };
            // Only skip the body when the response will actually be retried
            // as a redirect (a redirect status with a Location header). Any
            // other 3xx is a final response whose body must be kept.
            if (isRedirectStatus(status) and conn.getResponseHeader("location", 0) != null) {
                res.skip_body = true;
                return @intCast(chunk_len);
            }

            // Pre-size buffer from Content-Length.
            if (transfer.getContentLength()) |cl| {
                if (cl > transfer.client.max_response_size) {
                    res.callback_error = error.ResponseTooLarge;
                    return http.writefunc_error;
                }
                res.stream_buffer.ensureTotalCapacity(transfer.arena, cl) catch {};
            }
        }

        if (res.skip_body) return @intCast(chunk_len);

        res.bytes_received += chunk_len;
        if (res.bytes_received > transfer.client.max_response_size) {
            res.callback_error = error.ResponseTooLarge;
            return http.writefunc_error;
        }

        const chunk = buffer[0..chunk_len];
        res.stream_buffer.appendSlice(transfer.arena, chunk) catch |err| {
            res.callback_error = err;
            return http.writefunc_error;
        };

        if (transfer.state == .aborted) {
            return http.writefunc_error;
        }

        return @intCast(chunk_len);
    }

    pub fn responseHeaderIterator(self: *Transfer) HeaderIterator {
        // Injected responses are handled by InterceptionLayer.
        const c = self._conn;
        lp.assert(c != null, "Transfer.responseHeaderIterator", .{ .value = c != null });
        return .{ .response = .{ .conn = c.? } };
    }

    // This function should be called during the dataCallback. Calling it after
    // such as in the doneCallback is guaranteed to return null.
    pub fn getContentLength(self: *const Transfer) ?u32 {
        const cl = self.getContentLengthRawValue() orelse return null;
        return std.fmt.parseInt(u32, cl, 10) catch null;
    }

    fn getContentLengthRawValue(self: *const Transfer) ?[]const u8 {
        if (self._conn) |c| {
            // If we have a connection, than this is a normal request. We can get the
            // header value from the connection.
            const cl = c.getResponseHeader("content-length", 0) orelse return null;
            return cl.value;
        }

        // If we have no handle, then maybe this is being called after the
        // doneCallback. OR, maybe this is a "fulfilled" request. Let's check
        // the injected headers (if we have any).

        const rh = self.res.header orelse return null;
        for (rh._injected_headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-length")) {
                return hdr.value;
            }
        }

        return null;
    }

    // Response-state owned by this transfer's currently-in-flight response.
    // Reset on every retry (auth retry, redirect) via Transfer.reset — only
    // the cross-retry counters (_auth_challenge, _redirect_count) live on
    // Transfer itself. `Transfer.Response` is the on-Transfer storage; the
    // top-level `Client.Response` is the actual Response (which is a union, e.g.
    // for a cached response)
    const Response = struct {
        header: ?ResponseHead = null,

        // Decoded response body bytes delivered by the transport callback.
        bytes_received: usize = 0,

        // Exact wreq counters. Optional so synthetic responses can omit wire
        // metadata without inventing it.
        encoded_body_size: ?u64 = null,
        decoded_body_size: ?u64 = null,

        response_start_us: u64 = 0,
        response_end_us: u64 = 0,
        next_hop_protocol: []const u8 = "",

        // track if the header callbacks done have been called.
        header_done_called: bool = false,

        skip_body: bool = false,
        first_data_received: bool = false,

        // Buffered response body. Filled by dataCallback, consumed in processMessages.
        stream_buffer: std.ArrayList(u8) = .{},

        // Error captured in dataCallback to be reported in processMessages.
        callback_error: ?anyerror = null,
    };
};

pub fn continueTransfer(self: *Client, transfer: *Transfer) !void {
    if (comptime IS_DEBUG) {
        log.debug(.http, "continue transfer", .{ .intercepted = self.interception_layer.intercepted });
    }

    transfer.unpark();
    self.process(transfer) catch |err| {
        if (transfer.state == .created) {
            transfer.abort(err);
        }
        return err;
    };
}

const Noop = struct {
    fn headerCallback(_: Response) !HeaderResult {
        return .proceed;
    }
    fn dataCallback(_: Response, _: []const u8) !void {}
    fn doneCallback(_: *anyopaque) !void {}
    fn errorCallback(_: *anyopaque, _: anyerror) void {}
};

// An opaque-from-the-outside handle that Frame / WorkerGlobalScope embed
// to track the HTTP transfers + WebSockets they own.
pub const Owner = struct {
    accepting_requests: bool = true,
    transfers: std.DoublyLinkedList = .{},
    websockets: std.DoublyLinkedList = .{},

    // The owning Page/agent-cluster's blob: URL registry.
    blob_urls: ?*Blob.URLRegistry = null,
    blob_releaser: ?BlobReleaser = null,

    const WebSocket = @import("webapi/net/WebSocket.zig");
    const Blob = @import("webapi/Blob.zig");

    pub fn addTransfer(self: *Owner, t: *Transfer) void {
        self.transfers.append(&t.owner_node);
    }

    pub fn removeTransfer(self: *Owner, t: *Transfer) void {
        self.transfers.remove(&t.owner_node);
    }

    pub fn addWS(self: *Owner, ws: *WebSocket) void {
        self.websockets.append(&ws._owner_node);
    }

    pub fn removeWS(self: *Owner, ws: *WebSocket) void {
        self.websockets.remove(&ws._owner_node);
    }
};

// HttpClient deliberately does not own or import Page. Frame and
// WorkerGlobalScope provide this opaque release hook so a Transfer can retain
// the immutable Blob behind a resolved blob: URL without copying its body.
pub const BlobReleaser = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, blob: *anyopaque) void,
};

const BlobToken = struct {
    blob: *anyopaque,
    body: []const u8,
    content_type: []const u8,
    releaser: BlobReleaser,

    fn release(self: BlobToken) void {
        self.releaser.run(self.releaser.ctx, self.blob);
    }
};

const testing = @import("../testing.zig");

test "HttpClient: request context classifies same-origin, same-site and cross-site" {
    const Case = struct {
        initiator: ?[:0]const u8,
        target: [:0]const u8,
        expected: HeaderRequestContext.Site,
    };
    const cases = [_]Case{
        .{ .initiator = null, .target = "https://app.example/a", .expected = .none },
        .{ .initiator = "https://app.example/a", .target = "https://app.example/b", .expected = .same_origin },
        .{ .initiator = "https://a.example.test/a", .target = "https://b.example.test/b", .expected = .same_site },
        .{ .initiator = "https://app.example:443/a", .target = "https://app.example:8443/b", .expected = .same_site },
        .{ .initiator = "https://app.example/a", .target = "http://app.example/b", .expected = .cross_site },
        .{ .initiator = "https://app.example/a", .target = "https://other.test/b", .expected = .cross_site },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const target_origin = try URL.getOrigin(allocator, case.target);
        const request_origin: RequestOrigin = if (case.initiator) |url|
            if (try URL.getOrigin(allocator, url)) |origin| .{ .tuple = origin } else .@"opaque"
        else
            .none;
        try testing.expectEqual(
            case.expected,
            try requestOriginSite(allocator, request_origin, case.target, target_origin),
        );
    }
}

test "HttpClient: explicit request origin distinguishes none, tuple, and opaque" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const same: [:0]const u8 = "https://app.example.test/path";
    const same_site: [:0]const u8 = "https://cdn.example.test/asset";
    const cross_site: [:0]const u8 = "https://other.test/asset";
    const same_origin = try URL.getOrigin(allocator, same);
    const same_site_origin = try URL.getOrigin(allocator, same_site);
    const cross_site_origin = try URL.getOrigin(allocator, cross_site);
    const tuple: RequestOrigin = .{ .tuple = "https://app.example.test" };

    try testing.expectEqual(.none, try requestOriginSite(allocator, .none, same, same_origin));
    try testing.expectEqual(.cross_site, try requestOriginSite(allocator, .@"opaque", same, same_origin));
    try testing.expectEqual(.same_origin, try requestOriginSite(allocator, tuple, same, same_origin));
    try testing.expectEqual(.same_site, try requestOriginSite(allocator, tuple, same_site, same_site_origin));
    try testing.expectEqual(.cross_site, try requestOriginSite(allocator, tuple, cross_site, cross_site_origin));
    try testing.expect(try requestOriginIsSameOrigin(allocator, tuple, same));
    try testing.expect(!(try requestOriginIsSameOrigin(allocator, .@"opaque", same)));
}

test "HttpClient: Resource Timing TAO matches Chromium HTTP list semantics" {
    const origin = "https://app.example.test";

    try testing.expect(timingAllowOriginHeaderPasses("*", origin));
    try testing.expect(timingAllowOriginHeaderPasses(
        "https://other.test, https://app.example.test",
        origin,
    ));
    try testing.expect(timingAllowOriginHeaderPasses(
        "https://other.test, *",
        origin,
    ));
    try testing.expect(!timingAllowOriginHeaderPasses("https://other.test", origin));
    try testing.expect(!timingAllowOriginHeaderPasses("*", null));
    try testing.expect(timingAllowOriginHeaderPasses("null", "null"));
    // net::HttpUtil::ValuesIterator protects commas inside quotes but retains
    // the quote bytes, so the raw member cannot equal a serialized origin.
    try testing.expect(!timingAllowOriginHeaderPasses(
        "\"https://app.example.test\", https://other.test",
        origin,
    ));
}

test "HttpClient: Resource Timing TAO combines physical fields before parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const origin = "https://app.example.test";

    const ordinary = try combineHttpHeaderValues(arena.allocator(), &.{
        "https://other.test",
        origin,
    });
    try testing.expectString("https://other.test, https://app.example.test", ordinary);
    try testing.expect(timingAllowOriginHeaderPasses(ordinary, origin));

    // The quote begins in field one and ends in field two. Independent field
    // parsing would incorrectly accept the second physical value.
    const quoted_across_fields = try combineHttpHeaderValues(arena.allocator(), &.{
        "\"https://other.test",
        "https://app.example.test\"",
    });
    try testing.expectString(
        "\"https://other.test, https://app.example.test\"",
        quoted_across_fields,
    );
    try testing.expect(!timingAllowOriginHeaderPasses(quoted_across_fields, origin));
}

test "HttpClient: Resource Timing redirect TAO failure is sticky" {
    var failed = false;
    failed = timingAllowFailedAfterHop(failed, true, false);
    try testing.expect(!failed);

    failed = timingAllowFailedAfterHop(failed, false, true);
    try testing.expect(!failed);

    failed = timingAllowFailedAfterHop(failed, false, false);
    try testing.expect(failed);

    // A later same-origin or wildcard-enabled response cannot clear the flag.
    failed = timingAllowFailedAfterHop(failed, true, true);
    try testing.expect(failed);
}

test "HttpClient: Resource Timing redirects taint subsequent origin checks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const initiator: RequestOrigin = .{ .tuple = "https://a.example.test" };

    // The first A -> B redirect does not taint because the current response is
    // still same-origin with the initiator.
    try testing.expect(!try resourceTimingRedirectTaintsOrigin(
        allocator,
        initiator,
        "https://a.example.test/start",
        "https://b.example.test/next",
    ));
    // Once current URL is B, staying on B does not taint, but B -> A/C does.
    try testing.expect(!try resourceTimingRedirectTaintsOrigin(
        allocator,
        initiator,
        "https://b.example.test/next",
        "https://b.example.test/final",
    ));
    try testing.expect(try resourceTimingRedirectTaintsOrigin(
        allocator,
        initiator,
        "https://b.example.test/next",
        "https://a.example.test/final",
    ));
    try testing.expect(try resourceTimingRedirectTaintsOrigin(
        allocator,
        initiator,
        "https://b.example.test/next",
        "https://c.example.test/final",
    ));
    try testing.expect(try resourceTimingRedirectTaintsOrigin(
        allocator,
        .@"opaque",
        "https://b.example.test/next",
        "https://c.example.test/final",
    ));
    try testing.expect(!try resourceTimingRedirectTaintsOrigin(
        allocator,
        .none,
        "https://b.example.test/next",
        "https://c.example.test/final",
    ));
}

test "HttpClient: Resource Timing name remains the initial URL after redirect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var transfer: Transfer = .{
        .arena = arena.allocator(),
        .owner = null,
        .req = .{
            .frame_id = 1,
            .loader_id = 1,
            .method = .GET,
            .url = "https://app.example.test/initial",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "https://app.example.test/",
            .resource_type = .script,
            .notification = undefined,
        },
        .client = undefined,
        .start_time = 0,
        .resource_timing_name = "https://app.example.test/initial",
    };
    defer transfer.req.deinit();

    try transfer.updateURL("https://cdn.example.test/final");
    try testing.expectString("https://cdn.example.test/final", transfer.req.url);
    try testing.expectString(
        "https://app.example.test/initial",
        transfer.resourceTimingName(),
    );
}

test "HttpClient: Resource Timing filters content encoding like Chromium 149" {
    try testing.expectString("", filteredHttpContentEncoding(null, 0));
    try testing.expectString("", filteredHttpContentEncoding("", 1));
    try testing.expectString("gzip", filteredHttpContentEncoding("GZip", 1));
    try testing.expectString("br", filteredHttpContentEncoding("br", 1));
    try testing.expectString("dcb", filteredHttpContentEncoding("DCB", 1));
    try testing.expectString("dcz", filteredHttpContentEncoding("dcz", 1));
    try testing.expectString("deflate", filteredHttpContentEncoding("Deflate", 1));
    try testing.expectString("zstd", filteredHttpContentEncoding("ZSTD", 1));
    try testing.expectString("multiple", filteredHttpContentEncoding("gzip, br", 1));
    try testing.expectString("multiple", filteredHttpContentEncoding("gzip", 2));
    try testing.expectString("@unknown", filteredHttpContentEncoding("identity", 1));
    try testing.expectString("@unknown", filteredHttpContentEncoding("x-custom", 1));
}

test "HttpClient: Resource Timing minimizes Content-Type like Chromium 149" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectString("text/javascript", try minimizedResourceTimingContentType(
        allocator,
        "Application/JavaScript; Charset=UTF-8",
    ));
    try testing.expectString("application/json", try minimizedResourceTimingContentType(
        allocator,
        "application/problem+JSON; charset=utf-8",
    ));
    try testing.expectString("application/json", try minimizedResourceTimingContentType(
        allocator,
        "TEXT/JSON",
    ));
    try testing.expectString("image/svg+xml", try minimizedResourceTimingContentType(
        allocator,
        "IMAGE/SVG+XML; charset=utf-8",
    ));
    try testing.expectString("application/xml", try minimizedResourceTimingContentType(
        allocator,
        "Application/RSS+XML; charset=UTF-8",
    ));
    try testing.expectString("image/png", try minimizedResourceTimingContentType(
        allocator,
        "IMAGE/PNG; name=logo.png",
    ));
    try testing.expectString("application/json", try minimizedResourceTimingContentType(
        allocator,
        "text/html, text/json; charset=utf-8",
    ));
    try testing.expectString("", try minimizedResourceTimingContentType(
        allocator,
        "application/x-not-supported; version=1",
    ));
}

test "HttpClient: Resource Timing response detail origin matching is not a list" {
    const origin = "https://app.example.test";
    try testing.expect(accessControlAllowOriginPasses("*", origin, false));
    try testing.expect(!accessControlAllowOriginPasses("*", origin, true));
    try testing.expect(accessControlAllowOriginPasses(
        " https://app.example.test\t",
        origin,
        true,
    ));
    try testing.expect(!accessControlAllowOriginPasses(
        "https://app.example.test, https://other.test",
        origin,
        false,
    ));
    try testing.expect(!accessControlAllowOriginPasses("*", null, false));

    try testing.expect(resourceTimingResponseDetailsAllowed(
        true,
        false,
        false,
        null,
        0,
        null,
        0,
        origin,
    ));
    try testing.expect(!resourceTimingResponseDetailsAllowed(
        false,
        false,
        false,
        "*",
        1,
        null,
        0,
        origin,
    ));
    try testing.expect(resourceTimingResponseDetailsAllowed(
        false,
        true,
        false,
        "https://app.example.test",
        1,
        null,
        0,
        origin,
    ));
    try testing.expect(!resourceTimingResponseDetailsAllowed(
        false,
        true,
        false,
        "https://app.example.test",
        2,
        null,
        0,
        origin,
    ));
    try testing.expect(!resourceTimingResponseDetailsAllowed(
        false,
        true,
        true,
        "*",
        1,
        "true",
        1,
        origin,
    ));
    try testing.expect(!resourceTimingResponseDetailsAllowed(
        false,
        true,
        true,
        "https://app.example.test",
        1,
        null,
        0,
        origin,
    ));
    try testing.expect(resourceTimingResponseDetailsAllowed(
        false,
        true,
        true,
        "https://app.example.test",
        1,
        "true",
        1,
        origin,
    ));
    try testing.expect(!resourceTimingResponseDetailsAllowed(
        false,
        true,
        true,
        "https://app.example.test",
        1,
        "True",
        1,
        origin,
    ));
}

test "HttpClient: Resource Timing resolves legacy initiator without granting local schemes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tuple = try resolvedResourceTimingOrigin(
        arena.allocator(),
        .legacy_derive_from_initiator_url,
        "https://app.example.test/page",
    );
    try testing.expectString("https://app.example.test", tuple.tuple);

    const opaque_origin = try resolvedResourceTimingOrigin(
        arena.allocator(),
        .legacy_derive_from_initiator_url,
        "data:text/html,opaque",
    );
    try testing.expect(std.meta.activeTag(opaque_origin) == .@"opaque");
}

test "HttpClient: document.domain access key does not replace network origin" {
    const origin = requestOriginFromRelaxableSecurityKey(
        "!https://example.test",
        "https://sub.example.test:8443",
    );
    try testing.expectString("https://sub.example.test:8443", origin.tuple);
    try testing.expect(std.meta.activeTag(requestOriginFromSecurityKey("!https://example.test")) == .@"opaque");
    // A sandboxed creator can retain an HTTP URL tuple in Frame.origin while
    // its effective SecurityOrigin key is opaque; the URL tuple must not grant
    // its Worker network authority.
    try testing.expect(std.meta.activeTag(requestOriginFromRelaxableSecurityKey(
        "opaque-origin-uuid",
        "https://url-tuple.example",
    )) == .@"opaque");
}

test "HttpClient: explicit Worker cookie context combines site and initiator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const creator: RequestOrigin = .{ .tuple = "http://127.0.0.1:8100" };
    const inherited_site: SiteForCookies = .{ .schemeful_site = "http://127.0.0.1:8100" };

    try testing.expectEqual(true, (try cookieSameSiteContext(
        allocator,
        creator,
        inherited_site,
        "http://127.0.0.1:8100/resource",
    )).?);
    try testing.expectEqual(true, (try cookieSameSiteContext(
        allocator,
        creator,
        inherited_site,
        "http://127.0.0.1:8200/resource",
    )).?);
    try testing.expectEqual(false, (try cookieSameSiteContext(
        allocator,
        creator,
        inherited_site,
        "http://localhost:8200/resource",
    )).?);
    try testing.expectEqual(false, (try cookieSameSiteContext(
        allocator,
        .@"opaque",
        inherited_site,
        "http://127.0.0.1:8100/resource",
    )).?);
    try testing.expect((try cookieSameSiteContext(
        allocator,
        creator,
        .legacy_from_cookie_origin,
        "http://127.0.0.1:8100/resource",
    )) == null);
}

test "HttpClient: schemeful site normalizes subdomains ports IP and private suffixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectString(
        "https://example.test",
        (try obtainSchemefulSite(allocator, "HTTPS://Sub.Example.Test:8443")).?,
    );
    try testing.expectString(
        "http://127.0.0.1",
        (try obtainSchemefulSite(allocator, "http://127.0.0.1:8100")).?,
    );
    try testing.expectString(
        "https://tenant.blogspot.com",
        (try obtainSchemefulSite(allocator, "https://a.tenant.blogspot.com:443")).?,
    );

    const wildcard_source: RequestOrigin = .{ .tuple = "https://a.bar.foo.ck" };
    const wildcard_target: [:0]const u8 = "https://x.foo.ck/resource";
    try testing.expectEqual(
        .cross_site,
        try requestOriginSite(
            allocator,
            wildcard_source,
            wildcard_target,
            try URL.getOrigin(allocator, wildcard_target),
        ),
    );
}

test "HttpClient: default referrer policy sends full, origin-only, and no downgrade" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const same_target: [:0]const u8 = "https://app.example/asset.js";
    const same_origin = try URL.getOrigin(allocator, same_target);
    try testing.expectString(
        "https://app.example/page?q=1",
        (try requestReferrer(allocator, "https://app.example/page?q=1#fragment", same_target, same_origin)).?,
    );

    const cross_target: [:0]const u8 = "https://cdn.example.test/asset.js";
    const cross_origin = try URL.getOrigin(allocator, cross_target);
    try testing.expectString(
        "https://app.example/",
        (try requestReferrer(allocator, "https://app.example/page", cross_target, cross_origin)).?,
    );

    const downgrade_target: [:0]const u8 = "http://cdn.example.test/asset.js";
    const downgrade_origin = try URL.getOrigin(allocator, downgrade_target);
    try testing.expect((try requestReferrer(
        allocator,
        "https://app.example/page",
        downgrade_target,
        downgrade_origin,
    )) == null);
}

test "HttpClient: iframe policies and redirect hops preserve selected referrer monotonicity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "http://127.0.0.1:9582/parent?q=1#fragment";
    const srcdoc: [:0]const u8 = "about:srcdoc";
    try testing.expectString(
        "http://127.0.0.1:9582/",
        (try requestReferrerWithPolicy(
            allocator,
            source,
            srcdoc,
            null,
            .strict_origin_when_cross_origin,
        )).?,
    );
    try testing.expect((try requestReferrerWithPolicy(
        allocator,
        source,
        srcdoc,
        null,
        .no_referrer,
    )) == null);
    try testing.expectString(
        "http://127.0.0.1:9582/parent?q=1",
        (try requestReferrerWithPolicy(
            allocator,
            source,
            srcdoc,
            null,
            .unsafe_url,
        )).?,
    );

    const same_target: [:0]const u8 = "http://127.0.0.1:9582/first";
    const same_origin = try URL.getOrigin(allocator, same_target);
    const first = (try requestReferrerWithPolicy(
        allocator,
        source,
        same_target,
        same_origin,
        default_referrer_policy,
    )).?;
    try testing.expectString("http://127.0.0.1:9582/parent?q=1", first);

    const cross_target: [:0]const u8 = "http://localhost:9582/cross";
    const cross_origin = try URL.getOrigin(allocator, cross_target);
    const reduced = (try requestReferrerWithPolicy(
        allocator,
        first,
        cross_target,
        cross_origin,
        default_referrer_policy,
    )).?;
    try testing.expectString("http://127.0.0.1:9582/", reduced);

    // Returning to the source origin cannot restore path/query information
    // which an earlier cross-origin hop already removed.
    const returned = (try requestReferrerWithPolicy(
        allocator,
        reduced,
        same_target,
        same_origin,
        default_referrer_policy,
    )).?;
    try testing.expectString("http://127.0.0.1:9582/", returned);

    try testing.expectEqual(
        ReferrerPolicy.no_referrer,
        referrerPolicyFromHeader("origin, unknown, NO-REFERRER").?,
    );
    try testing.expectEqual(
        ReferrerPolicy.unsafe_url,
        referrerPolicyFromHeader("no-referrer, unsafe-url, future-policy").?,
    );
    try testing.expectEqual(null, referrerPolicyFromHeader("unknown, future-policy"));
}

test "HttpClient: managed redirect updates and removes the wire Referer header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var headers: Headers = .{ .headers = null };
    try headers.add("Referer: http://127.0.0.1:9582/parent?q=1");

    var transfer: Transfer = .{
        .arena = allocator,
        .owner = null,
        .req = .{
            .frame_id = 1,
            .loader_id = 1,
            .method = .GET,
            .url = "http://127.0.0.1:9582/start",
            .headers = headers,
            .cookie_jar = null,
            .cookie_origin = "http://127.0.0.1:9582/",
            .resource_type = .document,
            .notification = undefined,
            .selected_referrer = "http://127.0.0.1:9582/parent?q=1",
            .referrer_managed = true,
        },
        .client = undefined,
        .start_time = 0,
    };
    defer transfer.req.deinit();

    try transfer.updateReferrerForRedirect("http://localhost:9582/cross");
    try testing.expectString("http://127.0.0.1:9582/", transfer.req.selected_referrer.?);
    var iterator = transfer.req.headers.iterator();
    const referer = iterator.next().?;
    try testing.expectString("Referer", referer.name);
    try testing.expectString("http://127.0.0.1:9582/", referer.value);

    transfer.req.referrer_policy = .no_referrer;
    try transfer.updateReferrerForRedirect("http://localhost:9582/final");
    try testing.expectEqual(null, transfer.req.selected_referrer);
    iterator = transfer.req.headers.iterator();
    try testing.expect(iterator.next() == null);
}

test "HttpClient: Fetch Metadata trustworthiness includes loopback only for HTTP" {
    try testing.expect(isPotentiallyTrustworthy("https://example.test/"));
    try testing.expect(isPotentiallyTrustworthy("http://localhost:9222/"));
    try testing.expect(isPotentiallyTrustworthy("http://127.0.0.1:9222/"));
    try testing.expect(!isPotentiallyTrustworthy("http://example.test/"));
}

test "HttpClient: isFetchInterceptionMethod matches the four Fetch methods" {
    try testing.expect(isFetchInterceptionMethod("Fetch.continueRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.failRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.fulfillRequest"));
    try testing.expect(isFetchInterceptionMethod("Fetch.continueWithAuth"));
}

test "HttpClient: isFetchInterceptionMethod rejects unrelated methods" {
    try testing.expect(!isFetchInterceptionMethod(""));
    try testing.expect(!isFetchInterceptionMethod("Fetch.enable"));
    try testing.expect(!isFetchInterceptionMethod("Fetch.disable"));
    try testing.expect(!isFetchInterceptionMethod("Page.navigate"));
    try testing.expect(!isFetchInterceptionMethod("Runtime.evaluate"));
    // strict-equality check: a prefix of a valid name must not match
    try testing.expect(!isFetchInterceptionMethod("Fetch.continueReq"));
    // trailing space, etc.
    try testing.expect(!isFetchInterceptionMethod("Fetch.continueRequest "));
}

test "HttpClient: allowDuringSyncWait allows ping/close/disconnect" {
    var ping_msg = Inbox.Message{
        .arena = testing.allocator,
        .payload = .{ .ping = "" },
    };
    try testing.expect(allowDuringSyncWait(&ping_msg));

    var close_msg = Inbox.Message{
        .arena = testing.allocator,
        .payload = .close,
    };
    try testing.expect(allowDuringSyncWait(&close_msg));

    var disconnect_msg = Inbox.Message{
        .arena = testing.allocator,
        .payload = .{ .disconnect = null },
    };
    try testing.expect(allowDuringSyncWait(&disconnect_msg));

    var disconnect_err_msg = Inbox.Message{
        .arena = testing.allocator,
        .payload = .{ .disconnect = error.PeerClosed },
    };
    try testing.expect(allowDuringSyncWait(&disconnect_err_msg));
}

test "HttpClient: allowDuringSyncWait allows only Fetch interception CDP methods" {
    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Fetch.continueRequest",
        "Fetch.failRequest",
        "Fetch.fulfillRequest",
        "Fetch.continueWithAuth",
    }) |method| {
        var msg = Inbox.Message{
            .arena = testing.allocator,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(allowDuringSyncWait(&msg));
    }
}

test "HttpClient: allowDuringSyncWait denies non-Fetch CDP methods" {
    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Page.navigate",
        "Runtime.evaluate",
        "Target.createTarget",
        "Fetch.enable",
        "Fetch.disable",
        "",
    }) |method| {
        var msg = Inbox.Message{
            .arena = testing.allocator,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(!allowDuringSyncWait(&msg));
    }
}

test "HttpClient: isSyncWaitInterrupt matches teardown methods, close and disconnect" {
    var raw_buf: [16]u8 = undefined;

    inline for ([_][]const u8{
        "Target.closeTarget",
        "Target.disposeBrowserContext",
        "Page.close",
    }) |method| {
        var msg = Inbox.Message{
            .arena = testing.allocator,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(isSyncWaitInterrupt(&msg));
    }

    var close_msg = Inbox.Message{ .arena = testing.allocator, .payload = .close };
    try testing.expect(isSyncWaitInterrupt(&close_msg));

    var disconnect_msg = Inbox.Message{ .arena = testing.allocator, .payload = .{ .disconnect = null } };
    try testing.expect(isSyncWaitInterrupt(&disconnect_msg));
}

test "HttpClient: isSyncWaitInterrupt ignores ping and non-teardown CDP methods" {
    var ping_msg = Inbox.Message{ .arena = testing.allocator, .payload = .{ .ping = "" } };
    try testing.expect(!isSyncWaitInterrupt(&ping_msg));

    var raw_buf: [16]u8 = undefined;
    inline for ([_][]const u8{
        "Page.navigate",
        "Runtime.evaluate",
        "Target.createTarget",
        "Fetch.continueRequest",
        "",
    }) |method| {
        var msg = Inbox.Message{
            .arena = testing.allocator,
            .payload = .{ .cdp = .{
                .raw = &raw_buf,
                .input = .{ .method = method },
            } },
        };
        try testing.expect(!isSyncWaitInterrupt(&msg));
    }
}

test "HttpClient: redirect failure stages preserve one Connection owner" {
    const Stage = enum { configure, add, perform };

    inline for ([_]Stage{ .configure, .add, .perform }) |stage| {
        var client: Client = undefined;
        client.in_use = .{};
        client.http_active = 1;

        var transfer: Transfer = undefined;
        var conn = http.Connection{
            .in_use = true,
            .transport = .none,
        };
        conn.transport = .{ .http = &transfer };
        client.in_use.append(&conn.node);

        transfer._conn = &conn;
        // configure/add fail after Handles.remove and before the re-add is
        // committed. A perform error happens after the re-add, when normal
        // transfer.deinit still owns the Connection.
        transfer._detached_conn = if (stage == .perform) null else &conn;

        const recovered = client.takeDetachedRedirectConnection(&transfer);
        if (stage == .perform) {
            try testing.expectEqual(null, recovered);
            try testing.expect(transfer._conn == &conn);
            try testing.expectEqual(null, transfer._detached_conn);
            try testing.expect(conn.in_use);
            try testing.expectEqual(@as(usize, 1), client.http_active);
            try testing.expectEqual(@as(usize, 1), client.in_use.len());
        } else {
            try testing.expect(recovered == &conn);
            try testing.expectEqual(null, transfer._conn);
            try testing.expectEqual(null, transfer._detached_conn);
            try testing.expect(!conn.in_use);
            try testing.expectEqual(@as(usize, 0), client.http_active);
            try testing.expectEqual(@as(usize, 0), client.in_use.len());

            // Simulate Network.releaseConnection after the helper returns.
            // The trailing transfer.deinit sees _conn=null, so exactly this
            // one pool membership survives.
            var available: std.DoublyLinkedList = .{};
            available.append(&conn.node);
            try testing.expect(available.first == &conn.node);
            try testing.expectEqual(@as(usize, 1), available.len());
            try testing.expectEqual(@as(usize, 0), client.in_use.len());
        }
    }
}

test "HttpClient: trackConn failures roll back without consuming caller ownership" {
    inline for ([_]TrackConnFailurePoint{ .set_private, .add }) |failure| {
        var client: Client = undefined;
        client.in_use = .{};
        client.performing = false;
        client._track_conn_test = .{ .failure = failure };

        var conn = http.Connection{
            .in_use = false,
            .transport = .none,
        };

        const expected = switch (failure) {
            .set_private => error.InjectedTrackConnSetPrivateFailure,
            .add => error.InjectedTrackConnAddFailure,
        };
        try testing.expectError(expected, client.trackConn(&conn));
        try testing.expect(!conn.in_use);
        try testing.expectEqual(@as(usize, 0), client.in_use.len());

        // trackConn owns only its temporary in_use membership. The immediate
        // HTTP catch / WebSocket errdefer still owns the Connection and may
        // return it exactly once after a failed commit.
        var available: std.DoublyLinkedList = .{};
        available.append(&conn.node);
        try testing.expect(available.first == &conn.node);
        try testing.expectEqual(@as(usize, 1), available.len());
        try testing.expectEqual(@as(usize, 0), client.in_use.len());
    }
}

test "HttpClient: delayed trackConn failure survives reentrant owner teardown" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.in_use = .{};
    client.ready_queue = .{};
    client.dirty = .{};
    client.http_active = 0;
    client.ws_active = 0;
    client.performing = true;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    var owner: Owner = .{};
    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        error_called: bool = false,
        release_count: usize = 0,
        available: std.DoublyLinkedList = .{},

        fn errorCallback(raw: *anyopaque, _: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.error_called = true;
            // This used to free an .inflight Transfer inside abort(), leaving
            // abort's trailing detachOrDeinit to touch freed arena memory.
            self.client.abortOwner(self.owner);
        }

        fn releaseConnection(raw: *anyopaque, conn: *http.Connection) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.release_count += 1;
            conn.transport = .none;
            self.available.append(&conn.node);
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };
    client._track_conn_test = .{
        .release_ctx = &ctx,
        .release_callback = Ctx.releaseConnection,
    };

    var conn = http.Connection{
        .in_use = false,
        .transport = .none,
    };
    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .image,
            .notification = undefined,
            .ctx = &ctx,
            .error_callback = Ctx.errorCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
        .state = .inflight,
        ._conn = &conn,
    };
    conn.transport = .{ .http = transfer };
    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    // First call mirrors a request created from inside handles.perform: it is
    // owned by ready_queue but is not yet in the native backend.
    try client.trackConn(&conn);
    try testing.expect(!conn.in_use);
    try testing.expect(client.ready_queue.first == &conn.node);

    // perform has now returned. Its ready drain pops the sole membership and
    // hits a real injected add-stage failure after logical setPrivate success.
    client.performing = false;
    client._track_conn_test.failure = .add;
    const node = client.ready_queue.popFirst().?;
    try testing.expect(node == &conn.node);
    client.trackConn(&conn) catch |err| client.failReadyTrackConn(&conn, err);

    try testing.expect(ctx.error_called);
    try testing.expectEqual(@as(usize, 1), ctx.release_count);
    try testing.expectEqual(@as(usize, 0), client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
    try testing.expectEqual(null, client.ready_queue.first);
    try testing.expectEqual(null, client.in_use.first);
    try testing.expect(!conn.in_use);
    try testing.expect(ctx.available.first == &conn.node);
    try testing.expectEqual(@as(usize, 1), ctx.available.len());
}

test "HttpClient: owner retirement drops an uncommitted ready connection" {
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.in_use = .{};
    client.ready_queue = .{};
    client.dirty = .{};
    client.http_active = 0;
    client.ws_active = 0;
    client.performing = true;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    const ReleaseCtx = struct {
        count: usize = 0,
        available: std.DoublyLinkedList = .{},

        fn releaseConnection(raw: *anyopaque, conn: *http.Connection) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
            conn.transport = .none;
            self.available.append(&conn.node);
        }
    };
    var release_ctx: ReleaseCtx = .{};
    client._track_conn_test = .{
        .release_ctx = &release_ctx,
        .release_callback = ReleaseCtx.releaseConnection,
    };

    var owner: Owner = .{};
    var conn = http.Connection{
        .in_use = false,
        .transport = .none,
    };
    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .image,
            .notification = undefined,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
        .state = .inflight,
        ._conn = &conn,
    };
    conn.transport = .{ .http = transfer };
    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    try client.trackConn(&conn);
    try testing.expect(!conn.in_use);
    try testing.expect(client.ready_queue.first == &conn.node);

    // Even though client.performing is true, in_use=false proves this request
    // has never entered the backend. Retirement must synchronously remove it
    // from ready_queue instead of leaving an aborted request for the drain to
    // submit after handles.perform returns.
    client.abortOwner(&owner);

    try testing.expectEqual(@as(usize, 1), release_ctx.count);
    try testing.expectEqual(@as(usize, 0), client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
    try testing.expectEqual(null, client.ready_queue.first);
    try testing.expectEqual(null, client.in_use.first);
    try testing.expect(!conn.in_use);
    try testing.expect(release_ctx.available.first == &conn.node);
    try testing.expectEqual(@as(usize, 1), release_ctx.available.len());
}

test "HttpClient: fulfillRequest survives a done_callback that tears down the owner" {
    // Regression: Fetch.fulfillRequest runs the consumer's done_callback while
    // the transfer is still parked for interception. A done_callback that runs
    // JS which navigates / closes the page re-entrantly kills the transfer
    // (abortOwner -> kill -> deinit). Previously the transfer was still
    // `.parked` at that point, so the re-entrant teardown freed it
    // synchronously and fulfillRequest's trailing deinit was a double-free +
    // `intercepted` underflow (surfacing later as a Transfer.leaveIntercept
    // assert at session teardown). fulfillRequest now moves the transfer to
    // `.completing` first, so the teardown defers and there is exactly one free.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    var owner: Owner = .{};

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        done_called: bool = false,

        fn doneCallback(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done_called = true;
            // Mimics a navigation / page-close kicked off from inside the
            // fulfilled response's done_callback, which kills this transfer.
            self.client.abortOwner(self.owner);
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .ctx = &ctx,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    // Mirror InterceptionLayer.request committing the transfer to CDP.
    transfer.park(.intercept_request);
    client.interception_layer.intercepted += 1;

    try client.interception_layer.fulfillRequest(transfer, 200, &.{}, "hello");

    try testing.expect(ctx.done_called);
    // The transfer was freed exactly once: counter back to 0, dropped from the
    // id index and the owner list. A double-free would have underflowed
    // `intercepted` (or tripped the leaveIntercept assert).
    try testing.expectEqual(0, client.interception_layer.intercepted);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}

test "HttpClient: retired owner completion does not re-enter owner state" {
    // A transfer killed while a backend callback is on the stack cannot be
    // freed immediately. Its eventual DONE message is only a lifetime handoff:
    // it must not inspect Notification/CookieJar/ResourceTiming or invoke any
    // author-facing request callback after the owner has retired.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    var owner: Owner = .{};

    const Ctx = struct {
        shutdown_calls: usize = 0,
        forbidden_callback_calls: usize = 0,
        resource_timing_calls: usize = 0,

        fn shutdownCallback(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.shutdown_calls += 1;
        }

        fn headerCallback(response: Response) !HeaderResult {
            const self: *@This() = @ptrCast(@alignCast(response.ctx));
            self.forbidden_callback_calls += 1;
            return .proceed;
        }

        fn dataCallback(response: Response, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(response.ctx));
            self.forbidden_callback_calls += 1;
        }

        fn doneCallback(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.forbidden_callback_calls += 1;
        }

        fn errorCallback(raw: *anyopaque, _: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.forbidden_callback_calls += 1;
        }

        fn recordResourceTiming(
            raw: *anyopaque,
            _: *anyopaque,
            _: ResourceTimingInitiator,
            _: ResourceTimingInfo,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.resource_timing_calls += 1;
        }
    };
    var ctx = Ctx{};

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            // Deliberately poisonous owner-backed pointers. The regression
            // branch must return before either can be dereferenced.
            .cookie_jar = @ptrFromInt(0x1000),
            .cookie_origin = "",
            .resource_type = .document,
            .notification = @ptrFromInt(0x1000),
            .resource_timing = .{
                .context = &ctx,
                .execution_context = @ptrFromInt(0x1000),
                .initiator = .fetch,
                .record = Ctx.recordResourceTiming,
            },
            .ctx = &ctx,
            .header_callback = Ctx.headerCallback,
            .data_callback = Ctx.dataCallback,
            .done_callback = Ctx.doneCallback,
            .error_callback = Ctx.errorCallback,
            .shutdown_callback = Ctx.shutdownCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
        // Mirrors a re-entrant owner teardown while processOneMessage is in a
        // request callback: kill() must defer the sole deinit to its caller.
        .state = .completing,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    client.retireOwner(&owner);
    // Idempotent retirement must not notify shutdown twice.
    client.retireOwner(&owner);

    try testing.expect(!owner.accepting_requests);
    try testing.expectEqual(1, ctx.shutdown_calls);
    try testing.expectEqual(0, ctx.forbidden_callback_calls);
    try testing.expectEqual(0, ctx.resource_timing_calls);
    try testing.expect(transfer.state == .aborted);
    try testing.expectEqual(null, transfer.owner);
    try testing.expectEqual(null, owner.transfers.first);
    try testing.expectEqual(1, client.transfers.count());

    // The conn is poison too: an aborted completion is forbidden from even
    // querying response metadata. processMessages normally owns the following
    // deinit after this function returns true.
    const done = try client.processOneMessage(.{
        .conn = @ptrFromInt(0x1000),
        .err = null,
    }, transfer);
    try testing.expect(done);
    try testing.expectEqual(1, ctx.shutdown_calls);
    try testing.expectEqual(0, ctx.forbidden_callback_calls);
    try testing.expectEqual(0, ctx.resource_timing_calls);

    transfer.deinit();
    try testing.expectEqual(0, client.transfers.count());
}

test "HttpClient: fulfillRequest follows a 3xx redirect" {
    // Regression for #2828: a CDP Fetch.fulfillRequest with a 3xx status + a
    // Location header must be followed like a real network redirect (re-issued
    // down the chain to the resolved target), not delivered as a final response.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    // Only network.config is read (httpMaxRedirects, which ignores its config),
    // so a pointer to an otherwise-undefined Network is safe here.
    var net: Network = undefined;

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.network = &net;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    // Capturing stub for interception_layer.next: records the re-issued request
    // and returns without committing (transfer stays .created; we clean up).
    const Captor = struct {
        captured: bool = false,
        url: []const u8 = "",
        method: Method = undefined,

        fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.captured = true;
            self.url = transfer.req.url;
            self.method = transfer.req.method;
        }
    };
    var captor = Captor{};
    client.interception_layer.next = .{
        .ptr = &captor,
        .vtable = &.{ .request = Captor.request },
    };

    // 302 with a relative Location: rewrite to GET, drop body, resolve target.
    {
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .frame_id = 0,
                .loader_id = 0,
                .method = .POST,
                .url = "http://example.com/start",
                .body = "payload",
                .headers = .{ .headers = null },
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .document,
                .notification = undefined,
                .ctx = undefined,
            },
            .client = &client,
            .id = 1,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

        transfer.park(.intercept_request);
        client.interception_layer.intercepted += 1;

        try client.interception_layer.fulfillRequest(transfer, 302, &.{
            .{ .name = "Location", .value = "/end" },
        }, null);

        try testing.expect(captor.captured);
        try testing.expectEqual("http://example.com/end", captor.url);
        try testing.expectEqual(.GET, captor.method);
        try testing.expectEqual(null, transfer.req.body);
        // Unparked exactly once; transfer is still alive (re-issued, not deinited).
        try testing.expectEqual(0, client.interception_layer.intercepted);
        try testing.expectEqual(1, client.transfers.count());
        transfer.deinit();
    }

    // 307 with an absolute Location: keep method and body.
    captor = .{};
    {
        const arena = try pool.acquire(.small, "test");
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .frame_id = 0,
                .loader_id = 0,
                .method = .POST,
                .url = "http://example.com/start",
                .body = "payload",
                .headers = .{ .headers = null },
                .cookie_jar = null,
                .cookie_origin = "",
                .resource_type = .document,
                .notification = undefined,
                .ctx = undefined,
            },
            .client = &client,
            .id = 2,
            .start_time = 0,
        };
        try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

        transfer.park(.intercept_request);
        client.interception_layer.intercepted += 1;

        try client.interception_layer.fulfillRequest(transfer, 307, &.{
            .{ .name = "location", .value = "http://example.com/other" },
        }, null);

        try testing.expect(captor.captured);
        try testing.expectEqual("http://example.com/other", captor.url);
        try testing.expectEqual(.POST, captor.method);
        try testing.expectEqual("payload", transfer.req.body.?);
        try testing.expectEqual(0, client.interception_layer.intercepted);
        transfer.deinit();
    }
}

test "HttpClient: fulfillRequest delivers a 3xx without a Location as the response" {
    // A redirect status with no Location header is not a redirect: the body is
    // delivered as the final response (matching the real-network path).
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    const Ctx = struct {
        done_called: bool = false,
        fn doneCallback(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.done_called = true;
        }
    };
    var ctx = Ctx{};

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .ctx = &ctx,
            .done_callback = Ctx.doneCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };
    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);

    transfer.park(.intercept_request);
    client.interception_layer.intercepted += 1;

    try client.interception_layer.fulfillRequest(transfer, 302, &.{}, "body");

    // Delivered (done_callback ran) and freed exactly once.
    try testing.expect(ctx.done_called);
    try testing.expectEqual(0, client.interception_layer.intercepted);
    try testing.expectEqual(0, client.transfers.count());
}

test "HttpClient: abortParked survives an error_callback that tears down the owner" {
    // Same re-entrancy hazard as fulfillRequest, but on the abort path
    // (failRequest / continueWithAuth-cancel / session teardown). abortParked
    // fires the failure callback while .completing, so a re-entrant owner
    // teardown defers to the single deinit instead of double-freeing.
    var pool = ArenaPool.init(testing.allocator, .{});
    defer pool.deinit();

    var client: Client = undefined;
    client.allocator = testing.allocator;
    client.arena_pool = &pool;
    client.transfers = .empty;
    client.queue = .{};
    client.next_tick_queue = .{};
    client.next_tick_count = 0;
    client.performing = false;
    client.interception_layer = .{};
    defer client.transfers.deinit(testing.allocator);

    var owner: Owner = .{};

    const Ctx = struct {
        client: *Client,
        owner: *Owner,
        err_called: bool = false,

        fn errorCallback(ctx: *anyopaque, _: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.err_called = true;
            self.client.abortOwner(self.owner);
        }
    };
    var ctx = Ctx{ .client = &client, .owner = &owner };

    const arena = try pool.acquire(.small, "test");
    const transfer = try arena.create(Transfer);
    transfer.* = .{
        .arena = arena,
        .owner = null,
        .req = .{
            .frame_id = 0,
            .loader_id = 0,
            .method = .GET,
            .url = "http://example.com/",
            .headers = .{ .headers = null },
            .cookie_jar = null,
            .cookie_origin = "",
            .resource_type = .document,
            .notification = undefined,
            .ctx = &ctx,
            .error_callback = Ctx.errorCallback,
        },
        .client = &client,
        .id = 1,
        .start_time = 0,
    };

    try client.transfers.putNoClobber(testing.allocator, transfer.id, transfer);
    owner.addTransfer(transfer);
    transfer.owner = &owner;

    transfer.park(.intercept_request);
    client.interception_layer.intercepted += 1;

    transfer.abortParked(error.Abort);

    try testing.expect(ctx.err_called);
    try testing.expectEqual(0, client.interception_layer.intercepted);
    try testing.expectEqual(0, client.transfers.count());
    try testing.expectEqual(null, owner.transfers.first);
}
