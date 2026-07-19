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

const js = @import("js.zig");
const Env = @import("Env.zig");
const Origin = @import("Origin.zig");
const Scheduler = @import("Scheduler.zig");
const RejectedPromises = @import("RejectedPromises.zig");
const Execution = @import("Execution.zig");
const CSPCodeGeneration = @import("CSPCodeGeneration.zig");
const CSPTrustedTypes = @import("CSPTrustedTypes.zig");
const OwnerMailbox = @import("../OwnerMailbox.zig");

const Frame = @import("../Frame.zig");
const Page = @import("../Page.zig");
const ScriptManagerBase = @import("../ScriptManagerBase.zig");
const WorkerGlobalScope = @import("../webapi/WorkerGlobalScope.zig");

const v8 = js.v8;
const log = lp.log;
const Caller = js.Caller;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;
const builtin = @import("builtin");

// Chromium 149's Blink V8Initializer::InitializeWorker uses the current
// backing-thread stack position minus this budget. Win32 needs the smaller
// value because of its reserved/guard-page layout (crbug.com/1412239).
pub const WORKER_MAX_STACK_SIZE: usize = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) 492 * 1024 else 500 * 1024;

// Loosely maps to a Browser Page or Worker.
const Context = @This();

pub const GlobalScope = union(enum) {
    frame: *Frame,
    worker: *WorkerGlobalScope,

    pub fn base(self: GlobalScope) [:0]const u8 {
        return switch (self) {
            .frame => |frame| frame.base(),
            .worker => |worker| worker.base(),
        };
    }

    pub fn getJs(self: GlobalScope) *Context {
        return switch (self) {
            .frame => |frame| frame.js,
            .worker => |worker| worker.js,
        };
    }

    pub fn setJs(self: GlobalScope, ctx: *Context) void {
        switch (self) {
            .frame => |frame| frame.js = ctx,
            .worker => |worker| worker.js = ctx,
        }
    }
};

// Blink caches each cross-origin FunctionTemplate by callback within a world,
// then asks that template for a Function in the current V8 Context.  We keep
// the observable half of that model directly on the caller Context: functions
// are shared by every target accessed from this realm, but never leak into a
// sibling realm.  The extra name/receiver fields make the key robust against
// bridge wrappers which compile identical Zig callbacks for multiple IDL
// members (Blink's generated callbacks are distinct in that case).
const CrossOriginFunctionKey = struct {
    callback: usize,
    receiver_template: usize,
    name_hash: u64,
    name_len: u32,
    length: i32,
};

id: usize,
env: *Env,
global: GlobalScope,

// The Page this Context belongs to. For main-world frame contexts, this is
// the Page of the frame. For worker contexts, this is the Page of the
// worker's parent frame — a worker's v8 globals and identity tracking live
// on the same Page as its owning frame (worker dies with its page). The
// Session is always reachable via `page.session`.
page: *Page,

isolate: js.Isolate,

// V8 normally owns one fixed stack limit per isolate/thread. DarkPanda still
// multiplexes Window and DedicatedWorker realms on one isolate, so every
// context entry swaps to this source-derived agent limit and restores the
// exact previous V8 limit on exit. Frame limits are captured unchanged from
// V8; worker limits mirror Blink's InitializeWorker calculation.
execution_stack_limit: usize,

// V8 queue for this Context. Window contexts with the same AgentClusterKey
// share one Page-owned queue; workers and opaque Window agents keep a distinct
// Page-owned queue.
microtask_queue: *v8.MicrotaskQueue,
microtask_queue_kind: MicrotaskQueueKind = .exclusive,

// Agent-cluster selection can happen in a network callback while unrelated
// author JS is still entered (for example a wait predicate surrounding an
// event-loop tick). V8 makes SetMicrotaskQueue process-fatal in that state, so
// retain the desired queue until the next context-free host boundary.
pending_microtask_queue: ?*v8.MicrotaskQueue = null,

// Context::DetachGlobal makes it safe for the Page owner to destroy this
// Context's queue even if V8 has not collected the detached native context.
global_detached: bool = false,

// The v8::Global<v8::Context>. When necessary, we can create a v8::Local<<v8::Context>>
// from this, and we can free it when the context is done.
handle: v8.Global,

cpu_profiler: ?*v8.CpuProfiler = null,

heap_profiler: ?*v8.HeapProfiler = null,

// references Env.templates
templates: []*const v8.FunctionTemplate,

// Strong handles for Chrome-compatible cross-origin operation/accessor
// identity. These are deliberately Context-owned rather than target-owned:
// `a.postMessage === b.postMessage` for two cross-origin targets in one realm.
cross_origin_functions: std.AutoHashMapUnmanaged(CrossOriginFunctionKey, v8.Global) = .empty,

// Arena for the lifetime of the context
arena: Allocator,

// The call_arena for this context. For main world contexts this is
// frame.call_arena. For isolated world contexts this is a separate arena
// owned by the IsolatedWorld.
call_arena: Allocator,

// Like call_arena, but reset on _every_ Caller.deinit rather than only at
// call_depth 0.
local_arena: Allocator,

// Because calls can be nested (i.e.a function calling a callback),
// we can only reset the call_arena when call_depth == 0. If we were
// to reset it within a callback, it would invalidate the data of
// the call which is calling the callback.
call_depth: usize = 0,

// When a Caller is active (V8->Zig callback), this points to its Local.
// When null, Zig->V8 calls must create a js.Local.Scope and initialize via
// context.localScope
local: ?*const js.Local = null,

origin: *Origin,

// Identity tracking for this context. For main world contexts, this points to
// Session's Identity. For isolated world contexts (CDP inspector), this points
// to IsolatedWorld's Identity. This ensures same-origin frames share object
// identity while isolated worlds have separate identity tracking.
identity: *js.Identity,

// Allocator to use for identity map operations. For main world contexts this is
// page.frame_arena, for isolated worlds it's the isolated world's arena.
identity_arena: Allocator,

// Unlike other v8 types, like functions or objects, modules are not shared
// across origins.
global_modules: std.ArrayList(v8.Global) = .empty,

// Our module cache: normalized module specifier => module.
module_cache: std.StringHashMapUnmanaged(ModuleEntry) = .empty,

// Module => Path. The key is the module hashcode (module.getIdentityHash)
// and the value is the full path to the module. We need to capture this
// so that when we're asked to resolve a dependent module, and all we're
// given is the specifier, we can form the full path. The full path is
// necessary to lookup/store the dependent module in the module_cache.
module_identifier: std.AutoHashMapUnmanaged(u32, [:0]const u8) = .empty,

// Module-loading plumbing. Frame contexts point at the ScriptManager's
// embedded Base; worker contexts point at WorkerGlobalScope's Base directly.
script_manager: *ScriptManagerBase,

// Our macrotasks
scheduler: Scheduler,

// Chromium-style two-stage unhandled promise rejection bookkeeping. Entries
// are owned by their originating Context even when a handler is attached from
// another same-isolate realm.
promise_rejections: RejectedPromises,

// Embedder operations which own native V8 resources past a callback return
// (for example, a WasmStreaming decoder consuming a ReadableStream). Context
// teardown must cancel them before clearing embedder data and the microtask
// queue, otherwise their native holders would outlive the realm.
pending_embedder_operations: std.ArrayList(PendingEmbedderOperation) = .empty,

// Execution context for worker-compatible APIs. This provides a common
// interface that works in both Page and Worker contexts.
execution: Execution,

// Per-realm delivery boundary for native work posted from foreign threads.
// The mailbox invokes through `execution` only while this Target is open;
// teardown closes it before any scheduler, V8, or arena state is released.
owner_target: OwnerMailbox.Target,

// Enforced CSP state needed by V8's eval/Function and Wasm code-generation
// callbacks. This is deliberately narrower than a full loader CSP engine.
csp_code_generation: CSPCodeGeneration = .{},

// Enforced CSP state for require-trusted-types-for/trusted-types.  Kept
// separate from dynamic-code CSP because DOM sink and policy-name decisions
// compose independently from eval/WebAssembly permissions.
csp_trusted_types: CSPTrustedTypes = .{},

