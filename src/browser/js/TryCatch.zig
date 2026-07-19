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

const js = @import("js.zig");

const v8 = js.v8;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const TryCatch = @This();

handle: v8.TryCatch,
local: *const js.Local,

pub fn init(self: *TryCatch, l: *const js.Local) void {
    self.local = l;
    v8.v8__TryCatch__CONSTRUCT(&self.handle, l.isolate.handle);
}

pub fn hasCaught(self: TryCatch) bool {
    return v8.v8__TryCatch__HasCaught(&self.handle);
}

pub fn rethrow(self: *TryCatch) void {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.hasCaught());
    }
    _ = v8.v8__TryCatch__ReThrow(&self.handle);
}

pub fn exceptionValue(self: TryCatch) ?js.Value {
    if (!self.hasCaught()) return null;
    const handle = v8.v8__TryCatch__Exception(&self.handle) orelse return null;
    return .{ .local = self.local, .handle = handle };
}

/// Return V8's pending Message text without reading any property from the
/// thrown JavaScript value. This avoids invoking a user-defined `message`
/// getter merely because native code is deciding how to propagate an error.
pub fn messageText(self: TryCatch, allocator: Allocator) ?[]const u8 {
    if (!self.hasCaught()) return null;
    const message = v8.v8__TryCatch__Message(&self.handle) orelse return null;
    const handle = v8.v8__Message__Get(message) orelse return null;
    return js.String.toSliceWithAlloc(.{ .local = self.local, .handle = handle }, allocator) catch null;
}

/// Browser-visible data for one uncaught script exception. `error` owns one
/// tracked Global reference when non-null; transferring it into ErrorEvent
/// transfers that ownership as well.
pub const ErrorReport = struct {
    message: []const u8,
    filename: []const u8,
    lineno: u32 = 0,
    colno: u32 = 0,
    exception: ?js.Value.Global = null,

    pub fn releaseError(self: *ErrorReport) void {
        if (self.exception) |value| {
            value.release();
            self.exception = null;
        }
    }
};

/// Capture the same inputs Blink consumes from V8's main-thread message
/// handler: native message text, resource name, one-based line/column and the
/// original exception value. V8 columns are zero-based; ErrorEvent.colno is
/// one-based.
///
/// V8's ordinary classic-script reporting applies ToString to a thrown
/// non-Error object. Keep that operation inside its own TryCatch: authored
/// `toString` side effects occur exactly once, while a throwing conversion
/// leaves V8's original message as the fallback and never probes arbitrary
/// `name`, `message`, `stack` or `constructor` getters.
pub fn captureUncaught(
    self: *TryCatch,
    allocator: Allocator,
    fallback_url: []const u8,
) !ErrorReport {
    if (!self.hasCaught()) return error.NoCaughtException;

    var message = self.messageText(allocator) orelse try allocator.dupe(u8, "Uncaught");
    var filename = try allocator.dupe(u8, fallback_url);
    var lineno: u32 = 0;
    var colno: u32 = 0;

    if (v8.v8__TryCatch__Message(&self.handle)) |v8_message| {
        if (v8.v8__Message__GetScriptResourceName(v8_message)) |resource_handle| {
            const resource = js.Value{ .local = self.local, .handle = resource_handle };
            if (resource.isString()) |resource_string| {
                filename = resource_string.toSliceWithAlloc(allocator) catch filename;
            }
        }

        const line_number = v8.v8__Message__GetLineNumber(v8_message, self.local.handle);
        if (line_number >= 0) lineno = @intCast(line_number);

        const start_column = v8.v8__Message__GetStartColumn(v8_message);
        if (start_column >= 0) colno = @intCast(start_column + 1);
    }

    const exception = self.exceptionValue() orelse return error.NoCaughtException;
    if (exception.isObject() and !exception.isNativeError()) {
        var stringify_try_catch: TryCatch = undefined;
        stringify_try_catch.init(self.local);
        defer stringify_try_catch.deinit();

        if (exception.toStringSliceWithAlloc(allocator)) |rendered| {
            message = try std.fmt.allocPrint(allocator, "Uncaught {s}", .{rendered});
        } else |_| {}
    }

    return .{
        .message = message,
        .filename = filename,
        .lineno = lineno,
        .colno = colno,
        .exception = try exception.persist(),
    };
}

