//! DedicatedWorker owner runtime.
//!
//! The Runtime is allocated by the creator thread but every V8/HTTP field is
//! constructed, entered, pumped, and destroyed by one WorkerThread. Producer
//! threads communicate only through synchronized structured-clone mailboxes
//! and ForegroundWake's no-op V8 task.

const std = @import("std");
const lp = @import("darkpanda");

const App = @import("../../App.zig");
const HttpClient = @import("../HttpClient.zig");
const OwnerMailbox = @import("../OwnerMailbox.zig");
const js = @import("../js/js.zig");
const WorkerThread = @import("WorkerThread.zig");

const Runtime = @This();
const Allocator = std.mem.Allocator;
const mailbox_allocator = std.heap.page_allocator;

pub const Callbacks = struct {
    bootstrap: *const fn (*anyopaque, *Runtime) anyerror!void,
    load_script: *const fn (*anyopaque, *Runtime, EntryScript) anyerror!void,
    receive_message: *const fn (*anyopaque, *Runtime, *const js.Value.SerializedMessage) anyerror!void,
    receive_broadcast: *const fn (*anyopaque, *Runtime, *js.Value.BroadcastMessage) anyerror!void,
    drain_creator: *const fn (*anyopaque) anyerror!void,
    teardown: *const fn (*anyopaque, *Runtime) void,
};

pub const CSPDisposition = enum {
    enforce,
    report_only,
};

pub const ContentSecurityPolicy = struct {
    serialized: []const u8,
    disposition: CSPDisposition,
};

/// Immutable creator-owned entry data. Every referenced byte is allocated in
/// the Worker creator arena before enqueueScript publishes this value through
/// inbound_mutex. Worker.deinit joins the owner thread before releasing that
/// arena, so the command borrows these slices for its entire lifetime.
pub const EntryScript = struct {
    source: []const u8,
    policies: []const ContentSecurityPolicy = &.{},
};

pub const Outbound = union(enum) {
    message: js.Value.SerializedMessage,
    broadcast: *js.Value.BroadcastMessage,
    error_report: ErrorReport,

    pub fn deinit(self: *Outbound) void {
        switch (self.*) {
            .message => |*message| message.deinit(),
            .broadcast => |message| message.release(),
            .error_report => |*report| report.deinit(),
        }
        self.* = undefined;
    }
};

/// Isolate-free data captured from the worker's V8 Message while still on the
/// worker owner thread.  The creator reconstructs the ErrorEvent from this
/// envelope; no V8 handle (or creator Frame) crosses the mailbox boundary.
pub const ErrorReport = struct {
    message: []u8,
    filename: []u8,
    lineno: u32,
    colno: u32,

    fn deinit(self: *ErrorReport) void {
        mailbox_allocator.free(self.message);
        mailbox_allocator.free(self.filename);
        self.* = undefined;
    }
};

const Command = union(enum) {
    script: EntryScript,
    message: js.Value.SerializedMessage,
    broadcast: *js.Value.BroadcastMessage,
    shutdown,

    fn deinit(self: *Command) void {
        switch (self.*) {
            .message => |*message| message.deinit(),
            .broadcast => |message| message.release(),
            .script, .shutdown => {},
        }
        self.* = undefined;
    }
};

const Lifecycle = enum { starting, running, stopping, stopped };

app: *App,
// Immutable pointer captured on the creator thread. Handles.wakeup() is the
// transport's explicitly thread-safe poll wake; owner threads must not walk
// Worker -> Frame -> Session merely to reach it.
creator_http_client: *HttpClient,
// Retained handle for the creator realm's Browser-owned mailbox. Every
// outbound publication queues a native drain token here. The token is the
// authoritative task edge; HttpClient.wakeup and Frame's periodic scan remain
// harmless fallbacks, but delivery no longer depends on the Frame still being
// rediscovered between two host-boundary snapshots.
creator_sender: OwnerMailbox.Sender,
owner_context: *anyopaque,
callbacks: Callbacks,

thread: ?WorkerThread = null,
owner_thread_id: WorkerThread.ThreadId = 0,
env: ?js.Env = null,
http_client: HttpClient = undefined,
http_client_initialized: bool = false,
owner_wake: ?js.ForegroundWake = null,
producer_wake: ?js.ForegroundWake = null,
owner_mailbox: ?OwnerMailbox.Mailbox = null,

lifecycle_mutex: std.Thread.Mutex = .{},
lifecycle: Lifecycle = .starting,
shutdown_requested: std.atomic.Value(bool) = .init(false),