unknown_properties: (if (IS_DEBUG) std.StringHashMapUnmanaged(UnknownPropertyStat) else void) = if (IS_DEBUG) .{} else {},

const ModuleEntry = struct {
    // Can be null if we're asynchronously loading the module, in
    // which case resolver_promise cannot be null.
    module: ?js.Module.Global = null,

    // The promise of the evaluating module. The resolved value is
    // meaningless to us, but the resolver promise needs to chain
    // to this, since we need to know when it's complete.
    module_promise: ?js.Promise.Global = null,

    // The promise for the resolver which is loading the module.
    // (AKA, the first time we try to load it). This resolver will
    // chain to the module_promise  and, when it's done evaluating
    // will resolve its namespace. Any other attempt to load the
    // module willchain to this.
    resolver_promise: ?js.Promise.Global = null,
};

pub const MicrotaskQueueKind = enum {
    // Fresh queue used by only this Context and eligible for adoption by a
    // newly-created WindowAgent entry.
    exclusive,
    // Initial about:blank child/popup queue inherited while an outer Context
    // is entered. It is shared but not necessarily registered by origin yet.
    inherited,
    // Queue registered in Page.window_agent_microtask_queues.
    window_agent,
};

pub fn fromC(c_context: *const v8.Context) ?*Context {
    return @ptrCast(@alignCast(v8.v8__Context__GetAlignedPointerFromEmbedderData(c_context, 1)));
}

/// Return the caller-realm Function for a cross-origin IDL callback.
///
/// A real receiver Signature is essential: V8 rejects a non-Window/Location
/// receiver with `TypeError: Illegal invocation` before the callback performs
/// Web IDL argument conversion. Function::New cannot express that ordering.
pub fn crossOriginFunction(
    self: *Context,
    receiver_template_index: usize,
    comptime callback: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,
    comptime name: []const u8,
    length: i32,
) !js.Value {
    const local = self.local orelse return error.InvalidStateError;
    const receiver_template = self.templates[receiver_template_index];
    const key: CrossOriginFunctionKey = .{
        .callback = @intFromPtr(callback),
        .receiver_template = @intFromPtr(receiver_template),
        .name_hash = std.hash.Wyhash.hash(0, name),
        .name_len = @intCast(name.len),
        .length = length,
    };

    if (self.cross_origin_functions.getPtr(key)) |global| {
        return .{
            .local = local,
            .handle = @ptrCast(v8.v8__Global__Get(global, self.isolate.handle)),
        };
    }

    const signature = v8.v8__Signature__New(self.isolate.handle, receiver_template);
    const function_template = v8.v8__FunctionTemplate__New__Config(self.isolate.handle, &.{
        .callback = callback,
        .signature = signature,
        .length = length,
        .behavior = v8.kConstructorBehavior_Throw,
        .side_effect_type = v8.kSideEffectType_HasSideEffect,
    }) orelse return error.FunctionCreateFailed;
    v8.v8__FunctionTemplate__SetClassName(
        function_template,
        self.isolate.initStringHandle(name),
    );
    const function = v8.v8__FunctionTemplate__GetFunction(function_template, local.handle) orelse
        return error.FunctionCreateFailed;

    var global: v8.Global = undefined;
    v8.v8__Global__New(self.isolate.handle, function, &global);
    errdefer v8.v8__Global__Reset(&global);
    try self.cross_origin_functions.put(self.arena, key, global);

    return .{ .local = local, .handle = @ptrCast(function) };
}

/// Add an enforced Content-Security-Policy header or meta policy to this realm.
/// Policies only accumulate: CSP combines multiple policies by intersection.
pub fn addContentSecurityPolicy(self: *Context, serialized: []const u8) !void {
    // Stage both narrow CSP projections before publishing either one.  The
    // list copy may share its old backing allocation, but its original length
    // remains unchanged until this commit; arena-backed failed staging cannot
    // leave an observable half-policy.
    const eval_was_disabled = !self.csp_code_generation.allow_eval or
        self.csp_trusted_types.requiresScriptCheck();
    var staged_codegen = self.csp_code_generation;
    var staged_trusted_types = self.csp_trusted_types;
    const update = try staged_codegen.addSerialized(self.arena, serialized);
    try staged_trusted_types.addSerialized(self.arena, serialized);
    self.csp_code_generation = staged_codegen;
    self.csp_trusted_types = staged_trusted_types;
    const eval_is_disabled = !self.csp_code_generation.allow_eval or
        self.csp_trusted_types.requiresScriptCheck();
    const eval_became_disabled = !eval_was_disabled and eval_is_disabled;
    if (!eval_became_disabled and !update.wasm_became_blocked) return;

    // Blink records the first reason which disables string compilation.  In
    // one policy legacy CSP is checked before Trusted Types; later policies
    // cannot replace the already-installed V8 EvalError message.
    const eval_message: ?[]const u8 = if (!eval_became_disabled)
        null
    else if (update.eval_became_blocked)
        try self.csp_code_generation.evalErrorMessage(self.arena)
    else
        CSPTrustedTypes.code_generation_error_message;
    const wasm_message: ?[]const u8 = if (update.wasm_became_blocked)
        try self.csp_code_generation.wasmErrorMessage(self.arena)
    else
        null;
    if (self.local) |local| {
        return self.applyCodeGenerationPolicy(local.handle, eval_message, wasm_message);
    }

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();
    return self.applyCodeGenerationPolicy(ls.local.handle, eval_message, wasm_message);
}

/// Add a response Content-Security-Policy-Report-Only field. Legacy eval/Wasm
/// restrictions never block from this disposition, but a TT requirement still
/// has to route V8 through the modify callback so the default policy and
/// report-only failure semantics are observable.
pub fn addContentSecurityPolicyReportOnly(self: *Context, serialized: []const u8) !void {
    const eval_was_disabled = !self.csp_code_generation.allow_eval or
        self.csp_trusted_types.requiresScriptCheck();
    var staged = self.csp_trusted_types;
    try staged.addSerializedReportOnly(self.arena, serialized);
    self.csp_trusted_types = staged;
    const eval_is_disabled = !self.csp_code_generation.allow_eval or
        self.csp_trusted_types.requiresScriptCheck();
    if (eval_was_disabled or !eval_is_disabled) return;

    const message: ?[]const u8 = CSPTrustedTypes.code_generation_error_message;
    if (self.local) |local| {
        return self.applyCodeGenerationPolicy(local.handle, message, null);
    }
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();
    return self.applyCodeGenerationPolicy(ls.local.handle, message, null);
}

/// HTML's worker-policy initialization inherits the owner's policies for
/// local-scheme workers (about/data/blob/filesystem). This code-generation
/// subset retains the first directives which established each effective
/// block, so replaying those directives produces the same intersection in the
/// new realm without pretending to clone a complete CSP policy container.
pub fn inheritContentSecurityPolicyCodeGeneration(
    self: *Context,
    source: *const Context,
) !void {
    if (!source.csp_code_generation.allow_eval) {
        try self.addContentSecurityPolicy(
            source.csp_code_generation.eval_blocking_directive orelse unreachable,
        );
    }
    if (!source.csp_code_generation.allow_wasm) {
        try self.addContentSecurityPolicy(
            source.csp_code_generation.wasm_blocking_directive orelse unreachable,
        );
    }
    const trusted_types_was_required = self.csp_trusted_types.requiresScriptCheck();
    try self.csp_trusted_types.inheritFrom(self.arena, &source.csp_trusted_types);
    if (!trusted_types_was_required and
        self.csp_trusted_types.requiresScriptCheck() and
        self.csp_code_generation.allow_eval)
    {
        const message: ?[]const u8 = CSPTrustedTypes.code_generation_error_message;
        if (self.local) |local| {
            return self.applyCodeGenerationPolicy(local.handle, message, null);
        }
        var ls: js.Local.Scope = undefined;
        self.localScope(&ls);
        defer ls.deinit();
        return self.applyCodeGenerationPolicy(ls.local.handle, message, null);
    }
}

