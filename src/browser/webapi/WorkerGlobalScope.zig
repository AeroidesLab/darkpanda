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

// The struct is like a mix of Page and Window, but a very limited Page and
// a very limited Window. This dual-purpose does make it a bit harder to know
// what's what...e.g what is a WebAPI call and what it called internally.

const std = @import("std");
const lp = @import("darkpanda");

const JS = @import("../js/js.zig");
const URL = @import("../URL.zig");
const SecureContext = @import("../SecureContext.zig");
const Page = @import("../Page.zig");
const Frame = @import("../Frame.zig");
const Factory = @import("../Factory.zig");
const Session = @import("../Session.zig");
const HttpClient = @import("../HttpClient.zig");
const OwnerMailbox = @import("../OwnerMailbox.zig");
const EventManagerBase = @import("../EventManagerBase.zig");
const ScriptManagerBase = @import("../ScriptManagerBase.zig");

const Blob = @import("Blob.zig");
const Event = @import("Event.zig");
const Crypto = @import("Crypto.zig");
const TrustedTypes = @import("TrustedTypes.zig");
const Console = @import("Console.zig");
const WorkerNavigator = @import("WorkerNavigator.zig");
const Timers = @import("Timers.zig");
const EventTarget = @import("EventTarget.zig");
const Performance = @import("Performance.zig");
const WorkerLocation = @import("WorkerLocation.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const Fetch = @import("net/Fetch.zig");
const idb = @import("storage/idb/idb.zig");
const CookieStore = @import("storage/CookieStore.zig");
const DedicatedWorkerGlobalScope = @import("DedicatedWorkerGlobalScope.zig");

const builtin = @import("builtin");
const IS_DEBUG = builtin.mode == .Debug;

const log = lp.log;
const Allocator = std.mem.Allocator;

const WorkerGlobalScope = @This();

_type: Type,
_is_module: bool,
// Snapshot of the outside settings object's secure-context state at Worker
// construction, matching Blink's is_creator_secure_context_.
_creator_secure_context: bool,
// Immutable creator settings copied before the owner thread starts. Worker
// fetch/importScripts must not consult the live creator Frame.
_creator_url: [:0]const u8,
_creator_referer_header: []const u8,
_site_for_cookies: HttpClient.SiteForCookies,

// Meant to follow the same field naming as Page so that an anytype of generic
// can access these the same for a Page of a WGS.
// These fields represent the "Page"-like component of the WGS
_page: *Page,
_session: *Session,
_factory: *Factory,
_owned_factory: *Factory,
_identity: JS.Identity = .{},
_http_owner: HttpClient.Owner = .{},
_http_client: *HttpClient,
_owner_mailbox: *OwnerMailbox.Mailbox,

arena: Allocator,
call_arena: Allocator,
local_arena: Allocator,
url: [:0]const u8,
// Dedicated workers inherit their creator's origin; data: workers use null to
// represent the unique opaque origin required by HTML's worker setup algorithm.
origin: ?[]const u8 = null,
// Immutable creator storage partition. A data: worker or an opaque creator
// records null so backend IDB operations are denied while indexedDB.cmp stays
// available on the exposed factory.
_storage_origin_key: ?[]const u8 = null,
buf: [1024]u8 = undefined, // same size as frame.buf
// Document charset (matches Page.charset). Workers default to UTF-8.
charset: []const u8 = "UTF-8",
js: *JS.Context,

// Blob URL registry for URL.createObjectURL/revokeObjectURL.
_blob_urls: Blob.OwnedURLSet = .{},

// HTTP attribution
_frame_id: u32,
_loader_id: u32,
_root_frame_id: u32,

// Event management for non-DOM targets in worker context
_event_manager: EventManagerBase,

// Handles module imports (static + dynamic). No parser integration since
// workers don't have <script> tags.
_script_manager: ScriptManagerBase,

// List of open BroadcastChannels, used to route  HTTP attribution. Mirrors Frame's fiage between same-named
// channels in this worker's origin
_broadcast_channels: std.DoublyLinkedList = .{},

// These fields represent the "Window"-like component of the WGS
_proto: *EventTarget,
_console: Console = .init,
_crypto: Crypto = .init,
_trusted_types: TrustedTypes.TrustedTypePolicyFactory = .init,
_navigator: WorkerNavigator = .init,
_performance: Performance,
_idb_factory: ?*idb.IDBFactory = null,
_on_error: ?JS.Function.Global = null,
_on_rejection_handled: ?JS.Function.Global = null,
_on_unhandled_rejection: ?JS.Function.Global = null,
_cookie_store: ?*CookieStore = null,

_location: WorkerLocation,

_timers: Timers = .{},

pub const Type = union(enum) {
    dedicated: *DedicatedWorkerGlobalScope,
};

pub fn isShuttingDown(self: *const WorkerGlobalScope) bool {
    return switch (self._type) {
        .dedicated => |worker| worker._closed,
    };
}

pub fn init(
    arena: Allocator,
    url: [:0]const u8,
    child: Type,
    is_module: bool,
    frame_id: u32,
    loader_id: u32,
    root_frame_id: u32,
    frame: *Frame,
    creator_secure_context: bool,
    creator_origin_key: []const u8,
    creator_origin: ?[]const u8,
    creator_storage_origin_key: ?[]const u8,
    creator_url: [:0]const u8,
    creator_referer_header: []const u8,
    creator_site_for_cookies: HttpClient.SiteForCookies,
    env: *JS.Env,
    http_client: *HttpClient,
    owner_mailbox: *OwnerMailbox.Mailbox,
) !*WorkerGlobalScope {
    const session = frame._session;

    const call_arena = try session.getArena(.small, "WorkerGlobalScope.call_arena");
    errdefer session.releaseArena(call_arena);

    const local_arena = try session.getArena(.small, "WorkerGlobalScope.local_arena");
    errdefer session.releaseArena(local_arena);

    const factory = try arena.create(Factory);
    factory.* = Factory.init(arena);
    const worker_url = try arena.dupeZ(u8, url);
    const inherited_request_origin = HttpClient.requestOriginFromRelaxableSecurityKey(
        creator_origin_key,
        creator_origin,
    );
    const serialized_worker_origin: ?[]const u8 = if (std.ascii.startsWithIgnoreCase(url, "data:"))
        null
    else switch (inherited_request_origin) {
        .tuple => |origin| origin,
        else => null,
    };
    const self = try factory.eventTargetWithAllocator(arena, WorkerGlobalScope{
        .url = worker_url,
        .arena = arena,
        // Dedicated workers inherit their creator origin except data: workers,
        // whose environment settings object has a unique opaque origin.
        .origin = if (serialized_worker_origin) |origin| try arena.dupe(u8, origin) else null,
        ._storage_origin_key = if (!std.ascii.startsWithIgnoreCase(url, "data:"))
            if (creator_storage_origin_key) |key| try arena.dupe(u8, key) else null
        else
            null,
        .js = undefined,
        .call_arena = call_arena,
        .local_arena = local_arena,
        ._page = frame._page,
        ._session = session,
        ._identity = .{},
        ._type = child,
        ._proto = undefined,
        ._factory = factory,
        ._owned_factory = factory,
        ._http_client = http_client,
        ._owner_mailbox = owner_mailbox,
        ._is_module = is_module,
        ._creator_secure_context = creator_secure_context,
        ._creator_url = creator_url,
        ._creator_referer_header = creator_referer_header,
        ._site_for_cookies = try creator_site_for_cookies.dupe(arena),
        ._frame_id = frame_id,
        ._loader_id = loader_id,
        ._root_frame_id = root_frame_id,
        ._event_manager = .init(arena),
        ._script_manager = undefined,
        ._location = .{ ._url = url },
        ._performance = .init(),
    });
    // The embedded Performance must point at its final Worker-owned address
    // before createWorkerContext can expose it to the worker isolate.
    self._performance._proto = try factory.standaloneEventTarget(&self._performance);

    self._http_owner.blob_urls = &frame._page.blob_url_registry;
    self._http_owner.blob_releaser = .{
        .ctx = frame._page,
        .run = Page.releaseHttpBlob,
    };

    self._script_manager = ScriptManagerBase.init(
        arena,
        http_client,
        .{ .worker = self },
    );

    self.js = try env.createWorkerContext(self, .{
        .call_arena = call_arena,
        .local_arena = local_arena,
        .identity_arena = arena,
        .identity = &self._identity,
    });

    if (std.ascii.startsWithIgnoreCase(url, "data:")) {
        // Keep the worker Context's freshly generated opaque identity unique,
        // while installing that Origin's security token into V8.
        try self.js.setOriginKey(self.js.origin.key);
    } else {
        // Isolates cannot share a v8::Global security-token handle. Recreate a
        // token with the creator's exact serialized key inside this isolate.
        try self.js.setOriginKey(creator_origin_key);
    }

    return self;
}

pub fn deinit(self: *WorkerGlobalScope) void {
    const page = self._page;
    const session = page.session;
    self._http_client.retireOwner(&self._http_owner);
    // Completed transfers can still have terminal callbacks buffered behind a
    // synchronous request. They no longer appear in Owner.transfers, so close
    // those captured lifetimes before this Worker arena is freed.
    self._http_client.deferring_layer.cancelOwner(&self._http_owner);

    if (self._cookie_store) |cookie_store| cookie_store.detach();

    self._identity.deinit();
    self._script_manager.deinit();

    page.releaseOwnedBlobURLs(&self._blob_urls);
    self.js.env.destroyContext(self.js);
    session.releaseArena(self.call_arena);
    session.releaseArena(self.local_arena);
}

pub fn base(self: *const WorkerGlobalScope) [:0]const u8 {
    return self.url;
}

pub fn requestOrigin(self: *const WorkerGlobalScope) HttpClient.RequestOrigin {
    // Like Window, a Worker created after document.domain inherits the relaxed
    // access-control key but keeps the original network tuple in `origin`.
    return HttpClient.requestOriginFromRelaxableSecurityKey(self.js.origin.key, self.origin);
}

pub fn siteForCookies(self: *const WorkerGlobalScope) HttpClient.SiteForCookies {
    return self._site_for_cookies;
}

pub fn outgoingReferrerUrl(self: *const WorkerGlobalScope) ?[]const u8 {
    // ExecutionContext::OutgoingReferrerUrl uses the Worker environment's
    // creation URL. HTTP(S) Worker scripts therefore refer from their script
    // URL; blob:/data: URLs are stripped to no referrer.
    if (std.ascii.startsWithIgnoreCase(self.url, "http://") or
        std.ascii.startsWithIgnoreCase(self.url, "https://"))
    {
        return self.url;
    }
    return null;
}

pub fn asEventTarget(self: *WorkerGlobalScope) *EventTarget {
    return self._proto;
}

// Dispatch an event to listeners on the given target within this worker context.
pub fn dispatch(
    self: *WorkerGlobalScope,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManagerBase.DispatchDirectOptions,
) !void {
    try self._event_manager.dispatchDirect(
        self.call_arena,
        self.js,
        target,
        event,
        handler,
        self._page,
        opts,
    );
}

pub fn hasDirectListeners(self: *WorkerGlobalScope, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self._event_manager.hasDirectListeners(target, typ, handler);
}

// Workers don't have their own Referer; per spec, dedicated worker requests
// use the parent document's URL. Delegate to the owning frame.
pub fn headersForRequest(self: *WorkerGlobalScope, headers: *HttpClient.Headers) !void {
    if (self._creator_referer_header.len != 0) {
        try headers.add(self._creator_referer_header);
    }
}

pub fn isSameOrigin(self: *const WorkerGlobalScope, url: [:0]const u8) bool {
    return HttpClient.requestOriginIsSameOrigin(
        self.local_arena,
        self.requestOrigin(),
        url,
    ) catch false;
}

pub fn makeRequest(self: *WorkerGlobalScope, req: HttpClient.Request) !void {
    if (self.isShuttingDown()) {
        req.deinit();
        if (req.unstarted_callback) |callback| callback(req.ctx);
        return error.ContextShuttingDown;
    }

    var timed = req;
    timed.root_frame_id = self._root_frame_id;
    timed.initiator_context = .worker;
    if (timed.resource_timing == null and !timed.internal) {
        const initiator: HttpClient.ResourceTimingInitiator = switch (timed.resource_type) {
            .script => .script,
            .image => .img,
            .fetch => .fetch,
            .xhr => .xmlhttprequest,
            .stylesheet => .link,
            .document => .other,
        };
        timed.resource_timing = self.performance().resourceTimingSink(&self.js.execution, initiator);
    }
    return self._http_client.request(timed, &self._http_owner);
}

pub fn getSelf(self: *WorkerGlobalScope) *WorkerGlobalScope {
    return self;
}

pub fn getIsSecureContext(self: *const WorkerGlobalScope) bool {
    if (!self._creator_secure_context) return false;

    // Blink explicitly lets data: worker scripts proceed past the otherwise
    // opaque-origin rejection; creator security still applies through
    // HasInsecureContextInAncestors().
    if (std.ascii.startsWithIgnoreCase(self.url, "data:")) return true;

    if (self.origin) |origin| {
        return SecureContext.isOriginPotentiallyTrustworthy(origin);
    }
    return SecureContext.isTrustworthyMissingOriginURL(self.url);
}

pub fn setSelf(self: *WorkerGlobalScope, value: JS.Value) void {
    self.replaceGlobalProperty(value, "self");
}

pub fn getConsole(self: *WorkerGlobalScope) *Console {
    return &self._console;
}

pub fn setConsole(self: *WorkerGlobalScope, value: JS.Value) void {
    self.replaceGlobalProperty(value, "console");
}

pub fn getCrypto(self: *WorkerGlobalScope) *Crypto {
    return &self._crypto;
}

pub fn getTrustedTypes(self: *WorkerGlobalScope) *TrustedTypes.TrustedTypePolicyFactory {
    return &self._trusted_types;
}

pub fn getNavigator(self: *WorkerGlobalScope) *WorkerNavigator {
    return &self._navigator;
}

pub fn performance(self: *WorkerGlobalScope) *Performance {
    return &self._performance;
}

pub fn getLocation(self: *WorkerGlobalScope) *WorkerLocation {
    return &self._location;
}

pub fn getCookieStore(self: *WorkerGlobalScope, exec: *JS.Execution) !*CookieStore {
    if (self._cookie_store) |cs| return cs;
    const cs = try self._factory.eventTargetWithAllocator(self.arena, CookieStore{ ._proto = undefined });
    try cs.attach(exec);
    self._cookie_store = cs;
    return cs;
}

pub fn getOnError(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

pub fn getOnRejectionHandled(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const WorkerGlobalScope) ?JS.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *WorkerGlobalScope, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

const base64 = @import("encoding/base64.zig");
pub fn btoa(_: *const WorkerGlobalScope, input: base64.BinInput, exec: *JS.Execution) ![]const u8 {
    return base64.encode(exec.call_arena, input);
}

pub fn atob(_: *const WorkerGlobalScope, input: base64.BinInput, exec: *JS.Execution) !JS.String.OneByte {
    const bytes = try base64.decode(exec.call_arena, input);
    return .{ .bytes = bytes };
}

pub fn structuredClone(
    _: *const WorkerGlobalScope,
    value: JS.Value,
    options: ?JS.Value,
    exec: *JS.Execution,
) !JS.Value {
    // The serializer has already installed the operation-scoped
    // DataCloneError; do not replace it with a generic host error.
    return value.structuredCloneWithOptions(options, exec) catch error.TryCatchRethrow;
}

pub fn getCrossOriginIsolated(_: *const WorkerGlobalScope) bool {
    // COOP+COEP agent-cluster enablement is not implemented yet. This must
    // still be an observable false boolean, not an absent global binding.
    return false;
}

pub fn unhandledPromiseRejection(self: *WorkerGlobalScope, no_handler: bool, rejection: JS.PromiseRejection) !void {
    if (comptime IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "worker",
            .value = rejection.reason(),
            .stack = rejection.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    }

    const event_name, const attribute_callback = blk: {
        if (no_handler) {
            break :blk .{ "unhandledrejection", self._on_unhandled_rejection };
        }
        break :blk .{ "rejectionhandled", self._on_rejection_handled };
    };

    const target = self.asEventTarget();
    if (self._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .cancelable = no_handler,
            .reason = if (rejection.reason()) |r| try r.persist() else null,
            .promise = try rejection.promise().persist(),
        }, self._page)).asEvent();
        event.setTrusted();
        try self.dispatch(target, event, attribute_callback, .{});
    }
}

