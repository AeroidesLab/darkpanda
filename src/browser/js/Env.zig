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

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const Context = @import("Context.zig");
const Scheduler = @import("Scheduler.zig");
const Isolate = @import("Isolate.zig");
const Platform = @import("Platform.zig");
const Inspector = @import("Inspector.zig");
const WebIDL = @import("WebIDL.zig");
const WasmStreaming = @import("WasmStreaming.zig");
const OwnerMailbox = @import("../OwnerMailbox.zig");
const milliTimestamp = @import("../../datetime.zig").milliTimestamp;

const App = @import("../../App.zig");
const Frame = @import("../Frame.zig");
const Page = @import("../Page.zig");
const Window = @import("../webapi/Window.zig");
const TrustedTypes = @import("../webapi/TrustedTypes.zig");
const WorkerGlobalScope = @import("../webapi/WorkerGlobalScope.zig");
const DedicatedWorkerGlobalScope = @import("../webapi/DedicatedWorkerGlobalScope.zig");

const v8 = js.v8;
const log = lp.log;

const JsApis = bridge.JsApis;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

const MAX_CONTEXTS = if (lp.build_config.wpt_extensions) 8192 else 128;
// Blink's synchronous main-thread WebAssembly constructor limit in Chrome 149.
// Keep the human-readable "8MB" in the errors below in sync with this value.
const WASM_WIRE_BYTES_LIMIT: usize = 1 << 23;

fn initClassIds() void {
    inline for (JsApis, 0..) |JsApi, i| {
        JsApi.Meta.class_id = i;
    }
}

var class_id_once = std.once(initClassIds);

// The Env maps to a V8 isolate, which represents a isolated sandbox for
// executing JavaScript. The Env is where we'll define our V8 <-> Zig bindings,
// and it's where we'll start ExecutionWorlds, which actually execute JavaScript.
// The `S` parameter is arbitrary state. When we start an ExecutionWorld, an instance
// of S must be given. This instance is available to any Zig binding.
// The `types` parameter is a tuple of Zig structures we want to bind to V8.
const Env = @This();

app: *App,

allocator: Allocator,

platform: *const Platform,

// the global isolate
isolate: js.Isolate,

contexts: std.ArrayList(*Context),

// One monotonically increasing enqueue sequence for every Context scheduled
// by this agent. It is deliberately Env-owned: per-Context counters cannot
// preserve FIFO when sibling frames post to each other in opposite directions.
task_sequence: u64,

// A DedicatedWorker owns its isolate and all isolate-affine resources on its
// backing OS thread. Window Envs continue to delegate Page-scoped resources
// to Page; worker Envs keep their own queues/handles/finalizer registry so no
// v8::Global or MicrotaskQueue ever crosses an isolate boundary.
agent_kind: AgentKind,
owned_microtask_queues: std.ArrayList(*v8.MicrotaskQueue),
worker_globals: js.GlobalTracker,
worker_finalizer_callbacks: js.FinalizerCallback.Registry = .empty,
worker_finalizer_identity_pool: std.heap.MemoryPool(js.FinalizerCallback.Identity),

// just kept around because we need to free it on deinit
isolate_params: *v8.CreateParams,

context_id: usize,

// Maps origin -> shared Origin contains, for v8 values shared across
// same-origin Contexts. There's a mismatch here between our JS model and our
// Browser model. Origins only live as long as the root frame of a session exists.
// It would be wrong/dangerous to re-use an Origin across root frame navigations.

// Global handles that need to be freed on deinit
eternal_function_templates: []v8.Eternal,

// Dynamic slice to avoid circular dependency on JsApis.len at comptime
templates: []*const v8.FunctionTemplate,

// Inspector associated with the Isolate. Exists when CDP is being used.
inspector: ?*Inspector,

// We can store data in a v8::Object's Private data bag. The keys are v8::Private
// which an be created once per isolaet.
private_symbols: PrivateSymbols,

microtask_queues_are_running: bool,

// Temporary full-suite event-loop diagnostics; enabled only while the
// HTML.Image fixture is the active test page.

// Serializes V8 calls that race with TerminateExecution (which can fire from
// the sighandler thread). Without this, a terminate landing between the
// IsExecutionTerminating check and PerformCheckpoint trips a V8 debug assert.
terminate_mutex: std.Thread.Mutex = .{},

// Set from network thread, saying termination should happen. Read from worker
// thread making sure terminate hasn't been canceled.
terminate_requested: std.atomic.Value(bool) = .init(false),

pub const AgentKind = enum {
    window,
    dedicated_worker,
};

pub const InitOpts = struct {
    with_inspector: bool = false,
    agent_kind: AgentKind = .window,
};

