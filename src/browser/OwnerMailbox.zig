// Copyright (C) 2026 DarkPanda contributors
//
// Thread-safe, owner-thread task delivery shared by Window and Worker hosts.
// Producers publish isolate-free owned payloads. Only the owner may drain the
// mailbox, so invoke callbacks can safely enter Execution/Scheduler/V8.

const std = @import("std");

const OwnerMailbox = @This();
const Allocator = std.mem.Allocator;
const List = std.DoublyLinkedList;

/// A wake callback is an edge-trigger hint, not a task executor. It runs on the
/// posting thread and therefore must be thread-safe, non-blocking in normal
/// operation, and must never enter JS/Execution/Scheduler. Typical adapters are
/// HttpClient.handles.wakeup(), a worker Condition signal, or ForegroundWake.
pub const Wake = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque) void,
};

/// Ownership transfers to Sender.postOwned at call entry. `destroy` is called
/// exactly once, including allocation failure and immediate cancellation.
///
/// Immediate cancellation can happen on any producer thread. Consequently,
/// destroy must release only thread-safe/native envelope state; it must not
/// touch V8, Execution, or Scheduler. `invoke` is called only by the mailbox's
/// owner thread and receives the Target's current owner context.
pub const OwnedPayload = struct {
    data: *anyopaque,
    invoke: *const fn (data: *anyopaque, owner_context: *anyopaque) anyerror!void,
    destroy: *const fn (data: *anyopaque) void,

    fn dispose(self: OwnedPayload) void {
        self.destroy(self.data);
    }
};

pub const PostResult = enum {
    queued,
    cancelled,
};

/// Result of `Sender.deliverOwned`. Owner-thread sends are handed directly to
/// the target callback; sends from every other thread retain the ordinary
/// mailbox/FIFO behavior.
pub const DeliveryResult = enum {
    invoked,
    queued,
    cancelled,
};

pub const DrainStats = struct {
    invoked: usize = 0,
    cancelled: usize = 0,
};

pub const TargetError = error{
    MailboxClosed,
    TargetClosed,
};

// Creating a new Target cannot produce TargetClosed: there is no Target yet.
// Keep this precise so host construction does not leak producer-handle errors
// through unrelated DOM API error sets.
pub const CreateTargetError = error{MailboxClosed} || Allocator.Error;

const MailboxCore = struct {
    allocator: Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    owner_thread_id: std.Thread.Id,
    wake: ?Wake,

    mutex: std.Thread.Mutex = .{},
    posts_done: std.Thread.Condition = .{},
    queue: List = .{},
    queued_count: usize = 0,
    active_posts: usize = 0,
    closed: bool = false,

    // Owner-thread only. Closing while draining is supported; destroying the
    // owner handle re-entrantly from an invoke callback is not.
    drain_depth: usize = 0,

    fn assertOwner(self: *const MailboxCore) void {
        std.debug.assert(self.owner_thread_id == std.Thread.getCurrentId());
    }
};

const TargetCore = struct {
    refs: std.atomic.Value(usize) = .init(1),
    mailbox: *MailboxCore,

    mutex: std.Thread.Mutex = .{},
    posts_done: std.Thread.Condition = .{},
    generation: u64 = 1,
    active_posts: usize = 0,
    closed: bool = false,
    owner_context: ?*anyopaque,
};

const Node = struct {
    list_node: List.Node = .{},
    target: *TargetCore,
    generation: u64,
    payload: OwnedPayload,
};

