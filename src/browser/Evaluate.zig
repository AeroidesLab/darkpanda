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

const Frame = @import("Frame.zig");
const js = @import("js/js.zig");

pub const default_promise_timeout_ms: u32 = 30_000;

/// Controls whether a returned Promise is driven to settlement before the
/// evaluation completes. `return_immediately` is provided for embedders that
/// want to manage the Promise themselves; browser tools use the default.
pub const PromiseHandling = enum {
    await_settlement,
    return_immediately,
};

/// Controls conversion of a successful V8 value into the API's text result.
/// `json_objects` preserves the browser-tool contract: ordinary objects and
/// arrays become JSON while functions, errors, and primitives use JS string
/// conversion. `string` is available to lower-level embedders.
pub const ResultEncoding = enum {
    json_objects,
    string,
};

pub const Options = struct {
    /// Run only when `script` fails to compile. A runtime throw never retries.
    fallback: ?[:0]const u8 = null,
    promise_timeout_ms: u32 = default_promise_timeout_ms,
    promise_handling: PromiseHandling = .await_settlement,
    result_encoding: ResultEncoding = .json_objects,
};

/// A JS compile/runtime failure is returned in-band so API callers can expose
/// the original V8 diagnostic. Only allocation failure is an operational Zig
/// error.
pub const Result = struct {
    text: []const u8,
    is_error: bool = false,
};

pub const Error = error{OutOfMemory};

/// Evaluate a zero-terminated script in `page`'s V8 context.
///
/// The default options intentionally match the existing browser-tool
/// semantics, including a 30-second Promise timeout and JSON object encoding.
pub fn run(
    arena: std.mem.Allocator,
    page: *Frame,
    script: [:0]const u8,
    options: Options,
) Error!Result {
    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const js_result = ls.local.compileAndRun(script, null) catch |err| {
        if (err == error.CompilationError) if (options.fallback) |fallback| {
            var fallback_options = options;
            fallback_options.fallback = null;
            return run(arena, page, fallback, fallback_options);
        };
        return .{ .text = try formatJsError(arena, &try_catch, err), .is_error = true };
    };

    const awaited_promise: ?js.Promise = if (js_result.isPromise() and options.promise_handling == .await_settlement) blk: {
        const promise = js_result.toPromise();
        // Attach the embedder's await handling before the checkpoint.  A
        // synchronously rejected async function must not briefly look
        // unhandled merely because Runtime.evaluate is awaiting it.
        promise.markAsHandled();
        break :blk promise;
    } else null;

    // Runtime.evaluate is itself a JavaScript task boundary.  Blink performs
    // the responsible agent's microtask checkpoint after the evaluated script
    // returns and before any timer/network task is allowed to run.  Without
    // this checkpoint an async evaluation could observe setTimeout(0) before
    // queueMicrotask/Promise reactions, even though the same code in Chrome
    // observes the microtasks first.
    ls.local.runMicrotasks();

    if (awaited_promise) |promise| {
        var runner = page._session.runner(.{});
        var timer = std.time.Timer.start() catch unreachable;
        while (promise.state() == .pending) {
            const elapsed_ms: u32 = @intCast(timer.read() / std.time.ns_per_ms);
            if (elapsed_ms >= options.promise_timeout_ms) {
                return .{ .text = "promise: timed out waiting for resolution", .is_error = true };
            }
            const budget = @min(options.promise_timeout_ms - elapsed_ms, 50);
            _ = runner.tickForFrame(page._frame_id, budget, .{ .until = .done }) catch |err| switch (err) {
                error.Cancelled => return .{ .text = "promise: cancelled", .is_error = true },
                else => return .{ .text = "promise: tick failed", .is_error = true },
            };
        }

        const settled = promise.result();
        const rejected = promise.state() == .rejected;
        // No-return async IIFE -> undefined -> silence, so pipes stay clean.
        if (!rejected and settled.isUndefined()) return .{ .text = "" };
        const text = (if (rejected)
            settled.toStringSliceWithAlloc(arena)
        else
            encodeResult(arena, settled, options.result_encoding)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .text = try formatJsError(arena, &try_catch, err), .is_error = true },
        };
        return .{ .text = text, .is_error = rejected };
    }

    const text = encodeResult(arena, js_result, options.result_encoding) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .text = try formatJsError(arena, &try_catch, err), .is_error = true },
    };
    return .{ .text = text };
}

/// Objects/arrays serialize as JSON so `return obj` prints data, not
/// `[object Object]`; errors and primitives keep their string form.
fn encodeResult(arena: std.mem.Allocator, value: js.Value, encoding: ResultEncoding) ![]u8 {
    if (encoding == .json_objects and value.isObject() and !value.isFunction() and !value.isNativeError()) {
        return value.toJson(arena);
    }
    return value.toStringSliceWithAlloc(arena);
}

fn formatJsError(arena: std.mem.Allocator, try_catch: *js.TryCatch, err: anyerror) Error![]const u8 {
    const caught = try_catch.caughtOrError(arena, err);
    var aw: std.Io.Writer.Allocating = .init(arena);
    caught.format(&aw.writer) catch |fmt_err| switch (fmt_err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.written();
}
