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

const js = @import("../js/js.zig");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const HttpClient = @import("../HttpClient.zig");

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const BroadcastChannel = @import("BroadcastChannel.zig");
const DOMException = @import("DOMException.zig");
const TrustedTypes = @import("TrustedTypes.zig");
const DedicatedWorkerGlobalScope = @import("DedicatedWorkerGlobalScope.zig");
const DedicatedWorkerRuntime = @import("../worker_runtime/DedicatedWorkerRuntime.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Worker = @This();

pub const WorkerType = enum {
    classic,
    module,
    pub const js_enum_from_string = true;
};

pub const WorkerCredentials = enum {
    omit,
    @"same-origin",
    include,
    pub const js_enum_from_string = true;
};

// used by HttpClient when generating notification
// Ultimately used by CDP to generate request/loader ids.
_frame_id: u32,
_loader_id: u32,
// Immutable FFI Page attribution copied before the Worker owner thread starts.
_root_frame_id: u32,

_proto: *EventTarget,
_frame: *Frame,
_arena: Allocator,
_worker_arena: Allocator,
_worker_scope: ?*DedicatedWorkerGlobalScope = null,
_runtime: ?DedicatedWorkerRuntime = null,

_url: [:0]const u8,
_type: WorkerType = .classic,
_creator_secure_context: bool,
_creator_origin_key: []const u8,
_creator_origin: ?[]const u8,
// IndexedDB/DOM-storage identity is frozen independently from the effective
// scripting origin because document.domain may mutate the latter.
_creator_storage_origin_key: ?[]const u8,
_creator_url: [:0]const u8,
_creator_referer_header: []const u8,
_creator_site_for_cookies: HttpClient.SiteForCookies,
_script_loaded: bool = false,
_script_buffer: std.ArrayList(u8) = .empty,
_http_response: ?HttpClient.Response = null,
_entry_pending: bool = false,
// Final entry-response URL. Redirect processing owns the authoritative URL;
// policy-container selection must not be based on the originally requested
// URL because Blink makes the local-vs-network decision after fetch.
_response_url: ?[:0]const u8 = null,
_response_csp: std.ArrayList([]const u8) = .empty,
_response_csp_report_only: std.ArrayList([]const u8) = .empty,
_terminated: bool = false,

// Event handlers
_on_error: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_on_messageerror: ?js.Function.Global = null,

const WorkerOptions = struct {
    type: WorkerType = .classic,
    credentials: WorkerCredentials = .@"same-origin",
};

const EntryRequestPolicy = struct {
    mode: HttpClient.HeaderRequestContext.Mode,
    credentials: HttpClient.RequestContext.Credentials,

    fn sendsCookies(self: EntryRequestPolicy) bool {
        return self.credentials != .omit;
    }
};

/// HTML fixes classic worker entry credentials to `same-origin`. Module
/// workers use WorkerOptions.credentials, whose default is also
/// `same-origin`. Both entry fetches are same-origin fetches; CORS applies to
/// module-graph descendants, not to the top-level dedicated-worker script.
fn entryRequestPolicy(worker_type: WorkerType, requested: WorkerCredentials) EntryRequestPolicy {
    return .{
        .mode = .same_origin,
        .credentials = if (worker_type == .classic) .same_origin else switch (requested) {
            .omit => .omit,
            .@"same-origin" => .same_origin,
            .include => .include,
        },
    };
}

pub fn init(raw_url: js.Value, raw_options: ?js.Value, frame: *Frame) !*Worker {
    if (frame.isRetired()) {
        const local = frame.js.local orelse return error.InvalidAccessError;
        const exception = try local.zigValueToJs(
            DOMException.init(
                "Failed to construct 'Worker': The context provided is invalid.",
                "InvalidAccessError",
            ),
            .{},
        );
        _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
        _ = local.isolate.throwException(exception.handle);
        return error.TryCatchRethrow;
    }

    // Keep both visible arguments raw until this point. Converting the URL to
    // []const u8 in the bridge would erase a genuine TrustedScriptURL brand;
    // converting WorkerOptions there would also run author dictionary getters
    // before the first argument's Web IDL/Trusted Types conversion.
    const compliant_url = try TrustedTypes.getCompliantString(
        raw_url,
        frame.js,
        frame.window.getTrustedTypes(),
        .script_url,
        "Worker",
        "constructor",
        .{ .constructor = "Worker" },
        .usv_string,
        &frame.js.execution,
    );
    const url = try compliant_url.toSlice();
    const worker_options: WorkerOptions = if (raw_options) |value|
        (try frame.js.local.?.jsValueToZigWithContext(
            ?WorkerOptions,
            value,
            .{ .constructor = "Worker" },
        )) orelse .{}
    else
        .{};

    const session = frame._session;

    const arena = try session.getArena(.large, "Worker");
    errdefer session.releaseArena(arena);

    // The creator and owner threads must never allocate from the same Arena.
    const worker_arena = try session.getArena(.large, "DedicatedWorker.owner");
    errdefer session.releaseArena(worker_arena);

    const resolved_url = try URL.resolve(arena, frame.base(), url, .{ .encoding = frame.charset });
    const worker_type = worker_options.type;
    const entry_policy = entryRequestPolicy(worker_type, worker_options.credentials);
    const creator_url = try worker_arena.dupeZ(u8, frame.url);
    const creator_origin = if (frame.origin) |origin|
        try worker_arena.dupe(u8, origin)
    else
        null;
    const creator_storage_origin_key: ?[]const u8 = switch (frame.requestOrigin()) {
        .tuple => try worker_arena.dupe(u8, frame.document._storage_origin_key),
        else => null,
    };
    const creator_site_for_cookies = try frame.snapshotSiteForCookies(worker_arena);
    // Frame.headersForRequest lazily writes its referer cache. Snapshot the
    // exact current header while still on the creator thread so worker-owned
    // requests never read or mutate the creator Frame.
    const creator_referer_header = if (std.mem.startsWith(u8, frame.url, "http"))
        try std.mem.concat(worker_arena, u8, &.{ "Referer: ", frame.url })
    else
        "";

    // Blink's AbstractWorker::ResolveURL performs this access check before a
    // DedicatedWorker object is returned or any loader/owner thread is
    // started. Treating RequestMode.same_origin as sufficient would make the
    // failure asynchronous and, more importantly, would expose a live Worker
    // for a script which the creator is forbidden to read.
    try enforceWorkerScriptOrigin(resolved_url, frame);

    const self = try frame._page.factory.eventTargetWithAllocator(arena, Worker{
        ._arena = arena,
        ._worker_arena = worker_arena,
        ._proto = undefined,
        ._frame = frame,
        ._url = resolved_url,
        ._type = worker_type,
        ._creator_secure_context = frame.isSecureContext(),
        ._worker_scope = null,
        ._creator_origin_key = try worker_arena.dupe(u8, frame.js.origin.key),
        ._creator_origin = creator_origin,
        ._creator_storage_origin_key = creator_storage_origin_key,
        ._creator_url = creator_url,
        ._creator_referer_header = creator_referer_header,
        ._creator_site_for_cookies = creator_site_for_cookies,
        ._frame_id = session.nextFrameId(),
        ._loader_id = session.nextLoaderId(),
        ._root_frame_id = frame._page.frame._frame_id,
    });
    // Worker loading disabled by the browser configuration:
    // skip the script fetch and eval. The Worker object is still
    // constructed so JS `new Worker(url)` does not throw, but the
    // worker's eval never runs (postMessage from the page is queued
    // indefinitely with no handler to drain it). Mirrors the
    // `subframe_loading_enabled` pattern for iframes.
    if (!session.worker_loading_enabled) {
        log.debug(.browser, "worker disabled", .{ .url = resolved_url });
        try frame.trackWorker(self);
        return self;
    }

    // Cross-thread creator deliveries target the creator Context's retained
    // Browser mailbox handle. Frame retirement closes that target before any
    // Worker arena can be reclaimed, so late tokens are cancelled without
    // dereferencing this Worker or entering a stale V8 realm.
    const creator_sender = try frame.js.ownerSender();
    self._runtime = DedicatedWorkerRuntime.init(
        frame._page.session.browser.app,
        &session.browser.http_client,
        creator_sender,
        self,
        runtime_callbacks,
    );
    errdefer {
        self._runtime.?.deinit();
        self._runtime = null;
    }
    try self._runtime.?.start();
    try frame.trackWorker(self);

    const headers = try session.browser.http_client.newRequestHeaders(resolved_url, .{
        .destination = .worker,
        .mode = entry_policy.mode,
        .request_origin = frame.requestOrigin(),
        .initiator_url = frame.url,
        .top_level_url = frame.url,
        .referrer_url = frame.outgoingReferrerUrl(),
        .credentials = entry_policy.credentials,
    });
    self._entry_pending = true;
    frame.makeRequest(.{
        .ctx = self,
        .method = .GET,
        .headers = headers,
        .url = resolved_url,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .root_frame_id = self._root_frame_id,
        .resource_type = .script,
        .cookie_jar = if (entry_policy.sendsCookies()) &session.cookie_jar else null,
        .cookie_origin = frame.url,
        .request_origin = frame.requestOrigin(),
        .site_for_cookies = creator_site_for_cookies,
        .notification = session.notification,
        .header_callback = httpHeaderCallback,
        .data_callback = httpDataCallback,
        .done_callback = httpDoneCallback,
        .error_callback = httpErrorCallback,
        .shutdown_callback = httpShutdownCallback,
    }) catch |err| {
        self._entry_pending = false;
        log.err(.browser, "Worker request", .{ .url = resolved_url, .err = err });
        frame.removeWorker(self);
        return err;
    };
    return self;
}

fn enforceWorkerScriptOrigin(resolved_url: [:0]const u8, frame: *Frame) !void {
    // URL.getOrigin deliberately returns null for local/inheriting schemes.
    // blob:/data: worker access is decided by their creator/registry rules;
    // this tuple-origin gate covers the synchronous HTTP(S) boundary without
    // accidentally rejecting same-origin blob workers.
    if ((try URL.getOrigin(frame.local_arena, resolved_url)) == null) return;
    const creator_request_origin = frame.requestOrigin();
    if (try HttpClient.requestOriginIsSameOrigin(
        frame.local_arena,
        creator_request_origin,
        resolved_url,
    )) return;
    const serialized_creator_origin = switch (creator_request_origin) {
        .tuple => |origin| origin,
        else => "null",
    };

    const message = try std.fmt.allocPrint(
        frame.arena,
        "Failed to construct 'Worker': Script at '{s}' cannot be accessed from origin '{s}'.",
        .{ resolved_url, serialized_creator_origin },
    );
    const local = frame.js.local orelse return error.SecurityError;
    const exception = try local.zigValueToJs(DOMException.init(message, "SecurityError"), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

fn workerURLInheritsCreatorPolicy(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "about:") or
        std.ascii.startsWithIgnoreCase(url, "data:") or
        std.ascii.startsWithIgnoreCase(url, "blob:") or
        std.ascii.startsWithIgnoreCase(url, "filesystem:");
}

const runtime_callbacks: DedicatedWorkerRuntime.Callbacks = .{
    .bootstrap = runtimeBootstrap,
    .load_script = runtimeLoadScript,
    .receive_message = runtimeReceiveMessage,
    .receive_broadcast = runtimeReceiveBroadcast,
    .drain_creator = runtimeDrainCreator,
    .teardown = runtimeTeardown,
};

fn runtimeDrainCreator(raw: *anyopaque) !void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    try self.drainOutbound();
}

fn runtimeBootstrap(raw: *anyopaque, runtime: *DedicatedWorkerRuntime) !void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    const scope = try DedicatedWorkerGlobalScope.init(.{
        .arena = self._worker_arena,
        .url = self._url,
        .is_module = self._type == .module,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .root_frame_id = self._root_frame_id,
        .frame = self._frame,
        .creator_secure_context = self._creator_secure_context,
        .creator_origin_key = self._creator_origin_key,
        .creator_origin = self._creator_origin,
        .creator_storage_origin_key = self._creator_storage_origin_key,
        .creator_url = self._creator_url,
        .creator_referer_header = self._creator_referer_header,
        .creator_site_for_cookies = self._creator_site_for_cookies,
        .env = &runtime.env.?,
        .http_client = &runtime.http_client,
        .owner_mailbox = runtime.ownerMailbox(),
        .owner = .{
            .context = self,
            .post_message = runtimePostMessageToCreator,
            .post_broadcast = runtimePostBroadcastToCreator,
            .close = runtimeOwnerClose,
        },
    });
    errdefer scope.deinit();
    self._worker_scope = scope;
}

