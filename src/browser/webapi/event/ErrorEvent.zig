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
const Allocator = std.mem.Allocator;

const ErrorEvent = @This();

_proto: *Event,
_message: []const u8 = "",
_filename: []const u8 = "",
_line_number: u32 = 0,
_column_number: u32 = 0,
_error: ?js.Value.Global = null,
_arena: Allocator,

pub const ErrorEventOptions = struct {
    message: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    lineno: u32 = 0,
    colno: u32 = 0,
    @"error": ?js.Value.Global = null,
};

const Options = Event.inheritOptions(ErrorEvent, ErrorEventOptions);

// `ErrorEventInit.error` is an `any` member without a default. Keep the
// author-facing dictionary local so its optional wrapper can distinguish an
// absent member from an explicitly supplied `undefined` or `null`. Trusted
// runtime events use `ErrorEventOptions` above because they already own a
// persistent value and need `null` as the cross-world/muted-errors sentinel.
const ConstructorErrorEventOptions = struct {
    message: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    lineno: u32 = 0,
    colno: u32 = 0,
    @"error": ?js.Value = null,
};

const ConstructorOptions = Event.inheritOptions(ErrorEvent, ConstructorErrorEventOptions);

pub fn init(typ: []const u8, opts_: ?ConstructorOptions, exec: *js.Execution) !*ErrorEvent {
    const page = exec.page;
    const arena = try page.getArena(.small, "ErrorEvent");
    errdefer page.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});

    const opts = opts_ orelse ConstructorOptions{};
    const local = exec.js.local.?;
    const error_value = if (opts.@"error") |value|
        try value.persist()
    else
        try (js.Value{ .local = local, .handle = local.isolate.initUndefined() }).persist();
    errdefer error_value.release();

    return initWithOptions(arena, type_string, opts, error_value, false, page);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*ErrorEvent {
    const arena = try page.getArena(.small, "ErrorEvent.trusted");
    errdefer page.releaseArena(arena);
    const opts = opts_ orelse Options{};
    return initWithOptions(arena, typ, opts, opts.@"error", true, page);
}

fn initWithOptions(
    arena: Allocator,
    typ: String,
    opts: anytype,
    error_value: ?js.Value.Global,
    trusted: bool,
    page: *Page,
) !*ErrorEvent {
    const event = try page.factory.event(
        arena,
        typ,
        ErrorEvent{
            ._arena = arena,
            ._proto = undefined,
            ._message = if (opts.message) |str| try arena.dupe(u8, str) else "",
            ._filename = if (opts.filename) |str| try arena.dupe(u8, str) else "",
            ._line_number = opts.lineno,
            ._column_number = opts.colno,
            ._error = error_value,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *ErrorEvent, page: *Page) void {
    if (self._error) |e| {
        e.release();
    }
    self._proto.deinit(page);
}

pub fn releaseRef(self: *ErrorEvent, page: *Page) void {
    self._proto._rc.release(self, page);
}

pub fn acquireRef(self: *ErrorEvent) void {
    self._proto.acquireRef();
}

pub fn asEvent(self: *ErrorEvent) *Event {
    return self._proto;
}

pub fn getMessage(self: *const ErrorEvent) []const u8 {
    return self._message;
}

pub fn getFilename(self: *const ErrorEvent) []const u8 {
    return self._filename;
}

pub fn getLineNumber(self: *const ErrorEvent) u32 {
    return self._line_number;
}

pub fn getColumnNumber(self: *const ErrorEvent) u32 {
    return self._column_number;
}

pub fn getError(self: *const ErrorEvent) ?js.Value.Global {
    return self._error;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ErrorEvent);

    pub const Meta = struct {
        pub const name = "ErrorEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(ErrorEvent.deinit);
    };

    // Start API
    pub const constructor = bridge.constructor(ErrorEvent.init, .{});
    pub const message = bridge.accessor(ErrorEvent.getMessage, null, .{});
    pub const filename = bridge.accessor(ErrorEvent.getFilename, null, .{});
    pub const lineno = bridge.accessor(ErrorEvent.getLineNumber, null, .{});
    pub const colno = bridge.accessor(ErrorEvent.getColumnNumber, null, .{});
    // Authored absent/undefined values are stored as a persistent JavaScript
    // `undefined`; a null optional remains reserved for trusted muted/cross-
    // world reports and maps to JavaScript `null`.
    pub const @"error" = bridge.accessor(ErrorEvent.getError, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: ErrorEvent" {
    try testing.htmlRunner("event/error.html", .{});
}
