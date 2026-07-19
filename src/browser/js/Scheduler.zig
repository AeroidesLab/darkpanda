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
const builtin = @import("builtin");
const milliTimestamp = @import("../../datetime.zig").milliTimestamp;

const log = lp.log;
const IS_DEBUG = builtin.mode == .Debug;

const Queue = std.PriorityQueue(Task, void, struct {
    fn compare(_: void, a: Task, b: Task) std.math.Order {
        const time_order = std.math.order(a.run_at, b.run_at);
        if (time_order != .eq) return time_order;
        // Break ties with sequence number to maintain FIFO order
        return std.math.order(a.sequence, b.sequence);
    }
}.compare);

const Scheduler = @This();

_sequence: u64,
// Browser/worker Envs install one shared counter for every Context in the
// responsible agent. Standalone schedulers (notably pure Zig tests) keep using
// `_sequence`, so this module does not need to import Env and form a cycle.
shared_sequence: ?*u64,
// Some things (e.g. IndexedDB) can have operations that are only valid for a
// specific task boundary. So every time we start a task, we increment the
// scheduler's generation. Code can snapshot this version and then compare it
// later to see if we're still in the same task.
generation: u64,
// Context destruction stops HTML tasks permanently while leaving V8's
// MicrotaskQueue usable by the retained realm.
stopped: bool,
low_priority: Queue,
high_priority: Queue,

pub fn init(allocator: std.mem.Allocator) Scheduler {
    return .{
        ._sequence = 0,
        .shared_sequence = null,
        .generation = 0,
        .stopped = false,
        .low_priority = Queue.init(allocator, {}),
        .high_priority = Queue.init(allocator, {}),
    };
}

pub fn initShared(allocator: std.mem.Allocator, shared_sequence: *u64) Scheduler {
    var scheduler = init(allocator);
    scheduler.shared_sequence = shared_sequence;
    return scheduler;
}

pub fn deinit(self: *Scheduler) void {
    finalizeTasks(&self.low_priority);
    finalizeTasks(&self.high_priority);
}

pub fn reset(self: *Scheduler) void {
    finalizeTasks(&self.low_priority);
    finalizeTasks(&self.high_priority);
    self.low_priority.clearRetainingCapacity();
    self.high_priority.clearRetainingCapacity();
}

pub fn stop(self: *Scheduler) void {
    if (self.stopped) return;
    self.stopped = true;
    self.reset();
}

const AddOpts = struct {
    name: []const u8 = "",
    low_priority: bool = false,
    finalizer: ?Finalizer = null,
};
pub fn add(self: *Scheduler, ctx: *anyopaque, cb: Callback, run_in_ms: u32, opts: AddOpts) !void {
    if (self.stopped) {
        if (opts.finalizer) |finalize| finalize(ctx);
        return;
    }

    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "scheduler.add", .{ .name = opts.name, .run_in_ms = run_in_ms, .low_priority = opts.low_priority });
    }
    var queue = if (opts.low_priority) &self.low_priority else &self.high_priority;
    const sequence = self.shared_sequence orelse &self._sequence;
    sequence.* +%= 1;
    const seq = sequence.*;
    return queue.add(.{
        .ctx = ctx,
        .callback = cb,
        .sequence = seq,
        .name = opts.name,
        .finalizer = opts.finalizer,
        .run_at = milliTimestamp(.monotonic) + run_in_ms,
    });
}

/// Remove a queued task identified by its context and run its finalizer.
/// Returns false when the task is already executing or no longer queued.
pub fn cancel(self: *Scheduler, ctx: *anyopaque) bool {
    if (cancelFromQueue(&self.low_priority, ctx)) return true;
    return cancelFromQueue(&self.high_priority, ctx);
}

pub const Priority = enum {
    high,
    low,
};

pub const ReadyTask = struct {
    run_at: u64,
    sequence: u64,

    pub fn precedes(self: ReadyTask, other: ReadyTask) bool {
        if (self.run_at != other.run_at) return self.run_at < other.run_at;
        return self.sequence < other.sequence;
    }
};

pub fn peekReady(self: *Scheduler, priority: Priority, now: u64) ?ReadyTask {
    if (self.stopped) return null;
    const task = queueFor(self, priority).peek() orelse return null;
    if (task.run_at > now) return null;
    return .{
        .run_at = task.run_at,
        .sequence = task.sequence,
    };
}

