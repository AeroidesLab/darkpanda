// Copyright (C) 2026 Lightpanda contributors
//
// Shared Web IDL conversion and normalization for CanvasPath.roundRect().

const std = @import("std");

const js = @import("../../js/js.zig");
const adapter = @import("../../../canvas_backend/adapter.zig");
const CanvasException = @import("CanvasException.zig");

const Execution = js.Execution;
const Receiver = CanvasException.Receiver;

pub const Corners = [4]adapter.Radius;

const operation = "roundRect";

fn rangeError(
    exec: *Execution,
    receiver: Receiver,
    comptime format: []const u8,
    args: anytype,
) anyerror {
    const reason = try std.fmt.allocPrint(exec.call_arena, format, args);
    return CanvasException.rangeError(exec, receiver, operation, reason);
}

fn dictionaryNumber(
    value: js.Value,
    member: []const u8,
    receiver: Receiver,
    exec: *Execution,
) !f64 {
    if (value.isUndefined()) return 0;

    return js.WebIDL.toNumberWithContext(
        value,
        exec,
        .{ .dictionary_member = .{
            .parent = .{ .operation = .{
                .interface = receiver.name(),
                .name = operation,
            } },
            .dictionary = "DOMPointInit",
            .member = member,
        } },
    );
}

const ParsedRadius = struct {
    value: adapter.Radius,
    is_point: bool,
};

fn convertRadius(
    value: js.Value,
    receiver: Receiver,
    exec: *Execution,
) !ParsedRadius {
    if (value.isObject()) {
        const object = value.toObject();
        const raw_x = object.get("x") catch return error.TryCatchRethrow;
        const raw_y = object.get("y") catch return error.TryCatchRethrow;
        const x = try dictionaryNumber(raw_x, "x", receiver, exec);
        const y = try dictionaryNumber(raw_y, "y", receiver, exec);
        return .{ .value = .{ .x = x, .y = y }, .is_point = true };
    }

    const radius = try js.WebIDL.toNumber(value, exec, .{
        .interface = receiver.name(),
        .name = operation,
    });
    return .{
        .value = .{ .x = radius, .y = radius },
        .is_point = false,
    };
}

fn validateRadius(
    parsed: ParsedRadius,
    receiver: Receiver,
    exec: *Execution,
) !bool {
    const radius = parsed.value;
    if (!std.math.isFinite(radius.x) or !std.math.isFinite(radius.y)) return false;
    if (radius.x < 0) {
        if (parsed.is_point) {
            return rangeError(
                exec,
                receiver,
                "X-radius value {d} is negative.",
                .{radius.x},
            );
        }
        return rangeError(
            exec,
            receiver,
            "Radius value {d} is negative.",
            .{radius.x},
        );
    }
    if (parsed.is_point and radius.y < 0) {
        return rangeError(
            exec,
            receiver,
            "Y-radius value {d} is negative.",
            .{radius.y},
        );
    }
    return true;
}

/// Return an iterable's values when overload resolution selects the
/// sequence<> roundRect overload. A plain DOMPointInit has no @@iterator and
/// therefore returns null, selecting the single-radius overload.
fn sequenceValues(
    raw: js.Value,
    receiver: Receiver,
    exec: *Execution,
) !?[]const js.Value {
    if (!raw.isObject()) return null;

    const local = raw.local;
    const object = raw.toObject();
    const iterator_symbol = js.v8.v8__Symbol__GetIterator(local.isolate.handle);
    const method_handle = js.v8.v8__Object__Get(
        object.handle,
        local.handle,
        @ptrCast(iterator_symbol),
    ) orelse return error.TryCatchRethrow;
    const method = js.Value{ .local = local, .handle = method_handle };
    if (method.isNullOrUndefined()) return null;
    if (!method.isFunction()) {
        return CanvasException.typeError(
            exec,
            receiver,
            operation,
            "The object must have a callable @@iterator property.",
        );
    }

    const iterator_function = js.Function{
        .local = local,
        .handle = @ptrCast(method.handle),
    };
    const bound_iterator = try iterator_function.withThis(object);
    const iterator_value =
        try bound_iterator.callRethrow(js.Value, .{});
    if (!iterator_value.isObject()) {
        return CanvasException.typeError(
            exec,
            receiver,
            operation,
            "Iterator object must be an object.",
        );
    }
    const iterator = iterator_value.toObject();
    const next_value = iterator.get("next") catch return error.TryCatchRethrow;
    if (!next_value.isFunction()) {
        return CanvasException.typeError(
            exec,
            receiver,
            operation,
            "Expected next() function on iterator.",
        );
    }
    const next_function = js.Function{
        .local = local,
        .handle = @ptrCast(next_value.handle),
    };
    const bound_next = try next_function.withThis(iterator);

    var values: std.ArrayListUnmanaged(js.Value) = .empty;
    while (true) {
        const result_value = try bound_next.callRethrow(js.Value, .{});
        if (!result_value.isObject()) {
            return CanvasException.typeError(
                exec,
                receiver,
                operation,
                "Expected iterator.next() to return an Object.",
            );
        }
        const result = result_value.toObject();
        const done = result.get("done") catch return error.TryCatchRethrow;
        if (done.toBool()) break;
        try values.append(
            exec.call_arena,
            result.get("value") catch return error.TryCatchRethrow,
        );
    }
    return values.items;
}

/// Convert the overloaded radii argument and expand CSS shorthand order to
/// upper-left, upper-right, lower-right, lower-left corners. A null result
/// means Web IDL conversion succeeded but a non-finite value makes the path
/// operation a no-op.
pub fn parse(
    raw: ?js.Value,
    receiver: Receiver,
    exec: *Execution,
) !?Corners {
    var singleton: [1]js.Value = undefined;
    const values: []const js.Value = blk: {
        if (raw) |value| {
            if (!value.isUndefined()) {
                if (try sequenceValues(value, receiver, exec)) |sequence| {
                    break :blk sequence;
                }
                singleton[0] = value;
                break :blk &singleton;
            }
        }

        singleton[0] = try exec.js.local.?.newNumber(0);
        break :blk &singleton;
    };

    var converted: [4]ParsedRadius = undefined;
    for (values, 0..) |value, index| {
        const parsed = try convertRadius(value, receiver, exec);
        if (index < converted.len) converted[index] = parsed;
    }

    if (values.len < 1 or values.len > 4) {
        return rangeError(
            exec,
            receiver,
            "{d} radii provided. Between one and four radii are necessary.",
            .{values.len},
        );
    }

    var parsed: [4]adapter.Radius = undefined;
    for (converted[0..values.len], 0..) |radius, index| {
        if (!try validateRadius(radius, receiver, exec)) return null;
        parsed[index] = radius.value;
    }

    return switch (values.len) {
        1 => .{ parsed[0], parsed[0], parsed[0], parsed[0] },
        2 => .{ parsed[0], parsed[1], parsed[0], parsed[1] },
        3 => .{ parsed[0], parsed[1], parsed[2], parsed[1] },
        4 => .{ parsed[0], parsed[1], parsed[2], parsed[3] },
        else => unreachable,
    };
}
