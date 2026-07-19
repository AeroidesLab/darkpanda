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
const HttpClient = @import("../../HttpClient.zig");

const js = @import("../../js/js.zig");
const Mime = @import("../../Mime.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const AbortSignal = @import("../AbortSignal.zig");
const DOMException = @import("../DOMException.zig");

const log = lp.log;
const Execution = js.Execution;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Fetch = @This();

_exec: *const Execution,
_url: []const u8,
_buf: std.ArrayList(u8),
_response: *Response,
_resolver: js.PromiseResolver.Global,
_owns_response: bool,
_signal: ?*AbortSignal,
_abort_algorithm: ?*AbortSignal.AbortAlgorithm,
_aborted_by_signal: bool,
_promise_settled: bool,
_request_client: *HttpClient.Client,
_manual_redirect: bool,
_no_cors: bool,
_credentials_include: bool,
_opaque_response: bool,
_request_origin: HttpClient.RequestOrigin,

pub const Input = Request.Input;
pub const InitOpts = Request.InitOpts;

pub fn init(input: Input, options: ?InitOpts, exec: *const Execution) !js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();

    // LocalDOMWindow::FrameDestroyed leaves the V8 realm alive but clears the
    // ExecutionContext used by Fetch. Blink rejects the returned promise before
    // converting RequestInfo/RequestInit in this state.
    if (exec.isShuttingDown()) {
        const message: []const u8 = switch (exec.js.global) {
            .frame => "Failed to execute 'fetch' on 'Window': The global scope is shutting down.",
            .worker => "Failed to execute 'fetch' on 'WorkerGlobalScope': The global scope is shutting down.",
        };
        resolver.rejectError("fetch shutting down", .{ .type_error = message });
        return resolver.promise();
    }

    // A bad RequestInit (e.g. an invalid priority) must reject the promise,
    // not throw synchronously.
    const request = Request.initForFetch(input, options, exec) catch |err| {
        const message: []const u8 = switch (err) {
            error.InvalidRequestURL => blk: {
                const interface = switch (exec.js.global) {
                    .frame => "Window",
                    .worker => "WorkerGlobalScope",
                };
                const reason = try Request.invalidURLReason(input, exec.call_arena);
                break :blk try std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to execute 'fetch' on '{s}': {s}",
                    .{ interface, reason },
                );
            },
            else => "Failed to construct Request",
        };
        resolver.rejectError("fetch init error", .{ .type_error = message });
        return resolver.promise();
    };

    if (request._signal) |signal| {
        if (signal._aborted) {
            resolver.reject("fetch aborted", signal.getReason());
            return resolver.promise();
        }
    }

    // Fetch mode "same-origin" is a policy check, not merely a value for
    // Sec-Fetch-Mode. Chromium rejects before issuing a cross-origin request.
    const request_origin = exec.requestOrigin();
    const is_same_origin = HttpClient.requestOriginIsSameOrigin(
        exec.call_arena,
        request_origin,
        request._url,
    ) catch false;
    if (request._mode == .@"same-origin" and !is_same_origin) {
        resolver.rejectError("fetch same-origin", .{ .type_error = "Failed to fetch" });
        return resolver.promise();
    }

    const response = try Response.init(null, .{ .status = 0 }, exec);
    errdefer response.deinit(exec.page);

    const fetch = try response._arena.create(Fetch);
    fetch.* = .{
        ._exec = exec,
        ._buf = .empty,
        ._url = try response._arena.dupe(u8, request._url),
        ._resolver = try resolver.persist(),
        ._response = response,
        ._owns_response = true,
        ._signal = request._signal,
        ._abort_algorithm = null,
        ._aborted_by_signal = false,
        ._promise_settled = false,
        ._request_client = switch (exec.js.global) {
            .frame => |frame| &frame._session.browser.http_client,
            .worker => |worker| worker._http_client,
        },
        ._manual_redirect = request._redirect == .manual,
        ._no_cors = request._mode == .@"no-cors",
        ._credentials_include = request._credentials == .include,
        ._opaque_response = false,
        ._request_origin = try request_origin.dupe(response._arena),
    };
    // This must be registered after response's errdefer so it runs first:
    // AbortSignal stores a stable entry whose ctx points into response._arena.
    errdefer fetch.unregisterAbortAlgorithm();

    if (fetch._signal) |signal| {
        fetch._abort_algorithm = try signal.addAbortAlgorithm(fetch, abortAlgorithm, exec);
    }

    const session = exec.session;
    const http_client = &session.browser.http_client;
    var headers = try http_client.newRequestHeaders(request._url, .{
        .destination = .empty,
        .mode = switch (request._mode) {
            .cors => .cors,
            .@"no-cors" => .no_cors,
            .@"same-origin" => .same_origin,
        },
        .request_origin = fetch._request_origin,
        .initiator_url = exec.url.*,
        .top_level_url = exec.url.*,
        .referrer_url = exec.outgoingReferrerUrl(),
        .method = request._method,
        .has_body = request._body != null,
        .credentials = switch (request._credentials) {
            .omit => .omit,
            .include => .include,
            .@"same-origin" => .same_origin,
        },
    });
    var request_owns_headers = false;
    defer if (!request_owns_headers) headers.deinit();
    if (request._headers) |h| {
        try h.populateHttpHeader(exec.call_arena, &headers);
    }

    if (comptime IS_DEBUG) {
        log.debug(.http, "fetch", .{ .url = request._url });
    }

    const cookie_jar = switch (request._credentials) {
        .omit => null,
        .include => &session.cookie_jar,
        .@"same-origin" => if (is_same_origin) &session.cookie_jar else null,
    };

    // Synchronous failures after a Transfer is created are dispatched to
    // httpErrorCallback by Client.request, which rejects the promise and
    // releases response._arena. Propagating the error from here would also
    // fire the `errdefer response.deinit` above and double-free the arena.
    // Frame/WGS/HttpClient owns the header list from entry onward, including
    // every early failure path.
    request_owns_headers = true;
    exec.makeRequest(.{
        .ctx = fetch,
        .url = request._url,
        .method = request._method,
        .frame_id = exec.frameId(),
        .loader_id = exec.loaderId(),
        .body = request._body,
        .headers = headers,
        .cancellation_context = fetch,
        .resource_type = .fetch,
        .cookie_jar = cookie_jar,
        .cookie_origin = exec.url.*,
        .request_origin = fetch._request_origin,
        .site_for_cookies = exec.siteForCookies(),
        .redirect = switch (request._redirect) {
            .follow => .follow,
            .manual => .manual,
            .@"error" => .@"error",
        },
        .notification = session.notification,
        .start_callback = httpStartCallback,
        .header_callback = httpHeaderDoneCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
        .unstarted_callback = httpUnstartedCallback,
    }) catch {};
    return resolver.promise();
}