/// The owner-side handle for one event-loop mailbox. Initialize and destroy it
/// on the same OS thread. The allocator must itself be safe for allocations on
/// producer threads and must outlive all Target/Sender handles.
pub const Mailbox = struct {
    core: ?*MailboxCore,

    pub fn init(allocator: Allocator, wake: ?Wake) !Mailbox {
        const core = try allocator.create(MailboxCore);
        core.* = .{
            .allocator = allocator,
            .owner_thread_id = std.Thread.getCurrentId(),
            .wake = wake,
        };
        return .{ .core = core };
    }

    pub fn createTarget(self: *Mailbox, owner_context: *anyopaque) CreateTargetError!Target {
        const core = self.core orelse return error.MailboxClosed;
        core.assertOwner();

        core.mutex.lock();
        const closed = core.closed;
        core.mutex.unlock();
        if (closed) return error.MailboxClosed;

        const target = try core.allocator.create(TargetCore);
        retainMailbox(core);
        target.* = .{
            .mailbox = core,
            .owner_context = owner_context,
        };
        return .{ .core = target };
    }

    pub fn assertOwner(self: *const Mailbox) void {
        if (self.core) |core| core.assertOwner();
    }

    pub fn hasPending(self: *const Mailbox) bool {
        const core = self.core orelse return false;
        core.mutex.lock();
        defer core.mutex.unlock();
        return core.queued_count != 0;
    }

    pub fn pendingCount(self: *const Mailbox) usize {
        const core = self.core orelse return 0;
        core.mutex.lock();
        defer core.mutex.unlock();
        return core.queued_count;
    }

    /// Consume a stable FIFO snapshot. Tasks posted by an invoke callback are
    /// intentionally left for the next host boundary, matching macrotask
    /// semantics and preventing an unbounded producer from monopolizing drain.
    pub fn drain(self: *Mailbox) anyerror!DrainStats {
        const core = self.core orelse return .{};
        core.assertOwner();
        std.debug.assert(core.drain_depth == 0);
        core.drain_depth = 1;
        defer core.drain_depth = 0;

        core.mutex.lock();
        var batch = core.queue;
        core.queue = .{};
        core.queued_count = 0;
        core.mutex.unlock();

        var stats: DrainStats = .{};
        var first_error: ?anyerror = null;
        while (batch.popFirst()) |list_node| {
            const node: *Node = @fieldParentPtr("list_node", list_node);

            const mailbox_open = blk: {
                core.mutex.lock();
                defer core.mutex.unlock();
                break :blk !core.closed;
            };

            const owner_context = if (mailbox_open)
                currentOwnerContext(node.target, node.generation)
            else
                null;

            if (owner_context) |context| {
                node.payload.invoke(node.payload.data, context) catch |err| {
                    if (first_error == null) first_error = err;
                };
                stats.invoked += 1;
            } else {
                stats.cancelled += 1;
            }
            disposeNode(core, node);
        }

        if (first_error) |err| return err;
        return stats;
    }

    /// Publish the closed boundary, wait for every producer that may still be
    /// executing the wake callback, then cancel all queued work on the owner
    /// thread. After this returns the embedder may safely destroy wake.context.
    pub fn close(self: *Mailbox) void {
        const core = self.core orelse return;
        core.assertOwner();

        core.mutex.lock();
        if (!core.closed) core.closed = true;
        while (core.active_posts != 0) {
            core.posts_done.wait(&core.mutex);
        }
        var batch = core.queue;
        core.queue = .{};
        core.queued_count = 0;
        core.mutex.unlock();

        disposeBatch(core, &batch);
    }

    pub fn deinit(self: *Mailbox) void {
        const core = self.core orelse return;
        core.assertOwner();
        std.debug.assert(core.drain_depth == 0);
        self.close();
        self.core = null;
        releaseMailbox(core);
    }
};

/// Owner-side lifecycle token. A Target's owner context may be invalidated
/// independently of its mailbox (for example, navigation or Worker teardown).
/// Queued tasks retain the Target, but generation checks ensure they never
/// dereference a stale owner context.
pub const Target = struct {
    core: ?*TargetCore,

    pub fn sender(self: *const Target) TargetError!Sender {
        const core = self.core orelse return error.TargetClosed;
        core.mailbox.assertOwner();

        core.mutex.lock();
        defer core.mutex.unlock();
        if (core.closed) return error.TargetClosed;

        core.mailbox.mutex.lock();
        const mailbox_closed = core.mailbox.closed;
        core.mailbox.mutex.unlock();
        if (mailbox_closed) return error.MailboxClosed;

        retainTarget(core);
        return .{ .core = core, .generation = core.generation };
    }

    pub fn currentGeneration(self: *const Target) TargetError!u64 {
        const core = self.core orelse return error.TargetClosed;
        core.mailbox.assertOwner();
        core.mutex.lock();
        defer core.mutex.unlock();
        if (core.closed) return error.TargetClosed;
        return core.generation;
    }

    /// Cancel every existing Sender and queued task while keeping this Target
    /// open. A newly acquired Sender observes the incremented generation.
    pub fn invalidate(self: *Target) TargetError!void {
        const core = self.core orelse return error.TargetClosed;
        core.mailbox.assertOwner();

        core.mutex.lock();
        defer core.mutex.unlock();
        if (core.closed) return error.TargetClosed;
        core.generation +%= 1;
        while (core.active_posts != 0) {
            core.posts_done.wait(&core.mutex);
        }
    }

    /// Advance the generation and replace the owner context only after all
    /// old-generation producers have left their active-post sections.
    pub fn renew(self: *Target, owner_context: *anyopaque) TargetError!void {
        const core = self.core orelse return error.TargetClosed;
        core.mailbox.assertOwner();

        core.mutex.lock();
        defer core.mutex.unlock();
        if (core.closed) return error.TargetClosed;
        core.generation +%= 1;
        while (core.active_posts != 0) {
            core.posts_done.wait(&core.mutex);
        }
        core.owner_context = owner_context;
    }

    /// Idempotently stop new posts and wait until no producer can still touch
    /// the wake callback. Queued nodes become generation-cancelled and are
    /// destroyed at the next owner drain (or Mailbox.close).
    pub fn close(self: *Target) void {
        const core = self.core orelse return;
        core.mailbox.assertOwner();

        core.mutex.lock();
        if (!core.closed) {
            core.closed = true;
            core.generation +%= 1;
        }
        while (core.active_posts != 0) {
            core.posts_done.wait(&core.mutex);
        }
        core.owner_context = null;
        core.mutex.unlock();
    }

    pub fn deinit(self: *Target) void {
        const core = self.core orelse return;
        self.close();
        self.core = null;
        releaseTarget(core);
    }
};

