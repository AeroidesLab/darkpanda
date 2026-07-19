// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const js = @import("../../../js/js.zig");

const IDBRequest = @import("IDBRequest.zig");
const IDBVersionChangeEvent = @import("IDBVersionChangeEvent.zig");
const idb = @import("idb.zig");

const Execution = js.Execution;
const FunctionSetter = idb.FunctionSetter;

const IDBOpenDBRequest = @This();

_proto: *IDBRequest,
_on_blocked: ?js.Function.Global = null,

pub fn init(exec: *Execution) !*IDBOpenDBRequest {
    const request = try IDBRequest.init(exec);
    errdefer exec._factory.destroy(request);

    const self = try exec._factory.create(IDBOpenDBRequest{ ._proto = request });

    // Event dispatch starts from EventTarget. Point its concrete-type tag at
    // the public leaf so event.target/currentTarget reuse the exact same
    // IDBOpenDBRequest wrapper instead of materializing a second IDBRequest.
    request.asEventTarget()._type = .{ .idb_open_db_request = self };
    return self;
}

pub fn asRequest(self: *IDBOpenDBRequest) *IDBRequest {
    return self._proto;
}

pub fn getOnBlocked(self: *const IDBOpenDBRequest) ?js.Function.Global {
    return self._on_blocked;
}

pub fn setOnBlocked(self: *IDBOpenDBRequest, setter: ?FunctionSetter) void {
    self._on_blocked = functionFromSetter(setter);
}

pub fn getOnUpgradeNeeded(self: *const IDBOpenDBRequest) ?js.Function.Global {
    return self._proto.getOnUpgradeNeeded();
}

pub fn setOnUpgradeNeeded(self: *IDBOpenDBRequest, setter: ?FunctionSetter) void {
    self._proto.setOnUpgradeNeeded(setter);
}

pub fn fireBlocked(self: *IDBOpenDBRequest, exec: *Execution, old_version: u64, new_version: ?u64) !void {
    const event = try IDBVersionChangeEvent.initTrusted(
        comptime .wrap("blocked"),
        old_version,
        new_version,
        exec,
    );
    try exec.dispatch(
        self._proto.asEventTarget(),
        event.asEvent(),
        self._on_blocked,
        .{ .context = "IDBOpenDBRequest.blocked" },
    );
}

fn functionFromSetter(setter: ?FunctionSetter) ?js.Function.Global {
    const value = setter orelse return null;
    return switch (value) {
        .func => |function| function,
        .anything => null,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBOpenDBRequest);

    pub const Meta = struct {
        pub const name = "IDBOpenDBRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is observable through Reflect.ownKeys and follows the
    // Chrome 149 generated binding.
    pub const onblocked = bridge.accessor(IDBOpenDBRequest.getOnBlocked, IDBOpenDBRequest.setOnBlocked, .{});
    pub const onupgradeneeded = bridge.accessor(IDBOpenDBRequest.getOnUpgradeNeeded, IDBOpenDBRequest.setOnUpgradeNeeded, .{});
};