// Producers advance activity_epoch only after publishing queue state while
// holding the corresponding mailbox mutex. The owner may publish the same
// epoch as quiescent only after a stable double-check of both mailboxes and
// all owner-thread timer/network state. This avoids a sampled-idle race while
// keeping a genuinely dormant worker from holding Runner open forever.
activity_epoch: std.atomic.Value(u64) = .init(1),
quiescent_epoch: std.atomic.Value(u64) = .init(0),

inbound_mutex: std.Thread.Mutex = .{},
inbound_condition: std.Thread.Condition = .{},
inbound: std.ArrayList(Command) = .empty,

outbound_mutex: std.Thread.Mutex = .{},
outbound: std.ArrayList(Outbound) = .empty,

pub fn init(
    app: *App,
    creator_http_client: *HttpClient,
    creator_sender: OwnerMailbox.Sender,
    owner_context: *anyopaque,
    callbacks: Callbacks,
) Runtime {
    return .{
        .app = app,
        .creator_http_client = creator_http_client,
        .creator_sender = creator_sender,
        .owner_context = owner_context,
        .callbacks = callbacks,
    };
}

pub fn start(self: *Runtime) !void {
    std.debug.assert(self.thread == null);
    self.thread = try WorkerThread.spawnWithBootstrap(
        .{ .name = "DedicatedWorker" },
        self,
        bootstrap,
        run,
    );
}

fn bootstrap(raw: *anyopaque) anyerror!void {
    const self: *Runtime = @ptrCast(@alignCast(raw));
    self.owner_thread_id = WorkerThread.currentId();

    self.env = try js.Env.init(self.app, .{ .agent_kind = .dedicated_worker });
    errdefer {
        self.env.?.deinit();
        self.env = null;
    }

    try self.http_client.init(self.app.allocator, &self.app.network, null);
    self.http_client_initialized = true;
    errdefer {
        self.http_client.deinit();
        self.http_client_initialized = false;
    }

    self.owner_wake = try js.ForegroundWake.acquire(
        self.env.?.platform.handle,
        self.env.?.isolate.handle,
    );
    errdefer {
        _ = self.owner_wake.?.close();
        _ = self.owner_wake.?.notifyIsolateShutdown(
            self.env.?.platform.handle,
            self.env.?.isolate.handle,
        );
        self.owner_wake.?.deinit();
        self.owner_wake = null;
    }

    self.producer_wake = try self.owner_wake.?.retain();
    errdefer {
        self.producer_wake.?.deinit();
        self.producer_wake = null;
    }

    self.owner_mailbox = try OwnerMailbox.Mailbox.init(mailbox_allocator, .{
        .context = self,
        .notify = wakeOwnerMailbox,
    });
    errdefer {
        self.owner_mailbox.?.deinit();
        self.owner_mailbox = null;
    }

    try self.callbacks.bootstrap(self.owner_context, self);

    self.lifecycle_mutex.lock();
    self.lifecycle = .running;
    self.lifecycle_mutex.unlock();
}

fn run(raw: *anyopaque) void {
    const self: *Runtime = @ptrCast(@alignCast(raw));
    self.ownerLoop() catch |err| {
        lp.log.err(.browser, "DedicatedWorker owner loop", .{ .err = err });
        self.postError(@errorName(err), "", 0, 0);
    };
    self.ownerShutdown();
}