pub fn init(app: *App, opts: InitOpts) !Env {
    if (comptime IS_DEBUG) {
        comptime {
            // V8 requirement for any data using SetAlignedPointerInInternalField
            const a = @alignOf(@import("TaggedOpaque.zig"));
            std.debug.assert(a >= 2 and a % 2 == 0);
        }
    }

    // Initialize class IDs once before any V8 work
    class_id_once.call();

    const allocator = app.allocator;
    const snapshot = &app.snapshot;

    var params = try allocator.create(v8.CreateParams);
    errdefer allocator.destroy(params);
    v8.v8__Isolate__CreateParams__CONSTRUCT(params);
    // Blink disallows Atomics.wait on the main JavaScript thread and permits
    // it on a DedicatedWorker backing thread. Each worker has a distinct
    // isolate, so this isolate-wide switch now maps exactly to an agent kind.
    params.allow_atomics_wait = opts.agent_kind == .dedicated_worker;
    params.snapshot_blob = @ptrCast(&snapshot.startup_data);

    params.array_buffer_allocator = v8.v8__ArrayBuffer__Allocator__NewDefaultAllocator().?;
    errdefer v8.v8__ArrayBuffer__Allocator__DELETE(params.array_buffer_allocator.?);

    params.external_references = &snapshot.external_references;

    if (app.config.v8MaxHeapMb()) |mb| {
        v8.v8__ResourceConstraints__ConfigureDefaultsFromHeapSize(
            &params.constraints,
            0,
            @as(usize, mb) * 1024 * 1024,
        );
    }

    var isolate = js.Isolate.init(params);
    errdefer isolate.deinit();
    const isolate_handle = isolate.handle;

    v8.v8__Isolate__SetHostImportModuleDynamicallyCallback(isolate_handle, Context.dynamicModuleCallback);
    v8.v8__Isolate__SetPromiseRejectCallback(isolate_handle, promiseRejectCallback);
    v8.v8__Isolate__SetExceptionPropagationCallback(isolate_handle, WebIDL.exceptionPropagationCallback);
    v8.v8__Isolate__SetFailedAccessCheckCallbackFunction(isolate_handle, Window.failedAccessCheckCallback);
    v8.v8__Isolate__SetMicrotasksPolicy(isolate_handle, v8.kExplicit);
    v8.v8__Isolate__SetFatalErrorHandler(isolate_handle, fatalCallback);
    v8.v8__Isolate__SetOOMErrorHandler(isolate_handle, oomCallback);
    v8.v8__Isolate__SetIsJSApiWrapperNativeErrorCallback(isolate_handle, isJSApiWrapperNativeError);
    v8.v8__Isolate__SetSharedArrayBufferConstructorEnabledCallback(isolate_handle, sharedArrayBufferConstructorEnabled);
    v8.v8__Isolate__SetModifyCodeGenerationFromStringsCallback(isolate_handle, codeGenerationFromStringsAllowed);
    v8.v8__Isolate__SetAllowWasmCodeGenerationCallback(isolate_handle, wasmCodeGenerationAllowed);
    v8.v8__Isolate__SetWasmModuleCallback(isolate_handle, wasmModuleOverride);
    v8.v8__Isolate__SetWasmInstanceCallback(isolate_handle, wasmInstanceOverride);
    v8.v8__Isolate__SetWasmStreamingCallback(isolate_handle, WasmStreaming.callback);

    if (comptime IS_DEBUG) {
        v8.v8__Isolate__SetCaptureStackTraceForUncaughtExceptions(isolate_handle, true, 64);
    }

    isolate.enter();
    errdefer isolate.exit();

    v8.v8__Isolate__SetHostInitializeImportMetaObjectCallback(isolate_handle, Context.metaObjectCallback);

    // Allocate arrays dynamically to avoid comptime dependency on JsApis.len
    const eternal_function_templates = try allocator.alloc(v8.Eternal, JsApis.len);
    errdefer allocator.free(eternal_function_templates);

    const templates = try allocator.alloc(*const v8.FunctionTemplate, JsApis.len);
    errdefer allocator.free(templates);

    var private_symbols: PrivateSymbols = undefined;
    {
        var temp_scope: js.HandleScope = undefined;
        temp_scope.init(isolate);
        defer temp_scope.deinit();

        inline for (JsApis, 0..) |_, i| {
            const data = v8.v8__Isolate__GetDataFromSnapshotOnce(isolate_handle, snapshot.data_start + i);
            const function_handle: *const v8.FunctionTemplate = @ptrCast(data);
            // Make function template eternal
            v8.v8__Eternal__New(isolate_handle, @ptrCast(function_handle), &eternal_function_templates[i]);

            // Extract the local handle from the global for easy access
            const eternal_ptr = v8.v8__Eternal__Get(&eternal_function_templates[i], isolate_handle);
            templates[i] = @ptrCast(@alignCast(eternal_ptr.?));
        }

        private_symbols = PrivateSymbols.init(isolate_handle);
    }

    var inspector: ?*js.Inspector = null;
    if (opts.with_inspector) {
        inspector = try Inspector.init(allocator, isolate_handle);
    }

    return .{
        .app = app,
        .context_id = 0,
        .task_sequence = 0,
        .allocator = allocator,
        .contexts = .empty,
        .agent_kind = opts.agent_kind,
        .owned_microtask_queues = .empty,
        .worker_globals = .init(allocator),
        .worker_finalizer_identity_pool = .init(allocator),
        .isolate = isolate,
        .platform = &app.platform,
        .templates = templates,
        .isolate_params = params,
        .inspector = inspector,
        .private_symbols = private_symbols,
        .microtask_queues_are_running = false,
        .eternal_function_templates = eternal_function_templates,
    };
}

pub fn deinit(self: *Env) void {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.contexts.items.len == 0);
    }
    for (self.contexts.items) |ctx| {
        ctx.deinit();
    }
    self.contexts.deinit(self.allocator);

    const app = self.app;
    const allocator = app.allocator;

    // The worker registry has Env lifetime rather than Page lifetime. Mark
    // every weak-callback identity done before resetting the globals. V8 may
    // run weak callbacks until isolate disposal; their backing pool therefore
    // stays alive until after `isolate.deinit` below.
    if (self.agent_kind == .dedicated_worker) {
        var it = self.worker_finalizer_callbacks.valueIterator();
        while (it.next()) |fc| fc.*.deinit(fc.*.page);
    }
    self.worker_finalizer_callbacks.deinit(allocator);
    self.worker_finalizer_callbacks = .empty;
    self.worker_globals.deinit();

    for (self.owned_microtask_queues.items) |queue| {
        v8.v8__MicrotaskQueue__DELETE(queue);
    }
    self.owned_microtask_queues.deinit(allocator);

    if (self.inspector) |i| {
        i.deinit(allocator);
    }

    allocator.free(self.templates);
    allocator.free(self.eternal_function_templates);
    self.private_symbols.deinit();

    self.isolate.exit();
    self.isolate.deinit();
    v8.v8__ArrayBuffer__Allocator__DELETE(self.isolate_params.array_buffer_allocator.?);
    allocator.destroy(self.isolate_params);
    self.worker_finalizer_identity_pool.deinit();
}

pub fn isDedicatedWorker(self: *const Env) bool {
    return self.agent_kind == .dedicated_worker;
}

pub const FinalizerResources = struct {
    registry: *js.FinalizerCallback.Registry,
    allocator: Allocator,
    identity_pool: *std.heap.MemoryPool(js.FinalizerCallback.Identity),
};

pub fn globalTracker(self: *Env, page: *Page) *js.GlobalTracker {
    return if (self.isDedicatedWorker()) &self.worker_globals else &page.globals;
}

pub fn finalizerResources(self: *Env, page: *Page) FinalizerResources {
    if (self.isDedicatedWorker()) {
        return .{
            .registry = &self.worker_finalizer_callbacks,
            .allocator = self.allocator,
            .identity_pool = &self.worker_finalizer_identity_pool,
        };
    }
    return .{
        .registry = &page.finalizer_callbacks,
        .allocator = page.frame_arena,
        .identity_pool = &page.session.browser.fc_identity_pool,
    };
}

pub fn acquireContextOrigin(self: *Env, page: *Page, key_: ?[]const u8) !*js.Origin {
    if (!self.isDedicatedWorker()) return page.getOrCreateOrigin(key_);

    var opaque_origin: [36]u8 = undefined;
    const key = key_ orelse blk: {
        @import("../../id.zig").uuidv4(&opaque_origin);
        break :blk opaque_origin[0..];
    };
    return js.Origin.init(self.app, self.isolate, key);
}

pub fn releaseContextOrigin(self: *Env, page: *Page, origin: *js.Origin) void {
    if (!self.isDedicatedWorker()) return page.releaseOrigin(origin);
    origin.deinit(self.app);
}

pub const ContextParams = struct {
    identity: *js.Identity,
    identity_arena: Allocator,
    call_arena: Allocator,
    local_arena: Allocator,
    debug_name: []const u8 = "Context",
};

pub fn createContext(self: *Env, frame: *Frame, params: ContextParams) !*Context {
    return self._createContext(frame, params);
}

pub fn createWorkerContext(self: *Env, worker: *WorkerGlobalScope, params: ContextParams) !*Context {
    return self._createContext(worker, params);
}