fn runtimeLoadScript(
    raw: *anyopaque,
    runtime: *DedicatedWorkerRuntime,
    entry: DedicatedWorkerRuntime.EntryScript,
) !void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    const context = self._worker_scope.?._proto.js;
    for (entry.policies) |policy| {
        switch (policy.disposition) {
            .enforce => try context.addContentSecurityPolicy(policy.serialized),
            .report_only => try context.addContentSecurityPolicyReportOnly(policy.serialized),
        }
    }
    try self.loadInitialScript(runtime, entry.source);
}

fn runtimeReceiveMessage(raw: *anyopaque, _: *DedicatedWorkerRuntime, message: *const js.Value.SerializedMessage) !void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    try self._worker_scope.?.receiveSerializedMessage(message);
}

fn runtimeReceiveBroadcast(raw: *anyopaque, _: *DedicatedWorkerRuntime, message: *js.Value.BroadcastMessage) !void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    const scope = self._worker_scope orelse return;
    try BroadcastChannel.deliverToExecution(&scope._proto.js.execution, message, null);
}

fn runtimePostMessageToCreator(raw: *anyopaque, data: js.Value) !void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    var message = data.serializeForMessageWithContext(
        std.heap.page_allocator,
        "Failed to execute 'postMessage' on 'DedicatedWorkerGlobalScope': ",
    ) catch |err| switch (err) {
        error.JsException => return error.TryCatchRethrow,
        else => return err,
    };
    errdefer message.deinit();
    try self._runtime.?.postMessageToCreator(message);
}