fn httpStartCallback(response: HttpClient.Response) !void {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));
    if (comptime IS_DEBUG) {
        log.debug(.http, "request start", .{ .url = self._url, .source = "fetch" });
    }
    self._response._http_response = response;
    // An operation can be queued before the transport exposes its Response.
    // If the signal fired in that window, its promise is already rejected;
    // cancel the transfer as soon as it becomes reachable.
    if (self._aborted_by_signal) {
        const client = self._request_client;
        const cancellation_context: *anyopaque = self;
        _ = client.abortCancellationContext(cancellation_context, error.Abort);
        return;
    }
}

fn unregisterAbortAlgorithm(self: *Fetch) void {
    const algorithm = self._abort_algorithm orelse return;
    self._abort_algorithm = null;
    if (self._signal) |signal| signal.removeAbortAlgorithm(algorithm);
}

fn rejectWithSignalReason(self: *Fetch) void {
    if (self._promise_settled) return;
    self._promise_settled = true;
    const signal = self._signal orelse return;

    var ls: js.Local.Scope = undefined;
    self._exec.js.localScope(&ls);
    defer ls.deinit();
    ls.toLocal(self._resolver).reject("fetch aborted", signal.getReason());
}

fn abortAlgorithm(ctx: *anyopaque) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    // AbortSignal disables the entry before invoking us.  Clear the operation
    // side as well so every terminal path is idempotent.
    self._abort_algorithm = null;
    if (self._promise_settled) return;
    self._aborted_by_signal = true;
    const client = self._request_client;
    const cancellation_context: *anyopaque = self;

    // Reject promptly in every lifecycle state.  A queued request has no live
    // handle yet; a deferred terminal replay may already have released its
    // Transfer.  In both cases the operation arena remains owned by the later
    // start/error/shutdown callback.
    self.rejectWithSignalReason();
    _ = client.abortCancellationContext(cancellation_context, error.Abort);
    // Cancellation can synchronously free Fetch's response arena.  Do not
    // access self after this point.
}