fn applyCodeGenerationPolicy(
    self: *Context,
    v8_context: *const v8.Context,
    eval_message: ?[]const u8,
    wasm_message: ?[]const u8,
) void {
    if (eval_message) |message| {
        v8.v8__Context__AllowCodeGenerationFromStrings(v8_context, false);
        v8.v8__Context__SetErrorMessageForCodeGenerationFromStrings(
            v8_context,
            self.isolate.initStringHandle(message),
        );
    }
    if (wasm_message) |message| {
        v8.v8__Context__SetErrorMessageForWasmCodeGeneration(
            v8_context,
            self.isolate.initStringHandle(message),
        );
    }
}

/// Returns the Context and v8::Context for the given isolate.
/// If the current context is from a destroyed Context (e.g., navigated-away iframe),
/// falls back to the incumbent context (the calling context).
/// Returns null if neither context has a valid Context struct (both were destroyed).
pub fn fromIsolate(isolate: js.Isolate) ?struct { *Context, *const v8.Context } {
    const v8_context = v8.v8__Isolate__GetCurrentContext(isolate.handle).?;
    if (fromC(v8_context)) |ctx| {
        return .{ ctx, v8_context };
    }
    // The current context's Context struct has been freed (e.g., iframe navigated away).
    // Fall back to the incumbent context (the calling context).
    const v8_incumbent = v8.v8__Isolate__GetIncumbentContext(isolate.handle).?;
    const ctx = fromC(v8_incumbent) orelse return null;
    return .{ ctx, v8_incumbent };
}

