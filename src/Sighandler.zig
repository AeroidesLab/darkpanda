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

//! This structure processes operating system signals (SIGINT, SIGTERM)
//! and runs callbacks to clean up the system gracefully.
//!
//! The structure does not clear the memory allocated in the arena,
//! clear the entire arena when exiting the program.
const std = @import("std");
const builtin = @import("builtin");
const lp = @import("darkpanda");

const log = lp.log;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const SigHandler = @This();

// SetConsoleCtrlHandler does not accept a context pointer. SigHandler is a
// process-wide facility, so publish the installed instance for the callback.
// The handler lives in main's arena for the lifetime of the process.
var windows_handler: std.atomic.Value(usize) = .init(0);

arena: Allocator,

sigset: if (builtin.os.tag == .windows) void else std.posix.sigset_t = undefined,
handle_thread: ?std.Thread = null,

windows_event: std.Thread.ResetEvent = .{},
windows_termination_pending: std.atomic.Value(u32) = .init(0),
windows_deadline_pending: std.atomic.Value(u32) = .init(0),
windows_deadline_generation: std.atomic.Value(u32) = .init(0),

attempt: u32 = 0,
mutex: std.Thread.Mutex = .{},
listeners: std.ArrayList(Listener) = .empty,

pub const Listener = struct {
    args: []const u8,
    start: *const fn (context: *const anyopaque) void,
};

pub fn install(self: *SigHandler) !void {
    if (comptime builtin.os.tag == .windows) {
        return self.installWindows();
    }

    // Block these signals for the current thread and all created from it.
    // SIGALRM is included so arm() can wake the sighandler thread on a deadline.
    self.sigset = std.posix.sigemptyset();
    std.posix.sigaddset(&self.sigset, std.posix.SIG.INT);
    std.posix.sigaddset(&self.sigset, std.posix.SIG.TERM);
    std.posix.sigaddset(&self.sigset, std.posix.SIG.QUIT);
    std.posix.sigaddset(&self.sigset, std.posix.SIG.ALRM);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &self.sigset, null);

    self.handle_thread = try std.Thread.spawn(.{ .allocator = self.arena }, SigHandler.sighandle, .{self});
    self.handle_thread.?.detach();
}

fn installWindows(self: *SigHandler) !void {
    const address = @intFromPtr(self);
    if (windows_handler.cmpxchgStrong(0, address, .acq_rel, .acquire) != null) {
        return error.SignalHandlerAlreadyInstalled;
    }
    errdefer windows_handler.store(0, .release);

    try windows.SetConsoleCtrlHandler(windowsConsoleHandler, true);
    errdefer windows.SetConsoleCtrlHandler(windowsConsoleHandler, false) catch {};

    self.handle_thread = try std.Thread.spawn(.{ .allocator = self.arena }, SigHandler.windowsSighandle, .{self});
    self.handle_thread.?.detach();
}

fn windowsConsoleHandler(control_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    switch (control_type) {
        windows.CTRL_C_EVENT,
        windows.CTRL_BREAK_EVENT,
        windows.CTRL_CLOSE_EVENT,
        windows.CTRL_LOGOFF_EVENT,
        windows.CTRL_SHUTDOWN_EVENT,
        => {},
        else => return windows.FALSE,
    }

    const address = windows_handler.load(.acquire);
    if (address == 0) return windows.FALSE;

    const self: *SigHandler = @ptrFromInt(address);
    _ = self.windows_termination_pending.fetchAdd(1, .release);
    self.windows_event.set();
    return windows.TRUE;
}

const itimerval = extern struct {
    interval: std.c.timeval,
    value: std.c.timeval,
};
const ITIMER_REAL: c_int = 0;
extern "c" fn setitimer(which: c_int, new_value: *const itimerval, old_value: ?*itimerval) c_int;

