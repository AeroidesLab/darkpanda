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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");

const log = lp.log;
const Execution = js.Execution;

const BroadcastChannel = @This();

_proto: *EventTarget,
_exec: *Execution,
_name: lp.String,
_sequence: u64,
_closed: bool = false,
_on_message: ?js.Function.Global = null,
_on_message_error: ?js.Function.Global = null,

// Intrusive node, registered in the owning Window/Worker global until close.
_node: std.DoublyLinkedList.Node = .{},

pub fn init(name: lp.String.Global, exec: *Execution) !*BroadcastChannel {
    const sequence = exec.page.broadcast_sequence.fetchAdd(1, .acq_rel);
    const self = try exec._factory.eventTarget(BroadcastChannel{
        ._proto = undefined,
        ._exec = exec,
        ._name = name.str,
        ._sequence = sequence,
    });
    exec.getBroadcastChannels().append(&self._node);
    return self;
}

pub fn asEventTarget(self: *BroadcastChannel) *EventTarget {
    return self._proto;
}

pub fn getName(self: *const BroadcastChannel) lp.String {
    return self._name;
}

// https://html.spec.whatwg.org/multipage/web-messaging.html#dom-broadcastchannel-postmessage
pub fn postMessage(self: *BroadcastChannel, message: js.Value) !void {
    if (self._closed) return error.InvalidStateError;

    const exec = self._exec;
    // Chrome treats a cached method from a retired realm as inert before it
    // performs StructuredSerialize: even an otherwise uncloneable value does
    // not surface DataCloneError once the channel's owner is gone.
    if (exec.isShuttingDown()) return;

    // StructuredSerialize is synchronous. This produces an isolate-free byte
    // envelope plus retained SAB backing stores, so a failed clone is reported
    // before any destination task/mailbox entry is published.
    var serialized = blk: {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(message.local);
        defer try_catch.deinit();

        break :blk message.serializeForMessage(std.heap.page_allocator) catch {
            return error.DataClone;
        };
    };

    // The owner may retire while a worker is serializing. Recheck immediately
    // before publishing any destination task/mailbox entry.
    if (exec.isShuttingDown()) {
        serialized.deinit();
        return;
    }

    const envelope = js.Value.BroadcastMessage.create(
        std.heap.page_allocator,
        serialized,
        self._name.str(),
        exec.origin(),
        exec.page.broadcast_sequence.load(.acquire),
    ) catch |err| {
        serialized.deinit();
        return err;
    };
    errdefer envelope.release();

    const callback = try exec._factory.create(PostMessageCallback{
        .exec = exec,
        .sender = self,
        .message = envelope,
    });
    errdefer exec._factory.destroy(callback);

    try exec.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "BroadcastChannel.postMessage",
        .low_priority = false,
        .finalizer = PostMessageCallback.cancelled,
    });
}

pub fn close(self: *BroadcastChannel) void {
    if (self._closed) return;
    self._closed = true;
    self._exec.getBroadcastChannels().remove(&self._node);
}

pub fn getOnMessage(self: *const BroadcastChannel) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *BroadcastChannel, cb: ?js.Function.Global) !void {
    self._on_message = cb;
}

pub fn getOnMessageError(self: *const BroadcastChannel) ?js.Function.Global {
    return self._on_message_error;
}

pub fn setOnMessageError(self: *BroadcastChannel, cb: ?js.Function.Global) !void {
    self._on_message_error = cb;
}

const PostMessageCallback = struct {
    sender: *BroadcastChannel,
    message: *js.Value.BroadcastMessage,
    exec: *Execution,

    fn cancelled(ctx: *anyopaque) void {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        self.message.release();
        self.deinit();
    }

    fn deinit(self: *PostMessageCallback) void {
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();
        defer self.message.release();

        // A task can survive until the same scheduler turn in which its realm
        // is retired. Never fan out from a stopped environment even if the
        // payload was serialized while it was still active.
        if (self.exec.isShuttingDown()) return null;

        switch (self.exec.js.global) {
            .frame => {
                // Publish mailbox entries before Window listeners can mutate
                // the frame/worker tree.
                if (self.message.origin != null) {
                    self.exec.page.routeBroadcastToWorkers(self.message, null);
                }
                deliverToWindowPageWithSender(
                    self.exec.page,
                    self.message,
                    self.sender,
                ) catch |err| log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
            },
            .worker => |worker| {
                // A worker owner thread never traverses creator Page state. It
                // publishes one outbound reference for creator-side fan-out.
                if (self.message.origin != null) {
                    switch (worker._type) {
                        .dedicated => |scope| scope.publishBroadcast(self.message) catch |err| {
                            log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
                        },
                    }
                }
                deliverToExecution(self.exec, self.message, self.sender) catch |err| {
                    log.err(.dom, "BroadcastChannel.postMessage", .{ .err = err });
                };
            },
        }
        return null;
    }
};

// Creator-thread entry point for Worker -> Window delivery.
pub fn deliverToWindowPage(page: *Page, message: *js.Value.BroadcastMessage) !void {
    return deliverToWindowPageWithSender(page, message, null);
}