pub fn deinit(self: *Context) void {
    if (comptime IS_DEBUG and @import("builtin").is_test == false) {
        var it = self.unknown_properties.iterator();
        while (it.next()) |kv| {
            log.debug(.unknown_prop, "unknown property", .{
                .property = kv.key_ptr.*,
                .occurrences = kv.value_ptr.count,
                .first_stack = kv.value_ptr.first_stack,
            });
        }
    }

    const env = self.env;
    defer env.app.arena_pool.release(self.arena);

    // Publish the realm-dead boundary before unlinking any subsystem which
    // may still own a Sender. Queued nodes retain their native TargetCore but
    // can no longer recover this Context's Execution pointer.
    self.closeOwnerTarget();
    self.owner_target.deinit();

    // Unlink any IndexedDB gate participants first: the session-scoped engine
    // must never wake a waiter into this scheduler once it's torn down.
    self.page.session.idb.detachContext(self);

    if (!self.global_detached) self.detachGlobal();

    var hs: js.HandleScope = undefined;
    const entered = self.enter(&hs);
    defer entered.exit();

    while (self.pending_embedder_operations.pop()) |operation| {
        operation.cancel(operation.data);
    }
    self.pending_embedder_operations.deinit(self.arena);

    // this can release objects
    self.scheduler.deinit();
    self.promise_rejections.deinit();

    var cross_origin_functions = self.cross_origin_functions.iterator();
    while (cross_origin_functions.next()) |entry| {
        v8.v8__Global__Reset(entry.value_ptr);
    }
    self.cross_origin_functions.deinit(self.arena);

    for (self.global_modules.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    self.env.releaseContextOrigin(self.page, self.origin);

    // Clear the embedder data so that if V8 keeps this context alive
    // (because objects created in it are still referenced), we don't
    // have a dangling pointer to our freed Context struct.
    v8.v8__Context__SetAlignedPointerInEmbedderData(entered.handle, 1, null);

    v8.v8__Global__Reset(&self.handle);
    env.isolate.notifyContextDisposed();
    // There can be other tasks associated with this context that we need to
    // purge while the context is still alive. The Page, not this Context,
    // owns the MicrotaskQueue: V8 permits a detached realm to remain alive
    // through another Global and requires its queue to outlive that realm.
    _ = env.pumpMessageLoop();
}

/// Acquire a retained producer handle on the realm's owner thread. The
/// returned Sender is thread-safe and may outlive this Context; posts after
/// close are cancelled without dereferencing `execution`.
pub fn ownerSender(self: *const Context) OwnerMailbox.TargetError!OwnerMailbox.Sender {
    return self.owner_target.sender();
}

/// Idempotently reject new posts and invalidate every queued realm payload.
pub fn closeOwnerTarget(self: *Context) void {
    self.owner_target.close();
}

pub const PendingEmbedderOperation = struct {
    data: *anyopaque,
    cancel: *const fn (data: *anyopaque) void,
};

pub fn registerPendingEmbedderOperation(
    self: *Context,
    operation: PendingEmbedderOperation,
) !void {
    try self.pending_embedder_operations.append(self.arena, operation);
}

pub fn unregisterPendingEmbedderOperation(self: *Context, data: *anyopaque) void {
    for (self.pending_embedder_operations.items, 0..) |operation, i| {
        if (operation.data == data) {
            _ = self.pending_embedder_operations.orderedRemove(i);
            return;
        }
    }
}

// The global (e.g. Window) can be reused across contexts. If you do:
//
// var w = iframe.contentWindow;
// iframe.src = 'two.html';
// w === iframe.contentWindow  (must be true)
//
// so when we navigate, the Window/Global is re-used. That's fine with v8, but
// we need to explicitly detach it from the original before we can safely attach
// it to the new
pub fn detachGlobal(self: *Context) void {
    if (self.global_detached) return;

    var hs: js.HandleScope = undefined;
    hs.init(self.isolate);
    defer hs.deinit();

    const local_v8_context: *const v8.Context = @ptrCast(v8.v8__Global__Get(&self.handle, self.isolate.handle));
    v8.v8__Context__DetachGlobal(local_v8_context);
    self.global_detached = true;
}

// Install an already-retained Origin and its exact V8 security-token object.
// Keeping acquisition separate makes the ownership boundary explicit: same-
// Page inheritance retains the pointer, while cross-Page inheritance copies
// the key into an Origin owned by the destination Page.
fn installOrigin(self: *Context, origin: *Origin) void {
    self.env.releaseContextOrigin(self.page, self.origin);
    self.origin = origin;

    {
        var ls: js.Local.Scope = undefined;
        self.localScope(&ls);
        defer ls.deinit();

        // Set the V8::Context SecurityToken, which is a big part of what allows
        // one context to access another.
        const token_local = v8.v8__Global__Get(&origin.security_token, self.isolate.handle);
        v8.v8__Context__SetSecurityToken(ls.local.handle, token_local);
    }
}

// setOriginKey is called at navigation (opaque -> real/inherited origin) and
// again when a script sets document.domain. Passing null creates a new unique
// opaque identity; passing a captured opaque key recovers the Page-local
// identity if it is still alive.
pub fn setOriginKey(self: *Context, key: ?[]const u8) !void {
    self.installOrigin(try self.env.acquireContextOrigin(self.page, key));
}

// Preserve pointer identity inside one Page. A root Page replacement must not
// retain an Origin owned by the retiring Page, so that path deliberately
// recreates the identity from its copied opaque key instead.
pub fn inheritOrigin(self: *Context, source: *const Context) !void {
    const origin = if (self.env.isDedicatedWorker())
        try self.env.acquireContextOrigin(self.page, source.origin.key)
    else if (self.page == source.page)
        self.page.retainOrigin(source.origin)
    else
        try self.page.getOrCreateOrigin(source.origin.key);
    self.installOrigin(origin);
}

// Compatibility name for callers which are assigning a serialized/effective
// origin rather than inheriting a live Context identity.
pub fn setOrigin(self: *Context, key: ?[]const u8) !void {
    return self.setOriginKey(key);
}

// Associate a Window realm with the origin-keyed WindowAgent chosen at
// navigation commit. This is intentionally separate from setOrigin():
// document.domain changes the effective security origin but does not move a
// Document to another agent cluster.
pub fn setWindowAgentCluster(self: *Context, key: ?[]const u8) !void {
    switch (self.global) {
        .worker => return,
        .frame => {},
    }

    const agent_key = key orelse {
        if (self.microtask_queue_kind != .window_agent) return;
        const queue = try self.page.createMicrotaskQueue();
        self.microtask_queue_kind = .exclusive;
        self.requestMicrotaskQueue(queue);
        return;
    };

    const candidate = if (self.microtask_queue_kind == .exclusive)
        self.pending_microtask_queue orelse self.microtask_queue
    else
        null;
    const agent = try self.page.getOrCreateWindowAgentMicrotaskQueue(
        agent_key,
        candidate,
    );
    self.microtask_queue_kind = .window_agent;
    self.requestMicrotaskQueue(agent.queue);
}

fn requestMicrotaskQueue(self: *Context, queue: *v8.MicrotaskQueue) void {
    // A second navigation can return to the currently-installed queue before
    // the first deferred rebind was applied.
    if (queue == self.microtask_queue) {
        self.pending_microtask_queue = null;
        return;
    }

    var hs: js.HandleScope = undefined;
    hs.init(self.isolate);
    defer hs.deinit();

    const context: *const v8.Context = @ptrCast(v8.v8__Global__Get(
        &self.handle,
        self.isolate.handle,
    ));
    if (v8.v8__Context__TrySetMicrotaskQueue(context, queue)) {
        self.microtask_queue = queue;
        self.pending_microtask_queue = null;
    } else {
        self.pending_microtask_queue = queue;
    }
}

// Called only from host boundaries. The guarded binding still verifies V8's
// actual entered-context and MicrotasksScope state, so a nested embedder call
// can never turn a bookkeeping mistake into a process-fatal ApiCheck.
pub fn applyPendingMicrotaskQueue(self: *Context) bool {
    const queue = self.pending_microtask_queue orelse return true;
    self.requestMicrotaskQueue(queue);
    return self.pending_microtask_queue == null;
}

pub const IdentityResult = struct {
    value_ptr: *v8.Global,
    found_existing: bool,
};

pub fn addIdentity(self: *Context, ptr: usize) !IdentityResult {
    const gop = try self.identity.identity_map.getOrPut(self.identity_arena, ptr);
    return .{
        .value_ptr = gop.value_ptr,
        .found_existing = gop.found_existing,
    };
}

// Any operation on the context have to be made from a local.
pub fn localScope(self: *Context, ls: *js.Local.Scope) void {
    // Install any agent queue selected by the preceding task before this realm
    // is entered again. If this is itself a nested callback, TrySet leaves the
    // request pending without invoking V8's fatal SetMicrotaskQueue path.
    self.env.applyPendingMicrotaskQueues();

    const isolate = self.isolate;
    const previous_stack_limit = isolate.swapStackLimit(self.execution_stack_limit);
    js.HandleScope.init(&ls.handle_scope, isolate);

    const local_v8_context: *const v8.Context = @ptrCast(v8.v8__Global__Get(&self.handle, isolate.handle));
    v8.v8__Context__Enter(local_v8_context);

    // TODO: add and init ls.hs  for the handlescope
    ls.local = .{
        .ctx = self,
        .isolate = isolate,
        .handle = local_v8_context,
        .call_arena = self.call_arena,
    };
    ls.previous_stack_limit = previous_stack_limit;
}

pub fn toLocal(self: *Context, global: anytype) js.Local.ToLocalReturnType(@TypeOf(global)) {
    const l = self.local orelse @panic("toLocal called without active Caller context");
    return l.toLocal(global);
}

// This context's global (proxy) object, bound to an already-active local.
// Lets a caller running in a different context — e.g. a [Replaceable] setter
// invoked on another same-origin window — target this context's global rather
// than its own.
pub fn globalObject(self: *Context, local: *const js.Local) js.Object {
    const local_v8_context: *const v8.Context = @ptrCast(v8.v8__Global__Get(&self.handle, self.isolate.handle));
    return .{
        .local = local,
        .handle = v8.v8__Context__Global(local_v8_context).?,
    };
}

pub fn getIncumbent(self: *Context) *Frame {
    const ctx = fromC(v8.v8__Isolate__GetIncumbentContext(self.env.isolate.handle).?).?;
    return switch (ctx.global) {
        .frame => |frame| frame,
        .worker => unreachable,
    };
}

pub fn stringToPersistedFunction(
    self: *Context,
    function_body: []const u8,
    comptime parameter_names: []const []const u8,
    extensions: []const v8.Object,
) !js.Function.Global {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const js_function = try ls.local.compileFunction(function_body, parameter_names, extensions);
    return js_function.persist();
}

pub const ModuleErrorReport = js.TryCatch.ErrorReport;

const ModuleErrorSink = struct {
    allocator: Allocator,
    report: *?ModuleErrorReport,
    retain_exception: bool = false,
    fallback_url: ?[]const u8 = null,
};

pub fn module(self: *Context, comptime want_result: bool, local: *const js.Local, src: []const u8, url: []const u8, cacheable: bool) !(if (want_result) ModuleEntry else void) {
    return self.moduleImpl(want_result, local, src, url, cacheable, null);
}

/// Evaluate a module while retaining V8's isolate-local diagnostic as plain
/// bytes/numbers. Dedicated workers use this before crossing their owner
/// mailbox: a module evaluation failure is stored on v8::Module rather than in
/// the surrounding TryCatch, so the ordinary classic-script path cannot see it.
pub fn moduleWithErrorReport(
    self: *Context,
    comptime want_result: bool,
    local: *const js.Local,
    src: []const u8,
    url: []const u8,
    cacheable: bool,
    allocator: Allocator,
    report: *?ModuleErrorReport,
) !(if (want_result) ModuleEntry else void) {
    report.* = null;
    return self.moduleImpl(want_result, local, src, url, cacheable, .{
        .allocator = allocator,
        .report = report,
    });
}

/// Main-thread module evaluation keeps the original V8 exception so the
/// Window ErrorEvent can expose strict identity through event.error and the
/// fifth onerror argument. Worker callers intentionally keep using the plain
/// report above because a V8 value cannot cross their owner mailbox.
pub fn moduleWithWindowErrorReport(
    self: *Context,
    comptime want_result: bool,
    local: *const js.Local,
    src: []const u8,
    url: []const u8,
    cacheable: bool,
    fallback_url: []const u8,
    allocator: Allocator,
    report: *?ModuleErrorReport,
) !(if (want_result) ModuleEntry else void) {
    report.* = null;
    return self.moduleImpl(want_result, local, src, url, cacheable, .{
        .allocator = allocator,
        .report = report,
        .retain_exception = true,
        .fallback_url = fallback_url,
    });
}

fn moduleImpl(
    self: *Context,
    comptime want_result: bool,
    local: *const js.Local,
    src: []const u8,
    url: []const u8,
    cacheable: bool,
    error_sink: ?ModuleErrorSink,
) !(if (want_result) ModuleEntry else void) {
    const mod, const owned_url = blk: {
        const arena = self.arena;

        // gop will _always_ initiated if cacheable == true
        var gop: std.StringHashMapUnmanaged(ModuleEntry).GetOrPutResult = undefined;
        if (cacheable) {
            gop = try self.module_cache.getOrPut(arena, url);
            if (gop.found_existing) {
                if (gop.value_ptr.module) |cache_mod| {
                    if (gop.value_ptr.module_promise == null) {
                        // This an usual case, but it can happen if a module is
                        // first asynchronously requested and then synchronously
                        // requested as a child of some root import. In that case,
                        // the module may not be instantiated yet (so we have to
                        // do that). It might not be evaluated yet. So we have
                        // to do that too. Evaluation is particularly important
                        // as it sets up our cache entry's module_promise.
                        // It appears that v8 handles potential double-instantiated
                        // and double-evaluated modules safely. The 2nd instantiation
                        // is a no-op, and the second evaluation returns the same
                        // promise.
                        const mod = local.toLocal(cache_mod);
                        if (mod.getStatus() == .kUninstantiated and try mod.instantiate(resolveModuleCallback) == false) {
                            return error.ModuleInstantiationError;
                        }
                        return self.evaluateModule(want_result, mod, url, true, error_sink);
                    }
                    return if (comptime want_result) gop.value_ptr.* else {};
                }
            } else {
                // first time seeing this
                gop.value_ptr.* = .{};
            }
        }

        const owned_url = try arena.dupeZ(u8, url);
        if (cacheable and !gop.found_existing) {
            gop.key_ptr.* = owned_url;
        }
        const m = try compileModule(local, src, owned_url);

        if (cacheable) {
            // compileModule is synchronous - nothing can modify the cache during compilation
            lp.assert(gop.value_ptr.module == null, "Context.module has module", .{});
            gop.value_ptr.module = try m.persist();
        }

        break :blk .{ m, owned_url };
    };

    try self.postCompileModule(mod, owned_url, local);

    if (try mod.instantiate(resolveModuleCallback) == false) {
        return error.ModuleInstantiationError;
    }

    return self.evaluateModule(want_result, mod, owned_url, cacheable, error_sink);
}

fn evaluateModule(
    self: *Context,
    comptime want_result: bool,
    mod: js.Module,
    url: []const u8,
    cacheable: bool,
    error_sink: ?ModuleErrorSink,
) !(if (want_result) ModuleEntry else void) {
    const evaluated = mod.evaluate() catch {
        if (comptime IS_DEBUG) {
            std.debug.assert(mod.getStatus() == .kErrored);
        }

        // Some module-loading errors aren't handled by TryCatch. We need to
        // get the error from the module itself.
        const exception = mod.getException();
        if (error_sink) |sink| {
            sink.report.* = try captureModuleError(
                localFromModule(mod),
                exception,
                sink.fallback_url orelse url,
                sink.allocator,
                sink.retain_exception,
            );
        }
        const message = blk: {
            const e = exception.toString() catch break :blk "???";
            break :blk e.toSlice() catch "???";
        };
        const stack = blk: {
            if (comptime IS_DEBUG == false) {
                // SetCaptureStackTraceForUncaughtExceptions is only set in Debug
                break :blk "";
            }

            const stack_handle = v8.v8__Exception__GetStackTrace(exception.handle) orelse break :blk "";
            var buf = std.Io.Writer.Allocating.init(self.call_arena);
            js.writeStackTrace(self.isolate.handle, stack_handle, &buf.writer) catch break :blk "???";
            break :blk buf.written();
        };

        log.warn(.js, "evaluate module", .{
            .stack = stack,
            .specifier = url,
            .message = message,
        });
        return error.EvaluationError;
    };

    // https://v8.github.io/api/head/classv8_1_1Module.html#a1f1758265a4082595757c3251bb40e0f
    // Must be a promise that gets returned here.
    lp.assert(evaluated.isPromise(), "Context.module non-promise", .{});

    if (!cacheable) {
        switch (comptime want_result) {
            false => return,
            true => unreachable,
        }
    }

    // entry has to have been created atop this function
    const entry = self.module_cache.getPtr(url).?;

    // and the module must have been set after we compiled it
    lp.assert(entry.module != null, "Context.module with module", .{});
    if (entry.module_promise != null) {
        // While loading this script, it's possible that it was dynamically
        // included (either the module dynamically loaded itself (unlikely) or
        // it included a script which dynamically imported it). If it was, then
        // the module_promise would already be setup, and we don't need to do
        // anything
    } else {
        // The *much* more likely case where the module we're trying to load
        // didn't [directly or indirectly] dynamically load itself.
        entry.module_promise = try evaluated.toPromise().persist();
    }
    return if (comptime want_result) entry.* else {};
}

fn localFromModule(mod: js.Module) *const js.Local {
    return mod.local;
}

fn captureModuleError(
    local: *const js.Local,
    exception: js.Value,
    fallback_url: []const u8,
    allocator: Allocator,
    retain_exception: bool,
) !ModuleErrorReport {
    var filename = try allocator.dupe(u8, fallback_url);
    var message = try allocator.dupe(u8, "EvaluationError");
    var lineno: u32 = 0;
    var colno: u32 = 0;

    if (v8.v8__Exception__CreateMessage(local.isolate.handle, exception.handle)) |v8_message| {
        if (v8.v8__Message__Get(v8_message)) |message_handle| {
            message = js.String.toSliceWithAlloc(.{
                .local = local,
                .handle = message_handle,
            }, allocator) catch message;
        }
        if (v8.v8__Message__GetScriptResourceName(v8_message)) |resource_handle| {
            const resource = js.Value{ .local = local, .handle = resource_handle };
            if (resource.isString()) |resource_string| {
                filename = resource_string.toSliceWithAlloc(allocator) catch filename;
            }
        }

        const line_number = v8.v8__Message__GetLineNumber(v8_message, local.handle);
        if (line_number >= 0) lineno = @intCast(line_number);
        const start_column = v8.v8__Message__GetStartColumn(v8_message);
        if (start_column >= 0) colno = @intCast(start_column + 1);
    }

    return .{
        .message = message,
        .filename = filename,
        .lineno = lineno,
        .colno = colno,
        .exception = if (retain_exception) try exception.persist() else null,
    };
}

fn compileModule(local: *const js.Local, src: []const u8, name: []const u8) !js.Module {
    var origin_handle: v8.ScriptOrigin = undefined;
    v8.v8__ScriptOrigin__CONSTRUCT2(
        &origin_handle,
        local.isolate.initStringHandle(name),
        0, // resource_line_offset
        0, // resource_column_offset
        false, // resource_is_shared_cross_origin
        -1, // script_id
        null, // source_map_url
        false, // resource_is_opaque
        false, // is_wasm
        true, // is_module
        null, // host_defined_options
    );

    var source_handle: v8.ScriptCompilerSource = undefined;
    v8.v8__ScriptCompiler__Source__CONSTRUCT2(
        local.isolate.initStringHandle(src),
        &origin_handle,
        null, // cached data
        &source_handle,
    );

    defer v8.v8__ScriptCompiler__Source__DESTRUCT(&source_handle);

    const module_handle = v8.v8__ScriptCompiler__CompileModule(
        local.isolate.handle,
        &source_handle,
        v8.kNoCompileOptions,
        v8.kNoCacheNoReason,
    ) orelse {
        return error.JsException;
    };

    return .{
        .local = local,
        .handle = module_handle,
    };
}

// After we compile a module, whether it's a top-level one, or a nested one,
// we always want to track its identity (so that, if this module imports other
// modules, we can resolve the full URL), and preload any dependent modules.
fn postCompileModule(self: *Context, mod: js.Module, url: [:0]const u8, local: *const js.Local) !void {
    try self.module_identifier.putNoClobber(self.arena, mod.getIdentityHash(), url);

    // Non-async modules are blocking. We can download them in parallel, but
    // they need to be processed serially. So we want to get the list of
    // dependent modules this module has and start downloading them asap.
    const requests = mod.getModuleRequests();
    const request_len = requests.len();
    const script_manager = self.script_manager;
    for (0..request_len) |i| {
        const specifier = requests.get(i).specifier(local);
        const normalized_specifier = script_manager.resolveSpecifier(
            self.call_arena,
            url,
            try specifier.toSliceZ(),
        ) catch |err| switch (err) {
            error.SpecifierResolutionFailed => {
                _ = self.isolate.throwException(self.isolate.createTypeError("Failed to resolve module specifier"));
                return err;
            },
        };
        const nested_gop = try self.module_cache.getOrPut(self.arena, normalized_specifier);
        if (!nested_gop.found_existing) {
            const owned_specifier = try self.arena.dupeZ(u8, normalized_specifier);
            nested_gop.key_ptr.* = owned_specifier;
            nested_gop.value_ptr.* = .{};
            try script_manager.preloadImport(owned_specifier, url, .{});
        } else if (nested_gop.value_ptr.module == null) {
            // Entry exists but module failed to compile previously.
            // The imported_modules entry may have been consumed, so
            // re-preload to ensure waitForImport can find it.
            // Key was stored via dupeZ so it has a sentinel in memory.
            const key = nested_gop.key_ptr.*;
            const key_z: [:0]const u8 = key.ptr[0..key.len :0];
            try script_manager.preloadImport(key_z, url, .{});
        }
    }
}

fn newFunctionWithData(local: *const js.Local, comptime callback: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void, data: *anyopaque) js.Function {
    const external = local.isolate.createExternal(data);
    const handle = v8.v8__Function__New__DEFAULT2(local.handle, callback, @ptrCast(external)).?;
    return .{
        .local = local,
        .handle = handle,
    };
}

// == Callbacks ==
// Callback from V8, asking us to load a module. The "specifier" is
// the src of the module to load.
fn resolveModuleCallback(
    c_context: ?*const v8.Context,
    c_specifier: ?*const v8.String,
    import_attributes: ?*const v8.FixedArray,
    c_referrer: ?*const v8.Module,
) callconv(.c) ?*const v8.Module {
    _ = import_attributes;

    const self = fromC(c_context.?).?;
    const local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .isolate = self.isolate,
        .call_arena = self.call_arena,
    };

    const specifier = js.String.toSliceZ(.{ .local = &local, .handle = c_specifier.? }) catch |err| {
        log.err(.js, "resolve module", .{ .err = err });
        return null;
    };
    const referrer = js.Module{ .local = &local, .handle = c_referrer.? };

    return self._resolveModuleCallback(referrer, specifier, &local) catch |err| {
        if (err == error.SpecifierResolutionFailed) {
            _ = self.isolate.throwException(self.isolate.createTypeError("Failed to resolve module specifier"));
        }
        log.err(.js, "resolve module", .{
            .err = err,
            .specifier = specifier,
        });
        return null;
    };
}