fn ownerLoop(self: *Runtime) !void {
    // Publish the closed producer boundary before this function returns for
    // either the normal shutdown path or an owner-loop error.  enqueue() holds
    // the same mutex while publishing an inbound command, so a creator can
    // never successfully append after the owner has stopped consuming.
    defer {
        self.lifecycle_mutex.lock();
        self.lifecycle = .stopping;
        self.lifecycle_mutex.unlock();
    }

    while (!self.shutdown_requested.load(.acquire)) {
        while (self.popInbound()) |command_value| {
            var command = command_value;
            defer command.deinit();
            switch (command) {
                .script => |script| try self.callbacks.load_script(self.owner_context, self, script),
                .message => |*message| try self.callbacks.receive_message(self.owner_context, self, message),
                .broadcast => |message| try self.callbacks.receive_broadcast(self.owner_context, self, message),
                .shutdown => {
                    self.shutdown_requested.store(true, .release);
                    break;
                },
            }
            if (self.shutdown_requested.load(.acquire)) break;
        }
        if (self.shutdown_requested.load(.acquire)) break;

        _ = try self.owner_mailbox.?.drain();
        if (self.shutdown_requested.load(.acquire)) break;

        const env = &self.env.?;
        try env.runMacrotasks();
        env.pumpMessageLoop();
        env.runMicrotasks();

        const client = &self.http_client;
        if (client.http_active > 0 or
            client.next_tick_count > 0 or
            client.ws_active > 0 or
            client.queue.first != null or
            client.ready_queue.first != null)
        {
            try client.tick(10, .all);
            continue;
        }

        if (env.msToNextMacrotask()) |delay_ms| {
            const wait_ms: u64 = @max(@as(u64, 1), @min(delay_ms, 10));
            self.inbound_mutex.lock();
            if (self.inbound.items.len == 0 and
                !self.owner_mailbox.?.hasPending() and
                !self.shutdown_requested.load(.acquire))
            {
                self.inbound_condition.timedWait(
                    &self.inbound_mutex,
                    wait_ms * std.time.ns_per_ms,
                ) catch |err| switch (err) {
                    error.Timeout => {},
                };
            }
            self.inbound_mutex.unlock();
            continue;
        }

        // The non-blocking pump above may have consumed the mailbox producer's
        // coalesced wake after our first inbound drain. Recheck the mailbox
        // while holding its mutex before entering the blocking pump. A command
        // published after this check also publishes a new wake, which the
        // blocking pump will observe.
        self.inbound_mutex.lock();
        const mailbox_ready = self.inbound.items.len != 0 or
            self.owner_mailbox.?.hasPending() or
            self.shutdown_requested.load(.acquire);
        self.inbound_mutex.unlock();
        if (mailbox_ready) continue;

        self.publishQuiescentIfStable(env);

        // No embedder timer/network deadline exists. Let V8 block until a real
        // foreground task arrives. Mailbox producers post ForegroundWake's
        // coalesced no-op task immediately after publishing their command.
        _ = js.v8.v8__Platform__PumpMessageLoop(
            env.platform.handle,
            env.isolate.handle,
            true,
        );
        // The pump executes a foreground task before returning. Publish a new
        // epoch immediately afterwards so the following loop cannot inherit a
        // dormant-worker quiescent sample while processing derived work.
        self.noteActivity();
    }
}

fn ownerShutdown(self: *Runtime) void {
    self.lifecycle_mutex.lock();
    self.lifecycle = .stopping;
    self.lifecycle_mutex.unlock();

    const env = &self.env.?;
    env.cancelTerminate();

    // Stop producers first; Post after Close is a safe false. No blocking pump
    // is entered after this point.
    _ = self.owner_wake.?.close();
    self.callbacks.teardown(self.owner_context, self);
    self.owner_mailbox.?.deinit();
    self.owner_mailbox = null;
    self.http_client.deinit();
    self.http_client_initialized = false;

    // Chromium's platform shutdown notification must precede isolate Dispose
    // and run on the isolate owner thread.
    _ = self.owner_wake.?.notifyIsolateShutdown(
        env.platform.handle,
        env.isolate.handle,
    );
    env.deinit();
    self.env = null;
    self.owner_wake.?.deinit();
    self.owner_wake = null;

    self.lifecycle_mutex.lock();
    self.lifecycle = .stopped;
    self.lifecycle_mutex.unlock();
}

pub fn enqueueScript(self: *Runtime, script: EntryScript) !void {
    try self.enqueue(.{ .script = script });
}

pub fn enqueueMessage(self: *Runtime, message: js.Value.SerializedMessage) !void {
    // Ownership transfers only after enqueue() publishes the command.  The
    // caller retains and destroys `message` on every error path.
    try self.enqueue(.{ .message = message });
}

pub fn enqueueBroadcast(self: *Runtime, message: *js.Value.BroadcastMessage) !void {
    message.retain();
    errdefer message.release();
    try self.enqueue(.{ .broadcast = message });
}

fn enqueue(self: *Runtime, command: Command) !void {
    self.lifecycle_mutex.lock();
    defer self.lifecycle_mutex.unlock();

    if (self.lifecycle != .running or self.shutdown_requested.load(.acquire)) {
        return error.WorkerClosed;
    }

    self.inbound_mutex.lock();
    defer self.inbound_mutex.unlock();
    try self.inbound.append(mailbox_allocator, command);
    self.noteActivity();
    self.inbound_condition.signal();
    if (self.producer_wake) |*wake| _ = wake.post();
}

fn popInbound(self: *Runtime) ?Command {
    self.inbound_mutex.lock();
    defer self.inbound_mutex.unlock();
    if (self.inbound.items.len == 0) return null;
    return self.inbound.orderedRemove(0);
}