pub fn importScripts(self: *WorkerGlobalScope, urls: []const [:0]const u8) !void {
    if (self._is_module) {
        // not allowed to be called when the worker type is module (scripts should
        // use actual imports).
        return error.TypeError;
    }

    const session = self._session;
    const arena = try session.getArena(.large, "importScript");
    defer session.releaseArena(arena);

    for (urls) |url| {
        defer session.arena_pool.resetRetain(arena);
        try self.importScript(arena, url);
    }
}

fn importScript(self: *WorkerGlobalScope, arena: Allocator, url: [:0]const u8) !void {
    const session = self._session;

    const resolved_url = try URL.resolve(arena, self.url, url, .{});

    const http_client = self._http_client;

    const headers = try http_client.newRequestHeaders(resolved_url, .{
        .destination = .script,
        .mode = .no_cors,
        .initiator_url = self.url,
        .top_level_url = self._creator_url,
        .referrer_url = self._creator_url,
        .credentials = .include,
    });

    const response = http_client.syncRequest(arena, .{
        .url = resolved_url,
        .method = .GET,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .root_frame_id = self._root_frame_id,
        .initiator_context = .worker,
        .headers = headers,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = self.url,
        .resource_type = .script,
        .notification = session.notification,
        .resource_timing = self.performance().resourceTimingSink(&self.js.execution, .script),
    }) catch |err| {
        log.warn(.http, "importScript", .{ .url = resolved_url, .err = err });
        return error.NetworkError;
    };

    if (response.status != 200) {
        log.warn(.http, "importScript", .{ .url = resolved_url, .status = response.status });
        return error.NetworkError;
    }

    defer http_client.deferring_layer.flushFrame(self._frame_id);

    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: JS.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = ls.local.eval(response.body.items, url) catch |err| {
        const caught = try_catch.caughtOrError(arena, err);
        log.err(.browser, "importScript", .{ .url = resolved_url, .caught = caught });
        return;
    };

    ls.local.runMacrotasks();
}