pub fn dynamicModuleCallback(
    c_context: ?*const v8.Context,
    host_defined_options: ?*const v8.Data,
    resource_name: ?*const v8.Value,
    v8_specifier: ?*const v8.String,
    import_attrs: ?*const v8.FixedArray,
) callconv(.c) ?*v8.Promise {
    _ = host_defined_options;
    _ = import_attrs;

    const self = fromC(c_context.?).?;
    const local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .call_arena = self.call_arena,
        .isolate = self.isolate,
    };

    const resource = blk: {
        const resource_value = js.Value{ .handle = resource_name.?, .local = &local };
        if (resource_value.isNullOrUndefined()) {
            // will only be null / undefined in extreme cases (e.g. WPT tests)
            // where you're
            break :blk self.global.base();
        }

        break :blk js.String.toSliceZ(.{ .local = &local, .handle = resource_name.? }) catch |err| {
            log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback1" });
            return @constCast(local.rejectPromise(.{ .generic_error = "Out of memory" }).handle);
        };
    };

    const specifier = js.String.toSliceZ(.{ .local = &local, .handle = v8_specifier.? }) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback2" });
        return @constCast(local.rejectPromise(.{ .generic_error = "Out of memory" }).handle);
    };

    const normalized_specifier = self.script_manager.resolveSpecifier(
        self.arena, // might need to survive until the module is loaded
        resource,
        specifier,
    ) catch |err| switch (err) {
        error.SpecifierResolutionFailed => {
            return @constCast(local.rejectPromise(.{ .type_error = "Failed to resolve module specifier" }).handle);
        },
    };

    const promise = self._dynamicModuleCallback(normalized_specifier, resource, &local) catch |err| blk: {
        log.err(.js, "dynamic module callback", .{
            .err = err,
        });
        break :blk local.rejectPromise(.{ .generic_error = "Out of memory" });
    };
    return @constCast(promise.handle);
}

