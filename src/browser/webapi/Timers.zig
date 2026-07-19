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

// Shared bookkeeping for setTimeout / setInterval (and Window-only
// requestAnimationFrame / requestIdleCallback). Both Window
// and WorkerGlobalScope embed a Timers and forward their JS-bridged
// methods through `schedule` / `clear`.

const std = @import("std");
const lp = @import("darkpanda");

const js = @import("../js/js.zig");
const milliTimestamp = @import("../../datetime.zig").milliTimestamp;
const TrustedTypes = @import("TrustedTypes.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const CLAMP_MS = 4;
const CLAMP_NESTING = 6;

const Timers = @This();

_timer_id: u31 = 0,
_callbacks: CallbackHashMap = .{},

// We keep the depth of the timers (a setTimeout calling a setTimeout). When
// the depth exceeds CLAMP_NESTING, the minimum timeout is 4ms. This is per-
// spec and it's necessary to prevent some sites from virtually breaking because
// they repeatedly do heavy work in endlessly looping setTimeout with a short
// timeout (often of 0ms)
_nesting_level: u8 = 0,

const Key = u32;
const CallbackHashMap = std.HashMapUnmanaged(
    Key,
    *ScheduleCallback,
    struct {
        pub fn hash(_: @This(), key: Key) Key {
            return std.hash.int(key);
        }

        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return std.meta.eql(a, b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub const Mode = enum {
    idle,
    normal,
    animation_frame,
};

pub const ScheduleOpts = struct {
    repeat: bool,
    params: []js.Value.Global,
    name: []const u8,
    low_priority: bool = false,
    mode: Mode = .normal,
};

pub fn schedule(
    self: *Timers,
    exec: *js.Execution,
    cb: js.Function.Global,
    delay_ms: u32,
    opts: ScheduleOpts,
) !u32 {
    // schedule takes ownership of the callback and variadic arguments. If any
    // allocation or scheduler insertion fails, release them here as Blink's
    // timer initialization algorithm would discard the task.
    errdefer {
        cb.release();
        for (opts.params) |param| param.release();
    }

    // A detached Window keeps its realm alive, but HTML's timer initialization
    // steps abort and return 0 once its browsing context is gone. The converted
    // callback/arguments are owned by this function, so release them here just
    // as a completed/cancelled task would.
    if (exec.isShuttingDown()) {
        cb.release();
        for (opts.params) |param| param.release();
        return 0;
    }

    const arena = try exec.getArena(.tiny, "Timers.schedule");
    errdefer exec.releaseArena(arena);

    const timer_id = self.nextTimerId();

    const nesting = @min(self._nesting_level + 1, CLAMP_NESTING + 1);
    const delay = clampDelay(nesting, delay_ms);

    var persisted_params: []js.Value.Global = &.{};
    if (opts.params.len > 0) {
        persisted_params = try arena.dupe(js.Value.Global, opts.params);
    }

    const gop = try self._callbacks.getOrPut(exec.arena, timer_id);
    if (gop.found_existing) {
        // 2^31 would have to wrap for this to happen.
        return error.TooManyTimeout;
    }
    errdefer _ = self._callbacks.remove(timer_id);

    const callback = try arena.create(ScheduleCallback);
    callback.* = .{
        .cb = cb,
        .exec = exec,
        .timers = self,
        .arena = arena,
        .mode = opts.mode,
        .name = opts.name,
        .nesting = nesting,
        .timer_id = timer_id,
        .params = persisted_params,
        // Chrome 149 enables kSetIntervalWithoutClamp: a top-level
        // setInterval(..., 0) remains at zero until timer nesting reaches the
        // normal 4 ms clamp. Zero-delay repeats are explicitly re-queued in
        // ScheduleCallback.run because Scheduler's repeat return convention
        // reserves zero.
        .repeat_ms = if (opts.repeat) delay else null,
    };
    gop.value_ptr.* = callback;

    try exec.js.scheduler.add(callback, ScheduleCallback.run, delay, .{
        .name = opts.name,
        .low_priority = opts.low_priority,
        .finalizer = ScheduleCallback.cancelled,
    });

    return timer_id;
}

/// Schedule the two competing arms required by requestIdleCallback.
///
/// The low-priority arm is ready immediately. A positive explicit timeout also
/// gets a high-priority arm. Both arms retain the same logical callback; the
/// first one to claim it cancels the other before entering JavaScript. The
/// low-priority arm also checks the absolute timeout defensively; Scheduler
/// normally lets a ready high-priority timeout arm win before idle work.
pub fn scheduleIdle(
    self: *Timers,
    exec: *js.Execution,
    cb: js.Function.Global,
    timeout_ms: ?u32,
) !u32 {
    var ownership_transferred = false;
    errdefer if (!ownership_transferred) cb.release();

    if (exec.isShuttingDown()) {
        cb.release();
        return 0;
    }

    const arena = try exec.getArena(.tiny, "Timers.scheduleIdle");
    errdefer if (!ownership_transferred) exec.releaseArena(arena);

    const timer_id = self.nextTimerId();
    const gop = try self._callbacks.getOrPut(exec.arena, timer_id);
    if (gop.found_existing) return error.TooManyTimeout;
    errdefer if (!ownership_transferred) {
        _ = self._callbacks.remove(timer_id);
    };

    const callback = try arena.create(ScheduleCallback);
    callback.* = .{
        .cb = cb,
        .exec = exec,
        .timers = self,
        .arena = arena,
        .mode = .idle,
        .name = "window.requestIdleCallback",
        .nesting = 0,
        .timer_id = timer_id,
        .params = &.{},
        .repeat_ms = null,
        // Hold destruction until both Scheduler.add calls have either queued
        // an arm or synchronously finalized it on a stopped scheduler.
        .idle_deinit_held = true,
        .idle_deadline_ms = if (timeout_ms) |ms|
            if (ms > 0) milliTimestamp(.monotonic) + ms else null
        else
            null,
    };

    if (callback.idle_deadline_ms != null) {
        const timeout_arm = try arena.create(IdleTimeoutArm);
        timeout_arm.* = .{ .owner = callback };
        callback.idle_timeout_arm = timeout_arm;
    }

    gop.value_ptr.* = callback;
    ownership_transferred = true;

    callback.addIdleLowArm() catch |err| {
        callback.failIdleConstruction();
        return err;
    };

    // A stopped scheduler finalizes add() synchronously. Do not attempt to
    // queue its sibling after that cancellation has already won.
    if (!callback.removed and callback.idle_timeout_arm != null) {
        callback.addIdleTimeoutArm() catch |err| {
            callback.failIdleConstruction();
            return err;
        };
    }

    callback.idle_deinit_held = false;
    callback.idleMaybeDeinit();
    return timer_id;
}

pub fn clear(self: *Timers, id: u32) void {
    const sc = self._callbacks.fetchRemove(id) orelse return;
    const callback = sc.value;
    callback.removed = true;

    if (callback.mode == .idle) {
        callback.cancelIdleArms();
        return;
    }

    // A cleared timer must not keep Runner waiting until its original due
    // time. If it is currently executing it is no longer in the queue; the
    // removed flag above then prevents an interval from being re-armed.
    const scheduler = &callback.exec.js.scheduler;
    _ = scheduler.cancel(callback);
}

fn nextTimerId(self: *Timers) u31 {
    while (true) {
        const candidate: u31 = if (self._timer_id == std.math.maxInt(u31)) 1 else self._timer_id + 1;
        self._timer_id = candidate;
        if (!self._callbacks.contains(candidate)) return candidate;
    }
}

fn clampDelay(nesting: u8, delay_ms: u32) u32 {
    return if (nesting > CLAMP_NESTING and delay_ms < CLAMP_MS) CLAMP_MS else delay_ms;
}

fn nextRepeatDelay(nesting: *u8, interval_ms: u32) u32 {
    nesting.* = @min(nesting.* + 1, CLAMP_NESTING + 1);
    return clampDelay(nesting.*, interval_ms);
}

// https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#dom-settimeout
// https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#timerhandler
// TimerHandler = Function or DOMString. When a string is passed, it is
// compiled into an anonymous function body, matching how legacy browsers
// (and all current UAs) interpret `setTimeout("foo()", 100)`.
pub const LegacyHandler = union(enum) {
    function: js.Function.Global,
    string: StringHandler,

    const StringHandler = struct {
        // A genuine TrustedScript must keep its native brand until the TT
        // check after delay conversion. Every other input is already a plain
        // DOMString Value here, so author ToString side effects still occur in
        // the correct first conversion phase.
        input: js.Value,
        compliant: ?js.String = null,
    };

    pub fn release(handler: LegacyHandler) void {
        switch (handler) {
            .function => |fun| fun.release(),
            .string => {},
        }
    }

    pub fn applyTrustedTypes(
        handler: *LegacyHandler,
        owner_context: *js.Context,
        factory: *TrustedTypes.TrustedTypePolicyFactory,
        exec: *js.Execution,
        operation: js.WebIDL.Operation,
    ) !void {
        switch (handler.*) {
            .function => return,
            .string => |*string_handler| {
                const compliant = try TrustedTypes.getCompliantString(
                    string_handler.input,
                    owner_context,
                    factory,
                    .script,
                    operation.interface,
                    operation.name,
                    .{ .operation = operation },
                    .dom_string,
                    exec,
                );
                string_handler.compliant = compliant;
            },
        }
    }

    /// Legacy CSP denial for string timers is silent and returns timer id 0.
    /// An empty final handler is likewise not installed. Function handlers do
    /// not use string code generation and always continue to scheduling.
    pub fn shouldSchedule(handler: LegacyHandler, owner_context: *js.Context) !bool {
        return switch (handler) {
            .function => true,
            .string => |value| owner_context.csp_code_generation.allow_eval and
                (try value.compliant.?.toSlice()).len != 0,
        };
    }

    pub fn resolve(handler: LegacyHandler, exec: *js.Execution) !js.Function.Global {
        switch (handler) {
            .function => |fun| return fun,
            .string => |str| {
                const fun = try exec.js.local.?.compileFunction(try str.compliant.?.toSlice(), &.{}, &.{});
                return fun.persist();
            },
        }
    }
};

pub fn convertHandler(
    raw: ?js.Value,
    exec: *js.Execution,
    operation: js.WebIDL.Operation,
) !LegacyHandler {
    const value = raw orelse return js.WebIDL.requiredArgument(exec, operation, 1, 0);
    if (value.isFunction()) {
        const function = js.Function{
            .local = value.local,
            .handle = @ptrCast(value.handle),
        };
        return .{ .function = try function.persist() };
    }
    const input = if (TrustedTypes.trustedPayload(value, .script, value.local) != null)
        value
    else
        (try js.WebIDL.toDOMStringValueWithContext(
            value,
            exec,
            .{ .operation = operation },
        )).toValue();
    return .{ .string = .{ .input = input } };
}

pub fn convertDelay(
    raw: ?js.Value,
    exec: *js.Execution,
    operation: js.WebIDL.Operation,
) !u32 {
    const value = raw orelse return 0;
    const signed = try js.WebIDL.toLong(value, exec, operation);
    return if (signed <= 0) 0 else @intCast(signed);
}

const ScheduleCallback = struct {
    // for debugging
    name: []const u8,

    // Timers._callbacks key
    timer_id: u31,

    // delay, in ms, to repeat. When null, removed after first invocation.
    repeat_ms: ?u32,

    // The nesting of this task. When it executes, this nesting will become
    // the Timer's _nesting_level so that any new timers will become nesting + 1
    nesting: u8,

    cb: js.Function.Global,

    mode: Mode,
    exec: *js.Execution,
    timers: *Timers,
    arena: Allocator,
    removed: bool = false,
    params: []const js.Value.Global,

    // requestIdleCallback owns two Scheduler tasks but one JS callback. These
    // fields are unused by regular timers/RAF.
    idle_deadline_ms: ?u64 = null,
    idle_timeout_arm: ?*IdleTimeoutArm = null,
    idle_arm_refs: u2 = 0,
    idle_low_live: bool = false,
    idle_timeout_live: bool = false,
    idle_fired: bool = false,
    idle_deinit_held: bool = false,

    fn cancelled(ptr: *anyopaque) void {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ptr));
        self.unlink();
        self.deinit();
    }

    fn unlink(self: *ScheduleCallback) void {
        const current = self.timers._callbacks.get(self.timer_id) orelse return;
        if (current == self) _ = self.timers._callbacks.remove(self.timer_id);
    }

    fn deinit(self: *ScheduleCallback) void {
        self.cb.release();
        for (self.params) |param| {
            param.release();
        }
        self.exec.releaseArena(self.arena);
    }

    fn addIdleLowArm(self: *ScheduleCallback) !void {
        std.debug.assert(self.mode == .idle);
        std.debug.assert(!self.idle_low_live);
        self.idle_low_live = true;
        self.idle_arm_refs += 1;
        self.exec.js.scheduler.add(self, runIdleLow, 0, .{
            .name = "window.requestIdleCallback.idle",
            .low_priority = true,
            .finalizer = idleLowCancelled,
        }) catch |err| {
            // Scheduler.add only invokes the finalizer on a stopped scheduler.
            // Queue insertion errors leave ownership with the caller.
            if (self.idle_low_live) {
                self.idle_low_live = false;
                self.idle_arm_refs -= 1;
            }
            return err;
        };
    }

    fn addIdleTimeoutArm(self: *ScheduleCallback) !void {
        const arm = self.idle_timeout_arm.?;
        std.debug.assert(!self.idle_timeout_live);
        self.idle_timeout_live = true;
        self.idle_arm_refs += 1;
        const now = milliTimestamp(.monotonic);
        const deadline = self.idle_deadline_ms.?;
        const delay: u32 = if (deadline <= now) 0 else @intCast(deadline - now);
        self.exec.js.scheduler.add(arm, IdleTimeoutArm.run, delay, .{
            .name = "window.requestIdleCallback.timeout",
            .low_priority = false,
            .finalizer = IdleTimeoutArm.cancelled,
        }) catch |err| {
            if (self.idle_timeout_live) {
                self.idle_timeout_live = false;
                self.idle_arm_refs -= 1;
            }
            return err;
        };
    }

    fn failIdleConstruction(self: *ScheduleCallback) void {
        self.removed = true;
        self.unlink();
        self.cancelIdleArmsHeld();
        self.idle_deinit_held = false;
        self.idleMaybeDeinit();
    }

    fn cancelIdleArms(self: *ScheduleCallback) void {
        const was_held = self.idle_deinit_held;
        self.idle_deinit_held = true;
        self.cancelIdleArmsHeld();
        self.idle_deinit_held = was_held;
        if (!was_held) self.idleMaybeDeinit();
    }

    fn cancelIdleArmsHeld(self: *ScheduleCallback) void {
        if (self.idle_low_live) {
            _ = self.exec.js.scheduler.cancel(self);
        }
        if (self.idle_timeout_live) {
            _ = self.exec.js.scheduler.cancel(self.idle_timeout_arm.?);
        }
    }

    fn idleArmGone(self: *ScheduleCallback) void {
        std.debug.assert(self.idle_arm_refs > 0);
        self.idle_arm_refs -= 1;
        if (!self.idle_fired) {
            self.removed = true;
            self.unlink();
        }
        self.idleMaybeDeinit();
    }

    fn idleMaybeDeinit(self: *ScheduleCallback) void {
        if (self.idle_deinit_held or self.idle_arm_refs != 0) return;
        self.unlink();
        self.deinit();
    }

    fn idleLowCancelled(ptr: *anyopaque) void {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ptr));
        if (!self.idle_low_live) return;
        self.idle_low_live = false;
        self.idleArmGone();
    }

    fn runIdleLow(ptr: *anyopaque) !?u32 {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.idle_low_live);
        self.idle_low_live = false;
        defer self.idleArmGone();

        const did_timeout = if (self.idle_deadline_ms) |deadline|
            milliTimestamp(.monotonic) >= deadline
        else
            false;
        self.runIdleWinner(did_timeout, .low);
        return null;
    }

    const IdleWinningArm = enum { low, timeout };

    fn runIdleWinner(self: *ScheduleCallback, did_timeout: bool, winning_arm: IdleWinningArm) void {
        if (self.removed or self.idle_fired or self.exec.isShuttingDown()) {
            self.removed = true;
            self.unlink();
            return;
        }

        self.idle_fired = true;
        self.unlink();

        // Remove the losing scheduler task before invoking user code. This is
        // what gives cancel/close/reset a single callback and a single release.
        switch (winning_arm) {
            .low => if (self.idle_timeout_live) {
                _ = self.exec.js.scheduler.cancel(self.idle_timeout_arm.?);
            },
            .timeout => if (self.idle_low_live) {
                _ = self.exec.js.scheduler.cancel(self);
            },
        }

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        const IdleDeadline = @import("IdleDeadline.zig");
        ls.toLocal(self.cb).call(void, .{IdleDeadline.init(did_timeout)}) catch |err| {
            log.warn(.js, "idleCallback", .{ .name = self.name, .err = err });
        };
        ls.local.runMicrotasks();
    }

    fn run(ptr: *anyopaque) !?u32 {
        const self: *ScheduleCallback = @ptrCast(@alignCast(ptr));
        if (self.removed or self.exec.isShuttingDown()) {
            self.unlink();
            self.deinit();
            return null;
        }

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        const timers = self.timers;
        const prev_nesting = timers._nesting_level;
        timers._nesting_level = self.nesting;
        defer timers._nesting_level = prev_nesting;

        switch (self.mode) {
            .idle => unreachable,
            .animation_frame => {
                const now = switch (self.exec.js.global) {
                    .frame => |frame| frame.window._performance.now(),
                    .worker => |worker| worker._performance.now(),
                };
                ls.toLocal(self.cb).call(void, .{now}) catch |err| {
                    log.warn(.js, "RAF", .{ .name = self.name, .err = err });
                };
            },
            .normal => {
                ls.toLocal(self.cb).call(void, self.params) catch |err| {
                    log.warn(.js, "timer", .{ .name = self.name, .err = err });
                };
            },
        }
        ls.local.runMicrotasks();

        // close()/iframe removal can run inside the callback. Never let an
        // interval or animation callback re-arm itself across that boundary.
        if (self.removed or self.exec.isShuttingDown()) {
            self.unlink();
            self.deinit();
            return null;
        }

        if (self.repeat_ms) |ms| {
            // each repeat re-enters the timer initialization steps, so the
            // nesting level keeps growing and sub-4ms intervals get clamped.
            const repeat_delay = nextRepeatDelay(&self.nesting, ms);
            if (repeat_delay == 0) {
                // Scheduler uses a null return to mean "do not repeat" and
                // historically asserted that a repeat delay was non-zero.
                // Queue a fresh zero-delay timer task instead. Its new sequence
                // number also lets already-queued timer tasks retain FIFO order.
                self.exec.js.scheduler.add(self, ScheduleCallback.run, 0, .{
                    .name = self.name,
                    .finalizer = ScheduleCallback.cancelled,
                }) catch |err| {
                    self.removed = true;
                    self.unlink();
                    self.deinit();
                    return err;
                };
                // add() can synchronously finalize `self` on a stopped
                // scheduler, so do not access it after this point.
                return null;
            }
            return repeat_delay;
        }
        defer self.deinit();
        self.unlink();
        return null;
    }
};