fn _createContext(self: *Env, global: anytype, params: ContextParams) !*Context {
    const T = @TypeOf(global);
    const is_frame = T == *Frame;
    const page = global._page;

    const context_arena = try self.app.arena_pool.acquire(.medium, params.debug_name);
    errdefer self.app.arena_pool.release(context_arena);

    const isolate = self.isolate;
    var hs: js.HandleScope = undefined;
    hs.init(isolate);
    defer hs.deinit();

    // A newly-created child browsing context starts as about:blank and is
    // synchronously scriptable by its parent/opener. V8 forbids changing a
    // Context's queue while *any* Context is entered, so inherit the creator's
    // queue at construction time instead of creating then rebinding it from a
    // DOM callback. A later asynchronous cross-origin commit can move it.
    const inherited_context: ?*Context = blk: {
        if (comptime !is_frame) break :blk null;
        if (global.parent) |parent| break :blk parent.js;
        if (global.window._opener) |opener| break :blk opener._frame.js;
        break :blk null;
    };
    const microtask_queue = if (self.isDedicatedWorker()) blk: {
        const queue = v8.v8__MicrotaskQueue__New(isolate.handle, v8.kExplicit).?;
        errdefer v8.v8__MicrotaskQueue__DELETE(queue);
        try self.owned_microtask_queues.append(self.allocator, queue);
        errdefer _ = self.owned_microtask_queues.pop();
        break :blk queue;
    } else if (inherited_context) |context|
        context.microtask_queue
    else
        try page.createMicrotaskQueue();
    const microtask_queue_kind: Context.MicrotaskQueueKind = if (inherited_context) |context|
        if (context.microtask_queue_kind == .window_agent) .window_agent else .inherited
    else
        .exclusive;

    // Reuse the browsing context's outer global proxy across navigation. Each
    // commit now has a fresh native Window, so *Window is intentionally not
    // the canonical key; NavigationContext owns a dedicated stable identity
    // cell for the lifetime of the iframe/popup browsing context.
    const reuse_global_object: ?*const v8.Value = blk: {
        if (comptime !is_frame) break :blk null;
        const proxy_key = global._navigation_context.windowProxyIdentityKey();
        const existing = params.identity.identity_map.getPtr(proxy_key) orelse break :blk null;
        break :blk @ptrCast(v8.v8__Global__Get(existing, isolate.handle));
    };

    // Restore the context from the snapshot (0 = Page, 1 = Worker)
    const snapshot_index: u32 = if (comptime is_frame) 0 else 1;
    const v8_context = v8.v8__Context__FromSnapshot__Config(isolate.handle, snapshot_index, &.{
        .global_template = null,
        .global_object = reuse_global_object,
        .microtask_queue = microtask_queue,
    }).?;

    // Create the v8::Context and wrap it in a v8::Global
    var context_global: v8.Global = undefined;
    v8.v8__Global__New(isolate.handle, v8_context, &context_global);
    errdefer v8.v8__Global__Reset(&context_global);

    // Get the global object for the context
    const global_obj = v8.v8__Context__Global(v8_context).?;

    // Store our TAO inside the internal field of the global object. This
    // maps the v8::Object -> Zig instance.
    const tao = try params.identity_arena.create(@import("TaggedOpaque.zig"));
    tao.* = if (comptime is_frame) .{
        .value = @ptrCast(global.window),
        .prototype_chain = (&Window.JsApi.Meta.prototype_chain).ptr,
        .prototype_len = @intCast(Window.JsApi.Meta.prototype_chain.len),
        .subtype = .node,
    } else .{
        .value = @ptrCast(global._type.dedicated),
        .prototype_chain = (&DedicatedWorkerGlobalScope.JsApi.Meta.prototype_chain).ptr,
        .prototype_len = @intCast(DedicatedWorkerGlobalScope.JsApi.Meta.prototype_chain.len),
        .subtype = null,
    };
    v8.v8__Object__SetAlignedPointerInInternalField(global_obj, 0, tao);

    const context_id = self.context_id;
    self.context_id = context_id + 1;

    const origin = try self.acquireContextOrigin(page, null);
    errdefer self.releaseContextOrigin(page, origin);

    const context = try context_arena.create(Context);
    const execution_stack_limit = if (comptime is_frame)
        isolate.stackLimit()
    else
        isolate.stackLimitFromCurrentPosition(Context.WORKER_MAX_STACK_SIZE);
    context.* = .{
        .env = self,
        .global = if (comptime is_frame) .{ .frame = global } else .{ .worker = global },
        .origin = origin,
        .id = context_id,
        .page = page,
        .isolate = isolate,
        .execution_stack_limit = execution_stack_limit,
        .arena = context_arena,
        .handle = context_global,
        .templates = self.templates,
        .call_arena = params.call_arena,
        .local_arena = params.local_arena,
        .microtask_queue = microtask_queue,
        .microtask_queue_kind = microtask_queue_kind,
        .script_manager = if (comptime is_frame) &global._script_manager.base else &global._script_manager,
        .scheduler = .initShared(context_arena, &self.task_sequence),
        .promise_rejections = .init(self.allocator),
        .identity = params.identity,
        .identity_arena = params.identity_arena,
        .execution = undefined,
        .owner_target = undefined,
    };

    context.execution = .{
        .js = context,
        .url = &global.url,
        .buf = &global.buf,
        .charset = &global.charset,
        .arena = global.arena,
        .page = context.page,
        .session = page.session,
        .call_arena = params.call_arena,
        .local_arena = params.local_arena,
        ._factory = global._factory,
        ._scheduler = &context.scheduler,
    };

    // TrustedTypePolicyFactory is an ExecutionContextClient in Blink.  Bind
    // the embedded factory to its owner realm rather than whichever same-
    // origin realm happens to call a method on it.
    if (comptime is_frame) {
        global.window.getTrustedTypes().bindContext(context);
    } else {
        global.getTrustedTypes().bindContext(context);
    }

    // The Target's opaque owner is the completed per-realm Execution, never
    // the Context allocation itself. Window and DedicatedWorker contexts use
    // their respective owner-thread mailboxes through the same path.
    context.owner_target = context.execution.ownerMailbox().createTarget(&context.execution) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Context creation and mailbox shutdown are serialized on the same
        // owner thread. Browser/worker teardown closes the mailbox only after
        // all of its Contexts have been destroyed, so this is an invariant,
        // not a DOM-visible construction error.
        error.MailboxClosed => unreachable,
    };
    errdefer context.owner_target.deinit();

    // Store a pointer to our context inside the v8 context so native getters
    // invoked during realm initialization can recover their Execution.
    v8.v8__Context__SetAlignedPointerInEmbedderData(v8_context, 1, @ptrCast(context));
    errdefer v8.v8__Context__SetAlignedPointerInEmbedderData(v8_context, 1, null);

    // Populate and freeze Web IDL [SameObject] FrozenArray values before any
    // author script can replace Object.freeze.  Do this before registering the
    // outer proxy in Identity: a V8/OOM failure cannot leave a stale identity
    // map entry referring to this incomplete Context.
    v8.v8__Context__Enter(v8_context);
    initializeFrozenSameObjects(isolate.handle, v8_context) catch |err| {
        v8.v8__Context__Exit(v8_context);
        return err;
    };
    v8.v8__Context__Exit(v8_context);

    // Register the outer proxy under its browsing-context key. Multiple
    // contexts can be created for one Frame (via CDP), so only the first one
    // in a given Identity scope creates the persistent handle.
    const identity_ptr = if (comptime is_frame)
        global._navigation_context.windowProxyIdentityKey()
    else
        @intFromPtr(global._type.dedicated);
    const gop = try params.identity.identity_map.getOrPut(params.identity_arena, identity_ptr);
    if (gop.found_existing == false) {
        var global_global: v8.Global = undefined;
        v8.v8__Global__New(isolate.handle, global_obj, &global_global);
        gop.value_ptr.* = global_global;
    }

    if (comptime is_frame) {
        // Bridge return values are native *Window pointers. Alias every inner
        // Window address to the same outer proxy so current and stale native
        // references both preserve `contentWindow` / `window.open()` identity.
        // The canonical lookup above remains NavigationContext-keyed, and old
        // aliases stay valid because retired Frames live until Page teardown.
        const inner_key = @intFromPtr(global.window);
        const inner_gop = try params.identity.identity_map.getOrPut(params.identity_arena, inner_key);
        if (inner_gop.found_existing == false) {
            var inner_global: v8.Global = undefined;
            v8.v8__Global__New(isolate.handle, global_obj, &inner_global);
            inner_gop.value_ptr.* = inner_global;
        }
    }

    // Conditional feature callbacks may inspect embedder data. Chromium calls
    // this only after the Context has its security/runtime metadata installed.
    // Cross-origin isolation is not implemented yet, so the SAB callback below
    // deliberately keeps the constructor absent for ordinary pages.
    v8.v8__Isolate__InstallConditionalFeatures(isolate.handle, v8_context);

    if (self.contexts.items.len >= MAX_CONTEXTS) {
        return error.TooManyContexts;
    }
    try self.contexts.append(self.allocator, context);

    return context;
}