pub fn metaObjectCallback(c_context: ?*v8.Context, c_module: ?*v8.Module, c_meta: ?*v8.Object) callconv(.c) void {
    const self = fromC(c_context.?).?;
    var local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .isolate = self.isolate,
        .call_arena = self.call_arena,
    };

    const m = js.Module{ .local = &local, .handle = c_module.? };
    const meta = js.Object{ .local = &local, .handle = c_meta.? };

    const url = self.module_identifier.get(m.getIdentityHash()) orelse {
        // Shouldn't be possible.
        log.err(.js, "import meta", .{ .err = error.UnknownModuleReferrer });
        return;
    };

    const js_value = local.zigValueToJs(url, .{}) catch {
        log.err(.js, "import meta", .{ .err = error.FailedToConvertUrl });
        return;
    };
    const res = meta.defineOwnProperty("url", js_value, 0) orelse false;
    if (!res) {
        log.err(.js, "import meta", .{ .err = error.FailedToSet });
    }

    // import.meta.resolve(specifier) resolves against this module's URL,
    // applying the document's importmap. The base is bound per-module so the
    // function keeps working even when detached from import.meta.
    // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/import.meta/resolve
    const resolve_data = self.arena.create(ImportMetaResolveData) catch {
        log.err(.js, "import meta", .{ .err = error.OutOfMemory });
        return;
    };
    resolve_data.* = .{ .context = self, .base = url };

    const resolve_fn = newFunctionWithData(&local, importMetaResolveCallback, @ptrCast(resolve_data));
    const resolve_value = js.Value{ .local = &local, .handle = @ptrCast(resolve_fn.handle) };
    const resolve_res = meta.defineOwnProperty("resolve", resolve_value, 0) orelse false;
    if (!resolve_res) {
        log.err(.js, "import meta", .{ .err = error.FailedToSet });
    }
}

const ImportMetaResolveData = struct {
    context: *Context,
    base: [:0]const u8,
};

// Implements import.meta.resolve(specifier): resolves the specifier against the
// module's base URL (applying the document's importmap) and returns the
// absolute URL.
fn importMetaResolveCallback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    var c: Caller = undefined;
    if (!c.initFromHandle(callback_handle)) {
        return;
    }
    defer c.deinit();

    const l = &c.local;
    const info = Caller.FunctionCallbackInfo{ .handle = callback_handle.? };
    const data: *ImportMetaResolveData = @ptrCast(@alignCast(info.getData() orelse return));
    const ctx = data.context;
    const isolate = ctx.isolate;

    if (info.length() == 0) {
        _ = isolate.throwException(isolate.createTypeError("import.meta.resolve requires a specifier"));
        return;
    }

    const specifier = info.getArg(0, l).toStringSliceZ() catch {
        _ = isolate.throwException(isolate.createTypeError("invalid specifier"));
        return;
    };

    const resolved = ctx.script_manager.resolveSpecifier(ctx.local_arena, data.base, specifier) catch {
        _ = isolate.throwException(isolate.createTypeError("failed to resolve module specifier"));
        return;
    };

    const result = l.zigValueToJs(resolved, .{}) catch {
        _ = isolate.throwException(isolate.createTypeError("failed to resolve module specifier"));
        return;
    };
    info.getReturnValue().set(result);
}

fn _resolveModuleCallback(self: *Context, referrer: js.Module, specifier: [:0]const u8, local: *const js.Local) !?*const v8.Module {
    const referrer_path = self.module_identifier.get(referrer.getIdentityHash()) orelse {
        // Shouldn't be possible.
        return error.UnknownModuleReferrer;
    };

    const normalized_specifier = try self.script_manager.resolveSpecifier(
        self.arena,
        referrer_path,
        specifier,
    );

    if (self.module_cache.getPtr(normalized_specifier).?.module) |m| {
        // This import registered a waiter via preloadImport when it was discovered
        // but the compiled module is already cached so we don't have to call
        // waitForImport. Release our waiter so we no longer hold on waiter on
        // the resource.
        self.script_manager.releaseImport(normalized_specifier);
        return local.toLocal(m).handle;
    }

    var source = self.script_manager.waitForImport(normalized_specifier) catch |err| switch (err) {
        error.UnknownModule => blk: {
            // Module is in cache but was consumed from imported_modules
            // (e.g., by a previous failed resolution). Re-preload and retry.
            try self.script_manager.preloadImport(normalized_specifier, referrer_path, .{});
            break :blk try self.script_manager.waitForImport(normalized_specifier);
        },
        else => return err,
    };
    defer source.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const mod = try compileModule(local, source.src(), normalized_specifier);
    try self.postCompileModule(mod, normalized_specifier, local);
    // waitForImport can cause module_cache to be mutated (via HttpClient.tick),
    // so we need to refetch this incase the hashmap changed
    const entry = self.module_cache.getPtr(normalized_specifier).?;
    entry.module = try mod.persist();
    // Note: We don't instantiate/evaluate here - V8 will handle instantiation
    // as part of the parent module's dependency chain. If there's a resolver
    // waiting, it will be handled when the module is eventually evaluated
    // (either as a top-level module or when accessed via dynamic import)
    return mod.handle;
}