fn runtimePostBroadcastToCreator(raw: *anyopaque, message: *js.Value.BroadcastMessage) !void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    try self._runtime.?.postBroadcastToCreator(message);
}

fn runtimeOwnerClose(raw: *anyopaque) void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    self._runtime.?.requestOwnerClose();
}

fn runtimeTeardown(raw: *anyopaque, _: *DedicatedWorkerRuntime) void {
    const self: *Worker = @ptrCast(@alignCast(raw));
    if (self._worker_scope) |scope| {
        scope.deinit();
        self._worker_scope = null;
    }
}

// Called from Frame.deinit when the frame is destroyed, so we don't need to
// remove from the frame's worker list.
pub fn deinit(self: *Worker) void {
    // No pending frame for workers, so we can abort all frames.
    if (self._http_response) |res| {
        res.abort(error.Abort);
        self._http_response = null;
    }
    if (self._runtime) |*runtime| {
        runtime.deinit();
        self._runtime = null;
    }
    self._frame._session.releaseArena(self._worker_arena);
    self._frame._session.releaseArena(self._arena);
}

pub fn asEventTarget(self: *Worker) *EventTarget {
    return self._proto;
}

fn httpHeaderCallback(response: HttpClient.Response) !HttpClient.HeaderResult {
    const self: *Worker = @ptrCast(@alignCast(response.ctx));

    const status = response.status() orelse return .abort;
    if (status < 200 or status >= 300) {
        log.warn(.browser, "Worker status", .{
            .url = self._url,
            .status = status,
        });
        return .abort;
    }

    // Response.url() follows redirects and is therefore the same URL Blink
    // consults when selecting the Worker policy container. Keep an immutable
    // creator-arena copy: the Response/Transfer is gone before the snapshot is
    // published to the owner thread.
    self._response_url = try self._arena.dupeZ(u8, response.url());

    // A worker's entry response establishes its own enforced CSP before the
    // script is evaluated. Imported scripts do not replace that policy.
    var headers = response.headerIterator();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Content-Security-Policy")) {
            try self._response_csp.append(
                self._arena,
                try self._arena.dupe(u8, header.value),
            );
        } else if (std.ascii.eqlIgnoreCase(
            header.name,
            "Content-Security-Policy-Report-Only",
        )) {
            try self._response_csp_report_only.append(
                self._arena,
                try self._arena.dupe(u8, header.value),
            );
        }
    }

    self._http_response = response;
    if (response.contentLength()) |cl| {
        try self._script_buffer.ensureTotalCapacity(self._arena, cl);
    }

    return .proceed;
}