pub fn destroyContext(self: *Env, context: *Context) void {
    for (self.contexts.items, 0..) |ctx, i| {
        if (ctx == context) {
            _ = self.contexts.swapRemove(i);
            break;
        }
    } else {
        if (comptime IS_DEBUG) {
            @panic("Tried to remove unknown context");
        }
    }

    const isolate = self.isolate;
    if (self.inspector) |inspector| {
        var hs: js.HandleScope = undefined;
        hs.init(isolate);
        defer hs.deinit();
        inspector.contextDestroyed(@ptrCast(v8.v8__Global__Get(&context.handle, isolate.handle)));
    }

    // A deferred queue belongs to the Page, not the Context. Do not install it
    // merely to tear the realm down immediately afterwards.
    context.pending_microtask_queue = null;
    context.deinit();
}

pub fn contextById(self: *Env, id: usize) ?*Context {
    for (self.contexts.items) |context| {
        if (context.id == id) return context;
    }
    return null;
}

// Retry agent-cluster queue changes at a host boundary. The C++ binding checks
// V8's real entered-context stack, including contexts entered internally while
// invoking a Zig callback; therefore this is safe even when a nominal host
// boundary is reached through nested author code.
pub fn applyPendingMicrotaskQueues(self: *Env) void {
    var i: usize = 0;
    while (i < self.contexts.items.len) : (i += 1) {
        _ = self.contexts.items[i].applyPendingMicrotaskQueue();
    }
}

pub fn runMicrotasks(self: *Env) void {
    if (self.microtask_queues_are_running == false) {
        self.terminate_mutex.lock();
        defer self.terminate_mutex.unlock();

        const v8_isolate = self.isolate.handle;

        // terminatePending: once a forcible terminate is requested (and not
        // canceled), refuse to start new work — IsExecutionTerminating alone
        // goes false again as soon as the killed script finishes unwinding.
        if (v8.v8__Isolate__IsExecutionTerminating(v8_isolate) or self.terminatePending()) {
            return;
        }

        self.microtask_queues_are_running = true;
        defer self.microtask_queues_are_running = false;

        // A WindowAgent queue can be referenced by several same-origin
        // Contexts. Checkpoint each distinct queue once, while rescanning after
        // every checkpoint because user JS can create or destroy Contexts.
        var processed: [MAX_CONTEXTS]*v8.MicrotaskQueue = undefined;
        var processed_len: usize = 0;
        var scan: usize = 0;
        while (scan < self.contexts.items.len) {
            const queue = self.contexts.items[scan].microtask_queue;
            scan += 1;

            var already_processed = false;
            for (processed[0..processed_len]) |item| {
                if (item == queue) {
                    already_processed = true;
                    break;
                }
            }
            if (already_processed) continue;

            processed[processed_len] = queue;
            processed_len += 1;
            v8.v8__MicrotaskQueue__PerformCheckpoint(queue, v8_isolate);
            scan = 0;
        }

        // V8's reject callback runs while the promise job is executing. Blink
        // waits until the checkpoint is complete, then posts a DOM task which
        // checks HasHandler once more before dispatching unhandledrejection.
        var i: usize = 0;
        while (i < self.contexts.items.len) : (i += 1) {
            self.contexts.items[i].promise_rejections.processQueue();
        }

        // Jobs enqueued before an agent-cluster change were drained from the
        // old queue above. Install the new queue only after that checkpoint.
        self.applyPendingMicrotaskQueues();
    }
}

const ReadySelection = struct {
    context: *Context,
    priority: Scheduler.Priority,
    task: Scheduler.ReadyTask,
};

fn selectReadyTask(self: *Env, priority: Scheduler.Priority, now: u64) ?ReadySelection {
    var selected: ?ReadySelection = null;
    for (self.contexts.items) |context| {
        const task = context.scheduler.peekReady(priority, now) orelse continue;
        if (selected == null or task.precedes(selected.?.task)) {
            selected = .{ .context = context, .priority = priority, .task = task };
        }
    }
    return selected;
}

pub fn runMacrotasks(self: *Env) !void {
    const start = milliTimestamp(.monotonic);
    while (true) {
        if (v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle) or self.terminatePending()) {
            return;
        }

        // Every scheduler callback below enters a Context. Apply any rebind
        // left by the previous network/event-loop task first.
        self.applyPendingMicrotaskQueues();

        const now = milliTimestamp(.monotonic);
        // Preserve the existing high/low contract agent-wide: idle work is
        // eligible only if no normal task in any Context is ready. Within one
        // priority class, run_at is the deadline and Env-wide sequence breaks
        // ties, so Context-list order cannot reverse posted-message FIFO.
        const selected = self.selectReadyTask(.high, now) orelse
            self.selectReadyTask(.low, now) orelse return;
        const ran = blk: {
            var hs: js.HandleScope = undefined;
            const entered = selected.context.enter(&hs);
            defer entered.exit();
            break :blk try selected.context.scheduler.runOne(selected.priority, now);
        };
        if (!ran) continue;

        // Blink checkpoints the responsible agent after every task. Microtasks
        // may create/destroy Contexts, enqueue high work, or request an agent
        // queue rebind, so rescan from scratch after the checkpoint.
        self.runMicrotasks();
        self.applyPendingMicrotaskQueues();

        // Keep the scheduler's existing runaway-work guard, now across the
        // whole agent rather than once per Context queue.
        if (milliTimestamp(.monotonic) - start > 500) return;
    }
}