// Will get passed to ScriptManager and then passed back to us when
// the src of the module is loaded
const DynamicModuleResolveState = struct {
    // The module that we're resolving (we'll actually resolve its
    // namespace)
    module: ?js.Module.Global,
    context_id: usize,
    context: *Context,
    specifier: [:0]const u8,
    resolver: js.PromiseResolver.Global,
};

fn _dynamicModuleCallback(self: *Context, specifier: [:0]const u8, referrer: []const u8, local: *const js.Local) !js.Promise {
    const gop = try self.module_cache.getOrPut(self.arena, specifier);
    if (gop.found_existing) {
        if (gop.value_ptr.resolver_promise) |rp| {
            return local.toLocal(rp);
        }
    }

    const resolver = local.createPromiseResolver();
    const state = try self.arena.create(DynamicModuleResolveState);

    state.* = .{
        .module = null,
        .context = self,
        .specifier = specifier,
        .context_id = self.id,
        .resolver = try resolver.persist(),
    };

    const promise = resolver.promise();

    if (!gop.found_existing or gop.value_ptr.module == null) {
        // Either this is a completely new module, or it's an entry that was
        // created (e.g., in postCompileModule) but not yet loaded
        // this module hasn't been seen before. This is the most
        // complicated path.

        // First, we'll setup a bare entry into our cache. This will
        // prevent anyone one else from trying to asynchronously load
        // it. Instead, they can just return our promise.
        gop.value_ptr.* = ModuleEntry{
            .module = null,
            .module_promise = null,
            .resolver_promise = try promise.persist(),
        };

        // Next, we need to actually load it.
        self.script_manager.getAsyncImport(specifier, dynamicModuleSourceCallback, state, referrer) catch |err| {
            const error_msg = local.newString(@errorName(err));
            _ = resolver.reject("dynamic module get async", error_msg);
        };

        // For now, we're done. but this will be continued in
        // `dynamicModuleSourceCallback`, once the source for the module is loaded.
        return promise;
    }

    // we might update the map, so we might need to re-fetch this.
    var entry = gop.value_ptr;

    // So we have a module, but no async resolver. This can only
    // happen if the module was first synchronously loaded (Does that
    // ever even happen?!) You'd think we can just return the module
    // but no, we need to resolve the module namespace, and the
    // module could still be loading!
    // We need to do part of what the first case is going to do in
    // `dynamicModuleSourceCallback`, but we can skip some steps
    // since the module is already loaded,
    lp.assert(gop.value_ptr.module != null, "Context._dynamicModuleCallback has module", .{});

    // If the module hasn't been evaluated yet (it was only instantiated
    // as a static import dependency), we need to evaluate it now.
    if (entry.module_promise == null) {
        const mod = local.toLocal(gop.value_ptr.module.?);
        const status = mod.getStatus();
        if (status == .kEvaluated or status == .kEvaluating) {
            // Module was already evaluated (shouldn't normally happen, but handle it).
            // Create a pre-resolved promise with the module namespace.
            const module_resolver = local.createPromiseResolver();
            module_resolver.resolve("resolve module", mod.getModuleNamespace());
            _ = try module_resolver.persist();
            entry.module_promise = try module_resolver.promise().persist();
        } else {
            // the module was loaded, but not evaluated, we _have_ to evaluate it now
            if (status == .kUninstantiated) {
                if (try mod.instantiate(resolveModuleCallback) == false) {
                    _ = resolver.reject("module instantiation", local.newString("Module instantiation failed"));
                    return promise;
                }
            }

            const evaluated = mod.evaluate() catch {
                if (comptime IS_DEBUG) {
                    std.debug.assert(mod.getStatus() == .kErrored);
                }
                _ = resolver.reject("module evaluation", local.newString("Module evaluation failed"));
                return promise;
            };
            lp.assert(evaluated.isPromise(), "Context._dynamicModuleCallback non-promise", .{});
            // mod.evaluate can invalidate or gop
            entry = self.module_cache.getPtr(specifier).?;
            entry.module_promise = try evaluated.toPromise().persist();
        }
    }

    // like before, we want to set this up so that if anything else
    // tries to load this module, it can just return our promise
    // since we're going to be doing all the work.
    entry.resolver_promise = try promise.persist();

    // But we can skip directly to `resolveDynamicModule` which is
    // what the above callback will eventually do.
    self.resolveDynamicModule(state, entry.*, local);
    return promise;
}

fn dynamicModuleSourceCallback(ctx: *anyopaque, module_source_: anyerror!ScriptManagerBase.ModuleSource) void {
    const state: *DynamicModuleResolveState = @ptrCast(@alignCast(ctx));
    var self = state.context;

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const local = &ls.local;

    var ms = module_source_ catch |err| {
        const resolver = local.toLocal(state.resolver);
        switch (err) {
            error.UrlMalformat, error.Abort => resolver.rejectError("dynamic module source", .{ .type_error = @errorName(err) }),
            else => _ = resolver.reject("dynamic module source", local.newString(@errorName(err))),
        }
        return;
    };

    const module_entry = blk: {
        defer ms.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        break :blk self.module(true, local, ms.src(), state.specifier, true) catch |err| {
            const caught = try_catch.caughtOrError(self.local_arena, err);
            log.err(.js, "module compilation failed", .{
                .caught = caught,
                .specifier = state.specifier,
            });
            _ = local.toLocal(state.resolver).reject("dynamic compilation failure", local.newString(caught.exception orelse ""));
            return;
        };
    };

    self.resolveDynamicModule(state, module_entry, local);
}

fn resolveDynamicModule(self: *Context, state: *DynamicModuleResolveState, module_entry: ModuleEntry, local: *const js.Local) void {
    defer local.runMicrotasks();

    // we can only be here if the module has been evaluated and if
    // we have a resolve loading this asynchronously.
    lp.assert(module_entry.module_promise != null, "Context.resolveDynamicModule has module_promise", .{});
    lp.assert(module_entry.resolver_promise != null, "Context.resolveDynamicModule has resolver_promise", .{});
    if (comptime IS_DEBUG) {
        std.debug.assert(self.module_cache.contains(state.specifier));
    }
    state.module = module_entry.module.?;

    // We've gotten the source for the module and are evaluating it.
    // You might think we're done, but the module evaluation is
    // itself asynchronous. We need to chain to the module's own
    // promise. When the module is evaluated, it resolves to the
    // last value of the module. But, for module loading, we need to
    // resolve to the module's namespace.

    const then_callback = newFunctionWithData(local, struct {
        pub fn callback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            var c: Caller = undefined;
            if (!c.initFromHandle(callback_handle)) {
                return;
            }
            defer c.deinit();

            const info = Caller.FunctionCallbackInfo{ .handle = callback_handle.? };
            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(info.getData() orelse return));

            if (s.context_id != c.local.ctx.id) {
                // The microtask is tied to the isolate, not the context
                // it can be resolved while another context is active
                // (Which seems crazy to me). If that happens, then
                // another frame was loaded and we MUST ignore this
                // (most of the fields in state are not valid)
                return;
            }
            const l = c.local;
            defer l.runMicrotasks();
            const namespace = l.toLocal(s.module.?).getModuleNamespace();
            _ = l.toLocal(s.resolver).resolve("resolve namespace", namespace);
        }
    }.callback, @ptrCast(state));

    const catch_callback = newFunctionWithData(local, struct {
        pub fn callback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            var c: Caller = undefined;
            if (!c.initFromHandle(callback_handle)) return;
            defer c.deinit();

            const info = Caller.FunctionCallbackInfo{ .handle = callback_handle.? };
            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(info.getData() orelse return));

            const l = &c.local;
            if (s.context_id != l.ctx.id) {
                return;
            }

            defer l.runMicrotasks();
            _ = l.toLocal(s.resolver).reject("catch callback", js.Value{
                .local = l,
                .handle = v8.v8__FunctionCallbackInfo__Data(callback_handle).?,
            });
        }
    }.callback, @ptrCast(state));

    _ = local.toLocal(module_entry.module_promise.?).thenAndCatch(then_callback, catch_callback) catch |err| {
        log.err(.js, "module evaluation is promise", .{
            .err = err,
            .specifier = state.specifier,
        });
        _ = local.toLocal(state.resolver).reject("module promise", local.newString("Failed to evaluate promise"));
    };
}