fn httpHeaderDoneCallback(response: HttpClient.Response) !HttpClient.HeaderResult {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));

    if (self._signal) |signal| {
        if (signal._aborted) {
            return .abort;
        }
    }

    const arena = self._response._arena;

    const res = self._response;

    if (comptime IS_DEBUG) {
        log.debug(.http, "request header", .{
            .source = "fetch",
            .url = self._url,
            .status = response.status(),
        });
    }

    res._status = response.status().?;
    res._status_text = std.http.Status.phrase(@enumFromInt(response.status().?)) orelse "";
    res._url = try arena.dupeZ(u8, response.url());
    res._is_redirected = response.redirectCount().? > 0;

    // redirect: "manual" surfaces the unfollowed 3xx as an opaque-redirect
    // filtered response: status 0, no headers, no body.
    if (self._manual_redirect and HttpClient.isRedirectStatus(res._status)) {
        res._status = 0;
        res._status_text = "";
        res._url = "";
        res._type = .opaqueredirect;
        res._is_redirected = false;
        self._opaque_response = true;
        return .proceed;
    }

    // Determine response tainting from the immutable SecurityOrigin snapshot
    // captured when Fetch was constructed. Never re-read a live/global URL:
    // navigation can change it, and blob:/data: Worker URLs are not their
    // request security origins.
    const exec = self._exec;
    const local_scheme_response = std.ascii.startsWithIgnoreCase(res._url, "data:") or
        std.ascii.startsWithIgnoreCase(res._url, "blob:");
    const same_origin = if (local_scheme_response)
        false
    else
        HttpClient.requestOriginIsSameOrigin(
            arena,
            self._request_origin,
            res._url,
        ) catch false;
    if (local_scheme_response or same_origin) {
        // A successfully resolved data: response is a basic filtered response.
        // Blob registry access is checked before a response reaches this point;
        // a permitted blob: fetch likewise retains basic response semantics.
        res._type = .basic;
    } else if (self._no_cors) {
        // A cross-origin no-cors response is opaque: status, URL, headers and
        // body are not exposed to script.
        res._status = 0;
        res._status_text = "";
        res._url = "";
        res._type = .@"opaque";
        res._is_redirected = false;
        self._opaque_response = true;
        return .proceed;
    } else {
        res._type = .cors; // Cross-origin (for simplicity, assume CORS passed)
    }

    // Do not reserve from an untrusted cross-origin Content-Length until after
    // deciding whether this is an opaque response whose body is discarded.
    if (response.contentLength()) |cl| {
        try self._buf.ensureTotalCapacity(arena, cl);
    }

    var it = response.headerIterator();
    while (it.next()) |hdr| {
        // Set-Cookie response headers are forbidden response-header names for
        // every Fetch filtered response, including same-origin `basic`.
        // Exposing them here would also reveal HttpOnly cookie material.
        if (isForbiddenResponseHeaderName(hdr.name)) continue;
        // A CORS filtered response exposes only the safelisted response
        // headers and names accepted from Access-Control-Expose-Headers.
        // In credentials mode `include`, `*` is a literal header name rather
        // than a wildcard, matching Blink's ExtractCorsExposedHeaderNamesList.
        if (res._type == .cors and !corsExposesResponseHeader(
            response,
            hdr.name,
            self._credentials_include,
        )) continue;
        try res._headers.append(hdr.name, hdr.value, exec);
    }

    return .proceed;
}