pub fn msToNextMacrotask(self: *Env) ?u64 {
    var next_task: u64 = std.math.maxInt(u64);
    for (self.contexts.items) |ctx| {
        const candidate = ctx.scheduler.msToNextHigh() orelse continue;
        if (candidate < next_task) {
            next_task = candidate;
        }
    }
    return if (next_task == std.math.maxInt(u64)) null else next_task;
}

pub fn pumpMessageLoop(self: *const Env) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate.handle);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    const isolate = self.isolate.handle;
    const platform = self.platform.handle;
    while (v8.v8__Platform__PumpMessageLoop(platform, isolate, false)) {}
}

pub fn hasBackgroundTasks(self: *const Env) bool {
    return v8.v8__Isolate__HasPendingBackgroundTasks(self.isolate.handle);
}

pub fn waitForBackgroundTasks(self: *Env) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate.handle);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    const isolate = self.isolate.handle;
    const platform = self.platform.handle;
    while (v8.v8__Isolate__HasPendingBackgroundTasks(isolate)) {
        _ = v8.v8__Platform__PumpMessageLoop(platform, isolate, true);
        self.runMicrotasks();
    }
}

pub fn runIdleTasks(self: *const Env) void {
    v8.v8__Platform__RunIdleTasks(self.platform.handle, self.isolate.handle, 1);
}

// V8 doesn't immediately free memory associated with
// a Context, it's managed by the garbage collector. We use the
// `lowMemoryNotification` call on the isolate to encourage v8 to free
// any contexts which have been freed.
// This GC is very aggressive. Use memoryPressureNotification for less
// aggressive GC passes.
pub fn lowMemoryNotification(self: *Env) void {
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.isolate);
    defer handle_scope.deinit();
    self.isolate.lowMemoryNotification();
}

// V8 doesn't immediately free memory associated with
// a Context, it's managed by the garbage collector. We use the
// `memoryPressureNotification` call on the isolate to encourage v8 to free
// any contexts which have been freed.
// The level indicates the aggressivity of the GC required:
// moderate speeds up incremental GC
// critical runs one full GC
// For a more aggressive GC, use lowMemoryNotification.
pub fn memoryPressureNotification(self: *Env, level: Isolate.MemoryPressureLevel) void {
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.isolate);
    defer handle_scope.deinit();
    self.isolate.memoryPressureNotification(level);
}

pub fn dumpMemoryStats(self: *Env) void {
    const stats = self.isolate.getHeapStatistics();
    std.debug.print(
        \\ Total Heap Size: {d}
        \\ Total Heap Size Executable: {d}
        \\ Total Physical Size: {d}
        \\ Total Available Size: {d}
        \\ Used Heap Size: {d}
        \\ Heap Size Limit: {d}
        \\ Malloced Memory: {d}
        \\ External Memory: {d}
        \\ Peak Malloced Memory: {d}
        \\ Number Of Native Contexts: {d}
        \\ Number Of Detached Contexts: {d}
        \\ Total Global Handles Size: {d}
        \\ Used Global Handles Size: {d}
        \\ Zap Garbage: {any}
        \\
    , .{ stats.total_heap_size, stats.total_heap_size_executable, stats.total_physical_size, stats.total_available_size, stats.used_heap_size, stats.heap_size_limit, stats.malloced_memory, stats.external_memory, stats.peak_malloced_memory, stats.number_of_native_contexts, stats.number_of_detached_contexts, stats.total_global_handles_size, stats.used_global_handles_size, stats.does_zap_garbage });
}

pub fn isExecutionTerminating(self: *const Env) bool {
    return v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle);
}

// Whether a forcible terminate has been requested (and not yet cleared by
// cancelTerminate). Unlike isExecutionTerminating, this is our own sticky
// flag, so it stays true after V8 consumes the terminate on the JSEntry
// unwind. Callers about to enter a fresh eval use it to refuse to run.
pub fn terminatePending(self: *const Env) bool {
    return self.terminate_requested.load(.acquire);
}

pub fn terminate(self: *Env) void {
    self.terminate_mutex.lock();
    defer self.terminate_mutex.unlock();
    v8.v8__Isolate__TerminateExecution(self.isolate.handle);
}

// We need a stable pointer for *Env, so can't be setup in init.
pub fn protectHeapLimit(self: *Env) void {
    v8.v8__Isolate__AddNearHeapLimitCallback(self.isolate.handle, nearHeapLimit, self);
    // TODO: uncomment this when https://github.com/lightpanda-io/zig-v8-fork/pull/187 lands
    // if our nearHeapLimit extends the memory, we want to  restore the original
    // value, since the isolate can be long lived (relative to the page/script
    // that caused the memory spike).
    // v8.v8__Isolate__AutomaticallyRestoreInitialHeapLimit(self.isolate.handle, 0.5);
}

// v8 is telling us it's about to run out of memory for this isolate. We'll
// do two things:
// 1 - Terminate the execution (attempting to prevent v8 from OOM'ing the process)
// 2 - Grant more headroom so execution can reach a stack-guard check, where
//     the terminate lands
//
// The terminate must go through requestTerminate (RequestInterrupt), NOT a
// direct TerminateExecution: we're mid-GC, which is an arbitrary point —
// possibly inside a microtask run — and flagging termination there lets the
// run complete with a result while the isolate is terminating, tripping
// V8's DCHECK(maybe_result.is_null()) in MicrotaskQueue::RunMicrotasks. The
// interrupt lands at a stack-guard check, where termination unwinds the way
// V8 expects.
fn nearHeapLimit(data: ?*anyopaque, current_limit: usize, initial_limit: usize) callconv(.c) usize {
    const self: *Env = @ptrCast(@alignCast(data.?));
    log.err(.app, "JS heap limit reached", .{
        .initial_limit = initial_limit,
        .current_limit = current_limit,
    });
    self.requestTerminate();

    const cap = initial_limit + 256 * 1024 * 1024;
    if (current_limit >= cap) {
        return current_limit;
    }
    return @min(cap, current_limit + 64 * 1024 * 1024);
}

// Called from the network thread, caused v8 to eventually call terminateInterrupt
pub fn requestTerminate(self: *Env) void {
    self.terminate_requested.store(true, .release);
    v8.v8__Isolate__RequestInterrupt(self.isolate.handle, terminateInterrupt, self);
}

