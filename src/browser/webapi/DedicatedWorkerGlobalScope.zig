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

// The global object of a dedicated worker. Per the HTML spec this is the most
// derived interface of a dedicated worker's global, inheriting from
// WorkerGlobalScope (-> EventTarget). It is the actual JS global object (`self`);
// the WorkerGlobalScope base holds all of the state and implementation, reached
// here through `_proto`. Sites branch on `self instanceof DedicatedWorkerGlobalScope`
// to tell a worker apart from an iframe (e.g. Shopify's Web Pixel sandbox).

const std = @import("std");
const lp = @import("darkpanda");

const js = @import("../js/js.zig");

const WorkerGlobalScope = @import("WorkerGlobalScope.zig");
const Frame = @import("../Frame.zig");
const HttpClient = @import("../HttpClient.zig");
const OwnerMailbox = @import("../OwnerMailbox.zig");

const MessageEvent = @import("event/MessageEvent.zig");

const Allocator = std.mem.Allocator;

const DedicatedWorkerGlobalScope = @This();

_proto: *WorkerGlobalScope,
_owner: Owner,
_closed: bool = false,
_script_loaded: bool = false,
_on_message: ?js.Function.Global = null,
_on_messageerror: ?js.Function.Global = null,

// Messages received before the worker script finished evaluating. Per the
// HTML spec, postMessage'd data is buffered while the worker is loading
// and delivered once the worker is ready (i.e. once onmessage can be set).
// Drained by drainPendingMessages, called from Worker.loadInitialScript
// after the initial script has been evaluated.
_pending_messages: std.ArrayList(?js.Value.Global) = .empty,

pub const Owner = struct {
    context: *anyopaque,
    post_message: *const fn (*anyopaque, js.Value) anyerror!void,
    post_broadcast: *const fn (*anyopaque, *js.Value.BroadcastMessage) anyerror!void,
    close: *const fn (*anyopaque) void,
};

pub const InitOptions = struct {
    arena: Allocator,
    url: [:0]const u8,
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
    env: *js.Env,
    http_client: *HttpClient,
    owner_mailbox: *OwnerMailbox.Mailbox,
    owner: Owner,
};

pub fn init(options: InitOptions) !*DedicatedWorkerGlobalScope {
    const self = try options.arena.create(DedicatedWorkerGlobalScope);
    const proto = try WorkerGlobalScope.init(
        options.arena,
        options.url,
        .{ .dedicated = self },
        options.is_module,
        options.frame_id,
        options.loader_id,
        options.root_frame_id,
        options.frame,
        options.creator_secure_context,
        options.creator_origin_key,
        options.creator_origin,
        options.creator_storage_origin_key,
        options.creator_url,
        options.creator_referer_header,
        options.creator_site_for_cookies,
        options.env,
        options.http_client,
        options.owner_mailbox,
    );
    self.* = .{
        ._owner = options.owner,
        ._proto = proto,
    };
    return self;
}

pub fn deinit(self: *DedicatedWorkerGlobalScope) void {
    for (self._pending_messages.items) |maybe_data| {
        if (maybe_data) |d| {
            d.release();
        }
    }
    self._proto.deinit();
}

pub fn postMessage(self: *DedicatedWorkerGlobalScope, data: js.Value) !void {
    try self._owner.post_message(self._owner.context, data);
}

pub fn publishBroadcast(self: *DedicatedWorkerGlobalScope, message: *js.Value.BroadcastMessage) !void {
    if (self._closed) return;
    try self._owner.post_broadcast(self._owner.context, message);
}

pub fn close(self: *DedicatedWorkerGlobalScope) void {
    if (self._closed) return;
    self._closed = true;
    // Author close is an early realm boundary; the Context teardown fallback
    // repeats this idempotently before destroying Scheduler/V8/arena state.
    self._proto.js.closeOwnerTarget();
    self._proto._session.idb.detachContext(self._proto.js);
    self._proto.js.scheduler.stop();
    self._proto._http_client.retireOwner(&self._proto._http_owner);
    self._owner.close(self._owner.context);
}

pub fn getOnMessage(self: *const DedicatedWorkerGlobalScope) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *DedicatedWorkerGlobalScope, setter: ?WorkerGlobalScope.FunctionSetter) void {
    self._on_message = WorkerGlobalScope.getFunctionFromSetter(setter);
}

pub fn getOnMessageError(self: *const DedicatedWorkerGlobalScope) ?js.Function.Global {
    return self._on_messageerror;
}

pub fn setOnMessageError(self: *DedicatedWorkerGlobalScope, setter: ?WorkerGlobalScope.FunctionSetter) void {
    self._on_messageerror = WorkerGlobalScope.getFunctionFromSetter(setter);
}

pub fn requestAnimationFrame(self: *DedicatedWorkerGlobalScope, cb: js.Function.Global, exec: *js.Execution) !u32 {
    return self._proto._timers.schedule(exec, cb, 5, .{
        .repeat = false,
        .params = &.{},
        .mode = .animation_frame,
        .name = "worker.requestAnimationFrame",
    });
}

pub fn cancelAnimationFrame(self: *DedicatedWorkerGlobalScope, id: u32) void {
    self._proto._timers.clear(id);
}