pub fn caught(self: TryCatch, allocator: Allocator) ?Caught {
    if (self.hasCaught() == false) {
        return null;
    }

    const l = self.local;
    const line: ?u32 = blk: {
        const handle = v8.v8__TryCatch__Message(&self.handle) orelse return null;
        const line = v8.v8__Message__GetLineNumber(handle, l.handle);
        break :blk if (line < 0) null else @intCast(line);
    };

    const exception: ?[]const u8 = blk: {
        const handle = v8.v8__TryCatch__Exception(&self.handle) orelse break :blk null;
        var js_val = js.Value{ .local = l, .handle = handle };

        // If it's an Error object, try to get the message property
        if (js_val.isObject()) {
            const js_obj = js_val.toObject();
            if (js_obj.has("message")) {
                js_val = js_obj.get("message") catch break :blk null;
            }
        }

        if (js_val.isString()) |js_str| {
            break :blk js_str.toSliceWithAlloc(allocator) catch |err| @errorName(err);
        }
        break :blk null;
    };

    const stack: ?[]const u8 = blk: {
        const handle = v8.v8__TryCatch__StackTrace(&self.handle, l.handle) orelse break :blk null;
        var js_val = js.Value{ .local = l, .handle = handle };

        // If it's an Error object, try to get the stack property
        if (js_val.isObject()) {
            const js_obj = js_val.toObject();
            if (js_obj.has("stack")) {
                js_val = js_obj.get("stack") catch break :blk null;
            }
        }

        if (js_val.isString()) |js_str| {
            break :blk js_str.toSliceWithAlloc(allocator) catch |err| @errorName(err);
        }
        break :blk null;
    };

    return .{
        .line = line,
        .stack = stack,
        .caught = true,
        .exception = exception,
    };
}

pub fn caughtOrError(self: TryCatch, allocator: Allocator, err: anyerror) Caught {
    return self.caught(allocator) orelse .{
        .caught = false,
        .line = null,
        .stack = null,
        .exception = @errorName(err),
    };
}

pub fn deinit(self: *TryCatch) void {
    v8.v8__TryCatch__DESTRUCT(&self.handle);
}

pub const Caught = struct {
    line: ?u32 = null,
    caught: bool = false,
    stack: ?[]const u8 = null,
    exception: ?[]const u8 = null,

    pub fn format(self: Caught, writer: *std.Io.Writer) !void {
        const separator = lp.log.separator();
        try writer.print("{s}exception: {?s}", .{ separator, self.exception });
        try writer.print("{s}stack: {?s}", .{ separator, self.stack });
        try writer.print("{s}line: {?d}", .{ separator, self.line });
        try writer.print("{s}caught: {any}", .{ separator, self.caught });
    }

    pub fn logFmt(self: Caught, prefix: []const u8, writer: anytype) !void {
        var buf: [64]u8 = undefined;
        try writer.write(try std.fmt.bufPrint(&buf, "{s}.exception", .{prefix}), self.exception orelse "???");
        try writer.write(try std.fmt.bufPrint(&buf, "{s}.stack", .{prefix}), self.stack orelse "na");
        try writer.write(try std.fmt.bufPrint(&buf, "{s}.line", .{prefix}), self.line);
        try writer.write(try std.fmt.bufPrint(&buf, "{s}.caught", .{prefix}), self.caught);
    }

    pub fn jsonStringify(self: Caught, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("exception");
        try jw.write(self.exception);
        try jw.objectField("stack");
        try jw.write(self.stack);
        try jw.objectField("line");
        try jw.write(self.line);
        try jw.objectField("caught");
        try jw.write(self.caught);
        try jw.endObject();
    }
};
