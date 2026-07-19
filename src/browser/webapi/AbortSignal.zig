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

const std = @import("std");
const lp = @import("darkpanda");

const js = @import("../js/js.zig");

const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const DOMException = @import("DOMException.zig");
const ModelContextTool = @import("ModelContext.zig").Tool;

const log = lp.log;
const Execution = js.Execution;

const AbortSignal = @This();

const Dependend = union(enum) {
    signal: *AbortSignal,
    model_context_tool: *ModelContextTool,

    fn markAborted(self: Dependend, reason_: ?Reason, exec: *const Execution) !void {
        switch (self) {
            .signal => |dep| {
                if (dep._aborted) return;
                try dep.markAborted(reason_, exec);
            },
            .model_context_tool => |dep| {
                try dep.markAborted(exec);
            },
        }
    }

    fn dispatchAbortEvent(self: Dependend, exec: *const Execution) !void {
        switch (self) {
            .signal => |dep| try dep.dispatchAbortEvent(exec),
            .model_context_tool => {},
        }
    }
};

_proto: *EventTarget,
_aborted: bool = false,
_is_dependent: bool = false,
_reason: Reason = .undefined,
_on_abort: ?js.Function.Global = null,
_dependents: std.ArrayList(Dependend) = .{},
_source_signals: std.ArrayList(*AbortSignal) = .{},
_abort_algorithms: std.ArrayList(*AbortAlgorithm) = .{},

/// Native counterpart of the DOM Standard's abort algorithms.  The entry is
/// allocated from the Execution lifetime rather than an operation-specific
/// arena, so removing it before that operation is destroyed leaves a stable,
/// inert pointer in the signal's append-only list.
pub const AbortAlgorithm = struct {
    active: bool = true,
    ctx: *anyopaque,
    callback: *const fn (*anyopaque) void,
};

pub fn init(exec: *const Execution) !*AbortSignal {
    return exec._factory.eventTarget(AbortSignal{
        ._proto = undefined,
    });
}

pub fn getAborted(self: *const AbortSignal) bool {
    return self._aborted;
}

pub fn getReason(self: *const AbortSignal) Reason {
    return self._reason;
}

pub fn getOnAbort(self: *const AbortSignal) ?js.Function.Global {
    return self._on_abort;
}

pub fn setOnAbort(self: *AbortSignal, cb: ?js.Function.Global) !void {
    self._on_abort = cb;
}

pub fn asEventTarget(self: *AbortSignal) *EventTarget {
    return self._proto;
}

pub fn addAbortAlgorithm(
    self: *AbortSignal,
    ctx: *anyopaque,
    callback: *const fn (*anyopaque) void,
    exec: *const Execution,
) !?*AbortAlgorithm {
    if (self._aborted) return null;

    const algorithm = try exec.arena.create(AbortAlgorithm);
    algorithm.* = .{ .ctx = ctx, .callback = callback };
    try self._abort_algorithms.append(exec.arena, algorithm);
    return algorithm;
}

pub fn removeAbortAlgorithm(_: *AbortSignal, algorithm: *AbortAlgorithm) void {
    algorithm.active = false;
}

fn runAbortAlgorithms(self: *AbortSignal) void {
    for (self._abort_algorithms.items) |algorithm| {
        if (!algorithm.active) continue;
        // Disable first: callbacks are allowed to trigger arbitrary script and
        // cancellation paths, but an abort algorithm is strictly one-shot.
        algorithm.active = false;
        algorithm.callback(algorithm.ctx);
    }
}

pub fn abort(self: *AbortSignal, reason_: ?Reason, exec: *const Execution) !void {
    if (self._aborted) {
        return;
    }

    try self.markAborted(reason_, exec);

    // Per spec: mark all direct dependents aborted (with this signal's reason)
    // BEFORE firing any abort events. The graph is flattened at any() creation,
    // so we never need to recurse here.
    var to_dispatch: std.ArrayList(Dependend) = .{};
    for (self._dependents.items) |dep| {
        try dep.markAborted(self._reason, exec);
        try to_dispatch.append(exec.arena, dep);
    }

    try self.dispatchAbortEvent(exec);
    for (to_dispatch.items) |dep| {
        dep.dispatchAbortEvent(exec) catch |err| {
            log.warn(.app, "abort dependent dispatch", .{ .err = err });
        };
    }
}