/// Retained producer handle for one Target generation. It may cross threads.
pub const Sender = struct {
    core: ?*TargetCore,
    generation: u64,

    pub fn retain(self: *const Sender) TargetError!Sender {
        const core = self.core orelse return error.TargetClosed;
        retainTarget(core);
        return .{ .core = core, .generation = self.generation };
    }

    /// Takes payload ownership regardless of the result. Allocation errors are
    /// reported after destroy has run; lifecycle races return `.cancelled`.
    pub fn postOwned(self: *const Sender, payload: OwnedPayload) Allocator.Error!PostResult {
        const target = self.core orelse {
            payload.dispose();
            return .cancelled;
        };

        if (!beginTargetPost(target, self.generation)) {
            payload.dispose();
            return .cancelled;
        }
        defer endTargetPost(target);

        const mailbox = target.mailbox;
        if (!beginMailboxPost(mailbox)) {
            payload.dispose();
            return .cancelled;
        }
        defer endMailboxPost(mailbox);

        const node = mailbox.allocator.create(Node) catch |err| {
            payload.dispose();
            return err;
        };
        node.* = .{
            .target = target,
            .generation = self.generation,
            .payload = payload,
        };

        mailbox.mutex.lock();
        if (mailbox.closed) {
            mailbox.mutex.unlock();
            payload.dispose();
            mailbox.allocator.destroy(node);
            return .cancelled;
        }
        retainTarget(target); // queue ownership
        mailbox.queue.append(&node.list_node);
        mailbox.queued_count += 1;
        mailbox.mutex.unlock();

        if (mailbox.wake) |wake| wake.notify(wake.context);
        return .queued;
    }

    /// Hand an owned native envelope to its target without delaying an
    /// owner-thread producer until the next host poll. This is useful for
    /// callbacks whose job is to enqueue the *actual* HTML task: invoking the
    /// handoff inline preserves enqueue order while the resulting JS event is
    /// still asynchronous. Cross-thread callers always take the normal
    /// thread-safe FIFO path.
    ///
    /// Ownership transfers at call entry and `destroy` runs exactly once. The
    /// callback may close its own Target or Mailbox re-entrantly; the temporary
    /// Target retain keeps both cores alive until the handoff returns.
    pub fn deliverOwned(self: *const Sender, payload: OwnedPayload) anyerror!DeliveryResult {
        const target = self.core orelse {
            payload.dispose();
            return .cancelled;
        };
        const mailbox = target.mailbox;

        if (mailbox.owner_thread_id != std.Thread.getCurrentId()) {
            return switch (try self.postOwned(payload)) {
                .queued => .queued,
                .cancelled => .cancelled,
            };
        }

        retainTarget(target);
        defer releaseTarget(target);

        const owner_context = currentOwnerContext(target, self.generation) orelse {
            payload.dispose();
            return .cancelled;
        };

        mailbox.mutex.lock();
        const mailbox_open = !mailbox.closed;
        mailbox.mutex.unlock();
        if (!mailbox_open) {
            payload.dispose();
            return .cancelled;
        }

        defer payload.dispose();
        try payload.invoke(payload.data, owner_context);
        return .invoked;
    }

    pub fn deinit(self: *Sender) void {
        const core = self.core orelse return;
        self.core = null;
        releaseTarget(core);
    }
};