fn isForbiddenResponseHeaderName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "set-cookie") or
        std.ascii.eqlIgnoreCase(name, "set-cookie2");
}

fn isCorsSafelistedResponseHeaderName(name: []const u8) bool {
    const safelisted = [_][]const u8{
        "cache-control",
        "content-language",
        "content-length",
        "content-type",
        "expires",
        "last-modified",
        "pragma",
    };
    for (safelisted) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

const CorsExposureMatch = struct {
    explicit: bool = false,
    wildcard: bool = false,
};

/// Parse one Access-Control-Expose-Headers field-value using Chromium's
/// HTTPHeaderNameListParser rules. Empty comma-delimited elements are ignored;
/// any malformed element invalidates the complete exposed-name list.
fn matchCorsExposureValue(
    value: []const u8,
    response_name: []const u8,
    match: *CorsExposureMatch,
) bool {
    var pos: usize = 0;
    while (true) {
        while (pos < value.len and (value[pos] == ' ' or value[pos] == '\t')) pos += 1;
        if (pos < value.len and value[pos] == ',') {
            while (pos < value.len and value[pos] == ',') pos += 1;
            continue;
        }
        if (pos == value.len) return true;

        const start = pos;
        while (pos < value.len and value[pos] != ',' and value[pos] != ' ' and value[pos] != '\t') pos += 1;
        const token = value[start..pos];
        if (token.len == 0 or !Mime.isHttpToken(token)) return false;

        if (std.ascii.eqlIgnoreCase(token, response_name)) match.explicit = true;
        if (std.mem.eql(u8, token, "*")) match.wildcard = true;

        while (pos < value.len and (value[pos] == ' ' or value[pos] == '\t')) pos += 1;
        if (pos == value.len) return true;
        if (value[pos] != ',') return false;
        pos += 1;
    }
}

fn corsExposesResponseHeader(
    response: HttpClient.Response,
    response_name: []const u8,
    credentials_include: bool,
) bool {
    if (isCorsSafelistedResponseHeaderName(response_name)) return true;

    var match: CorsExposureMatch = .{};
    var it = response.headerIterator();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "access-control-expose-headers")) continue;
        if (!matchCorsExposureValue(header.value, response_name, &match)) return false;
    }
    return match.explicit or (!credentials_include and match.wildcard);
}

fn httpDataCallback(response: HttpClient.Response, data: []const u8) !void {
    const self: *Fetch = @ptrCast(@alignCast(response.ctx));

    // Check if aborted
    if (self._signal) |signal| {
        if (signal._aborted) {
            return error.Abort;
        }
    }

    if (!self._opaque_response) {
        try self._buf.appendSlice(self._response._arena, data);
    }
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    self.unregisterAbortAlgorithm();
    var response = self._response;
    response._http_response = null;

    // A queued/synthetic request can reach done after its signal already
    // rejected the promise.  In that case completion is cleanup-only: never
    // expose the Response or attempt to resolve a settled promise.
    if (self._promise_settled) {
        const owns_response = self._owns_response;
        self._owns_response = false;
        if (owns_response) response.deinit(self._exec.page);
        return;
    }

    response._body = if (self._opaque_response) .empty else .{ .bytes = self._buf.items };
    // Network responses expose an immutable Headers guard. Native population
    // is complete at this point; clones preserve the guard, while
    // `new Headers(response.headers)` deliberately creates a mutable copy.
    response._headers.setGuard(.immutable);

    log.info(.http, "request complete", .{
        .source = "fetch",
        .url = self._url,
        .status = response._status,
        .len = self._buf.items.len,
    });

    var ls: js.Local.Scope = undefined;
    self._exec.js.localScope(&ls);
    defer ls.deinit();

    const js_val = try ls.local.zigValueToJs(self._response, .{});
    self._promise_settled = true;
    self._owns_response = false;
    return ls.toLocal(self._resolver).resolve("fetch done", js_val);
}

