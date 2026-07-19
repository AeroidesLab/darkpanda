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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");

const String = lp.String;

const PromiseRejectionEvent = @This();

_proto: *Event,
_reason: ?js.Value.Global = null,
_promise: ?js.Promise.Global = null,

const PromiseRejectionEventOptions = struct {
    reason: ?js.Value.Global = null,
    promise: ?js.Promise.Global = null,
};

const Options = Event.inheritOptions(PromiseRejectionEvent, PromiseRejectionEventOptions);

// The public dictionary keeps raw local values until the native constructor
// can apply Web IDL's Promise conversion. Optional `js.Value` is intentional:
// null at the Zig level means the dictionary member was absent, while explicit
// JavaScript undefined/null remain ordinary values.
const ConstructorPromiseRejectionEventOptions = struct {
    promise: ?js.Value = null,
    reason: ?js.Value = null,
};

const ConstructorOptions = Event.inheritOptions(PromiseRejectionEvent, ConstructorPromiseRejectionEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*PromiseRejectionEvent {
    const arena = try page.getArena(.tiny, "PromiseRejectionEvent");
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = opts_ orelse Options{};
    return initWithOptions(arena, type_string, opts, opts.reason, opts.promise, page);
}

pub fn construct(typ: []const u8, opts_: ?ConstructorOptions, exec: *js.Execution) !*PromiseRejectionEvent {
    const opts = opts_ orelse return requiredPromiseMember(exec);
    const promise_value = opts.promise orelse return requiredPromiseMember(exec);
    const local = exec.js.local.?;

    // Blink retains a genuine V8 Promise. Other values, including null,
    // undefined and thenables, are assimilated by a Promise resolver in the
    // constructor's current realm.
    const promise = if (promise_value.isPromise())
        try promise_value.toPromise().persist()
    else
        try (try local.resolvePromise(promise_value)).persist();
    errdefer promise.release();

    const reason = if (opts.reason) |value|
        try value.persist()
    else
        try (js.Value{ .local = local, .handle = local.isolate.initUndefined() }).persist();
    errdefer reason.release();

    const page = exec.page;
    const arena = try page.getArena(.tiny, "PromiseRejectionEvent");
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithOptions(arena, type_string, opts, reason, promise, page);
}

fn requiredPromiseMember(exec: *js.Execution) anyerror {
    return js.WebIDL.constructorTypeError(
        exec,
        "PromiseRejectionEvent",
        "Failed to read the 'promise' property from 'PromiseRejectionEventInit': Required member is undefined.",
    );
}

fn initWithOptions(
    arena: std.mem.Allocator,
    type_string: String,
    opts: anytype,
    reason: ?js.Value.Global,
    promise: ?js.Promise.Global,
    page: *Page,
) !*PromiseRejectionEvent {
    const event = try page.factory.event(
        arena,
        type_string,
        PromiseRejectionEvent{
            ._proto = undefined,
            ._reason = reason,
            ._promise = promise,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn deinit(self: *PromiseRejectionEvent, page: *Page) void {
    if (self._reason) |r| {
        r.release();
    }
    if (self._promise) |p| {
        p.release();
    }
    self._proto.deinit(page);
}

pub fn releaseRef(self: *PromiseRejectionEvent, page: *Page) void {
    self._proto._rc.release(self, page);
}

pub fn acquireRef(self: *PromiseRejectionEvent) void {
    self._proto.acquireRef();
}

pub fn asEvent(self: *PromiseRejectionEvent) *Event {
    return self._proto;
}

pub fn getReason(self: *const PromiseRejectionEvent) ?js.Value.Global {
    return self._reason;
}

pub fn getPromise(self: *const PromiseRejectionEvent) ?js.Promise.Global {
    return self._promise;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PromiseRejectionEvent);

    pub const Meta = struct {
        pub const name = "PromiseRejectionEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PromiseRejectionEvent.construct, .{ .arity = 2, .required_args = 2 });
    pub const promise = bridge.accessor(PromiseRejectionEvent.getPromise, null, .{});
    pub const reason = bridge.accessor(PromiseRejectionEvent.getReason, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: PromiseRejectionEvent" {
    try testing.htmlRunner("event/promise_rejection.html", .{});
}