fn deliverToWindowPageWithSender(
    page: *Page,
    message: *js.Value.BroadcastMessage,
    sender: ?*BroadcastChannel,
) !void {
    const origin = message.origin orelse {
        // Opaque origins are unique to one environment settings object and are
        // therefore never routed across globals or agents.
        if (sender) |channel| {
            try deliverToExecution(channel._exec, message, channel);
        }
        return;
    };

    const arena = try page.getArena(.tiny, "BroadcastChannel.destinations");
    defer page.releaseArena(arena);
    const executions = try page.executionsForOrigin(arena, origin);
    for (executions) |exec| {
        try deliverToExecution(exec, message, sender);
    }
}

// Must be called on `exec`'s owner thread with its isolate idle/currently
// enterable. The serialized envelope is immutable and contains no handles;
// every channel gets a fresh receiver-local deserialization.
pub fn deliverToExecution(
    exec: *Execution,
    message: *js.Value.BroadcastMessage,
    sender: ?*BroadcastChannel,
) !void {
    if (exec.isShuttingDown()) return;

    if (message.origin) |origin| {
        const receiver_origin = exec.origin() orelse return;
        if (!std.mem.eql(u8, origin, receiver_origin)) return;
    } else {
        const local_sender = sender orelse return;
        if (local_sender._exec != exec) return;
    }

    // Snapshot destination pointers before running any listener. close() may
    // unlink nodes during dispatch, but Page/Worker arenas keep objects alive
    // through this owner task.
    var recipients: std.ArrayList(*BroadcastChannel) = .empty;
    defer recipients.deinit(std.heap.page_allocator);

    var it = exec.getBroadcastChannels().*.first;
    while (it) |node| : (it = node.next) {
        const channel: *BroadcastChannel = @alignCast(@fieldParentPtr("_node", node));
        if (channel._closed or channel == sender) continue;
        if (channel._sequence >= message.post_sequence) continue;
        if (!channel._name.eqlSlice(message.name)) continue;

        const target = channel.asEventTarget();
        if (!exec.hasDirectListeners(target, "message", channel._on_message)) continue;
        try recipients.append(std.heap.page_allocator, channel);
    }
    if (recipients.items.len == 0) return;

    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();

    const sender_origin = message.origin orelse "null";
    for (recipients.items) |channel| {
        if (exec.isShuttingDown()) return;
        if (channel._closed) continue;
        const target = channel.asEventTarget();
        if (!exec.hasDirectListeners(target, "message", channel._on_message)) continue;

        const cloned = js.Value.deserializeMessage(&ls.local, &message.serialized) catch |err| {
            dispatchMessageError(exec, channel, sender_origin) catch |dispatch_err| {
                log.err(.dom, "BroadcastChannel.messageerror", .{ .err = dispatch_err });
            };
            log.err(.dom, "BroadcastChannel.deserialize", .{ .err = err });
            continue;
        };
        const persisted = cloned.persist() catch |err| {
            log.err(.dom, "BroadcastChannel.persist", .{ .err = err });
            continue;
        };

        // Deserialization may cross host-object callbacks. If that retired the
        // destination, discard the receiver-local handle instead of creating a
        // delivery event for the replacement environment.
        if (exec.isShuttingDown()) {
            persisted.release();
            return;
        }

        const event = (MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = persisted },
            .origin = sender_origin,
            .source = null,
        }, exec.page) catch |err| {
            persisted.release();
            log.err(.dom, "BroadcastChannel.event", .{ .err = err });
            continue;
        }).asEvent();

        exec.dispatch(target, event, channel._on_message, .{
            .context = "BroadcastChannel message",
        }) catch |err| log.err(.dom, "BroadcastChannel.dispatch", .{ .err = err });
    }
}

fn dispatchMessageError(
    exec: *Execution,
    channel: *BroadcastChannel,
    sender_origin: []const u8,
) !void {
    if (exec.isShuttingDown()) return;
    const target = channel.asEventTarget();
    if (!exec.hasDirectListeners(target, "messageerror", channel._on_message_error)) return;
    const event = (try MessageEvent.initTrusted(comptime .wrap("messageerror"), .{
        .origin = sender_origin,
        .source = null,
    }, exec.page)).asEvent();
    try exec.dispatch(target, event, channel._on_message_error, .{
        .context = "BroadcastChannel messageerror",
    });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BroadcastChannel);

    pub const Meta = struct {
        pub const name = "BroadcastChannel";
        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const constructor = bridge.constructor(BroadcastChannel.init, .{});

    pub const name = bridge.accessor(BroadcastChannel.getName, null, .{});
    pub const postMessage = bridge.function(BroadcastChannel.postMessage, .{});
    pub const close = bridge.function(BroadcastChannel.close, .{});

    pub const onmessage = bridge.accessor(BroadcastChannel.getOnMessage, BroadcastChannel.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(BroadcastChannel.getOnMessageError, BroadcastChannel.setOnMessageError, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: BroadcastChannel" {
    try testing.htmlRunner("broadcast_channel.html", .{});
}