/// Runs at most one eligible task from the requested priority queue. Env uses
/// this boundary to arbitrate across Contexts and checkpoint microtasks after
/// every callback instead of draining one Context at a time.
pub fn runOne(self: *Scheduler, priority: Priority, now: u64) !bool {
    const queue = queueFor(self, priority);
    const next = queue.peek() orelse return false;
    if (self.stopped or next.run_at > now) return false;

    var task = queue.remove();
    if (comptime IS_DEBUG) {
        log.debug(.scheduler, "scheduler.runTask", .{ .name = task.name });
    }

    self.generation +%= 1;

    const repeat_in_ms = task.callback(task.ctx) catch |err| {
        log.warn(.scheduler, "task.callback", .{ .name = task.name, .err = err });
        return true;
    };
    if (repeat_in_ms) |ms| {
        // Task cannot be repeated immediately, and they should know that.
        if (comptime IS_DEBUG) {
            std.debug.assert(ms != 0);
        }
        if (self.stopped) {
            if (task.finalizer) |finalize| finalize(task.ctx);
        } else {
            task.run_at = now + ms;
            // A repeating task stays in its original task queue. In
            // particular, setInterval is normal timer work on every firing; it
            // must not turn into idle/background work after its first callback.
            try queue.add(task);
        }
    }

    return true;
}

pub fn run(self: *Scheduler) !void {
    const start = milliTimestamp(.monotonic);
    while (true) {
        const now = milliTimestamp(.monotonic);
        // Idle/background work is only eligible after every currently ready
        // normal task has run. Re-check high after every callback because a low
        // task is allowed to enqueue normal work.
        const priority: Priority = if (self.peekReady(.high, now) != null)
            .high
        else if (self.peekReady(.low, now) != null)
            .low
        else
            return;

        _ = try self.runOne(priority, now);
        if (milliTimestamp(.monotonic) - start > 500) return;
    }
}

pub fn hasReadyTasks(self: *Scheduler) bool {
    const now = milliTimestamp(.monotonic);
    return self.peekReady(.high, now) != null or self.peekReady(.low, now) != null;
}

pub fn msToNextHigh(self: *Scheduler) ?u64 {
    const task = self.high_priority.peek() orelse return null;
    const now = milliTimestamp(.monotonic);
    if (task.run_at <= now) {
        return 0;
    }
    return @intCast(task.run_at - now);
}

fn queueFor(self: *Scheduler, priority: Priority) *Queue {
    return switch (priority) {
        .high => &self.high_priority,
        .low => &self.low_priority,
    };
}

fn cancelFromQueue(queue: *Queue, ctx: *anyopaque) bool {
    for (queue.items, 0..) |task, index| {
        if (task.ctx != ctx) continue;

        const removed = queue.removeIndex(index);
        if (removed.finalizer) |finalize| finalize(removed.ctx);
        return true;
    }
    return false;
}

fn finalizeTasks(queue: *Queue) void {
    var it = queue.iterator();
    while (it.next()) |t| {
        if (t.finalizer) |func| {
            func(t.ctx);
        }
    }
}

const Task = struct {
    run_at: u64,
    sequence: u64,
    ctx: *anyopaque,
    name: []const u8,
    callback: Callback,
    finalizer: ?Finalizer,
};

const Callback = *const fn (ctx: *anyopaque) anyerror!?u32;
const Finalizer = *const fn (ctx: *anyopaque) void;