pub fn postMessageToCreator(self: *Runtime, message: js.Value.SerializedMessage) !void {
    // As with enqueueMessage(), ownership transfers only on successful
    // publication.  The worker-side caller owns the error path.
    self.outbound_mutex.lock();
    defer self.outbound_mutex.unlock();
    try self.outbound.append(mailbox_allocator, .{ .message = message });
    self.noteActivity();
    self.signalCreatorDrain();
}

pub fn postBroadcastToCreator(self: *Runtime, message: *js.Value.BroadcastMessage) !void {
    message.retain();
    errdefer message.release();
    self.outbound_mutex.lock();
    defer self.outbound_mutex.unlock();
    try self.outbound.append(mailbox_allocator, .{ .broadcast = message });
    self.noteActivity();
    self.signalCreatorDrain();
}

pub fn postError(
    self: *Runtime,
    message: []const u8,
    filename: []const u8,
    lineno: u32,
    colno: u32,
) void {
    const owned_message = mailbox_allocator.dupe(u8, message) catch return;
    const owned_filename = mailbox_allocator.dupe(u8, filename) catch {
        mailbox_allocator.free(owned_message);
        return;
    };
    var report = ErrorReport{
        .message = owned_message,
        .filename = owned_filename,
        .lineno = lineno,
        .colno = colno,
    };
    self.outbound_mutex.lock();
    defer self.outbound_mutex.unlock();
    self.outbound.append(mailbox_allocator, .{ .error_report = report }) catch {
        report.deinit();
        return;
    };
    self.noteActivity();
    self.signalCreatorDrain();
}

const CreatorDrainToken = struct {
    owner_context: *anyopaque,
    callback: *const fn (*anyopaque) anyerror!void,

    fn owned(self: *CreatorDrainToken) OwnerMailbox.OwnedPayload {
        return .{
            .data = self,
            .invoke = invoke,
            .destroy = destroy,
        };
    }

    fn invoke(raw: *anyopaque, _: *anyopaque) !void {
        const self: *CreatorDrainToken = @ptrCast(@alignCast(raw));
        try self.callback(self.owner_context);
    }

    fn destroy(raw: *anyopaque) void {
        const self: *CreatorDrainToken = @ptrCast(@alignCast(raw));
        mailbox_allocator.destroy(self);
    }
};

/// Publish an explicit owner-thread task for every outbound envelope. A token
/// may drain several envelopes that became ready in the same host turn; the
/// Runtime FIFO retains their message/error ordering. If allocation fails, the
/// legacy transport wake and Frame scan still provide a best-effort fallback.
fn signalCreatorDrain(self: *Runtime) void {
    const token = mailbox_allocator.create(CreatorDrainToken) catch {
        self.creator_http_client.handles.wakeup() catch {};
        return;
    };
    token.* = .{
        .owner_context = self.owner_context,
        .callback = self.callbacks.drain_creator,
    };
    const result = self.creator_sender.postOwned(token.owned()) catch {
        // postOwned owns and destroys the token on allocation failure.
        self.creator_http_client.handles.wakeup() catch {};
        return;
    };
    if (result == .cancelled) {
        // A retired creator realm intentionally rejects the token. Wake the
        // host only as a teardown hint; no JS callback may cross that target.
        self.creator_http_client.handles.wakeup() catch {};
    }
}

fn wakeOwnerMailbox(raw: *anyopaque) void {
    const self: *Runtime = @ptrCast(@alignCast(raw));
    self.noteActivity();
    self.inbound_mutex.lock();
    self.inbound_condition.signal();
    self.inbound_mutex.unlock();
    if (self.producer_wake) |*wake| _ = wake.post();
}

pub fn popOutbound(self: *Runtime) ?Outbound {
    self.outbound_mutex.lock();
    if (self.outbound.items.len == 0) {
        self.outbound_mutex.unlock();
        return null;
    }
    const outbound = self.outbound.orderedRemove(0);
    const became_empty = self.outbound.items.len == 0;
    self.outbound_mutex.unlock();

    // Only the owner thread may declare the epoch quiescent. Wake it after the
    // creator consumes the last envelope so it can recheck timers/network and
    // publish stable idle. Post is safely false after owner Close.
    if (became_empty) {
        if (self.producer_wake) |*wake| _ = wake.post();
    }
    return outbound;
}

pub fn hasOutbound(self: *Runtime) bool {
    self.outbound_mutex.lock();
    defer self.outbound_mutex.unlock();
    return self.outbound.items.len != 0;
}