fn httpDataCallback(response: HttpClient.Response, data: []const u8) !void {
    const self: *Worker = @ptrCast(@alignCast(response.ctx));
    try self._script_buffer.appendSlice(self._arena, data);
}

fn httpDoneCallback(ctx: *anyopaque) !void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_response = null;
    self._entry_pending = false;

    // Worker.terminate() may win before the entry response reaches its done
    // callback (blob:/data: responses are deliberately delivered on the next
    // host tick). Chromium keeps an AskedToTerminate gate between that late
    // completion and StartWorkerGlobalScope; completion after the gate is a
    // silent no-op, not a script-fetch failure on the creator Worker object.
    if (self._terminated) return;

    const url = self._url;
    const entry = try self.snapshotEntryScript();

    if (comptime IS_DEBUG) {
        log.info(.browser, "worker fetch done", .{
            .url = url,
            .len = entry.source.len,
        });
    }

    if (self._runtime) |*runtime| {
        try runtime.enqueueScript(entry);
    }
}

/// Freeze the policy container at the entry-response completion boundary.
/// Local-scheme workers clone the creator's then-current container; network
/// workers use only the final entry response's CSP/CSPRO headers. These paths
/// replace one another rather than merge. Strings and the descriptor slice
/// live in the creator-owned Worker arena and become immutable before
/// enqueueScript publishes them.
fn snapshotEntryScript(self: *Worker) !DedicatedWorkerRuntime.EntryScript {
    var policies: std.ArrayList(DedicatedWorkerRuntime.ContentSecurityPolicy) = .empty;
    errdefer policies.deinit(self._arena);

    const final_url = self._response_url orelse self._url;
    if (workerURLInheritsCreatorPolicy(final_url)) {
        // CSPTrustedTypes retains every serialized policy, including policies
        // without TT directives. Replaying this list rebuilds both the legacy
        // code-generation projection and TT state exactly once. Adding the
        // projection separately would duplicate each enforced policy.
        for (self._frame.js.csp_trusted_types.policies.items) |policy| {
            try policies.append(self._arena, .{
                .serialized = try self._arena.dupe(u8, policy.serialized),
                .disposition = switch (policy.disposition) {
                    .enforce => .enforce,
                    .report_only => .report_only,
                },
            });
        }
    } else {
        for (self._response_csp.items) |policy| {
            try policies.append(self._arena, .{
                .serialized = policy,
                .disposition = .enforce,
            });
        }
        for (self._response_csp_report_only.items) |policy| {
            try policies.append(self._arena, .{
                .serialized = policy,
                .disposition = .report_only,
            });
        }
    }

    return .{
        .source = self._script_buffer.items,
        .policies = try policies.toOwnedSlice(self._arena),
    };
}

// Frame.abortOwner destroys the transfer before Worker.deinit runs.  Clear the
// transfer-backed Response without dispatching an error event so deinit cannot
// call abort through a stale pointer.
fn httpShutdownCallback(ctx: *anyopaque) void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_response = null;
    self._entry_pending = false;
}

fn loadInitialScript(
    self: *Worker,
    runtime: *DedicatedWorkerRuntime,
    script: []const u8,
) !void {
    const js_context = self._worker_scope.?._proto.js;

    if (js_context.env.terminatePending()) {
        return;
    }

    // Keep buffering throughout the entire outer eval (including any
    // runMacrotasks pumped by importScripts via the synchronous CDP path,
    // see WorkerGlobalScope.importScripts). The flip-and-drain happens
    // via defer so it runs after eval AND after the trailing
    // runMacrotasks below — by which point the outer script has had its
    // only chance to register onmessage. drainPendingMessages enqueues
    // messages in receive order, so pre-eval and during-eval messages
    // are delivered FIFO on the next runner tick, matching the spec.
    //
    // On eval-throw the defer still fires; the messages get scheduled
    // and then drop at the "no listener" check, mirroring the
    // httpErrorCallback path.
    defer {
        self._script_loaded = true;
        self._worker_scope.?.drainPendingMessages();
    }

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // Classic workers evaluate the entry script as a classic script; module
    // workers (`new Worker(url, { type: "module" })`) instantiate it as a
    // module so top-level `import`/`export` work. Static imports load
    // synchronously through ScriptManagerBase (client.tick sync_wait).
    switch (self._type) {
        .classic => _ = ls.local.eval(script, self._url) catch |err| {
            if (js_context.env.terminatePending()) {
                return;
            }

            const report = self.captureOwnerThreadError(&try_catch, err);
            log.err(.browser, "worker script error", .{
                .url = report.filename,
                .message = report.message,
                .line = report.lineno,
                .column = report.colno,
            });
            runtime.postError(report.message, report.filename, report.lineno, report.colno);
            return;
        },
        .module => {
            var module_error: ?js.Context.ModuleErrorReport = null;
            js_context.moduleWithErrorReport(
                false,
                &ls.local,
                script,
                self._url,
                true,
                self._worker_arena,
                &module_error,
            ) catch |err| {
                if (js_context.env.terminatePending()) {
                    return;
                }

                const report: OwnerThreadError = if (module_error) |captured| .{
                    .message = captured.message,
                    .filename = captured.filename,
                    .lineno = captured.lineno,
                    .colno = captured.colno,
                } else self.captureOwnerThreadError(&try_catch, err);
                log.err(.browser, "worker module error", .{
                    .url = report.filename,
                    .message = report.message,
                    .line = report.lineno,
                    .column = report.colno,
                });
                runtime.postError(report.message, report.filename, report.lineno, report.colno);
                return;
            };
        },
    }

    ls.local.runMacrotasks();
}

