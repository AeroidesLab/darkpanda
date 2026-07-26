// Copyright (C) 2026 Lightpanda contributors
//
// Canvas-specific exception helpers. Chromium qualifies synchronous Canvas
// errors with both the operation and receiver interface; returning a bare Zig
// error loses that observable message while also conflating Web IDL TypeError,
// DOMException and native RangeError objects.

const std = @import("std");

const js = @import("../../js/js.zig");
const DOMException = @import("../DOMException.zig");

const Execution = js.Execution;

pub const Receiver = enum {
    canvas,
    offscreen,

    pub fn name(self: Receiver) []const u8 {
        return switch (self) {
            .canvas => "CanvasRenderingContext2D",
            .offscreen => "OffscreenCanvasRenderingContext2D",
        };
    }
};

fn operationMessage(
    exec: *Execution,
    receiver: []const u8,
    operation: []const u8,
    reason: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '{s}' on '{s}': {s}",
        .{ operation, receiver, reason },
    );
}

fn replaceNativeErrorMessage(
    local: *const js.Local,
    exception: *const js.v8.Value,
    message: []const u8,
) void {
    // Force V8's lazy stack string while the compact native message is still
    // installed, then expose Blink's qualified own `message` property.
    const stack_key = local.isolate.initStringHandle("stack");
    _ = js.v8.v8__Object__Get(@ptrCast(exception), local.handle, stack_key);
    const message_key = local.isolate.initStringHandle("message");
    const message_value = local.isolate.initStringHandle(message);
    var maybe_result: js.v8.MaybeBool = undefined;
    js.v8.v8__Object__DefineOwnProperty(
        @ptrCast(exception),
        local.handle,
        @ptrCast(message_key),
        @ptrCast(message_value),
        js.v8.None,
        &maybe_result,
    );
}

/// Throw a Web IDL TypeError with Chromium's operation-qualified message.
pub fn typeError(
    exec: *Execution,
    receiver: Receiver,
    operation: []const u8,
    reason: []const u8,
) anyerror {
    return js.WebIDL.typeError(exec, .{
        .interface = receiver.name(),
        .name = operation,
    }, reason);
}

/// Throw a TypeError where Blink exposes a nested dictionary/conversion reason
/// in `message`, but retains only V8's compact conversion reason in `stack`.
pub fn typeErrorWithStackReason(
    exec: *Execution,
    receiver: []const u8,
    operation: []const u8,
    exposed_reason: []const u8,
    stack_reason: []const u8,
) anyerror {
    const local = exec.js.local orelse return error.TypeError;
    const message = try operationMessage(exec, receiver, operation, exposed_reason);
    const exception = local.isolate.createTypeError(stack_reason);
    replaceNativeErrorMessage(local, exception, message);
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

/// CanvasGradient is shared by regular and offscreen contexts, so its receiver
/// name is fixed rather than selected through Receiver.
pub fn gradientTypeError(
    exec: *Execution,
    operation: []const u8,
    reason: []const u8,
) anyerror {
    return js.WebIDL.typeError(exec, .{
        .interface = "CanvasGradient",
        .name = operation,
    }, reason);
}

/// Throw an operation-qualified DOMException while preserving its native
/// prototype, legacy numeric code and captured stack.
fn domException(
    exec: *Execution,
    receiver: []const u8,
    operation: []const u8,
    name: []const u8,
    reason: []const u8,
) anyerror {
    const local = exec.js.local orelse return error.TypeError;
    const message = try operationMessage(exec, receiver, operation, reason);
    const exception = try local.zigValueToJs(DOMException.init(message, name), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

pub fn canvasDOMException(
    exec: *Execution,
    receiver: Receiver,
    operation: []const u8,
    name: []const u8,
    reason: []const u8,
) anyerror {
    return domException(exec, receiver.name(), operation, name, reason);
}

/// Canvas operations also live on HTMLCanvasElement and OffscreenCanvas.
/// Keep the generic interface form centralized so those entry points expose
/// the same qualified message, DOMException prototype, legacy code and stack.
pub fn operationDOMException(
    exec: *Execution,
    receiver: []const u8,
    operation: []const u8,
    name: []const u8,
    reason: []const u8,
) anyerror {
    return domException(exec, receiver, operation, name, reason);
}

/// Promise-returning Canvas operations reject instead of synchronously
/// throwing. Build the same native DOMException object without installing it
/// as the isolate's pending exception.
pub fn rejectedDOMException(
    exec: *Execution,
    receiver: []const u8,
    operation: []const u8,
    name: []const u8,
    reason: []const u8,
) !js.Promise {
    const local = exec.js.local orelse return error.TypeError;
    const message = try operationMessage(exec, receiver, operation, reason);
    const exception = try local.zigValueToJs(DOMException.init(message, name), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    const resolver = local.createPromiseResolver();
    resolver.reject("CanvasException.rejectedDOMException", exception);
    return resolver.promise();
}

pub fn gradientDOMException(
    exec: *Execution,
    operation: []const u8,
    name: []const u8,
    reason: []const u8,
) anyerror {
    return domException(exec, "CanvasGradient", operation, name, reason);
}

/// RangeError is an ECMAScript native error, not a DOMException.
pub fn rangeError(
    exec: *Execution,
    receiver: Receiver,
    operation: []const u8,
    reason: []const u8,
) anyerror {
    const local = exec.js.local orelse return error.RangeError;
    const message = try operationMessage(exec, receiver.name(), operation, reason);
    // Blink creates the native RangeError with the concise reason, eagerly
    // materializes Error.stack, then replaces the exposed message with the
    // operation-qualified text. Thus `message` and stack's first line are
    // intentionally different.
    const exception = local.isolate.createRangeError(reason);
    replaceNativeErrorMessage(local, exception, message);
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

const testing = @import("../../../testing.zig");
test "WebApi: Canvas browser binding semantics" {
    try testing.htmlRunner("canvas/canvas_browser_semantics.html", .{});
}