const IdleTimeoutArm = struct {
    owner: *ScheduleCallback,

    fn cancelled(ptr: *anyopaque) void {
        const arm: *IdleTimeoutArm = @ptrCast(@alignCast(ptr));
        const self = arm.owner;
        if (!self.idle_timeout_live) return;
        self.idle_timeout_live = false;
        self.idleArmGone();
    }

    fn run(ptr: *anyopaque) !?u32 {
        const arm: *IdleTimeoutArm = @ptrCast(@alignCast(ptr));
        const self = arm.owner;
        std.debug.assert(self.idle_timeout_live);
        self.idle_timeout_live = false;
        defer self.idleArmGone();
        self.runIdleWinner(true, .timeout);
        return null;
    }
};

test "timer delay clamp starts after six nested timers" {
    try std.testing.expectEqual(@as(u32, 0), clampDelay(6, 0));
    try std.testing.expectEqual(@as(u32, 4), clampDelay(7, 0));
    try std.testing.expectEqual(@as(u32, 4), clampDelay(7, 3));
    try std.testing.expectEqual(@as(u32, 4), clampDelay(7, 4));
    try std.testing.expectEqual(@as(u32, 5), clampDelay(7, 5));
}

test "zero interval repeats immediately six times before the 4ms clamp" {
    // The initial installation at nesting level 1 has a zero delay. The next
    // five re-arms also remain zero; the re-arm after the sixth callback is the
    // first one whose nesting level is 7 and is therefore clamped.
    var nesting: u8 = 1;
    for (0..5) |_| {
        try std.testing.expectEqual(@as(u32, 0), nextRepeatDelay(&nesting, 0));
    }
    try std.testing.expectEqual(@as(u8, 6), nesting);
    try std.testing.expectEqual(@as(u32, 4), nextRepeatDelay(&nesting, 0));
    try std.testing.expectEqual(@as(u8, 7), nesting);
    try std.testing.expectEqual(@as(u32, 4), nextRepeatDelay(&nesting, 0));
}