// Called internally by Worker when it wants to post a message to us
pub fn receiveMessage(self: *DedicatedWorkerGlobalScope, data: js.Value) !void {
    if (self._closed) {
        return;
    }

    const cloned_data: ?js.Value.Global = blk: {
        // Enter our context to clone the message
        var ls: js.Local.Scope = undefined;
        self._proto.js.localScope(&ls);
        defer ls.deinit();

        // clones from where it currently is (the Worker's Page context) to our Context
        const cloned = data.structuredCloneTo(&ls.local) catch break :blk null;
        break :blk cloned.persist() catch break :blk null;
    };

    if (!self._script_loaded) {
        // Buffer until Worker.loadInitialScript calls drainPendingMessages.
        // Without this, postMessage'd data races against the worker's
        // script load: if onmessage hasn't been registered yet (because
        // the worker hasn't been evaluated), the dispatched event finds
        // no listener and the message is silently dropped.
        try self._pending_messages.append(self._proto.arena, cloned_data);
        return;
    }

    try self.scheduleMessage(cloned_data);
}

// Cross-isolate mailbox entry. The serialized envelope contains no source
// isolate handles; deserialization and persistence happen only on this
// DedicatedWorker's owner thread.
pub fn receiveSerializedMessage(self: *DedicatedWorkerGlobalScope, message: *const js.Value.SerializedMessage) !void {
    if (self._closed) return;

    const cloned_data: ?js.Value.Global = blk: {
        var ls: js.Local.Scope = undefined;
        self._proto.js.localScope(&ls);
        defer ls.deinit();

        const cloned = js.Value.deserializeMessage(&ls.local, message) catch break :blk null;
        break :blk cloned.persist() catch break :blk null;
    };

    if (!self._script_loaded) {
        try self._pending_messages.append(self._proto.arena, cloned_data);
        return;
    }
    try self.scheduleMessage(cloned_data);
}

fn scheduleMessage(self: *DedicatedWorkerGlobalScope, cloned_data: ?js.Value.Global) !void {
    const wgs = self._proto;
    const session = wgs._session;

    const message_arena = try session.getArena(.tiny, "DedicatedWorkerGlobalScope.receiveMessage");
    errdefer session.releaseArena(message_arena);

    const callback = try message_arena.create(ReceiveMessageCallback);
    callback.* = .{
        .data = cloned_data,
        .worker_scope = self,
        .arena = message_arena,
    };

    try wgs.js.scheduler.add(callback, ReceiveMessageCallback.run, 0, .{
        .name = "WorkerGlobalScope.receiveMessage",
        .low_priority = false,
        .finalizer = ReceiveMessageCallback.cancelled,
    });
}

// Called by Worker.loadInitialScript once the initial script has been
// evaluated and onmessage has had a chance to be registered. Any messages
// that arrived while the worker was loading are scheduled for delivery in
// the order they were received.
pub fn drainPendingMessages(self: *DedicatedWorkerGlobalScope) void {
    self._script_loaded = true;
    for (self._pending_messages.items) |cloned_data| {
        self.scheduleMessage(cloned_data) catch |err| {
            lp.log.warn(.browser, "worker drain msg failed", .{ .err = err });
            if (cloned_data) |d| d.release();
        };
    }
    self._pending_messages.clearRetainingCapacity();
}

const ReceiveMessageCallback = struct {
    data: ?js.Value.Global,
    arena: Allocator,
    worker_scope: *DedicatedWorkerGlobalScope,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        if (self.data) |d| {
            d.release();
        }
        self.deinit();
    }

    fn deinit(self: *ReceiveMessageCallback) void {
        self.worker_scope._proto._session.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReceiveMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const worker_scope = self.worker_scope;
        const wsg = worker_scope._proto;
        const target = wsg.asEventTarget();

        // If data is null, structured clone failed - fire messageerror
        if (self.data == null) {
            const on_messageerror = worker_scope._on_messageerror;
            if (!wsg._event_manager.hasDirectListeners(target, "messageerror", on_messageerror)) {
                return null;
            }
            const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
                .bubbles = false,
                .cancelable = false,
            }, wsg._page)).asEvent();
            try wsg.dispatch(target, event, on_messageerror, .{});
            return null;
        }

        const on_message = worker_scope._on_message;

        // Check if there are any listeners before creating the event
        if (!wsg._event_manager.hasDirectListeners(target, "message", on_message)) {
            self.data.?.release();
            return null;
        }

        const event = (try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.data.? },
            .bubbles = false,
            .cancelable = false,
        }, wsg._page)).asEvent();
        try wsg.dispatch(target, event, on_message, .{});
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(DedicatedWorkerGlobalScope);

    pub const Meta = struct {
        pub const name = "DedicatedWorkerGlobalScope";
        pub const global_scope = true;
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const TEMPORARY = bridge.property(0, .{ .template = true });
    pub const PERSISTENT = bridge.property(1, .{ .template = true });

    pub const postMessage = bridge.function(DedicatedWorkerGlobalScope.postMessage, .{});
    pub const close = bridge.function(DedicatedWorkerGlobalScope.close, .{});
    pub const onmessage = bridge.accessor(DedicatedWorkerGlobalScope.getOnMessage, DedicatedWorkerGlobalScope.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(DedicatedWorkerGlobalScope.getOnMessageError, DedicatedWorkerGlobalScope.setOnMessageError, .{});
    pub const requestAnimationFrame = bridge.function(DedicatedWorkerGlobalScope.requestAnimationFrame, .{});
    pub const cancelAnimationFrame = bridge.function(DedicatedWorkerGlobalScope.cancelAnimationFrame, .{});
};