fn beginTargetPost(target: *TargetCore, generation: u64) bool {
    target.mutex.lock();
    defer target.mutex.unlock();
    if (target.closed or target.generation != generation) return false;
    target.active_posts += 1;
    return true;
}

fn endTargetPost(target: *TargetCore) void {
    target.mutex.lock();
    std.debug.assert(target.active_posts != 0);
    target.active_posts -= 1;
    if (target.active_posts == 0) target.posts_done.broadcast();
    target.mutex.unlock();
}

fn beginMailboxPost(mailbox: *MailboxCore) bool {
    mailbox.mutex.lock();
    defer mailbox.mutex.unlock();
    if (mailbox.closed) return false;
    mailbox.active_posts += 1;
    return true;
}

fn endMailboxPost(mailbox: *MailboxCore) void {
    mailbox.mutex.lock();
    std.debug.assert(mailbox.active_posts != 0);
    mailbox.active_posts -= 1;
    if (mailbox.active_posts == 0) mailbox.posts_done.broadcast();
    mailbox.mutex.unlock();
}

fn currentOwnerContext(target: *TargetCore, generation: u64) ?*anyopaque {
    target.mutex.lock();
    defer target.mutex.unlock();
    if (target.closed or target.generation != generation) return null;
    return target.owner_context;
}

fn disposeNode(mailbox: *MailboxCore, node: *Node) void {
    node.payload.dispose();
    const target = node.target;
    mailbox.allocator.destroy(node);
    releaseTarget(target);
}

fn disposeBatch(mailbox: *MailboxCore, batch: *List) void {
    while (batch.popFirst()) |list_node| {
        const node: *Node = @fieldParentPtr("list_node", list_node);
        disposeNode(mailbox, node);
    }
}

fn retainMailbox(core: *MailboxCore) void {
    const previous = core.refs.fetchAdd(1, .monotonic);
    std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
}

fn releaseMailbox(core: *MailboxCore) void {
    const previous = core.refs.fetchSub(1, .acq_rel);
    std.debug.assert(previous != 0);
    if (previous != 1) return;

    std.debug.assert(core.closed);
    std.debug.assert(core.active_posts == 0);
    std.debug.assert(core.queue.first == null);
    core.allocator.destroy(core);
}

fn retainTarget(core: *TargetCore) void {
    const previous = core.refs.fetchAdd(1, .monotonic);
    std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
}

fn releaseTarget(core: *TargetCore) void {
    const previous = core.refs.fetchSub(1, .acq_rel);
    std.debug.assert(previous != 0);
    if (previous != 1) return;

    core.mutex.lock();
    const closed = core.closed;
    const active_posts = core.active_posts;
    core.mutex.unlock();
    std.debug.assert(closed);
    std.debug.assert(active_posts == 0);

    const mailbox = core.mailbox;
    const allocator = mailbox.allocator;
    allocator.destroy(core);
    releaseMailbox(mailbox);
}

const TestPayload = struct {
    value: u32,
    destroyed: *std.atomic.Value(usize),

    fn owned(self: *TestPayload) OwnedPayload {
        return .{
            .data = self,
            .invoke = invoke,
            .destroy = destroy,
        };
    }

    fn invoke(raw: *anyopaque, owner_raw: *anyopaque) !void {
        const self: *TestPayload = @ptrCast(@alignCast(raw));
        const owner: *TestOwner = @ptrCast(@alignCast(owner_raw));
        if (std.Thread.getCurrentId() != owner.thread_id) owner.wrong_thread = true;
        owner.order[owner.next] = self.value;
        owner.next += 1;
    }

    fn destroy(raw: *anyopaque) void {
        const self: *TestPayload = @ptrCast(@alignCast(raw));
        _ = self.destroyed.fetchAdd(1, .acq_rel);
        std.heap.page_allocator.destroy(self);
    }
};

const TestOwner = struct {
    thread_id: std.Thread.Id,
    order: [64]u32 = undefined,
    next: usize = 0,
    wrong_thread: bool = false,
};

