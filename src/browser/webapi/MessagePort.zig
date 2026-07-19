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

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");
const MessageEvent = @import("event/MessageEvent.zig");

const log = lp.log;
const Execution = js.Execution;

const MessagePort = @This();

_proto: *EventTarget,
_exec: *Execution,
_enabled: bool = false,
_closed: bool = false,
// A transferred port is neutered, which is observably different from close().
// close() leaves a (closed) port transferable; transfer permanently removes
// the channel from the original wrapper.
_neutered: bool = false,
_on_message: ?js.Function.Global = null,
_on_message_error: ?js.Function.Global = null,
_entangled_port: ?*MessagePort = null,

pub fn init(exec: *Execution) !*MessagePort {
    return exec._factory.eventTarget(MessagePort{
        ._proto = undefined,
        ._exec = exec,
    });
}

pub fn asEventTarget(self: *MessagePort) *EventTarget {
    return self._proto;
}

pub fn entangle(port1: *MessagePort, port2: *MessagePort) void {
    port1._entangled_port = port2;
    port2._entangled_port = port1;
}

pub fn isNeutered(self: *const MessagePort) bool {
    return self._neutered;
}

/// Move this port's channel into a fresh MessagePort owned by `exec`.  The old
/// wrapper stays alive but becomes inert, while the peer is rewired to the new
/// wrapper.  Event listeners and the started flag intentionally remain on the
/// old object, matching MessagePort disentangle/entangle in Blink.
pub fn transferTo(self: *MessagePort, exec: *Execution) !*MessagePort {
    if (self._neutered) return error.DataClone;

    const destination = try MessagePort.init(exec);
    const peer = self._entangled_port;

    self._entangled_port = null;
    self._neutered = true;

    if (peer) |other| {
        if (!other._closed and !other._neutered and other._entangled_port == self) {
            destination._entangled_port = other;
            other._entangled_port = destination;
        }
    }
    return destination;
}

pub fn postMessage(self: *MessagePort, message: js.Value) !void {
    if (self._closed or self._neutered) {
        return;
    }

    const other = self._entangled_port orelse return;
    if (other._closed) {
        return;
    }

    const source_exec = self._exec;
    const target_exec = other._exec;
    // Match Chrome's detached-owner behavior: a cached port method becomes
    // inert before StructuredSerialize/transfer validation, so uncloneable
    // input from a replacement caller realm must not throw here.
    if (source_exec.isShuttingDown() or target_exec.isShuttingDown()) return;

    // StructuredSerialize runs synchronously in the caller realm. Keep the
    // resulting bytes independent of both ports so an owner teardown observed
    // immediately afterwards cannot publish a task into a replacement realm.
    const serialized = blk: {
        var try_catch: js.TryCatch = undefined;
        try_catch.init(message.local);
        defer try_catch.deinit();

        break :blk message.serialize() catch {
            return error.DataClone;
        };
    };
    defer serialized.deinit();

    // Either owner may retire while a worker is serializing.
    if (source_exec.isShuttingDown() or target_exec.isShuttingDown()) return;

    // Deserialize and persist in the receiving port's stable owner realm, not
    // whichever realm happened to invoke this cached method.
    const cloned = blk: {
        var ls: js.Local.Scope = undefined;
        target_exec.js.localScope(&ls);
        defer ls.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const value = js.Value.deserialize(&ls.local, serialized.bytes()) catch {
            return error.DataClone;
        };
        break :blk try value.persist();
    };
    errdefer cloned.release();

    if (source_exec.isShuttingDown() or target_exec.isShuttingDown()) {
        cloned.release();
        return;
    }

    // Create callback to deliver message
    const callback = try target_exec._factory.create(PostMessageCallback{
        .source_exec = source_exec,
        .exec = target_exec,
        .port = other,
        .message = cloned,
    });
    errdefer target_exec._factory.destroy(callback);

    try target_exec.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "MessagePort.postMessage",
        .low_priority = false,
        .finalizer = PostMessageCallback.cancelled,
    });
}

pub fn start(self: *MessagePort) void {
    if (self._closed or self._neutered) {
        return;
    }
    self._enabled = true;
}

pub fn close(self: *MessagePort) void {
    self._closed = true;

    // Break entanglement
    if (self._entangled_port) |other| {
        other._entangled_port = null;
    }
    self._entangled_port = null;
}

pub fn getOnMessage(self: *const MessagePort) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *MessagePort, cb: ?js.Function.Global) !void {
    self._on_message = cb;
}

pub fn getOnMessageError(self: *const MessagePort) ?js.Function.Global {
    return self._on_message_error;
}

pub fn setOnMessageError(self: *MessagePort, cb: ?js.Function.Global) !void {
    self._on_message_error = cb;
}

const PostMessageCallback = struct {
    port: *MessagePort,
    message: js.Value.Global,
    source_exec: *Execution,
    exec: *Execution,

    // Called by the scheduler if the task is dropped before it runs. `run` and
    // `cancelled` are mutually exclusive, so the temp is released exactly once.
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
        const exec = self.exec;

        // The MessageEvent takes ownership of the cloned temp and releases it on
        // teardown; on any path where we don't hand it over, release it here so
        // it doesn't leak.
        if (self.source_exec.isShuttingDown() or
            exec.isShuttingDown() or
            self.port._exec != exec or
            self.port._closed)
        {
            self.message.release();
            return null;
        }

        const target = self.port.asEventTarget();
        if (!exec.hasDirectListeners(target, "message", self.port._on_message)) {
            self.message.release();
            return null;
        }

        if (self.source_exec.isShuttingDown() or exec.isShuttingDown()) {
            self.message.release();
            return null;
        }

        const event = (MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.message },
            .origin = "",
            .source = null,
        }, exec.page) catch |err| {
            self.message.release();
            log.err(.dom, "MessagePort.postMessage", .{ .err = err });
            return null;
        }).asEvent();

        exec.dispatch(target, event, self.port._on_message, .{ .context = "MessagePort message" }) catch |err| {
            log.err(.dom, "MessagePort.postMessage", .{ .err = err });
        };

        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(MessagePort);

    pub const Meta = struct {
        pub const name = "MessagePort";
        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const postMessage = bridge.function(MessagePort.postMessage, .{});
    pub const start = bridge.function(MessagePort.start, .{});
    pub const close = bridge.function(MessagePort.close, .{});

    pub const onmessage = bridge.accessor(MessagePort.getOnMessage, MessagePort.setOnMessage, .{});
    pub const onmessageerror = bridge.accessor(MessagePort.getOnMessageError, MessagePort.setOnMessageError, .{});
};