// Runs on the worker thread
fn terminateInterrupt(_: ?*v8.Isolate, data: ?*anyopaque) callconv(.c) void {
    const self: *Env = @ptrCast(@alignCast(data.?));
    if (self.terminate_requested.load(.acquire)) {
        v8.v8__Isolate__TerminateExecution(self.isolate.handle);
    }
}

/// Clears a pending termination so V8 calls (e.g. those made during cleanup)
/// don't keep tripping over the terminating-state asserts. Safe to call
/// unconditionally; a no-op if termination wasn't pending. Also clears the
/// requestTerminate gate so any still-pending interrupt becomes a no-op.
pub fn cancelTerminate(self: *Env) void {
    self.terminate_mutex.lock();
    defer self.terminate_mutex.unlock();
    self.terminate_requested.store(false, .release);
    v8.v8__Isolate__CancelTerminateExecution(self.isolate.handle);
}

/// Like `runMicrotasks`, but for the isolate-default queue used by contexts
/// created outside `createContext` (the agent runtime's bare context), which
/// aren't tracked in `contexts`. Guarded so a sighandler-thread terminate
/// can't land mid-checkpoint.
pub fn performIsolateMicrotasks(self: *Env) void {
    self.terminate_mutex.lock();
    defer self.terminate_mutex.unlock();
    if (v8.v8__Isolate__IsExecutionTerminating(self.isolate.handle)) return;
    v8.v8__Isolate__PerformMicrotaskCheckpoint(self.isolate.handle);
}

fn promiseRejectCallback(message_handle: ?*const v8.PromiseRejectMessage) callconv(.c) void {
    const message = message_handle orelse return;
    const promise_event = v8.v8__PromiseRejectMessage__GetEvent(message);
    if (promise_event != v8.kPromiseRejectWithNoHandler and promise_event != v8.kPromiseHandlerAddedAfterReject) {
        return;
    }

    const v8_isolate = v8.v8__Isolate__GetCurrent().?;
    const isolate = js.Isolate{ .handle = v8_isolate };
    const ctx, const v8_context = Context.fromIsolate(isolate) orelse return;

    const promise_handle = v8.v8__PromiseRejectMessage__GetPromise(message) orelse return;
    if (promise_event == v8.kPromiseHandlerAddedAfterReject) {
        // A promise may cross same-isolate realms. Search every Context so the
        // eventual event still targets the realm where the rejection arose.
        for (ctx.env.contexts.items) |candidate| {
            if (candidate.promise_rejections.handlerAdded(promise_handle)) return;
        }
        return;
    }

    const local = js.Local{
        .ctx = ctx,
        .isolate = isolate,
        .handle = v8_context,
        .call_arena = ctx.call_arena,
    };

    const rejection = js.PromiseRejection.init(&local, message).persist() catch |err| {
        log.warn(.browser, "persist rejected promise", .{ .err = err });
        return;
    };
    ctx.promise_rejections.rejected(ctx, rejection) catch |err| {
        rejection.deinit();
        log.warn(.browser, "queue rejected promise", .{ .err = err });
    };
}

fn isJSApiWrapperNativeError(
    _: ?*v8.Isolate,
    object: ?*const v8.Object,
) callconv(.c) bool {
    const handle = object orelse return false;
    if (v8.v8__Object__InternalFieldCount(handle) == 0) return false;

    const tao_ptr = v8.v8__Object__GetAlignedPointerFromInternalField(handle, 0) orelse return false;
    const tao: *const @import("TaggedOpaque.zig") = @ptrCast(@alignCast(tao_ptr));
    if (tao.prototype_len == 0 or tao.prototype_len > bridge.JsApis.len) return false;
    const dom_exception_id = bridge.JsApiLookup.getId(@import("../webapi/DOMException.zig").JsApi);
    for (tao.prototype_chain[0..tao.prototype_len]) |prototype| {
        if (prototype.index == dom_exception_id) return true;
    }
    return false;
}

fn sharedArrayBufferConstructorEnabled(_: ?*const v8.Context) callconv(.c) bool {
    // First-stage Chromium parity: no page is cross-origin isolated yet.
    return false;
}

fn codeGenerationFromStringsAllowed(
    c_context: ?*const v8.Context,
    source: ?*const v8.Value,
    is_code_like: bool,
    modified_source: [*c]?*const v8.String,
) callconv(.c) bool {
    _ = is_code_like;
    if (modified_source == null) return false;
    modified_source[0] = null;
    const context = c_context orelse return false;
    const ctx = Context.fromC(context) orelse return false;
    const value = source orelse return false;

    // M149 disables TrustedTypesUseCodeLike, but Blink still recognizes its
    // own native TrustedScript wrapper independently of V8's flag.
    var trusted_script = false;
    var input_handle: *const v8.String = undefined;
    if (TrustedTypes.codeGenerationPayload(value)) |payload| {
        const local_payload = v8.v8__Global__Get(&payload.handle, ctx.isolate.handle) orelse return false;
        const payload_value: *const v8.Value = @ptrCast(local_payload);
        if (!v8.v8__Value__IsString(payload_value)) return false;
        trusted_script = true;
        input_handle = @ptrCast(local_payload);
    } else if (v8.v8__Value__IsString(value)) {
        input_handle = @ptrCast(value);
    } else {
        // eval(nonString) returns its input without compiling it.  Function
        // constructors have already produced a String by the time V8 calls us.
        return true;
    }

    // `trusted-types-eval` is checked before the default policy and legacy CSP
    // and deliberately returns no replacement.  For direct eval of a genuine
    // TrustedScript that means eval returns the wrapper object unchanged.
    if (ctx.csp_trusted_types.allowsTrustedTypesEval()) return true;

    // The callback already runs inside V8's entered Context and HandleScope.
    // Caller installs the matching Local/call-depth state without opening a
    // nested HandleScope which would invalidate modified_source on return.
    var caller: js.Caller = undefined;
    caller.initWithContext(ctx, context);
    defer caller.deinit();
    const local = &caller.local;

    var compliant = js.String{ .local = local, .handle = input_handle };
    if (ctx.csp_trusted_types.requiresScriptCheck() and !trusted_script) {
        const factory = switch (ctx.global) {
            .frame => |frame| frame.window.getTrustedTypes(),
            .worker => |worker| worker.getTrustedTypes(),
        };
        compliant = switch (TrustedTypes.checkCodeGenerationString(
            factory,
            compliant,
            ctx,
            &ctx.execution,
        )) {
            .blocked => return false,
            .replacement => |replacement| replacement,
        };
    }

    modified_source[0] = compliant.handle;
    return ctx.csp_code_generation.allow_eval;
}

fn wasmCodeGenerationAllowed(
    c_context: ?*const v8.Context,
    _: ?*const v8.String,
) callconv(.c) bool {
    const ctx = Context.fromC(c_context orelse return false) orelse return false;
    return ctx.csp_code_generation.allow_wasm;
}