test "cancel removes queued task and finalizes it exactly once" {
    const State = struct {
        ran: usize = 0,
        finalized: usize = 0,

        fn run(ctx: *anyopaque) anyerror!?u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ran += 1;
            return null;
        }

        fn finalize(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.finalized += 1;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var scheduler = Scheduler.init(arena.allocator());
    defer scheduler.deinit();

    var high: State = .{};
    try scheduler.add(&high, State.run, 60_000, .{ .finalizer = State.finalize });
    try std.testing.expect(scheduler.msToNextHigh() != null);
    try std.testing.expect(scheduler.cancel(&high));
    try std.testing.expectEqual(@as(usize, 0), high.ran);
    try std.testing.expectEqual(@as(usize, 1), high.finalized);
    try std.testing.expectEqual(@as(?u64, null), scheduler.msToNextHigh());
    try std.testing.expect(!scheduler.cancel(&high));
    try std.testing.expectEqual(@as(usize, 1), high.finalized);

    var low: State = .{};
    try scheduler.add(&low, State.run, 60_000, .{ .low_priority = true, .finalizer = State.finalize });
    try std.testing.expect(scheduler.cancel(&low));
    try std.testing.expectEqual(@as(usize, 1), low.finalized);
}

test "ready high-priority tasks run before idle work" {
    const State = struct {
        order: *[2]u8,
        next: *usize,
        value: u8,

        fn run(ctx: *anyopaque) anyerror!?u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.order[self.next.*] = self.value;
            self.next.* += 1;
            return null;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var scheduler = Scheduler.init(arena.allocator());
    defer scheduler.deinit();

    var order: [2]u8 = undefined;
    var next: usize = 0;
    var low = State{ .order = &order, .next = &next, .value = 2 };
    var high = State{ .order = &order, .next = &next, .value = 1 };
    try scheduler.add(&low, State.run, 0, .{ .low_priority = true });
    try scheduler.add(&high, State.run, 0, .{});
    try scheduler.run();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &order);
}

test "shared enqueue sequence orders ready work across schedulers" {
    const State = struct {
        order: *[2]u8,
        next: *usize,
        value: u8,

        fn run(ctx: *anyopaque) anyerror!?u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.order[self.next.*] = self.value;
            self.next.* += 1;
            return null;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sequence: u64 = 0;
    var scheduler_a = Scheduler.initShared(arena.allocator(), &sequence);
    defer scheduler_a.deinit();
    var scheduler_b = Scheduler.initShared(arena.allocator(), &sequence);
    defer scheduler_b.deinit();

    var order: [2]u8 = undefined;
    var next: usize = 0;
    var first = State{ .order = &order, .next = &next, .value = 1 };
    var second = State{ .order = &order, .next = &next, .value = 2 };

    // This models A posting to B first and B posting to A second. The target
    // Context schedulers appear in the opposite order from enqueue order.
    try scheduler_b.add(&first, State.run, 0, .{});
    try scheduler_a.add(&second, State.run, 0, .{});
    scheduler_a.high_priority.items[0].run_at = 0;
    scheduler_b.high_priority.items[0].run_at = 0;

    const candidate_a = scheduler_a.peekReady(.high, 0).?;
    const candidate_b = scheduler_b.peekReady(.high, 0).?;
    try std.testing.expect(candidate_b.precedes(candidate_a));
    try std.testing.expectEqual(@as(u64, 1), candidate_b.sequence);
    try std.testing.expectEqual(@as(u64, 2), candidate_a.sequence);

    try std.testing.expect(try scheduler_b.runOne(.high, 0));
    try std.testing.expect(try scheduler_a.runOne(.high, 0));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &order);
    try std.testing.expectEqual(@as(u64, 1), scheduler_a.generation);
    try std.testing.expectEqual(@as(u64, 1), scheduler_b.generation);
}

test "a low task yields to high work it enqueues" {
    const State = struct {
        scheduler: *Scheduler,
        order: *[3]u8,
        next: *usize,
        value: u8,
        enqueue_high: ?*@This() = null,

        fn run(ctx: *anyopaque) anyerror!?u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.order[self.next.*] = self.value;
            self.next.* += 1;
            if (self.enqueue_high) |high| {
                self.enqueue_high = null;
                try self.scheduler.add(high, @This().run, 0, .{});
            }
            return null;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var scheduler = Scheduler.init(arena.allocator());
    defer scheduler.deinit();

    var order: [3]u8 = undefined;
    var next: usize = 0;
    var high = State{ .scheduler = &scheduler, .order = &order, .next = &next, .value = 2 };
    var low_second = State{ .scheduler = &scheduler, .order = &order, .next = &next, .value = 3 };
    var low_first = State{ .scheduler = &scheduler, .order = &order, .next = &next, .value = 1, .enqueue_high = &high };

    try scheduler.add(&low_first, State.run, 0, .{ .low_priority = true });
    try scheduler.add(&low_second, State.run, 0, .{ .low_priority = true });
    try scheduler.run();

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &order);
}

test "setInterval-style repeating task preserves high priority ahead of idle work" {
    const State = struct {
        order: *[3]u8,
        next: *usize,
        value: u8,
        repeat_once_ms: ?u32 = null,

        fn run(ctx: *anyopaque) anyerror!?u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.order[self.next.*] = self.value;
            self.next.* += 1;

            const repeat_ms = self.repeat_once_ms;
            self.repeat_once_ms = null;
            return repeat_ms;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var scheduler = Scheduler.init(arena.allocator());
    defer scheduler.deinit();

    var order: [3]u8 = undefined;
    var next: usize = 0;
    var interval = State{ .order = &order, .next = &next, .value = 1, .repeat_once_ms = 60_000 };
    var idle = State{ .order = &order, .next = &next, .value = 3 };

    // The interval's first firing is ready while idle work is still pending.
    try scheduler.add(&interval, State.run, 0, .{});
    try scheduler.add(&idle, State.run, 60_000, .{ .low_priority = true });
    try scheduler.run();
    try std.testing.expectEqual(@as(usize, 1), next);
    try std.testing.expectEqual(@as(usize, 1), scheduler.high_priority.count());
    try std.testing.expectEqual(@as(usize, 1), scheduler.low_priority.count());

    // Make both pending tasks ready, with idle work carrying the earlier
    // timestamp. Queue priority must still make the second interval firing run
    // first. Each queue contains one item, so changing run_at preserves its
    // priority-queue invariant.
    scheduler.low_priority.items[0].run_at = 0;
    scheduler.high_priority.items[0].run_at = 1;
    interval.value = 2;
    try scheduler.run();

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &order);
}