fn newTestPayload(value: u32, destroyed: *std.atomic.Value(usize)) !OwnedPayload {
    const payload = try std.heap.page_allocator.create(TestPayload);
    payload.* = .{ .value = value, .destroyed = destroyed };
    return payload.owned();
}

test "OwnerMailbox: cross-thread FIFO invokes only on the owner and owns payloads once" {
    var owner: TestOwner = .{ .thread_id = std.Thread.getCurrentId() };
    var destroyed = std.atomic.Value(usize).init(0);
    var mailbox = try Mailbox.init(std.heap.page_allocator, null);
    defer mailbox.deinit();
    var target = try mailbox.createTarget(&owner);
    defer target.deinit();

    const Producer = struct {
        sender: Sender,
        destroyed: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),

        fn run(raw: *@This()) void {
            defer raw.sender.deinit();
            for (0..32) |i| {
                const payload = newTestPayload(@intCast(i), raw.destroyed) catch {
                    raw.failed.store(true, .release);
                    return;
                };
                const result = raw.sender.postOwned(payload) catch {
                    raw.failed.store(true, .release);
                    return;
                };
                if (result != .queued) {
                    raw.failed.store(true, .release);
                    return;
                }
            }
        }
    };

    var failed = std.atomic.Value(bool).init(false);
    var producer = Producer{
        .sender = try target.sender(),
        .destroyed = &destroyed,
        .failed = &failed,
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    thread.join();

    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 32), mailbox.pendingCount());
    const stats = try mailbox.drain();
    try std.testing.expectEqual(@as(usize, 32), stats.invoked);
    try std.testing.expectEqual(@as(usize, 0), stats.cancelled);
    try std.testing.expect(!owner.wrong_thread);
    try std.testing.expectEqual(@as(usize, 32), owner.next);
    for (0..32) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), owner.order[i]);
    try std.testing.expectEqual(@as(usize, 32), destroyed.load(.acquire));
}

test "OwnerMailbox: owner delivery invokes the handoff inline without queueing" {
    var owner: TestOwner = .{ .thread_id = std.Thread.getCurrentId() };
    var destroyed = std.atomic.Value(usize).init(0);
    var mailbox = try Mailbox.init(std.heap.page_allocator, null);
    defer mailbox.deinit();
    var target = try mailbox.createTarget(&owner);
    defer target.deinit();
    var sender = try target.sender();
    defer sender.deinit();

    try std.testing.expectEqual(
        DeliveryResult.invoked,
        try sender.deliverOwned(try newTestPayload(17, &destroyed)),
    );
    try std.testing.expectEqual(@as(usize, 0), mailbox.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), owner.next);
    try std.testing.expectEqual(@as(u32, 17), owner.order[0]);
    try std.testing.expectEqual(@as(usize, 1), destroyed.load(.acquire));
}