const OwnerThreadError = struct {
    message: []const u8,
    filename: []const u8,
    lineno: u32,
    colno: u32,
};

/// Read V8's Message only while its worker-owned HandleScope is active and
/// reduce it to plain bytes/numbers for DedicatedWorkerRuntime's mailbox.
/// In particular, never persist the thrown value: a Global from this isolate
/// cannot be consumed by the creator Window isolate.
fn captureOwnerThreadError(
    self: *Worker,
    try_catch: *js.TryCatch,
    err: anyerror,
) OwnerThreadError {
    const arena = self._worker_arena;
    var filename: []const u8 = self._worker_scope.?._proto.url;
    var lineno: u32 = 0;
    var colno: u32 = 0;

    if (js.v8.v8__TryCatch__Message(&try_catch.handle)) |v8_message| {
        if (js.v8.v8__Message__GetScriptResourceName(v8_message)) |resource_handle| {
            const resource = js.Value{
                .local = try_catch.local,
                .handle = resource_handle,
            };
            if (resource.isString()) |resource_string| {
                filename = resource_string.toSliceWithAlloc(arena) catch filename;
            }
        }

        const line_number = js.v8.v8__Message__GetLineNumber(v8_message, try_catch.local.handle);
        if (line_number >= 0) lineno = @intCast(line_number);

        // v8::Message columns are zero-based; ErrorEvent.colno is one-based.
        const start_column = js.v8.v8__Message__GetStartColumn(v8_message);
        if (start_column >= 0) colno = @intCast(start_column + 1);
    }

    var message = try_catch.messageText(arena) orelse @errorName(err);

    // Blink/V8 reports a non-native thrown object by applying the ordinary
    // ToString operation to the value. This may invoke a user-defined
    // `toString`, but must not probe arbitrary `message` or `stack` getters.
    // A nested TryCatch contains an author toString that itself throws and
    // leaves the original V8 Message as the fallback.
    if (try_catch.exceptionValue()) |exception| {
        if (exception.isObject() and !exception.isNativeError()) {
            var stringify_try_catch: js.TryCatch = undefined;
            stringify_try_catch.init(try_catch.local);
            defer stringify_try_catch.deinit();

            if (exception.toStringSliceWithAlloc(arena)) |rendered| {
                message = std.fmt.allocPrint(arena, "Uncaught {s}", .{rendered}) catch message;
            } else |_| {}
        }
    }

    return .{
        .message = message,
        .filename = filename,
        .lineno = lineno,
        .colno = colno,
    };
}

fn httpErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const self: *Worker = @ptrCast(@alignCast(ctx));
    self._http_response = null;
    self._entry_pending = false;

    // Termination is not a worker-script fetch failure. This also covers the
    // synchronous error callback produced when terminate() aborts a response
    // after headers have arrived: publish the terminated state first, then
    // let that re-entrant callback perform only the state cleanup above.
    if (self._terminated) return;

    log.err(.browser, "worker fetch error", .{
        .url = self._url,
        .err = err,
    });

    // The worker will never load and onmessage will never be registered.
    // Drain any buffered messages so they get dispatched (and silently
    // dropped at the "no listener" check) rather than accumulating until
    // worker teardown. Future postMessages then schedule normally.
    self._script_loaded = true;
    if (self._runtime) |*runtime| {
        runtime.enqueueScript(.{ .source = "" }) catch {};
    }

    self.fireErrorEvent(.{
        .message = @errorName(err),
        .filename = self._url,
    }, null);
}

const CreatorErrorReport = struct {
    message: []const u8,
    filename: []const u8,
    lineno: u32 = 0,
    colno: u32 = 0,
};

// Fire an error event on the Worker object (parent context)
fn fireErrorEvent(self: *Worker, report: CreatorErrorReport, error_value: ?js.Value.Global) void {
    self._fireErrorEvent(report, error_value) catch |err| {
        log.warn(.browser, "worker fire error", .{ .err = err, .message = report.message });
    };
}

fn _fireErrorEvent(self: *Worker, report: CreatorErrorReport, error_value: ?js.Value.Global) !void {
    const frame = self._frame;
    const target = self.asEventTarget();
    const on_error = self._on_error;

    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = error_value,
        .message = report.message,
        .filename = report.filename,
        .lineno = report.lineno,
        .colno = report.colno,
        .bubbles = false,
        .cancelable = true,
    }, frame._page);

    try frame._event_manager.dispatchDirect(target, error_event.asEvent(), on_error, .{
        .context = "Worker.onerror",
    });

    // HTML propagates an uncancelled dedicated-worker exception to the
    // creator's error-reporting path. It must not be dropped merely because
    // the Worker object has no direct listener. Queue the parent dispatch so
    // it runs as a creator-realm task after this Worker dispatch unwinds.
    if (!error_event.asEvent().getDefaultPrevented()) {
        try scheduleParentError(frame, report);
    }
}

fn scheduleParentError(frame: *Frame, report: CreatorErrorReport) !void {
    if (frame.isRetired()) return;

    const arena = try frame.getArena(.tiny, "Worker.parentError");
    errdefer frame.releaseArena(arena);
    const callback = try arena.create(ParentErrorCallback);
    callback.* = .{
        .frame = frame,
        .arena = arena,
        .report = .{
            .message = try arena.dupe(u8, report.message),
            .filename = try arena.dupe(u8, report.filename),
            .lineno = report.lineno,
            .colno = report.colno,
        },
    };
    try frame.js.scheduler.add(callback, ParentErrorCallback.run, 0, .{
        .name = "Worker.propagateError",
        .low_priority = false,
        .finalizer = ParentErrorCallback.cancelled,
    });
}