fn markAborted(self: *AbortSignal, reason_: ?Reason, exec: *const Execution) !void {
    const reason = reason_ orelse Reason.undefined;
    const new_reason: Reason = switch (reason) {
        // Persist DOMException reasons once.  Returning a newly wrapped native
        // value for every getter access breaks both `signal.reason ===
        // signal.reason` and Fetch's required rejection identity.
        .dom => |dom| .{ .js_val = try persistDOMReason(dom, exec) },
        .js_val => |js_val| .{ .js_val = js_val },
        .string => |str| .{ .string = try exec.dupeString(str) },
        .undefined => .{ .js_val = try persistDOMReason(
            DOMException.init("signal is aborted without reason", "AbortError"),
            exec,
        ) },
    };
    // Commit only after all allocation/V8 conversion succeeds.  A failed
    // conversion must not leave an irrevocably-aborted signal with its old
    // reason and live algorithms.
    self._reason = new_reason;
    self._aborted = true;
    self.runAbortAlgorithms();
}

fn persistDOMReason(reason: DOMException, exec: *const Execution) !js.Value.Global {
    // Scheduler callbacks (notably AbortSignal.timeout) run after the Web IDL
    // call scope which created the signal has gone away.  Establish a fresh V8
    // HandleScope before wrapping/persisting the DOMException; exec.js.local
    // may otherwise point at a retired call-local scope.
    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();
    return (try ls.local.zigValueToJs(reason, .{})).persist();
}

fn dispatchAbortEvent(self: *AbortSignal, exec: *const Execution) !void {
    const target = self.asEventTarget();
    const on_abort = self._on_abort;
    switch (exec.js.global) {
        inline else => |g| {
            if (g._event_manager.hasDirectListeners(target, "abort", on_abort)) {
                const event = try Event.initTrusted(comptime .wrap("abort"), .{}, g._page);
                try g.dispatch(target, event, on_abort, .{ .context = "abort signal" });
            }
        },
    }
}

// Static method to create an already-aborted signal
pub fn createAborted(reason_: ?js.Value.Global, exec: *const Execution) !*AbortSignal {
    const signal = try init(exec);
    try signal.abort(if (reason_) |r| .{ .js_val = r } else null, exec);
    return signal;
}

pub fn createAny(signals: []const *AbortSignal, exec: *const Execution) !*AbortSignal {
    const result = try init(exec);
    for (signals) |source| {
        if (source._aborted) {
            try result.abort(source._reason, exec);
            return result;
        }
    }

    result._is_dependent = true;

    for (signals) |source| {
        if (!source._is_dependent) {
            try source._dependents.append(exec.arena, .{ .signal = result });
            try result._source_signals.append(exec.arena, source);
        } else {
            for (source._source_signals.items) |s| {
                try s._dependents.append(exec.arena, .{ .signal = result });
                try result._source_signals.append(exec.arena, s);
            }
        }
    }
    return result;
}

pub fn createTimeout(delay: u32, exec: *const Execution) !*AbortSignal {
    const callback = try exec.arena.create(TimeoutCallback);
    callback.* = .{
        .exec = exec,
        .signal = try init(exec),
    };

    try exec._scheduler.add(callback, TimeoutCallback.run, delay, .{
        .name = "AbortSignal.timeout",
    });

    return callback.signal;
}

const ThrowIfAborted = union(enum) {
    exception: js.Exception,
    undefined: void,
};
pub fn throwIfAborted(self: *const AbortSignal, exec: *const Execution) !ThrowIfAborted {
    const local = exec.js.local.?;

    if (self._aborted) {
        const exception = switch (self._reason) {
            .dom => |err| local.newException(err),
            .string => |str| local.newException(str),
            .js_val => |js_val| local.newException(js_val),
            .undefined => local.newException(DOMException.fromError(error.AbortError).?),
        };
        return .{ .exception = exception };
    }
    return .undefined;
}

const Reason = union(enum) {
    js_val: js.Value.Global,
    dom: DOMException,
    string: []const u8,
    undefined: void,
};

const TimeoutCallback = struct {
    exec: *const Execution,
    signal: *AbortSignal,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *TimeoutCallback = @ptrCast(@alignCast(ctx));
        self.signal.abort(.{ .dom = DOMException.init("signal timed out", "TimeoutError") }, self.exec) catch |err| {
            log.warn(.app, "abort signal timeout", .{ .err = err });
        };
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(AbortSignal);

    pub const Meta = struct {
        pub const name = "AbortSignal";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const Prototype = EventTarget;

    pub const constructor = bridge.constructor(AbortSignal.init, .{});
    pub const aborted = bridge.accessor(AbortSignal.getAborted, null, .{});
    pub const reason = bridge.accessor(AbortSignal.getReason, null, .{});
    pub const onabort = bridge.accessor(AbortSignal.getOnAbort, AbortSignal.setOnAbort, .{});
    pub const throwIfAborted = bridge.function(AbortSignal.throwIfAborted, .{});

    // Static method
    pub const abort = bridge.function(AbortSignal.createAborted, .{ .static = true });
    pub const any = bridge.function(AbortSignal.createAny, .{ .static = true });
    pub const timeout = bridge.function(AbortSignal.createTimeout, .{ .static = true });
};
