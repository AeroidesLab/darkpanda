// Copyright (C) 2026 Lightpanda contributors

const js = @import("../js/js.zig");

const ViewTransition = @This();

_ready: ?js.Promise.Global = null,
_finished: ?js.Promise.Global = null,
_update_callback_done: ?js.Promise.Global = null,

pub fn init(exec: *js.Execution) !*ViewTransition {
    return exec._factory.create(ViewTransition{});
}

fn resolved(field: *?js.Promise.Global, exec: *js.Execution) !js.Promise {
    const local = exec.js.local orelse return error.InvalidStateError;
    if (field.*) |promise| return promise.local(local);
    const promise = try local.resolvePromise(.{});
    field.* = try promise.persist();
    return promise;
}

pub fn getReady(self: *ViewTransition, exec: *js.Execution) !js.Promise {
    return resolved(&self._ready, exec);
}

pub fn getFinished(self: *ViewTransition, exec: *js.Execution) !js.Promise {
    return resolved(&self._finished, exec);
}

pub fn getUpdateCallbackDone(self: *ViewTransition, exec: *js.Execution) !js.Promise {
    return resolved(&self._update_callback_done, exec);
}

pub fn skipTransition(_: *ViewTransition) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ViewTransition);

    pub const Meta = struct {
        pub const name = "ViewTransition";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const ready = bridge.accessor(ViewTransition.getReady, null, .{});
    pub const finished = bridge.accessor(ViewTransition.getFinished, null, .{});
    pub const updateCallbackDone = bridge.accessor(ViewTransition.getUpdateCallbackDone, null, .{});
    pub const skipTransition = bridge.function(ViewTransition.skipTransition, .{});
};