fn httpUnstartedCallback(ctx: *anyopaque) void {
    // No Transfer exists, so the normal transport error callback cannot run.
    // Reuse its single-settlement and response-arena cleanup path.
    httpErrorCallback(ctx, error.NetworkError);
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    self.unregisterAbortAlgorithm();

    log.info(.http, "request error", .{
        .source = "fetch",
        .url = self._url,
        .status = self._response._status,
        .err = err,
    });

    var response = self._response;
    response._http_response = null;

    // Capture this before we reject. Rejection could trigger httpShutdownCallback
    // (via a microtask callback). But if we're here, then we'll take care of
    // cleaning up when we're done.
    const owns_response = self._owns_response;
    self._owns_response = false;

    // the response is only passed on v8 on success, if we're here, it's safe to
    // clear this. (defer since `self is in the response's arena).

    defer if (owns_response) {
        response.deinit(self._exec.page);
    };

    if (!self._promise_settled) {
        var ls: js.Local.Scope = undefined;
        self._exec.js.localScope(&ls);
        defer ls.deinit();

        self._promise_settled = true;
        if (self._aborted_by_signal) {
            // Fetch rejects with the exact AbortSignal reason, not a newly
            // constructed DOMException or a generic network TypeError.
            ls.toLocal(self._resolver).reject("fetch aborted", self._signal.?.getReason());
        } else {
            // fetch() must reject with a TypeError on network errors per spec
            ls.toLocal(self._resolver).rejectError("fetch error", .{ .type_error = "fetch error" });
        }
    }
}

fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    self.unregisterAbortAlgorithm();
    self._promise_settled = true;

    if (self._owns_response) {
        var response = self._response;
        response._http_response = null;
        response.deinit(self._exec.page);
        // Do not access `self` after this point: the Fetch struct was
        // allocated from response._arena which has been released.
    }
}

const testing = @import("../../../testing.zig");
test "WebApi: fetch" {
    try testing.htmlRunner("net/fetch.html", .{});
    try testing.htmlRunner("net/fetch_hash_route.html", .{});
}

test "WebApi: fetch filters forbidden response cookie headers" {
    try std.testing.expect(isForbiddenResponseHeaderName("Set-Cookie"));
    try std.testing.expect(isForbiddenResponseHeaderName("set-cookie2"));
    try std.testing.expect(!isForbiddenResponseHeaderName("content-type"));
}

test "WebApi: CORS exposed response header parser matches Chromium list rules" {
    try std.testing.expect(isCorsSafelistedResponseHeaderName("Content-Type"));
    try std.testing.expect(isCorsSafelistedResponseHeaderName("last-modified"));
    try std.testing.expect(!isCorsSafelistedResponseHeaderName("x-hidden"));

    var match: CorsExposureMatch = .{};
    try std.testing.expect(matchCorsExposureValue(", , X-Visible, * ,", "x-visible", &match));
    try std.testing.expect(match.explicit);
    try std.testing.expect(match.wildcard);

    match = .{};
    try std.testing.expect(matchCorsExposureValue("*", "x-hidden", &match));
    try std.testing.expect(!match.explicit);
    try std.testing.expect(match.wildcard);

    match = .{};
    try std.testing.expect(!matchCorsExposureValue("x-visible invalid", "x-visible", &match));
}