// Blink's IsMainThread() test maps to a Window realm here. Dedicated workers
// currently share the page Env/isolate and native execution thread, so checking
// the OS thread would incorrectly impose the Window-only limit on workers.
fn isWindowContext(c_context: ?*const v8.Context) bool {
    const ctx = Context.fromC(c_context orelse return false) orelse return false;
    return switch (ctx.global) {
        .frame => true,
        .worker => false,
    };
}

fn throwWasmRangeError(c_isolate: ?*v8.Isolate, message: []const u8) bool {
    const isolate = js.Isolate{ .handle = c_isolate orelse return false };
    _ = isolate.throwException(isolate.createRangeError(message));
    return true;
}

fn wasmModuleOverride(
    c_isolate: ?*v8.Isolate,
    c_context: ?*const v8.Context,
    source: ?*const v8.Value,
    argument_count: c_int,
) callconv(.c) bool {
    // Returning false asks V8 to continue with its ordinary constructor.
    if (!isWindowContext(c_context) or argument_count < 1) return false;
    const value = source orelse return false;

    const byte_length: usize = if (v8.v8__Value__IsArrayBuffer(value))
        v8.v8__ArrayBuffer__ByteLength(@ptrCast(value))
    else if (v8.v8__Value__IsArrayBufferView(value))
        v8.v8__ArrayBufferView__ByteLength(@ptrCast(value))
    else
        return false;

    if (byte_length <= WASM_WIRE_BYTES_LIMIT) return false;
    return throwWasmRangeError(
        c_isolate,
        "WebAssembly.Compile is disallowed on the main thread, " ++
            "if the buffer size is larger than 8MB. Use " ++
            "WebAssembly.compile, compile on a worker thread, or use the flag " ++
            "`--enable-features=WebAssemblyUnlimitedSyncCompilation`.",
    );
}

fn wasmInstanceOverride(
    c_isolate: ?*v8.Isolate,
    c_context: ?*const v8.Context,
    source: ?*const v8.Value,
    argument_count: c_int,
) callconv(.c) bool {
    if (!isWindowContext(c_context) or argument_count < 1) return false;
    const value = source orelse return false;
    if (!v8.v8__Value__IsWasmModuleObject(value)) return false;
    if (v8.v8__WasmModuleObject__WireBytesLength(value) <= WASM_WIRE_BYTES_LIMIT) return false;

    return throwWasmRangeError(
        c_isolate,
        "WebAssembly.Instance is disallowed on the main thread, " ++
            "if the buffer size is larger than 8MB. Use " ++
            "WebAssembly.instantiate, or use the flag " ++
            "`--enable-features=WebAssemblyUnlimitedSyncCompilation`.",
    );
}

fn fatalCallback(c_location: [*c]const u8, c_message: [*c]const u8) callconv(.c) void {
    const location = std.mem.span(c_location);
    const message = std.mem.span(c_message);
    log.fatal(.app, "V8 fatal callback", .{ .location = location, .message = message });
    @import("../../crash_handler.zig").crash("Fatal V8 Error", .{ .location = location, .message = message }, @returnAddress());
}

fn oomCallback(c_location: [*c]const u8, details: ?*const v8.OOMDetails) callconv(.c) void {
    const location = std.mem.span(c_location);
    const detail = if (details) |d| std.mem.span(d.detail) else "";
    log.fatal(.app, "V8 OOM", .{ .location = location, .detail = detail });
    @import("../../crash_handler.zig").crash("V8 OOM", .{ .location = location, .detail = detail }, @returnAddress());
}

const PrivateSymbols = struct {
    const Private = @import("Private.zig");

    child_nodes: Private,
    performance_observer_supported_entry_types: Private,
    webidl_native_conversion_reason: Private,

    fn init(isolate: *v8.Isolate) PrivateSymbols {
        return .{
            .child_nodes = Private.init(isolate, "child_nodes"),
            .performance_observer_supported_entry_types = Private.init(
                isolate,
                "performance_observer_supported_entry_types",
            ),
            .webidl_native_conversion_reason = Private.init(
                isolate,
                "webidl_native_conversion_reason",
            ),
        };
    }

    fn deinit(self: *PrivateSymbols) void {
        self.child_nodes.deinit();
        self.performance_observer_supported_entry_types.deinit();
        self.webidl_native_conversion_reason.deinit();
    }
};

fn initializeFrozenSameObjects(isolate: *v8.Isolate, context: *const v8.Context) error{JsException}!void {
    const source_text = "Object.freeze(PerformanceObserver.supportedEntryTypes)";
    const source = v8.v8__String__NewFromUtf8(
        isolate,
        source_text.ptr,
        v8.kNormal,
        @intCast(source_text.len),
    );
    const script = v8.v8__Script__Compile(context, source, null) orelse
        return error.JsException;
    _ = v8.v8__Script__Run(script, context) orelse
        return error.JsException;
}

const testing = @import("../../testing.zig");

const ContextOwnerPayloadState = struct {
    invoked: std.atomic.Value(usize) = .init(0),
    destroyed: std.atomic.Value(usize) = .init(0),
    wrong_owner: std.atomic.Value(bool) = .init(false),
};

const ContextOwnerPayload = struct {
    state: *ContextOwnerPayloadState,
    expected_owner: *js.Execution,
    expected_context_id: usize,

    fn create(
        state: *ContextOwnerPayloadState,
        expected_owner: *js.Execution,
        expected_context_id: usize,
    ) !OwnerMailbox.OwnedPayload {
        const self = try std.heap.page_allocator.create(ContextOwnerPayload);
        self.* = .{
            .state = state,
            .expected_owner = expected_owner,
            .expected_context_id = expected_context_id,
        };
        return .{
            .data = self,
            .invoke = invoke,
            .destroy = destroy,
        };
    }

    fn invoke(raw: *anyopaque, owner_raw: *anyopaque) !void {
        const self: *ContextOwnerPayload = @ptrCast(@alignCast(raw));
        const owner: *js.Execution = @ptrCast(@alignCast(owner_raw));
        if (owner != self.expected_owner or owner.js.id != self.expected_context_id) {
            self.state.wrong_owner.store(true, .release);
        }
        _ = self.state.invoked.fetchAdd(1, .acq_rel);
    }

    fn destroy(raw: *anyopaque) void {
        const self: *ContextOwnerPayload = @ptrCast(@alignCast(raw));
        _ = self.state.destroyed.fetchAdd(1, .acq_rel);
        std.heap.page_allocator.destroy(self);
    }
};

// DedicatedWorker owns a different isolate and OS thread. Its observable
// global topology is exercised from author code in worker/worker.html; a
// creator-thread unit test must never enter the worker's Context directly.

test "Env: Worker stack-limit scopes restore Window state" {
    // This fixture checks the worker limit at initial evaluation,
    // importScripts, timer, and message entry, then verifies that Window's
    // recursion depth is restored after worker execution. Keeping the probe in
    // author code preserves V8's isolate/thread-affinity contract.
    try testing.htmlRunner("worker/stack-limit.html", .{ .timeout_ms = 8_000 });
}

