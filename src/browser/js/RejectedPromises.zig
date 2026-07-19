// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const std = @import("std");
const lp = @import("darkpanda");

const js = @import("js.zig");
const Context = @import("Context.zig");

const v8 = js.v8;
const log = lp.log;
const Allocator = std.mem.Allocator;

// Chromium keeps only a bounded set of already-reported promises waiting for
// a possible late handler. This also prevents a page that continually rejects
// promises from retaining unbounded native bookkeeping.
const MAX_REPORTED_PENDING_RESOLUTION = 1000;
const REPORTED_TRIM_COUNT = MAX_REPORTED_PENDING_RESOLUTION / 10;

const RejectedPromises = @This();

allocator: Allocator,
entries: std.ArrayList(*Entry) = .empty,

pub fn init(allocator: Allocator) RejectedPromises {
    return .{ .allocator = allocator };
}

// Context.deinit calls Scheduler.deinit first. Its finalizers remove all
// scheduled entries, leaving only pending/reported entries here.
pub fn deinit(self: *RejectedPromises) void {
    while (self.entries.pop()) |entry| {
        entry.rejection.deinit();
        self.allocator.destroy(entry);
    }
    self.entries.deinit(self.allocator);
}

// Takes ownership of rejection on success.
pub fn rejected(self: *RejectedPromises, context: *Context, rejection: js.PromiseRejection.Global) !void {
    const entry = try self.allocator.create(Entry);
    errdefer self.allocator.destroy(entry);
    entry.* = .{
        .owner = self,
        .context = context,
        .rejection = rejection,
    };
    try self.entries.append(self.allocator, entry);
}

// Returns true when this Context owns the promise. report_scheduled entries
// need no explicit cancellation: the DOM task re-checks Promise::HasHandler.
pub fn handlerAdded(self: *RejectedPromises, promise_handle: *const v8.Promise) bool {
    for (self.entries.items) |entry| {
        if (!entry.rejection.isPromise(promise_handle)) continue;
        switch (entry.state) {
            .pending => self.destroyEntry(entry),
            .report_scheduled => {},
            .reported => {
                if (entry.rejection.isCollected(entry.context.isolate)) {
                    self.destroyEntry(entry);
                    return true;
                }
                entry.rejection.makeStrong();
                entry.state = .revoke_scheduled;
                entry.context.scheduler.add(entry, Entry.revokeTask, 0, .{
                    .name = "Promise.rejectionhandled",
                    .finalizer = Entry.cancelScheduled,
                }) catch |err| {
                    log.warn(.browser, "schedule rejectionhandled", .{ .err = err });
                    self.destroyEntry(entry);
                };
            },
            .revoke_scheduled, .done => {},
        }
        return true;
    }
    return false;
}

// Called only after all per-Context V8 microtask checkpoints for the current
// turn. The queued DOM task performs the final HasHandler check, matching
// Blink's RejectedPromises::ProcessQueue / ProcessQueueNow split.
pub fn processQueue(self: *RejectedPromises) void {
    var i: usize = 0;
    while (i < self.entries.items.len) {
        const entry = self.entries.items[i];
        if (entry.state != .pending) {
            i += 1;
            continue;
        }

        entry.state = .report_scheduled;
        entry.context.scheduler.add(entry, Entry.reportTask, 0, .{
            .name = "Promise.unhandledrejection",
            .finalizer = Entry.cancelScheduled,
        }) catch |err| {
            log.warn(.browser, "schedule unhandledrejection", .{ .err = err });
            self.destroyEntry(entry);
            continue;
        };
        i += 1;
    }
}

fn destroyEntry(self: *RejectedPromises, entry: *Entry) void {
    for (self.entries.items, 0..) |candidate, i| {
        if (candidate != entry) continue;
        _ = self.entries.swapRemove(i);
        break;
    } else return;

    entry.state = .done;
    entry.rejection.deinit();
    self.allocator.destroy(entry);
}

fn trimReported(self: *RejectedPromises) void {
    var reported: usize = 0;
    for (self.entries.items) |entry| {
        if (entry.state == .reported) reported += 1;
    }
    if (reported <= MAX_REPORTED_PENDING_RESOLUTION) return;

    var to_remove: usize = REPORTED_TRIM_COUNT;
    var i: usize = 0;
    while (i < self.entries.items.len and to_remove > 0) {
        const entry = self.entries.items[i];
        if (entry.state != .reported) {
            i += 1;
            continue;
        }
        self.destroyEntry(entry);
        to_remove -= 1;
    }
}

const Entry = struct {
    owner: *RejectedPromises,
    context: *Context,
    rejection: js.PromiseRejection.Global,
    state: State = .pending,

    const State = enum {
        pending,
        report_scheduled,
        reported,
        revoke_scheduled,
        done,
    };

    fn cancelScheduled(data: *anyopaque) void {
        const self: *Entry = @ptrCast(@alignCast(data));
        self.owner.destroyEntry(self);
    }

    fn reportTask(data: *anyopaque) !?u32 {
        const self: *Entry = @ptrCast(@alignCast(data));
        if (self.state != .report_scheduled) return null;

        const context = self.context;
        if (context.env.isExecutionTerminating() or
            self.rejection.isCollected(context.isolate) or
            self.rejection.hasHandler(context.isolate))
        {
            self.owner.destroyEntry(self);
            return null;
        }

        var ls: js.Local.Scope = undefined;
        context.localScope(&ls);
        defer ls.deinit();
        const rejection = self.rejection.local(&ls.local) orelse {
            self.owner.destroyEntry(self);
            return null;
        };

        switch (context.global) {
            .frame => |frame| frame.window.unhandledPromiseRejection(true, rejection, frame) catch |err| {
                log.warn(.browser, "unhandled rejection handler", .{ .err = err, .target = "window" });
            },
            .worker => |worker| worker.unhandledPromiseRejection(true, rejection) catch |err| {
                log.warn(.browser, "unhandled rejection handler", .{ .err = err, .target = "worker" });
            },
        }

        self.rejection.makeWeak();
        self.state = .reported;
        self.owner.trimReported();
        return null;
    }

    fn revokeTask(data: *anyopaque) !?u32 {
        const self: *Entry = @ptrCast(@alignCast(data));
        if (self.state != .revoke_scheduled) return null;
        defer self.owner.destroyEntry(self);

        const context = self.context;
        if (context.env.isExecutionTerminating() or self.rejection.isCollected(context.isolate)) return null;

        var ls: js.Local.Scope = undefined;
        context.localScope(&ls);
        defer ls.deinit();
        const rejection = self.rejection.local(&ls.local) orelse return null;

        switch (context.global) {
            .frame => |frame| frame.window.unhandledPromiseRejection(false, rejection, frame) catch |err| {
                log.warn(.browser, "rejectionhandled handler", .{ .err = err, .target = "window" });
            },
            .worker => |worker| worker.unhandledPromiseRejection(false, rejection) catch |err| {
                log.warn(.browser, "rejectionhandled handler", .{ .err = err, .target = "worker" });
            },
        }
        return null;
    }
};