test "OwnerMailbox: cross-thread delivery remains queued for the owner" {
    const Producer = struct {
        sender: Sender,
        destroyed: *std.atomic.Value(usize),
        result: ?DeliveryResult = null,
        failed: bool = false,

        fn run(self: *@This()) void {
            defer self.sender.deinit();
            const payload = newTestPayload(23, self.destroyed) catch {
                self.failed = true;
                return;
            };
            self.result = self.sender.deliverOwned(payload) catch {
                self.failed = true;
                return;
            };
        }
    };

    var owner: TestOwner = .{ .thread_id = std.Thread.getCurrentId() };
    var destroyed = std.atomic.Value(usize).init(0);
    var mailbox = try Mailbox.init(std.heap.page_allocator, null);
    defer mailbox.deinit();
    var target = try mailbox.createTarget(&owner);
    defer target.deinit();

    var producer = Producer{
        .sender = try target.sender(),
        .destroyed = &destroyed,
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    thread.join();

    try std.testing.expect(!producer.failed);
    try std.testing.expectEqual(DeliveryResult.queued, producer.result.?);
    try std.testing.expectEqual(@as(usize, 0), owner.next);
    try std.testing.expectEqual(@as(usize, 1), mailbox.pendingCount());
    _ = try mailbox.drain();
    try std.testing.expectEqual(@as(usize, 1), owner.next);
    try std.testing.expectEqual(@as(u32, 23), owner.order[0]);
    try std.testing.expectEqual(@as(usize, 1), destroyed.load(.acquire));
}

test "OwnerMailbox: generation invalidation cancels stale queued and future posts" {
    var owner: TestOwner = .{ .thread_id = std.Thread.getCurrentId() };
    var destroyed = std.atomic.Value(usize).init(0);
    var mailbox = try Mailbox.init(std.heap.page_allocator, null);
    defer mailbox.deinit();
    var target = try mailbox.createTarget(&owner);
    defer target.deinit();
    var stale = try target.sender();
    defer stale.deinit();

    try std.testing.expectEqual(
        PostResult.queued,
        try stale.postOwned(try newTestPayload(1, &destroyed)),
    );
    try target.invalidate();
    try std.testing.expectEqual(
        PostResult.cancelled,
        try stale.postOwned(try newTestPayload(2, &destroyed)),
    );

    var fresh = try target.sender();
    defer fresh.deinit();
    try std.testing.expectEqual(
        PostResult.queued,
        try fresh.postOwned(try newTestPayload(3, &destroyed)),
    );

    const stats = try mailbox.drain();
    try std.testing.expectEqual(@as(usize, 1), stats.invoked);
    try std.testing.expectEqual(@as(usize, 1), stats.cancelled);
    try std.testing.expectEqual(@as(usize, 1), owner.next);
    try std.testing.expectEqual(@as(u32, 3), owner.order[0]);
    try std.testing.expectEqual(@as(usize, 3), destroyed.load(.acquire));
}

test "OwnerMailbox: Target.close waits for the active wake and cancels its queued task" {
    const BlockingWake = struct {
        entered: std.Thread.ResetEvent = .{},
        release: std.Thread.ResetEvent = .{},
        calls: std.atomic.Value(usize) = .init(0),

        fn notify(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.calls.fetchAdd(1, .acq_rel);
            self.entered.set();
            self.release.wait();
        }
    };
    const Producer = struct {
        sender: Sender,
        destroyed: *std.atomic.Value(usize),
        result: ?PostResult = null,
        failed: bool = false,

        fn run(self: *@This()) void {
            defer self.sender.deinit();
            const payload = newTestPayload(7, self.destroyed) catch {
                self.failed = true;
                return;
            };
            self.result = self.sender.postOwned(payload) catch {
                self.failed = true;
                return;
            };
        }
    };
    const Releaser = struct {
        wake: *BlockingWake,

        fn run(self: *@This()) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            self.wake.release.set();
        }
    };

    var wake: BlockingWake = .{};
    var owner: TestOwner = .{ .thread_id = std.Thread.getCurrentId() };
    var destroyed = std.atomic.Value(usize).init(0);
    var mailbox = try Mailbox.init(std.heap.page_allocator, .{
        .context = &wake,
        .notify = BlockingWake.notify,
    });
    defer mailbox.deinit();
    var target = try mailbox.createTarget(&owner);
    defer target.deinit();

    var producer = Producer{
        .sender = try target.sender(),
        .destroyed = &destroyed,
    };
    const producer_thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    wake.entered.wait();

    var releaser = Releaser{ .wake = &wake };
    const release_thread = try std.Thread.spawn(.{}, Releaser.run, .{&releaser});
    target.close();
    release_thread.join();
    producer_thread.join();

    try std.testing.expect(!producer.failed);
    try std.testing.expectEqual(PostResult.queued, producer.result.?);
    try std.testing.expectEqual(@as(usize, 1), wake.calls.load(.acquire));
    const stats = try mailbox.drain();
    try std.testing.expectEqual(@as(usize, 0), stats.invoked);
    try std.testing.expectEqual(@as(usize, 1), stats.cancelled);
    try std.testing.expectEqual(@as(usize, 1), destroyed.load(.acquire));
}

test "OwnerMailbox: retained Sender safely observes mailbox and target teardown" {
    var owner: TestOwner = .{ .thread_id = std.Thread.getCurrentId() };
    var destroyed = std.atomic.Value(usize).init(0);
    var mailbox = try Mailbox.init(std.heap.page_allocator, null);
    var target = try mailbox.createTarget(&owner);
    var sender = try target.sender();
    defer sender.deinit();

    mailbox.deinit();
    target.deinit();

    try std.testing.expectEqual(
        PostResult.cancelled,
        try sender.postOwned(try newTestPayload(9, &destroyed)),
    );
    try std.testing.expectEqual(@as(usize, 1), destroyed.load(.acquire));
}
