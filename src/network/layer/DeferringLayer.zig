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
const log = lp.log;

const Network = @import("../Network.zig");
const HttpClient = @import("../../browser/HttpClient.zig");
const Transfer = HttpClient.Transfer;
const Request = HttpClient.Request;
const Response = HttpClient.Response;
const Layer = HttpClient.Layer;
const StableResponse = HttpClient.StableResponse;
const Owner = HttpClient.Owner;
const Forward = @import("Forward.zig");
const HeaderResult = @import("../../browser/HttpClient.zig").HeaderResult;

const DeferringLayer = @This();

allocator: std.mem.Allocator,
network: *Network,
next: Layer = undefined,
active: std.DoublyLinkedList = .{},

pub fn layer(self: *DeferringLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

pub fn deinit(self: *DeferringLayer) void {
    self.drainAll();
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *DeferringLayer = @ptrCast(@alignCast(ptr));

    if (transfer.req.internal) {
        return self.next.request(transfer);
    }

    const arena = try self.network.app.arena_pool.acquire(.small, "DeferringContext");
    var callbacks_own_context = false;
    errdefer if (!callbacks_own_context) self.network.app.arena_pool.release(arena);

    // This might outlive the transfer, so duplicate everything needed later.
    const ctx = try arena.create(DeferredContext);
    ctx.* = .{
        .arena = arena,
        .layer = self,
        .transfer = transfer,
        .frame_id = transfer.req.frame_id,
        // Transfer.owner is cleared when a completed/aborted Transfer leaves
        // its execution context. Keep the original pointer identity so a
        // terminal deferred callback can still be cancelled for exactly that
        // Frame/Worker rather than every context sharing its numeric frame id.
        .owner = transfer.owner,
        .url = try arena.dupeZ(u8, transfer.req.url),
        .forward = Forward.capture(&transfer.req),
    };

    self.active.append(&ctx.node);
    errdefer if (!callbacks_own_context) self.active.remove(&ctx.node);

    ctx.installCallbacks(&transfer.req);

    // From this point every completion, including a synchronous error from
    // next.request, is owned by Transfer.abort -> our wrapper callback. Do not
    // free ctx in this stack frame: the callback still needs it to unlink from
    // active and to notify/clean the captured resource context exactly once.
    callbacks_own_context = true;
    return self.next.request(transfer);
}

pub fn flushFrame(self: *DeferringLayer, frame_id: u32) void {
    // DeferredContext.fire() can re-enter flushFrame, so we'll capture
    // ready items in this list, so that a reentrant flushFrame doesn't mutate
    // self.active while we're iterating.
    var ready: std.DoublyLinkedList = .{};

    var node = self.active.first;
    while (node) |n| {
        node = n.next;
        const ctx: *DeferredContext = @fieldParentPtr("node", n);
        if (!ctx.deferring) {
            continue;
        }

        // captured frame_id, not ctx.transfer: the transfer may be freed.
        if (ctx.frame_id != frame_id) {
            continue;
        }

        if (ctx.terminal) {
            self.active.remove(n);
            ready.append(n);
        } else {
            switch (ctx.firePartial()) {
                .continued => ctx.deferring = false,
                // firePartial routed the failure through Transfer.abort and
                // completed the DeferredContext lifetime. It may already be
                // freed, so this branch must never dereference ctx.
                .aborted => {},
            }
        }
    }

    // ready is local, ctx.fire() re-entering flushFrame can't invalidate it.
    while (ready.popFirst()) |n| {
        const ctx: *DeferredContext = @fieldParentPtr("node", n);
        ctx.fire();
    }
}

/// Drop orphaned deferred contexts for an owner that's going away. A `terminal`
/// context's transfer already completed while deferred, so it has been
/// deinited and unlinked from the owner. abortOwner cannot reach it, yet it lingers in
/// `active` pointing at a forward target (the Fetch) whose arena page teardown
/// is about to free, and a later flushFrame would fire into it. Non-terminal
/// contexts still have a live transfer that cleans them up itself.
pub fn cancelOwner(self: *DeferringLayer, owner: *Owner) void {
    var node = self.active.first;
    while (node) |n| {
        node = n.next;
        const ctx: *DeferredContext = @fieldParentPtr("node", n);
        if (ctx.owner != owner or !ctx.terminal) {
            continue;
        }
        self.active.remove(n);
        // Its Transfer has already completed and left the Frame owner, so
        // abortOwner cannot reach the captured resource lifetime. Forward
        // cleanup-only shutdown before releasing the deferred wrapper.
        ctx.done = true;
        ctx.forward.forwardShutdown();
        ctx.deinit();
    }
}

pub fn drainAll(self: *DeferringLayer) void {
    while (self.active.popFirst()) |node| {
        const ctx: *DeferredContext = @fieldParentPtr("node", node);
        // Terminal transfers have already left their Owner list, so the
        // client's normal abort walk cannot deliver cleanup to the captured
        // resource context. Do so before releasing the wrapper arena.
        if (ctx.terminal and !ctx.done) {
            ctx.done = true;
            ctx.forward.forwardShutdown();
        }
        ctx.deinit();
    }
}

const DeferredContext = struct {
    arena: std.mem.Allocator,
    layer: *DeferringLayer,
    transfer: *Transfer,
    frame_id: u32,
    owner: ?*Owner,
    url: [:0]const u8,
    forward: Forward,
    node: std.DoublyLinkedList.Node = .{},

    buffered: std.ArrayList(BufferedEvent) = .{},
    done: bool = false,
    deferring: bool = false,
    terminal: bool = false,
    stable_resp: ?StableResponse = null,
    partial_abort: ?*PartialAbortHandoff = null,

    const BufferedEvent = union(enum) {
        start,
        header,
        data: []const u8,
        done,
        err: anyerror,
    };

    const PartialFireResult = enum {
        continued,
        aborted,
    };

    // Transfer.abort invokes the wrapped error callback synchronously before
    // it detaches/deinits the Transfer. Keep the cleanup/notification handoff
    // on firePartial's stack so errorCallback need not call user code while
    // Transfer.abort is still re-entrant, and so firePartial never accesses
    // DeferredContext after abort has completed its lifetime.
    const PartialAbortHandoff = struct {
        layer: *DeferringLayer,
        arena: std.mem.Allocator,
        node: *std.DoublyLinkedList.Node,
        forward: Forward,
        callback_seen: bool = false,
        node_removed: bool = false,
        err: ?anyerror = null,
    };

    fn deinit(self: *DeferredContext) void {
        self.layer.network.app.arena_pool.release(self.arena);
    }

    fn installCallbacks(self: *DeferredContext, req: *Request) void {
        req.ctx = self;
        req.start_callback = if (self.forward.start != null) startCallback else null;
        req.header_callback = headerCallback;
        req.data_callback = dataCallback;
        req.done_callback = doneCallback;
        req.error_callback = errorCallback;
        // Always install our shutdown wrapper. Even when the captured request
        // has no shutdown hook, this callback owns DeferredContext unlinking
        // and arena release when an Owner aborts a non-terminal transfer.
        req.shutdown_callback = shutdownCallback;
    }

    fn setStableResponse(self: *DeferredContext, response: Response, refresh: bool) !void {
        if (refresh or self.stable_resp == null) {
            self.stable_resp = try Response.toStable(response, self.arena);
        }
    }

    fn replayResponse(self: *DeferredContext) Response {
        const stable = if (self.stable_resp) |*value|
            value
        else
            @panic("stable_resp must be set for response replay");

        // This points into DeferredContext, not a stack copy, so callbacks may
        // retain it until done/error/shutdown ends this deferred lifecycle.
        // It is deliberately a metadata snapshot: Response.abort() has no
        // live transport handle for `.stable`, including during partial
        // replay. We do not expose a Transfer pointer that would dangle during
        // terminal replay; callback errors and HeaderResult.abort are instead
        // mediated by abortPartial while the Transfer is known to be live.
        return Response.fromStable(stable);
    }

    fn shouldDefer(self: *DeferredContext) bool {
        const req = self.transfer.req;
        const blocking_id = self.transfer.client.blocking_requests.get(req.frame_id) orelse return false;
        return self.transfer.id != blocking_id;
    }

    fn startCallback(response: Response) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardStart(response);
        }

        log.debug(.http, "deferring start callback", .{ .url = self.url });
        try self.setStableResponse(response, false);
        self.deferring = true;
        try self.buffered.append(self.arena, .start);
    }

    fn headerCallback(response: Response) anyerror!HeaderResult {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardHeader(response);
        }

        log.debug(.http, "deferring header callback", .{ .url = self.url });
        // start can precede response headers and therefore snapshot status 0.
        // Refresh here so replay observes the final status/header collection.
        try self.setStableResponse(response, true);
        self.deferring = true;
        try self.buffered.append(self.arena, .header);
        return .proceed;
    }

    fn dataCallback(response: Response, chunk: []const u8) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(response.ctx));

        if (!self.deferring and !self.shouldDefer()) {
            return self.forward.forwardData(response, chunk);
        }

        log.debug(.http, "deferring data callback", .{ .url = self.url });
        try self.setStableResponse(response, false);
        self.deferring = true;
        try self.buffered.append(self.arena, .{ .data = try self.arena.dupe(u8, chunk) });
    }

    fn doneCallback(ctx: *anyopaque) anyerror!void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));

        if (!self.deferring and !self.shouldDefer()) {
            defer self.deinit();
            self.done = true;
            self.layer.active.remove(&self.node);
            return self.forward.forwardDone();
        }

        log.debug(.http, "deferring done callback", .{ .url = self.url });
        self.deferring = true;
        self.terminal = true;
        try self.buffered.append(self.arena, .done);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));

        if (self.partial_abort) |handoff| {
            if (self.done) return;
            self.done = true;
            self.layer.active.remove(&self.node);
            handoff.node_removed = true;
            handoff.callback_seen = true;
            handoff.err = err;
            // abortPartial owns the arena until Transfer.abort has completed;
            // it forwards the captured error only after the live Transfer is
            // safely detached/deinited. Do not deinit or notify from here.
            return;
        }

        if (!self.deferring and !self.shouldDefer()) {
            defer self.deinit();
            self.done = true;
            self.layer.active.remove(&self.node);
            self.forward.forwardErr(err);
            return;
        }

        log.debug(.http, "deferring error callback", .{ .url = self.url, .err = err });
        self.deferring = true;
        self.terminal = true;
        self.buffered.append(self.arena, .{ .err = err }) catch {};
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *DeferredContext = @ptrCast(@alignCast(ctx));
        if (self.done) return;

        defer self.deinit();
        self.done = true;
        self.layer.active.remove(&self.node);

        log.debug(.http, "deferring shutdown callback", .{});
        self.forward.forwardShutdown();
    }

    fn fire(self: *DeferredContext) void {
        defer self.deinit();

        for (self.buffered.items) |event| {
            switch (event) {
                .start => {
                    const response = self.replayResponse();

                    self.forward.forwardStart(response) catch |err| {
                        log.err(.http, "deferred start callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                },
                .header => {
                    const response = self.replayResponse();

                    const result = self.forward.forwardHeader(response) catch |err| {
                        log.err(.http, "deferred header callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                    if (result == .abort) {
                        self.forward.forwardErr(error.Abort);
                        return;
                    }
                },
                .data => |chunk| {
                    const response = self.replayResponse();

                    self.forward.forwardData(response, chunk) catch |err| {
                        log.err(.http, "deferred data callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                        return;
                    };
                },
                .done => {
                    self.forward.forwardDone() catch |err| {
                        log.err(.http, "deferred done callback", .{ .err = err, .url = self.url });
                        self.forward.forwardErr(err);
                    };

                    return;
                },
                .err => |err| {
                    self.forward.forwardErr(err);
                    return;
                },
            }
        }
    }

    fn abortPartial(self: *DeferredContext, err: anyerror) PartialFireResult {
        var handoff: PartialAbortHandoff = .{
            .layer = self.layer,
            .arena = self.arena,
            .node = &self.node,
            .forward = self.forward,
        };
        self.partial_abort = &handoff;

        // Capture the Transfer before abort: the call may synchronously finish
        // it. The normal callback path below uses only the stack handoff; its
        // node fallback runs solely when requestFailed suppressed the callback,
        // in which case DeferredContext is necessarily still allocated.
        const transfer = self.transfer;
        transfer.abort(err);

        // requestFailed normally reaches errorCallback exactly once. The
        // fallback only owns structural cleanup if an earlier failure latch
        // suppressed it; in that case the original error was already notified
        // and must not be sent twice.
        if (!handoff.node_removed) {
            handoff.layer.active.remove(handoff.node);
        }
        if (handoff.callback_seen) {
            handoff.forward.forwardErr(handoff.err orelse err);
        }
        handoff.layer.network.app.arena_pool.release(handoff.arena);
        return .aborted;
    }

    fn firePartial(self: *DeferredContext) PartialFireResult {
        const response = self.replayResponse();

        for (self.buffered.items) |event| {
            switch (event) {
                .start => {
                    self.forward.forwardStart(response) catch |err| {
                        log.err(.http, "defer part start callback", .{ .err = err, .url = self.url });
                        return self.abortPartial(err);
                    };
                },
                .header => {
                    const result = self.forward.forwardHeader(response) catch |err| {
                        log.err(.http, "defer part header callback", .{ .err = err, .url = self.url });
                        return self.abortPartial(err);
                    };
                    if (result == .abort) {
                        return self.abortPartial(error.Abort);
                    }
                },
                .data => |chunk| {
                    self.forward.forwardData(response, chunk) catch |err| {
                        log.err(.http, "defer part data callback", .{ .err = err, .url = self.url });
                        return self.abortPartial(err);
                    };
                },
                .done, .err => @panic("firePartial cant fire terminal events"),
            }
        }

        self.buffered.clearRetainingCapacity();
        return .continued;
    }
};

const testing = @import("../../testing.zig");

test "DeferringLayer refreshes the header-phase stable response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var marker: u8 = 0;
    const start_snapshot: StableResponse = .{
        .ctx = &marker,
        .status = 0,
        .url = "https://example.test/image.png",
        .headers = &.{},
        .body = null,
    };
    const header_snapshot: StableResponse = .{
        .ctx = &marker,
        .status = 200,
        .url = "https://example.test/image.png",
        .headers = &.{.{ .name = "Content-Type", .value = "image/png" }},
        .body = null,
    };

    var context: DeferredContext = undefined;
    context.arena = arena.allocator();
    context.stable_resp = null;

    try context.setStableResponse(Response.fromStable(&start_snapshot), false);
    try testing.expectEqual(@as(u16, 0), context.stable_resp.?.status);

    try context.setStableResponse(Response.fromStable(&header_snapshot), true);
    try testing.expectEqual(@as(u16, 200), context.stable_resp.?.status);
    try testing.expectString("image/png", context.stable_resp.?.contentType().?);
}

test "DeferringLayer always owns shutdown and replays stable storage by address" {
    var marker: u8 = 0;
    var context: DeferredContext = undefined;
    context.forward = undefined;
    context.forward.start = null;
    context.forward.shutdown = null;
    context.stable_resp = .{
        .ctx = &marker,
        .status = 204,
        .url = "https://example.test/image.png",
        .headers = &.{},
        .body = null,
    };

    var req: Request = undefined;
    context.installCallbacks(&req);
    try testing.expect(req.shutdown_callback != null);

    const expected = if (context.stable_resp) |*stable| stable else unreachable;
    const replay = context.replayResponse();
    switch (replay.inner) {
        .stable => |actual| try testing.expect(actual == expected),
        else => return error.UnexpectedResponseStorage,
    }
    try testing.expectEqual(@as(u16, 204), replay.status().?);
}

test "DeferringLayer partial abort callback only records and unlinks once" {
    var defer_layer: DeferringLayer = undefined;
    defer_layer.active = .{};

    var context: DeferredContext = undefined;
    context.layer = &defer_layer;
    context.node = .{};
    context.done = false;

    var handoff: DeferredContext.PartialAbortHandoff = .{
        .layer = &defer_layer,
        .arena = testing.allocator,
        .node = &context.node,
        .forward = undefined,
    };
    context.partial_abort = &handoff;
    defer_layer.active.append(&context.node);

    DeferredContext.errorCallback(&context, error.PartialAbortUnit);
    try testing.expect(context.done);
    try testing.expect(handoff.callback_seen);
    try testing.expect(handoff.node_removed);
    try testing.expect(handoff.err.? == error.PartialAbortUnit);
    try testing.expect(defer_layer.active.first == null);

    // A duplicate callback is ignored and cannot remove the node again.
    DeferredContext.errorCallback(&context, error.DuplicatePartialAbortUnit);
    try testing.expect(handoff.err.? == error.PartialAbortUnit);
    try testing.expect(defer_layer.active.first == null);
}