/// Schedule a SIGALRM after `ms` milliseconds, which wakes the sighandler
/// thread and runs the registered listeners. Used to enforce --terminate-ms.
pub fn deadline(self: *SigHandler, ms: u32) !void {
    if (comptime builtin.os.tag == .windows) {
        const generation = self.windows_deadline_generation.fetchAdd(1, .acq_rel) +% 1;
        var thread = try std.Thread.spawn(
            .{ .allocator = self.arena },
            SigHandler.windowsDeadline,
            .{ self, generation, ms },
        );
        thread.detach();
        return;
    }

    const it = itimerval{
        .interval = .{ .sec = 0, .usec = 0 },
        .value = .{
            .sec = @intCast(ms / std.time.ms_per_s),
            .usec = @intCast((ms % std.time.ms_per_s) * std.time.us_per_ms),
        },
    };
    if (setitimer(ITIMER_REAL, &it, null) != 0) {
        return error.SetItimerFailed;
    }
}

fn windowsDeadline(self: *SigHandler, generation: u32, ms: u32) void {
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
    if (self.windows_deadline_generation.load(.acquire) != generation) return;

    _ = self.windows_deadline_pending.fetchAdd(1, .release);
    self.windows_event.set();
}

pub fn on(self: *SigHandler, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    assert(@typeInfo(@TypeOf(func)).@"fn".return_type.? == void);

    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque) void {
            const args_casted: *const Args = @ptrCast(@alignCast(context));
            @call(.auto, func, args_casted.*);
        }
    };

    const buffer = try self.arena.alignedAlloc(u8, .of(Args), @sizeOf(Args));
    errdefer self.arena.free(buffer);

    const bytes: []const u8 = @ptrCast((&args)[0..1]);
    @memcpy(buffer, bytes);

    self.mutex.lock();
    defer self.mutex.unlock();

    try self.listeners.append(self.arena, .{
        .args = buffer,
        .start = TypeErased.start,
    });

    // If a termination signal arrived before this listener was registered,
    // the sighandler thread had nothing to call. Fire the new listener now
    // so the shutdown isn't lost — otherwise main proceeds into the network
    // run loop and the process becomes an orphan that ignores the signal.
    if (self.attempt > 0) {
        const item = &self.listeners.items[self.listeners.items.len - 1];
        item.start(item.args.ptr);
    }
}

fn sighandle(self: *SigHandler) noreturn {
    while (true) {
        var sig: c_int = 0;

        const rc = std.c.sigwait(&self.sigset, &sig);
        if (rc != 0) {
            log.err(.app, "Unable to process signal {}", .{rc});
            std.process.exit(1);
        }

        switch (sig) {
            std.posix.SIG.INT, std.posix.SIG.TERM => {
                self.mutex.lock();
                if (self.attempt > 1) {
                    self.mutex.unlock();
                    std.process.exit(1);
                }
                self.attempt += 1;

                log.info(.app, "Received termination signal...", .{});
                for (self.listeners.items) |*item| {
                    item.start(item.args.ptr);
                }
                self.mutex.unlock();
                continue;
            },
            std.posix.SIG.ALRM => {
                // Deadline tripped (e.g. --terminate-ms). Run the same listeners,
                // but don't bump `attempt` — a subsequent ctrl-c should still get
                // the normal first-attempt graceful path before hard-exiting.
                self.mutex.lock();
                defer self.mutex.unlock();
                log.info(.app, "Deadline reached ", .{});
                for (self.listeners.items) |*item| {
                    item.start(item.args.ptr);
                }
                continue;
            },
            else => continue,
        }
    }
}

fn windowsSighandle(self: *SigHandler) noreturn {
    while (true) {
        self.windows_event.wait();

        // Reset before consuming the counters. If a notification arrives
        // between reset and swap, the counter is consumed now and the still-set
        // event merely causes one harmless empty iteration. A notification
        // after the swaps remains pending for the next iteration.
        self.windows_event.reset();
        const termination_count = self.windows_termination_pending.swap(0, .acq_rel);
        const deadline_count = self.windows_deadline_pending.swap(0, .acq_rel);

        for (0..termination_count) |_| {
            self.mutex.lock();
            if (self.attempt > 1) {
                self.mutex.unlock();
                std.process.exit(1);
            }
            self.attempt += 1;

            log.info(.app, "Received termination signal...", .{});
            for (self.listeners.items) |*item| {
                item.start(item.args.ptr);
            }
            self.mutex.unlock();
        }

        for (0..deadline_count) |_| {
            self.mutex.lock();
            defer self.mutex.unlock();
            log.info(.app, "Deadline reached ", .{});
            for (self.listeners.items) |*item| {
                item.start(item.args.ptr);
            }
        }
    }
}
