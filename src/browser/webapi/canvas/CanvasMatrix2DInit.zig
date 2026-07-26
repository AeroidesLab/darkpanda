// Copyright (C) 2026 Lightpanda contributors
//
// Shared DOMMatrix2DInit conversion for CanvasTransform.setTransform().

const std = @import("std");

const js = @import("../../js/js.zig");
const CanvasException = @import("CanvasException.zig");

const Execution = js.Execution;
const Receiver = CanvasException.Receiver;

pub const Matrix = [6]f64;

const Member = struct {
    raw: ?js.Value,
    value: f64,
};

fn readMember(
    object: js.Object,
    field: []const u8,
    default: f64,
    receiver: []const u8,
    operation: []const u8,
    exec: *Execution,
) !Member {
    const raw = object.get(field) catch return error.TryCatchRethrow;
    if (raw.isUndefined()) return .{ .raw = null, .value = default };

    return .{
        .raw = raw,
        .value = try js.WebIDL.toNumberWithContext(
            raw,
            exec,
            .{ .dictionary_member = .{
                .parent = .{ .operation = .{
                    .interface = receiver,
                    .name = operation,
                } },
                .dictionary = "DOMMatrix2DInit",
                .member = field,
            } },
        ),
    };
}

fn conflict(a: Member, alias: Member) bool {
    if (a.raw == null or alias.raw == null) return false;
    if (a.value == alias.value) return false;
    return !(std.math.isNan(a.value) and std.math.isNan(alias.value));
}

pub fn parse(
    raw: ?js.Value,
    receiver: Receiver,
    operation: []const u8,
    exec: *Execution,
) !Matrix {
    return parseForInterface(raw, receiver.name(), operation, exec);
}

pub fn parseForInterface(
    raw: ?js.Value,
    receiver: []const u8,
    operation: []const u8,
    exec: *Execution,
) !Matrix {
    const value = raw orelse return .{ 1, 0, 0, 1, 0, 0 };
    if (value.isNullOrUndefined()) return .{ 1, 0, 0, 1, 0, 0 };
    if (!value.isObject()) {
        return CanvasException.typeErrorWithStackReason(
            exec,
            receiver,
            operation,
            "The provided value is not of type 'DOMMatrix2DInit'.",
            "The provided value is not of type 'DOMMatrix2DInit'.",
        );
    }

    const object = value.toObject();
    const a = try readMember(object, "a", 1, receiver, operation, exec);
    const b = try readMember(object, "b", 0, receiver, operation, exec);
    const c = try readMember(object, "c", 0, receiver, operation, exec);
    const d = try readMember(object, "d", 1, receiver, operation, exec);
    const e = try readMember(object, "e", 0, receiver, operation, exec);
    const f = try readMember(object, "f", 0, receiver, operation, exec);
    const m11 = try readMember(object, "m11", 1, receiver, operation, exec);
    const m12 = try readMember(object, "m12", 0, receiver, operation, exec);
    const m21 = try readMember(object, "m21", 0, receiver, operation, exec);
    const m22 = try readMember(object, "m22", 1, receiver, operation, exec);
    const m41 = try readMember(object, "m41", 0, receiver, operation, exec);
    const m42 = try readMember(object, "m42", 0, receiver, operation, exec);

    if (conflict(a, m11) or conflict(b, m12) or conflict(c, m21) or
        conflict(d, m22) or conflict(e, m41) or conflict(f, m42))
    {
        return CanvasException.typeErrorWithStackReason(
            exec,
            receiver,
            operation,
            "Property mismatch on matrix initialization.",
            "Property mismatch on matrix initialization.",
        );
    }

    return .{
        if (a.raw != null) a.value else m11.value,
        if (b.raw != null) b.value else m12.value,
        if (c.raw != null) c.value else m21.value,
        if (d.raw != null) d.value else m22.value,
        if (e.raw != null) e.value else m41.value,
        if (f.raw != null) f.value else m42.value,
    };
}