pub fn hasCreatorActivity(self: *Runtime) bool {
    self.lifecycle_mutex.lock();
    const stopped = self.lifecycle == .stopped;
    self.lifecycle_mutex.unlock();
    if (stopped) return self.hasOutbound();

    return self.activity_epoch.load(.acquire) !=
        self.quiescent_epoch.load(.acquire);
}

pub fn acceptsInbound(self: *Runtime) bool {
    self.lifecycle_mutex.lock();
    defer self.lifecycle_mutex.unlock();
    return self.lifecycle == .running and
        !self.shutdown_requested.load(.acquire);
}

pub fn pendingInboundCount(self: *Runtime) usize {
    self.inbound_mutex.lock();
    defer self.inbound_mutex.unlock();
    return self.inbound.items.len;
}

fn noteActivity(self: *Runtime) void {
    _ = self.activity_epoch.fetchAdd(1, .acq_rel);
}

fn publishQuiescentIfStable(self: *Runtime, env: *js.Env) void {
    const observed_epoch = self.activity_epoch.load(.acquire);

    self.inbound_mutex.lock();
    const inbound_empty = self.inbound.items.len == 0;
    self.inbound_mutex.unlock();
    if (!inbound_empty) return;
    if (self.owner_mailbox.?.hasPending()) return;

    self.outbound_mutex.lock();
    const outbound_empty = self.outbound.items.len == 0;
    self.outbound_mutex.unlock();
    if (!outbound_empty) return;

    const client = &self.http_client;
    if (client.http_active > 0 or
        client.next_tick_count > 0 or
        client.ws_active > 0 or
        client.queue.first != null or
        client.ready_queue.first != null or
        env.msToNextMacrotask() != null or
        env.hasBackgroundTasks())
    {
        return;
    }

    // A producer publishes its queue entry and advances activity_epoch under
    // that queue's mutex. If it raced any check above, this equality fails; if
    // it races after the load, its increment leaves epoch != quiescent.
    if (self.activity_epoch.load(.acquire) == observed_epoch) {
        self.quiescent_epoch.store(observed_epoch, .release);
    }
}

pub fn requestOwnerClose(self: *Runtime) void {
    std.debug.assert(self.owner_thread_id == WorkerThread.currentId());
    self.shutdown_requested.store(true, .release);
}

pub fn requestStop(self: *Runtime) void {
    if (self.shutdown_requested.swap(true, .acq_rel)) return;

    self.inbound_mutex.lock();
    self.inbound.append(mailbox_allocator, .shutdown) catch {};
    self.noteActivity();
    self.inbound_condition.signal();
    self.inbound_mutex.unlock();
    if (self.producer_wake) |*wake| _ = wake.post();

    // TerminateExecution is the only path that can unwind an infinite
    // Atomics.wait or author-code loop. The lifecycle mutex prevents racing
    // isolate disposal; there is deliberately no native force-kill fallback.
    self.lifecycle_mutex.lock();
    if (self.lifecycle == .running) self.env.?.requestTerminate();
    self.lifecycle_mutex.unlock();
}

pub fn stopAndJoin(self: *Runtime) void {
    self.requestStop();
    if (self.thread) |*thread| {
        if (!thread.isJoined()) thread.join();
        self.thread = null;
    }
    if (self.producer_wake) |*wake| {
        wake.deinit();
        self.producer_wake = null;
    }
}

/// Creator-thread terminal cleanup after Worker.terminate()/Document retire.
/// stopAndJoin establishes the producer boundary before this is called, so no
/// worker thread can append behind the drain. Queued Browser-mailbox tokens may
/// still run later, but observe an empty FIFO and are therefore safe no-ops.
pub fn discardOutbound(self: *Runtime) void {
    self.outbound_mutex.lock();
    for (self.outbound.items) |*outbound| outbound.deinit();
    self.outbound.clearRetainingCapacity();
    self.outbound_mutex.unlock();
}

pub fn deinit(self: *Runtime) void {
    self.stopAndJoin();

    self.inbound_mutex.lock();
    for (self.inbound.items) |*command| command.deinit();
    self.inbound.deinit(mailbox_allocator);
    self.inbound_mutex.unlock();

    self.discardOutbound();
    self.outbound_mutex.lock();
    self.outbound.deinit(mailbox_allocator);
    self.outbound_mutex.unlock();
    self.creator_sender.deinit();
}

pub fn isolateHandle(self: *const Runtime) ?*js.v8.Isolate {
    return if (self.env) |*env| env.isolate.handle else null;
}

pub fn ownerMailbox(self: *Runtime) *OwnerMailbox.Mailbox {
    std.debug.assert(self.owner_mailbox != null);
    return &self.owner_mailbox.?;
}
