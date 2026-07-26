// Copyright (C) 2026 Lightpanda contributors
//
// Shared Web IDL conversion for CanvasFillRule arguments.

const std = @import("std");

const js = @import("../../js/js.zig");
const CanvasException = @import("CanvasException.zig");

const Execution = js.Execution;
const Receiver = CanvasException.Receiver;

pub fn parse(
    raw: ?js.Value,
    receiver: Receiver,
    operation: []const u8,
    exec: *Execution,
) !i32 {
    const value = raw orelse return 0;
    if (value.isUndefined()) return 0;

    const text = try js.WebIDL.toDOMString(value, exec, .{
        .interface = receiver.name(),
        .name = operation,
    });
    if (std.mem.eql(u8, text, "nonzero")) return 0;
    if (std.mem.eql(u8, text, "evenodd")) return 1;

    const reason = try std.fmt.allocPrint(
        exec.call_arena,
        "The provided value '{s}' is not a valid enum value of type CanvasFillRule.",
        .{text},
    );
    return CanvasException.typeError(exec, receiver, operation, reason);
}