const ParentErrorCallback = struct {
    frame: *Frame,
    arena: Allocator,
    report: CreatorErrorReport,

    fn deinit(self: *ParentErrorCallback) void {
        self.frame.releaseArena(self.arena);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *ParentErrorCallback = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ParentErrorCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const frame = self.frame;
        if (frame.isRetired()) return null;
        const window = frame.window;
        const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
            .@"error" = null,
            .message = self.report.message,
            .filename = self.report.filename,
            .lineno = self.report.lineno,
            .colno = self.report.colno,
            .bubbles = false,
            .cancelable = true,
        }, frame._page);

        // Window.onerror is the legacy five-argument callback. Returning true
        // cancels error reporting; addEventListener listeners still receive the
        // ErrorEvent afterwards.
        var prevent_default = false;
        if (window._on_error) |on_error| {
            var ls: js.Local.Scope = undefined;
            frame.js.localScope(&ls);
            defer ls.deinit();

            const local_func = ls.toLocal(on_error);
            const result = local_func.call(js.Value, .{
                error_event._message,
                error_event._filename,
                error_event._line_number,
                error_event._column_number,
                null,
            }) catch null;
            if (result) |value| prevent_default = value.isTrue();
        }

        const event = error_event.asEvent();
        event._prevent_default = prevent_default;
        try frame._event_manager.dispatchDirect(window.asEventTarget(), event, null, .{
            .context = "Worker.parentError",
        });
        return null;
    }
};

pub fn terminate(self: *Worker) void {
    if (self._terminated) return;

    // Publish the terminal gate before aborting. Response.abort() can invoke
    // httpErrorCallback synchronously, and Chrome does not expose that
    // owner-request cancellation as an ErrorEvent from Worker.terminate().
    self._terminated = true;
    self._entry_pending = false;

    // Abort any pending script fetch
    if (self._http_response) |resp| {
        resp.abort(error.Abort);
        self._http_response = null;
    }
    if (self._runtime) |*runtime| {
        runtime.stopAndJoin();
        runtime.discardOutbound();
    }
}

/// Stop the worker's fetch/isolate/thread while retaining the creator-side
/// Worker wrapper and both owner arenas. Cached JS references remain callable
/// after their Document is discarded; final arena release belongs to deinit().
pub fn shutdown(self: *Worker) void {
    self.terminate();
}

// Posts a message from the frame to the worker.
pub fn postMessage(self: *Worker, data: js.Value) !void {
    if (self._terminated) return;
    const runtime = if (self._runtime) |*value| value else return;
    if (!runtime.acceptsInbound()) return;
    var message = data.serializeForMessageWithContext(
        std.heap.page_allocator,
        "Failed to execute 'postMessage' on 'Worker': ",
    ) catch |err| switch (err) {
        error.JsException => return error.TryCatchRethrow,
        else => return err,
    };
    errdefer message.deinit();
    runtime.enqueueMessage(message) catch |err| switch (err) {
        error.WorkerClosed => {
            message.deinit();
            return;
        },
        else => return err,
    };
}

// Creator-thread producer for the DedicatedWorker inbound mailbox. The
// Runtime retains `message` only after it can publish the command, so a
// closing/disabled worker cannot leak the shared envelope.
pub fn enqueueBroadcast(self: *Worker, message: *js.Value.BroadcastMessage) void {
    if (self._terminated) return;
    const runtime = if (self._runtime) |*value| value else return;
    if (!runtime.acceptsInbound()) return;
    runtime.enqueueBroadcast(message) catch |err| {
        if (err == error.WorkerClosed) return;
        log.warn(.browser, "worker broadcast enqueue", .{ .err = err });
    };
}

// Called internally by DedicatedWorkerGlobalScope when it wants to post a message to us
pub fn receiveMessage(self: *Worker, data: js.Value) !void {
    try runtimePostMessageToCreator(self, data);
}

// Main-thread host-boundary drain. The worker never mutates the creator's
// Scheduler or V8 isolate; it publishes an isolate-free envelope and the
// creator deserializes/dispatches it here after the author stack is empty.
pub fn drainOutbound(self: *Worker) !void {
    const runtime = if (self._runtime) |*value| value else return;
    while (runtime.popOutbound()) |outbound_value| {
        var outbound = outbound_value;
        defer outbound.deinit();
        switch (outbound) {
            .message => |*message| try self.dispatchSerializedMessage(message),
            .broadcast => |message| {
                const page = self._frame._page;
                page.routeBroadcastToWorkers(message, @as(*anyopaque, @ptrCast(self)));
                BroadcastChannel.deliverToWindowPage(page, message) catch |err| {
                    log.warn(.browser, "worker broadcast delivery", .{ .err = err });
                };
            },
            .error_report => |report| self.fireErrorEvent(.{
                .message = report.message,
                .filename = report.filename,
                .lineno = report.lineno,
                .colno = report.colno,
            }, null),
        }
    }
}

pub fn hasOutbound(self: *Worker) bool {
    const runtime = if (self._runtime) |*value| value else return false;
    return runtime.hasOutbound();
}

pub fn hasCreatorActivity(self: *Worker) bool {
    if (self.hasOutbound()) return true;
    if (self._terminated) return false;
    if (self._entry_pending) return true;
    const runtime = if (self._runtime) |*value| value else return false;
    return runtime.hasCreatorActivity();
}