test "zero interval installed at nesting four clamps after three callbacks" {
    // An async continuation resumed by a timer is still part of that timer's
    // task. If earlier timer continuations have raised the inherited nesting
    // to four, only two zero-delay re-arms remain before the re-arm after the
    // third callback reaches nesting seven and is clamped.
    var nesting: u8 = 4;
    try std.testing.expectEqual(@as(u32, 0), nextRepeatDelay(&nesting, 0));
    try std.testing.expectEqual(@as(u8, 5), nesting);
    try std.testing.expectEqual(@as(u32, 0), nextRepeatDelay(&nesting, 0));
    try std.testing.expectEqual(@as(u8, 6), nesting);
    try std.testing.expectEqual(@as(u32, 4), nextRepeatDelay(&nesting, 0));
    try std.testing.expectEqual(@as(u8, 7), nesting);
}

test "timer ids wrap at INT_MAX and skip live ids" {
    var timers: Timers = .{};
    defer timers._callbacks.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u31, 1), timers.nextTimerId());

    var callback: ScheduleCallback = undefined;
    try timers._callbacks.put(std.testing.allocator, std.math.maxInt(u31), &callback);
    try timers._callbacks.put(std.testing.allocator, 1, &callback);
    timers._timer_id = std.math.maxInt(u31) - 1;

    try std.testing.expectEqual(std.math.maxInt(u31) - 1, timers._timer_id);
    try std.testing.expectEqual(@as(u31, 2), timers.nextTimerId());
}