// Used to make temporarily enter and exit a context, updating and restoring
// frame.js:
//    var hs: js.HandleScope = undefined;
//    const entered = ctx.enter(&hs);
//    defer entered.exit();
pub fn enter(self: *Context, hs: *js.HandleScope) Entered {
    self.env.applyPendingMicrotaskQueues();

    const isolate = self.isolate;
    const previous_stack_limit = isolate.swapStackLimit(self.execution_stack_limit);
    js.HandleScope.init(hs, isolate);

    const original = self.global.getJs();
    self.global.setJs(self);

    const handle: *const v8.Context = @ptrCast(v8.v8__Global__Get(&self.handle, isolate.handle));
    v8.v8__Context__Enter(handle);
    return .{
        .original = original,
        .handle = handle,
        .handle_scope = hs,
        .global = self.global,
        .isolate = isolate,
        .previous_stack_limit = previous_stack_limit,
    };
}

const Entered = struct {
    // the context we should restore on the frame/worker
    original: *Context,

    // the handle of the entered context
    handle: *const v8.Context,

    handle_scope: *js.HandleScope,

    global: GlobalScope,

    isolate: js.Isolate,

    previous_stack_limit: usize,

    pub fn exit(self: Entered) void {
        self.global.setJs(self.original);
        v8.v8__Context__Exit(self.handle);
        _ = self.isolate.swapStackLimit(self.previous_stack_limit);
        self.handle_scope.deinit();
    }
};

pub fn queueMutationDelivery(self: *Context) !void {
    try self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| Frame.observers.deliverMutations(frame),
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueIntersectionChecks(self: *Context) !void {
    try self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| Frame.observers.performScheduledIntersectionChecks(frame),
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueIntersectionDelivery(self: *Context) !void {
    try self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| Frame.observers.deliverIntersections(frame),
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueCustomElementBackupDrain(self: *Context) !void {
    try self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| frame._ce_reactions.drainBackup(frame),
                .worker => unreachable,
            }
        }
    }.run);
}

// Helper for executing a Microtask on this Context. In V8, microtasks aren't
// associated to a Context - they are just functions to execute in an Isolate.
// But for these Context microtasks, we want to (a) make sure the context isn't
// being shut down and (b) that it's entered.
fn enqueueMicrotask(self: *Context, callback: anytype) !void {
    // A shared queue can outlive one of its Contexts. Store only Env + the
    // monotonic id in the callback data so a navigated-away iframe cannot
    // leave a dangling *Context in another Window realm's queue.
    const state = try self.page.frame_arena.create(PendingContextMicrotask);
    state.* = .{ .env = self.env, .context_id = self.id };
    v8.v8__MicrotaskQueue__EnqueueMicrotask(self.microtask_queue, self.isolate.handle, struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const queued: *const PendingContextMicrotask = @ptrCast(@alignCast(data.?));
            const ctx = queued.env.contextById(queued.context_id) orelse return;
            var hs: js.HandleScope = undefined;
            const entered = ctx.enter(&hs);
            defer entered.exit();
            callback(ctx);
        }
    }.run, state);
}

const PendingContextMicrotask = struct {
    env: *Env,
    context_id: usize,
};

// There's an assumption here: the js.Function will be alive when microtasks are
// run. If we're Env.runMicrotasks in all the places that we're supposed to, then
// this should be safe (I think). In whatever HandleScope a microtask is enqueued,
// PerformCheckpoint should be run. So the v8::Local<v8::Function> should remain
// valid. If we have problems with this, a simple solution is to provide a Zig
// wrapper for these callbacks which references a js.Function, on callback
// it executes the function and then releases the global.
pub fn queueMicrotaskFunc(self: *Context, cb: js.Function) void {
    // Use context-specific microtask queue instead of isolate queue
    v8.v8__MicrotaskQueue__EnqueueMicrotaskFunc(self.microtask_queue, self.isolate.handle, cb.handle);
}

// == Profiler ==
pub fn startCpuProfiler(self: *Context) void {
    if (comptime !IS_DEBUG) {
        // Still testing this out, don't have it properly exposed, so add this
        // guard for the time being to prevent any accidental/weird prod issues.
        @compileError("CPU Profiling is only available in debug builds");
    }

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    std.debug.assert(self.cpu_profiler == null);
    v8.v8__CpuProfiler__UseDetailedSourcePositionsForProfiling(self.isolate.handle);

    const cpu_profiler = v8.v8__CpuProfiler__Get(self.isolate.handle).?;
    const title = self.isolate.initStringHandle("v8_cpu_profile");
    v8.v8__CpuProfiler__StartProfiling(cpu_profiler, title);
    self.cpu_profiler = cpu_profiler;
}

pub fn stopCpuProfiler(self: *Context) ![]const u8 {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const title = self.isolate.initStringHandle("v8_cpu_profile");
    const handle = v8.v8__CpuProfiler__StopProfiling(self.cpu_profiler.?, title) orelse return error.NoProfiles;
    const string_handle = v8.v8__CpuProfile__Serialize(handle, self.isolate.handle) orelse return error.NoProfile;
    return (js.String{ .local = &ls.local, .handle = string_handle }).toSlice();
}

pub fn startHeapProfiler(self: *Context) void {
    if (comptime !IS_DEBUG) {
        @compileError("Heap Profiling is only available in debug builds");
    }

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    std.debug.assert(self.heap_profiler == null);
    const heap_profiler = v8.v8__HeapProfiler__Get(self.isolate.handle).?;

    // Sample every 32KB, stack depth 32
    v8.v8__HeapProfiler__StartSamplingHeapProfiler(heap_profiler, 32 * 1024, 32);
    v8.v8__HeapProfiler__StartTrackingHeapObjects(heap_profiler, true);

    self.heap_profiler = heap_profiler;
}

pub fn stopHeapProfiler(self: *Context) !struct { []const u8, []const u8 } {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const allocating = blk: {
        const profile = v8.v8__HeapProfiler__GetAllocationProfile(self.heap_profiler.?);
        const string_handle = v8.v8__AllocationProfile__Serialize(profile, self.isolate.handle);
        v8.v8__HeapProfiler__StopSamplingHeapProfiler(self.heap_profiler.?);
        v8.v8__AllocationProfile__Delete(profile);
        break :blk try (js.String{ .local = &ls.local, .handle = string_handle.? }).toSlice();
    };

    const snapshot = blk: {
        const snapshot = v8.v8__HeapProfiler__TakeHeapSnapshot(self.heap_profiler.?, null) orelse return error.NoProfiles;
        const string_handle = v8.v8__HeapSnapshot__Serialize(snapshot, self.isolate.handle);
        v8.v8__HeapProfiler__StopTrackingHeapObjects(self.heap_profiler.?);
        v8.v8__HeapSnapshot__Delete(snapshot);
        break :blk try (js.String{ .local = &ls.local, .handle = string_handle.? }).toSlice();
    };

    return .{ allocating, snapshot };
}

const UnknownPropertyStat = struct {
    count: usize,
    first_stack: []const u8,
};
