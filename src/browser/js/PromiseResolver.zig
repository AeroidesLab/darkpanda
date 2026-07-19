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

const lp = @import("darkpanda");

const js = @import("js.zig");

const DOMException = @import("../webapi/DOMException.zig");

const v8 = js.v8;
const log = lp.log;

const PromiseResolver = @This();

local: *const js.Local,
handle: *const v8.PromiseResolver,

pub fn init(local: *const js.Local) PromiseResolver {
    return .{
        .local = local,
        .handle = v8.v8__Promise__Resolver__New(local.handle).?,
    };
}

pub fn promise(self: PromiseResolver) js.Promise {
    return .{
        .local = self.local,
        .handle = v8.v8__Promise__Resolver__GetPromise(self.handle).?,
    };
}

pub fn resolve(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._resolve(value) catch |err| {
        log.err(.bug, "resolve", .{ .source = source, .err = err, .persistent = false });
    };
}

fn _resolve(self: PromiseResolver, value: anytype) !void {
    const local = self.local;
    const js_val = try local.zigValueToJs(value, .{});

    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Resolve(self.handle, self.local.handle, js_val.handle, &out);
    if (!out.has_value or !out.value) {
        return error.FailedToResolvePromise;
    }

    // Settling a promise only enqueues its reactions. Chromium's
    // ScriptPromiseResolverBase explicitly uses V8DoNotRunMicrotasksScope here;
    // the responsible event loop performs the checkpoint at the task boundary.
    // Running Env.runMicrotasks() here would synchronously re-enter author code
    // and, because Env owns multiple Window/Worker agents, drain unrelated
    // MicrotaskQueues as a side effect of this resolver.
}

pub fn reject(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._reject(value) catch |err| {
        log.err(.bug, "reject", .{ .source = source, .err = err, .persistent = false });
    };
}

pub const RejectError = union(enum) {
    /// Not to be confused with `DOMException`; this is bare `Error`.
    generic_error: []const u8,
    range_error: []const u8,
    reference_error: []const u8,
    syntax_error: []const u8,
    type_error: []const u8,
    /// DOM exceptions are unknown to V8, belongs to web standards.
    dom_exception: struct { err: anyerror },
};

/// Rejects the promise w/ an error object.
pub fn rejectError(
    self: PromiseResolver,
    comptime source: []const u8,
    err: RejectError,
) void {
    const handle = switch (err) {
        .generic_error => |msg| self.local.isolate.createError(msg),
        .range_error => |msg| self.local.isolate.createRangeError(msg),
        .reference_error => |msg| self.local.isolate.createReferenceError(msg),
        .syntax_error => |msg| self.local.isolate.createSyntaxError(msg),
        .type_error => |msg| self.local.isolate.createTypeError(msg),
        // "Exceptional".
        .dom_exception => |exception| {
            self._reject(DOMException.fromError(exception.err) orelse unreachable) catch |reject_err| {
                log.err(.bug, "rejectDomException", .{ .source = source, .err = reject_err, .persistent = false });
            };
            return;
        },
    };

    self._reject(js.Value{ .handle = handle, .local = self.local }) catch |reject_err| {
        log.err(.bug, "rejectError", .{ .source = source, .err = reject_err, .persistent = false });
    };
}

fn _reject(self: PromiseResolver, value: anytype) !void {
    const local = self.local;
    const js_val = try local.zigValueToJs(value, .{});

    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Reject(self.handle, local.handle, js_val.handle, &out);
    if (!out.has_value or !out.value) {
        return error.FailedToRejectPromise;
    }

    // See _resolve: rejection reactions run at the event-loop checkpoint, not
    // synchronously inside the host API that rejected the promise.
}

pub fn persist(self: PromiseResolver) !Global {
    return .{ .slot = try js.newTrackedSlot(self.local.ctx, self.handle) };
}

pub const Global = struct {
    slot: *js.GlobalSlot,

    pub fn deinit(self: Global) void {
        self.slot.release();
    }

    pub const release = deinit;

    pub fn local(self: Global, l: *const js.Local) PromiseResolver {
        return .{
            .local = l,
            .handle = @ptrCast(v8.v8__Global__Get(&self.slot.handle, l.isolate.handle)),
        };
    }
};

const testing = @import("../../testing.zig");

test "PromiseResolver: settlement defers reactions" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var frame_scope: js.Local.Scope = undefined;
    frame.js.localScope(&frame_scope);
    defer frame_scope.deinit();

    // Resolve: a queueMicrotask registered before settlement must run before
    // the promise reaction, but neither callback may run inside resolve().
    const resolver = PromiseResolver.init(&frame_scope.local);
    try testing.expect(try frame_scope.local.getGlobal().set(
        "__nativeResolvedPromise",
        resolver.promise(),
        .{},
    ));
    _ = try frame_scope.local.exec(
        "globalThis.__resolveOrder = [];" ++
            "queueMicrotask(() => __resolveOrder.push('queueMicrotask'));" ++
            "__nativeResolvedPromise.then(() => __resolveOrder.push('promise-then'));",
        null,
    );

    resolver.resolve("PromiseResolver test", "resolved");
    try testing.expectEqual(js.Promise.State.fulfilled, resolver.promise().state());
    try testing.expect((try frame_scope.local.exec(
        "__resolveOrder.length === 0",
        null,
    )).isTrue());

    v8.v8__MicrotaskQueue__PerformCheckpoint(
        frame.js.microtask_queue,
        frame.js.isolate.handle,
    );
    try testing.expect((try frame_scope.local.exec(
        "__resolveOrder.join(',') === 'queueMicrotask,promise-then'",
        null,
    )).isTrue());

    // Reject has the same non-reentrant ordering guarantee.
    const rejecter = PromiseResolver.init(&frame_scope.local);
    try testing.expect(try frame_scope.local.getGlobal().set(
        "__nativeRejectedPromise",
        rejecter.promise(),
        .{},
    ));
    _ = try frame_scope.local.exec(
        "globalThis.__rejectOrder = [];" ++
            "queueMicrotask(() => __rejectOrder.push('queueMicrotask'));" ++
            "__nativeRejectedPromise.catch(() => __rejectOrder.push('promise-catch'));",
        null,
    );

    rejecter.reject("PromiseResolver test", "rejected");
    try testing.expectEqual(js.Promise.State.rejected, rejecter.promise().state());
    try testing.expect((try frame_scope.local.exec(
        "__rejectOrder.length === 0",
        null,
    )).isTrue());

    v8.v8__MicrotaskQueue__PerformCheckpoint(
        frame.js.microtask_queue,
        frame.js.isolate.handle,
    );
    try testing.expect((try frame_scope.local.exec(
        "__rejectOrder.join(',') === 'queueMicrotask,promise-catch'",
        null,
    )).isTrue());
}

test "PromiseResolver: Window checkpoint does not drain a worker agent" {
    try testing.htmlRunner("worker/promise-resolver-agent.html", .{ .timeout_ms = 8_000 });
}