fn dispatchSerializedMessage(self: *Worker, message: *const js.Value.SerializedMessage) !void {
    const frame = self._frame;
    const cloned_data: anyerror!js.Value.Global = blk: {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const cloned = js.Value.deserializeMessage(&ls.local, message) catch |err| break :blk err;
        break :blk cloned.persist();
    };

    const message_arena = try frame.getArena(.tiny, "Worker.receiveMessage");
    errdefer frame.releaseArena(message_arena);
    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .worker = self,
        .data = cloned_data,
        .arena = message_arena,
    };
    _ = try ReceiveMessageCallback.run(callback);
}

pub fn getOnMessage(self: *const Worker) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *Worker, setter: ?FunctionSetter) void {
    self._on_message = getFunctionFromSetter(setter);
}

pub fn getOnMessageError(self: *const Worker) ?js.Function.Global {
    return self._on_messageerror;
}

pub fn setOnMessageError(self: *Worker, setter: ?FunctionSetter) void {
    self._on_messageerror = getFunctionFromSetter(setter);
}

pub fn getOnError(self: *const Worker) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *Worker, setter: ?FunctionSetter) void {
    self._on_error = getFunctionFromSetter(setter);
}

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func,
        .anything => null,
    };
}

const ReceiveMessageCallback = struct {
    data: anyerror!js.Value.Global,
    arena: Allocator,
    worker: *Worker,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        if (self.data) |d| {
            d.release();
        } else |_| {}
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.worker._frame._session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker = self.worker;
        const frame = worker._frame;
        const target = worker.asEventTarget();

        // If data is null, structured clone failed - fire messageerror
        const data = self.data catch |err| {
            const on_messageerror = worker._on_messageerror;
            if (!frame._event_manager.hasDirectListeners(target, "messageerror", on_messageerror)) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .data = .{ .string = @errorName(err) },
                .bubbles = false,
                .cancelable = false,
            }, frame._page)).asEvent();
            try frame._event_manager.dispatchDirect(target, event, on_messageerror, .{ .context = "Worker.messageerror" });
            return null;
        };

        const on_message = worker._on_message;

        // Check if there are any listeners before creating the event
        if (!frame._event_manager.hasDirectListeners(target, "message", on_message)) {
            data.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = data },
            .bubbles = false,
            .cancelable = false,
        }, frame._page)).asEvent();

        try frame._event_manager.dispatchDirect(target, event, on_message, .{ .context = "Worker.receiveMessage" });

        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Worker);

    pub const Meta = struct {
        pub const name = "Worker";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Worker.init, .{});

    pub const terminate = bridge.function(Worker.terminate, .{});
    pub const postMessage = bridge.function(Worker.postMessage, .{});

    pub const onmessage = bridge.accessor(Worker.getOnMessage, Worker.setOnMessage, .{});
    pub const onerror = bridge.accessor(Worker.getOnError, Worker.setOnError, .{});
};

const testing = @import("../../testing.zig");
const EntryRequestCapture = struct {
    const Record = struct {
        seen: bool = false,
        duplicate: bool = false,
        mode_same_origin: bool = false,
        destination_worker: bool = false,
        site_same_origin: bool = false,
        has_cookie_jar: bool = false,
    };

    records: [5]Record = [_]Record{.{}} ** 5,
    count: usize = 0,

    fn indexForURL(url: []const u8) ?usize {
        const suffixes = [_][]const u8{
            "/entry-policy-classic-omit.js",
            "/entry-policy-module-omit.js",
            "/entry-policy-module-default.js",
            "/entry-policy-module-same-origin.js",
            "/entry-policy-module-include.js",
        };
        for (suffixes, 0..) |suffix, index| {
            if (std.mem.endsWith(u8, url, suffix)) return index;
        }
        return null;
    }

    fn onRequestStart(raw: *anyopaque, event: *const @import("../../Notification.zig").RequestStart) !void {
        const self: *EntryRequestCapture = @ptrCast(@alignCast(raw));
        const req = &event.transfer.req;
        const index = indexForURL(req.url) orelse return;
        const record = &self.records[index];
        if (record.seen) {
            record.duplicate = true;
            return;
        }

        record.seen = true;
        record.has_cookie_jar = req.cookie_jar != null;
        self.count += 1;

        var headers = req.headers.iterator();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Sec-Fetch-Mode")) {
                record.mode_same_origin = std.mem.eql(u8, header.value, "same-origin");
            } else if (std.ascii.eqlIgnoreCase(header.name, "Sec-Fetch-Dest")) {
                record.destination_worker = std.mem.eql(u8, header.value, "worker");
            } else if (std.ascii.eqlIgnoreCase(header.name, "Sec-Fetch-Site")) {
                record.site_same_origin = std.mem.eql(u8, header.value, "same-origin");
            }
        }
    }
};

test "WebApi: Chrome 149 Worker entry request policy" {
    const cases = [_]struct {
        worker_type: WorkerType,
        requested: WorkerCredentials,
        credentials: HttpClient.RequestContext.Credentials,
        sends_cookies: bool,
    }{
        .{ .worker_type = .classic, .requested = .omit, .credentials = .same_origin, .sends_cookies = true },
        .{ .worker_type = .classic, .requested = .@"same-origin", .credentials = .same_origin, .sends_cookies = true },
        .{ .worker_type = .classic, .requested = .include, .credentials = .same_origin, .sends_cookies = true },
        .{ .worker_type = .module, .requested = .omit, .credentials = .omit, .sends_cookies = false },
        .{ .worker_type = .module, .requested = .@"same-origin", .credentials = .same_origin, .sends_cookies = true },
        .{ .worker_type = .module, .requested = .include, .credentials = .include, .sends_cookies = true },
    };

    for (cases) |case| {
        const policy = entryRequestPolicy(case.worker_type, case.requested);
        try testing.expectEqual(HttpClient.HeaderRequestContext.Mode.same_origin, policy.mode);
        try testing.expectEqual(case.credentials, policy.credentials);
        try testing.expectEqual(case.sends_cookies, policy.sendsCookies());
    }
}