test "Env: Frame context" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // Frame already has a context created, use it directly
    const ctx = frame.js;

    var ls: js.Local.Scope = undefined;
    ctx.localScope(&ls);
    defer ls.deinit();

    try testing.expectEqual(true, (try ls.local.exec("typeof Node !== 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof WorkerGlobalScope === 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof DedicatedWorkerGlobalScope === 'undefined'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof Float16Array === 'function'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof DisposableStack === 'function'", null)).isTrue());
    try testing.expectEqual(true, (try ls.local.exec("typeof RegExp.escape === 'function'", null)).isTrue());
}

test "Env: agent scheduler re-enters a task Context beneath an entered Context" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const State = struct {
        expected: *Context,
        ran: bool = false,
        wrong_context: bool = false,

        fn run(raw: *anyopaque) anyerror!?u32 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.ran = true;
            const current = v8.v8__Isolate__GetCurrentContext(self.expected.isolate.handle) orelse {
                self.wrong_context = true;
                return null;
            };
            self.wrong_context = Context.fromC(current) != self.expected;
            return null;
        }
    };

    // ScriptManagerBase reaches this shape at the end of a parser-executed
    // script: its Local.Scope is still entered while the agent arbiter runs a
    // timer/message task. V8 must restore the outer Context after the nested
    // enter rather than requiring a per-Context scheduler drain.
    var outer: js.Local.Scope = undefined;
    frame.js.localScope(&outer);
    defer outer.deinit();
    try testing.expectEqual(frame.js, Context.fromC(v8.v8__Isolate__GetCurrentContext(frame.js.isolate.handle).?).?);

    var state = State{ .expected = frame.js };
    try frame.js.scheduler.add(&state, State.run, 0, .{ .name = "nested-enter-regression" });
    try frame.js.env.runMacrotasks();

    try testing.expect(state.ran);
    try testing.expect(!state.wrong_context);
    try testing.expectEqual(frame.js, Context.fromC(v8.v8__Isolate__GetCurrentContext(frame.js.isolate.handle).?).?);
}

test "Env: realm owner target cancels stale payload before Context teardown" {
    // The Browser mailbox is shared by the whole test process. A preceding
    // realm (notably a Worker) may have closed after posting its final wake
    // token; Target.close deliberately leaves that generation-stale node for
    // the next owner drain to destroy. Establish a boundary before creating
    // this realm, while still proving that no callback from an earlier test
    // can cross its teardown boundary and remain invokable here.
    const prior = try testing.test_browser.owner_mailbox.drain();
    try testing.expectEqual(@as(usize, 0), prior.invoked);

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var state: ContextOwnerPayloadState = .{};
    var sender = try frame.js.execution.ownerSender();
    defer sender.deinit();
    const realm_owner = &frame.js.execution;
    const realm_id = frame.js.id;

    // A live delivery proves the Target's opaque owner is this exact realm's
    // Execution rather than a Browser, Worker, or mailbox-global pointer.
    try testing.expectEqual(
        OwnerMailbox.PostResult.queued,
        try sender.postOwned(try ContextOwnerPayload.create(&state, realm_owner, realm_id)),
    );
    const live = try testing.test_browser.owner_mailbox.drain();
    try testing.expectEqual(@as(usize, 1), live.invoked);
    try testing.expectEqual(@as(usize, 0), live.cancelled);
    try testing.expectEqual(@as(usize, 1), state.invoked.load(.acquire));
    try testing.expect(!state.wrong_owner.load(.acquire));

    // Leave a second envelope queued, then destroy the owning Frame/Context.
    // Its destroy callback is deliberately isolate-free; invoking it would
    // compare against a dangling Execution and increment `invoked`.
    try testing.expectEqual(
        OwnerMailbox.PostResult.queued,
        try sender.postOwned(try ContextOwnerPayload.create(&state, realm_owner, realm_id)),
    );
    testing.test_session.closeAllPages();

    const stale = try testing.test_browser.owner_mailbox.drain();
    try testing.expectEqual(@as(usize, 0), stale.invoked);
    try testing.expectEqual(@as(usize, 1), stale.cancelled);
    try testing.expectEqual(@as(usize, 1), state.invoked.load(.acquire));
    try testing.expectEqual(@as(usize, 2), state.destroyed.load(.acquire));

    // A retained Sender also observes the published close boundary without
    // requiring the already-freed Context allocation.
    try testing.expectEqual(
        OwnerMailbox.PostResult.cancelled,
        try sender.postOwned(try ContextOwnerPayload.create(&state, realm_owner, realm_id)),
    );
    try testing.expectEqual(@as(usize, 1), state.invoked.load(.acquire));
    try testing.expectEqual(@as(usize, 3), state.destroyed.load(.acquire));
}

test "Env: Chrome WebAssembly synchronous constructor limits" {
    try testing.htmlRunner("wasm_sync_limits.html", .{ .timeout_ms = 15_000 });
}

test "Env: WindowAgent queue rebind waits for entered contexts" {
    const parent = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // Establish the creator's origin-keyed WindowAgent before constructing an
    // initial about:blank child.
    try parent.js.setWindowAgentCluster("https://parent.example");
    const parent_queue = parent.js.microtask_queue;

    const child = try parent.arena.create(Frame);
    try Frame.init(
        child,
        testing.test_session.nextFrameId(),
        parent._page,
        .{ .parent = parent },
    );
    defer child.deinit();
    try testing.expectEqual(parent_queue, child.js.microtask_queue);

    // This is the fatal shape: another Context is entered when a network
    // commit selects a different WindowAgent for the child. The guarded C++
    // API must decline the Set and leave a pending request instead.
    var parent_scope: js.Local.Scope = undefined;
    parent.js.localScope(&parent_scope);
    try child.js.setWindowAgentCluster("https://child.example");
    try testing.expectEqual(parent_queue, child.js.microtask_queue);
    try testing.expect(child.js.pending_microtask_queue != null);
    parent_scope.deinit();

    parent.js.env.applyPendingMicrotaskQueues();
    try testing.expect(child.js.pending_microtask_queue == null);
    try testing.expect(child.js.microtask_queue != parent_queue);

    var parent_ran = false;
    var child_ran = false;
    const mark = struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const flag: *bool = @ptrCast(@alignCast(data.?));
            flag.* = true;
        }
    }.run;
    v8.v8__MicrotaskQueue__EnqueueMicrotask(
        parent_queue,
        parent.js.isolate.handle,
        mark,
        &parent_ran,
    );
    v8.v8__MicrotaskQueue__EnqueueMicrotask(
        child.js.microtask_queue,
        child.js.isolate.handle,
        mark,
        &child_ran,
    );

    v8.v8__MicrotaskQueue__PerformCheckpoint(parent_queue, parent.js.isolate.handle);
    try testing.expect(parent_ran);
    try testing.expect(!child_ran);
    v8.v8__MicrotaskQueue__PerformCheckpoint(child.js.microtask_queue, child.js.isolate.handle);
    try testing.expect(child_ran);
}
