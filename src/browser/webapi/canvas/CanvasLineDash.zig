// Copyright (C) 2026 Lightpanda contributors
//
// Web IDL sequence conversion for CanvasPathDrawingStyles.setLineDash().

const std = @import("std");

const js = @import("../../js/js.zig");
const CanvasException = @import("CanvasException.zig");

const Execution = js.Execution;
const Receiver = CanvasException.Receiver;

const operation = "setLineDash";

fn sequenceTypeError(
    receiver: Receiver,
    reason: []const u8,
    exec: *Execution,
) anyerror {
    return CanvasException.typeError(exec, receiver, operation, reason);
}

pub fn parse(
    raw: js.Value,
    receiver: Receiver,
    exec: *Execution,
) ![]const f64 {
    if (!raw.isObject()) {
        return sequenceTypeError(
            receiver,
            "The provided value cannot be converted to a sequence.",
            exec,
        );
    }

    const iterable = raw.toObject();
    const local = raw.local;
    const iterator_symbol = js.v8.v8__Symbol__GetIterator(local.isolate.handle);
    const method_handle = js.v8.v8__Object__Get(
        iterable.handle,
        local.handle,
        @ptrCast(iterator_symbol),
    ) orelse return error.TryCatchRethrow;
    const method = js.Value{ .local = local, .handle = method_handle };
    if (!method.isFunction()) {
        return sequenceTypeError(
            receiver,
            "The object must have a callable @@iterator property.",
            exec,
        );
    }

    const iterator_function = js.Function{
        .local = local,
        .handle = @ptrCast(method.handle),
    };
    const bound_iterator = try iterator_function.withThis(iterable);
    const iterator_value = try bound_iterator.callRethrow(js.Value, .{});
    if (!iterator_value.isObject()) {
        return sequenceTypeError(
            receiver,
            "Iterator object must be an object.",
            exec,
        );
    }

    const iterator = iterator_value.toObject();
    const next_value = iterator.get("next") catch return error.TryCatchRethrow;
    if (!next_value.isFunction()) {
        return sequenceTypeError(
            receiver,
            "Expected next() function on iterator.",
            exec,
        );
    }
    const next_function = js.Function{
        .local = local,
        .handle = @ptrCast(next_value.handle),
    };
    const bound_next = try next_function.withThis(iterator);

    var segments: std.ArrayListUnmanaged(f64) = .empty;
    while (true) {
        const result_value = try bound_next.callRethrow(js.Value, .{});
        if (!result_value.isObject()) {
            return sequenceTypeError(
                receiver,
                "Expected iterator.next() to return an Object.",
                exec,
            );
        }
        const result = result_value.toObject();
        const done = result.get("done") catch return error.TryCatchRethrow;
        if (done.toBool()) break;
        const value = result.get("value") catch return error.TryCatchRethrow;
        try segments.append(
            exec.call_arena,
            try js.WebIDL.toNumber(value, exec, .{
                .interface = receiver.name(),
                .name = operation,
            }),
        );
    }
    return segments.items;
}