test "WebApi: Chrome 149 Worker entry request wire mode and credentials" {
    var capture: EntryRequestCapture = .{};
    try testing.test_notification.register(.http_request_start, &capture, EntryRequestCapture.onRequestStart);
    defer testing.test_notification.unregisterAll(&capture);

    try testing.htmlRunner("worker/entry-request-policy.html", .{ .timeout_ms = 8_000 });

    try testing.expectEqual(@as(usize, capture.records.len), capture.count);
    const expected_cookie_jar = [_]bool{ true, false, true, true, true };
    for (capture.records, expected_cookie_jar) |record, has_cookie_jar| {
        try testing.expectEqual(true, record.seen);
        try testing.expectEqual(false, record.duplicate);
        try testing.expectEqual(has_cookie_jar, record.has_cookie_jar);
        if (@import("builtin").os.tag == .windows) {
            try testing.expectEqual(true, record.mode_same_origin);
            try testing.expectEqual(true, record.destination_worker);
            try testing.expectEqual(true, record.site_same_origin);
        }
    }
}

test "WebApi: Worker" {
    // Worker tests chain a worker-script fetch with a dynamic-import fetch
    // and a cross-context postMessage. The default 2 s assertion budget can
    // blow up on TSAN CI; give it more room.
    try testing.htmlRunner("worker", .{ .timeout_ms = 8000 });
}

test "WebApi: Chrome 149 Worker security boundaries" {
    try testing.htmlRunner("worker/security-boundaries.html", .{ .timeout_ms = 8000 });
}

test "WebApi: Chrome 149 Worker policy-container timing and replacement" {
    inline for (.{
        "csp/worker_policy_local_same_task.html",
        "csp/worker_policy_ready_no_live_link.html",
        "csp/worker_policy_network_delayed_no_inheritance.html",
        "csp/worker_policy_network_replacement.html",
        "csp/worker_trusted_script_url_constructor.html",
    }) |fixture| {
        try testing.htmlRunner(fixture, .{ .timeout_ms = 8_000 });
    }
}

test "WebApi: Worker local policy schemes are ASCII case insensitive" {
    try testing.expect(workerURLInheritsCreatorPolicy("ABOUT:blank"));
    try testing.expect(workerURLInheritsCreatorPolicy("Data:text/javascript,"));
    try testing.expect(workerURLInheritsCreatorPolicy("BLOB:https://example.test/id"));
    try testing.expect(workerURLInheritsCreatorPolicy("FileSystem:https://example.test/temporary/id"));
    try testing.expect(!workerURLInheritsCreatorPolicy("https://example.test/worker.js"));
}

test "WebApi: Worker top-level errors cross the isolate mailbox" {
    try testing.htmlRunner("worker/top-level-error-mailbox.html", .{ .timeout_ms = 8000 });
}

test "WebApi: self-closed Worker drops creator messages without dead letters" {
    const page = try testing.pageTest(
        "worker/close-postmessage.html",
        .{ .wait_until_done = false },
    );
    defer page.close();

    var runner = page.session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2_000, .{ .until = .done });

    const frame = page.frame().?;
    try testing.expectEqual(@as(usize, 1), frame.workers.items.len);
    const runtime = &frame.workers.items[0]._runtime.?;
    try testing.expectEqual(false, runtime.acceptsInbound());
    try testing.expectEqual(@as(usize, 0), runtime.pendingInboundCount());
}

test "WebApi: Worker pending entry fetch page close" {
    const page = try testing.pageTest(
        "worker/pending-fetch-page-close.html",
        .{ .wait_until_done = false },
    );
    var runner = page.session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2_000, .{ .until = .load });

    // Frame.abortOwner runs before Worker.deinit. The request shutdown callback
    // must clear the transfer-backed Response so the latter cannot abort it a
    // second time. Let the delayed server response drain after close as well.
    page.close();
    try testing.test_browser.http_client.tick(500, .all);
}

test "WebApi: Chrome 149 Worker termination lifecycle" {
    try testing.htmlRunner("worker/termination-lifecycle.html", .{ .timeout_ms = 8_000 });
}

test "WebApi: Worker iterator teardown uses owner Factory" {
    try testing.htmlRunner("worker/iterator-factory-owner.html", .{ .timeout_ms = 8_000 });
}

test "WebApi: dormant DedicatedWorker reaches creator-visible quiescence" {
    const page = try testing.pageTest(
        "worker/quiescence-dormant.html",
        .{ .wait_until_done = false },
    );
    defer page.close();

    var runner = page.session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2_000, .{ .until = .done });
    try testing.expectEqual(false, page.frame().?.hasWorkerActivity());
}

test "WebApi: delayed DedicatedWorker message prevents premature done" {
    const page = try testing.pageTest(
        "worker/quiescence-delayed.html",
        .{ .wait_until_done = false },
    );
    defer page.close();

    var runner = page.session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2_000, .{ .until = .done });

    const frame = page.frame().?;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    try testing.expectEqual(
        true,
        (try ls.local.exec("window.__delayedWorkerMessage === true", null)).isTrue(),
    );
}