pub fn reportError(self: *WorkerGlobalScope, err: JS.Value) !void {
    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = try err.persist(),
        .message = err.toStringSlice() catch "Unknown error",
        .bubbles = false,
        .cancelable = true,
    }, self._page);

    // Invoke onerror callback if set (per WHATWG spec, this is called
    // with 5 arguments: message, source, lineno, colno, error)
    // If it returns true, the event is cancelled.
    var prevent_default = false;
    if (self._on_error) |on_error| {
        var ls: JS.Local.Scope = undefined;
        self.js.localScope(&ls);
        defer ls.deinit();

        const local_func = ls.toLocal(on_error);
        const result = local_func.call(JS.Value, .{
            error_event._message,
            error_event._filename,
            error_event._line_number,
            error_event._column_number,
            err,
        }) catch null;

        // Per spec: returning true from onerror cancels the event
        if (result) |r| {
            prevent_default = r.isTrue();
        }
    }

    const event = error_event.asEvent();
    event._prevent_default = prevent_default;
    // Pass null as handler: onerror was already called above with 5 args.
    // We still dispatch so that addEventListener('error', ...) listeners fire.
    try self.dispatch(self.asEventTarget(), event, null, .{});

    if (comptime builtin.is_test == false) {
        if (!event._prevent_default) {
            log.warn(.js, "worker.reportError", .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
}

pub fn fetch(_: *const WorkerGlobalScope, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const JS.Execution) !JS.Promise {
    return Fetch.init(input, options, exec);
}

pub fn queueMicrotask(self: *WorkerGlobalScope, cb: JS.Function) void {
    self.js.queueMicrotaskFunc(cb);
}

pub fn setTimeout(self: *WorkerGlobalScope, raw_handler: ?JS.Value, raw_delay: ?JS.Value, params: []JS.Value.Global, exec: *JS.Execution) !u32 {
    var params_owned = true;
    errdefer if (params_owned) for (params) |param| param.release();
    const operation: JS.WebIDL.Operation = .{ .interface = "WorkerGlobalScope", .name = "setTimeout" };
    var handler = try Timers.convertHandler(raw_handler, exec, operation);
    var handler_owned = true;
    errdefer if (handler_owned) handler.release();
    const delay_ms = try Timers.convertDelay(raw_delay, exec, operation);
    try handler.applyTrustedTypes(self.js, self.getTrustedTypes(), exec, operation);
    const schedule_params: []JS.Value.Global = switch (handler) {
        .function => params,
        .string => blk: {
            for (params) |param| param.release();
            params_owned = false;
            if (!try handler.shouldSchedule(self.js)) {
                handler_owned = false;
                return 0;
            }
            break :blk &.{};
        },
    };
    const cb = try handler.resolve(exec);
    handler_owned = false;
    var cb_owned = true;
    errdefer if (cb_owned) cb.release();
    cb_owned = false;
    params_owned = false;
    return self._timers.schedule(exec, cb, delay_ms, .{
        .repeat = false,
        .params = schedule_params,
        .name = "worker.setTimeout",
    });
}

pub fn clearTimeout(self: *WorkerGlobalScope, id: u32) void {
    self._timers.clear(id);
}

pub fn setInterval(self: *WorkerGlobalScope, raw_handler: ?JS.Value, raw_delay: ?JS.Value, params: []JS.Value.Global, exec: *JS.Execution) !u32 {
    var params_owned = true;
    errdefer if (params_owned) for (params) |param| param.release();
    const operation: JS.WebIDL.Operation = .{ .interface = "WorkerGlobalScope", .name = "setInterval" };
    var handler = try Timers.convertHandler(raw_handler, exec, operation);
    var handler_owned = true;
    errdefer if (handler_owned) handler.release();
    const delay_ms = try Timers.convertDelay(raw_delay, exec, operation);
    try handler.applyTrustedTypes(self.js, self.getTrustedTypes(), exec, operation);
    const schedule_params: []JS.Value.Global = switch (handler) {
        .function => params,
        .string => blk: {
            for (params) |param| param.release();
            params_owned = false;
            if (!try handler.shouldSchedule(self.js)) {
                handler_owned = false;
                return 0;
            }
            break :blk &.{};
        },
    };
    const cb = try handler.resolve(exec);
    handler_owned = false;
    var cb_owned = true;
    errdefer if (cb_owned) cb.release();
    cb_owned = false;
    params_owned = false;
    return self._timers.schedule(exec, cb, delay_ms, .{
        .repeat = true,
        .params = schedule_params,
        .name = "worker.setInterval",
    });
}

pub fn clearInterval(self: *WorkerGlobalScope, id: u32) void {
    self._timers.clear(id);
}

pub fn getIndexedDB(self: *WorkerGlobalScope, exec: *JS.Execution) !*idb.IDBFactory {
    if (self._idb_factory) |f| {
        return f;
    }
    const f = try exec._factory.create(try idb.IDBFactory.init(exec, self._storage_origin_key));
    self._idb_factory = f;
    return f;
}

// Some properties are readonly but [Replaceable]. They get assigned as own
// data properties on the underlying v8::object that represents the global (the
// WorkerGlobalScope)
fn replaceGlobalProperty(self: *WorkerGlobalScope, value: JS.Value, comptime name: []const u8) void {
    const global = self.js.globalObject(value.local);
    _ = global.defineOwnProperty(name, value, 0);
}

pub const FunctionSetter = union(enum) {
    func: JS.Function.Global,
    anything: JS.Value,
};

pub fn getFunctionFromSetter(setter_: ?FunctionSetter) ?JS.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

pub const JsApi = struct {
    pub const bridge = JS.Bridge(WorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "WorkerGlobalScope";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const console = bridge.accessor(WorkerGlobalScope.getConsole, WorkerGlobalScope.setConsole, .{});
    pub const crypto = bridge.accessor(WorkerGlobalScope.getCrypto, null, .{});
    pub const trustedTypes = bridge.accessor(WorkerGlobalScope.getTrustedTypes, null, .{});
    pub const navigator = bridge.accessor(WorkerGlobalScope.getNavigator, null, .{});
    pub const performance = bridge.accessor(struct {
        // Unnecessary, But, our WebAPI getters are ALWAYS `fn getPerformance()...`.
        // But for performance, we _need_ to have fn performance() *Performance to
        // have parity with frame. So rather than having method called `performance`
        // and one called `getPerformance`, we create this wrapper here.
        pub fn wrap(wgs: *WorkerGlobalScope) *Performance {
            return wgs.performance();
        }
    }.wrap, null, .{});
    pub const self = bridge.accessor(WorkerGlobalScope.getSelf, WorkerGlobalScope.setSelf, .{});
    pub const location = bridge.accessor(WorkerGlobalScope.getLocation, null, .{});
    pub const cookieStore = bridge.accessor(WorkerGlobalScope.getCookieStore, null, .{});
    pub const indexedDB = bridge.accessor(WorkerGlobalScope.getIndexedDB, null, .{});

    pub const onerror = bridge.accessor(WorkerGlobalScope.getOnError, WorkerGlobalScope.setOnError, .{});
    pub const onrejectionhandled = bridge.accessor(WorkerGlobalScope.getOnRejectionHandled, WorkerGlobalScope.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(WorkerGlobalScope.getOnUnhandledRejection, WorkerGlobalScope.setOnUnhandledRejection, .{});

    pub const btoa = bridge.function(WorkerGlobalScope.btoa, .{});
    pub const atob = bridge.function(WorkerGlobalScope.atob, .{});
    pub const structuredClone = bridge.function(WorkerGlobalScope.structuredClone, .{});
    pub const reportError = bridge.function(WorkerGlobalScope.reportError, .{});
    pub const fetch = bridge.function(WorkerGlobalScope.fetch, .{});
    pub const importScripts = bridge.function(WorkerGlobalScope.importScripts, .{ .variadic = true });
    pub const queueMicrotask = bridge.function(WorkerGlobalScope.queueMicrotask, .{});
    pub const setTimeout = bridge.function(WorkerGlobalScope.setTimeout, .{ .arity = 1, .required_args = 1, .variadic = true });
    pub const clearTimeout = bridge.function(WorkerGlobalScope.clearTimeout, .{});
    pub const setInterval = bridge.function(WorkerGlobalScope.setInterval, .{ .arity = 1, .required_args = 1, .variadic = true });
    pub const clearInterval = bridge.function(WorkerGlobalScope.clearInterval, .{});

    pub const isSecureContext = bridge.accessor(WorkerGlobalScope.getIsSecureContext, null, .{});
    pub const crossOriginIsolated = bridge.accessor(WorkerGlobalScope.getCrossOriginIsolated, null, .{});
};
