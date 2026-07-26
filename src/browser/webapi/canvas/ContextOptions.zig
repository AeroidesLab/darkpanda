// Copyright (C) 2026 Lightpanda contributors
//
// Shared Canvas 2D context-creation attributes. HTMLCanvasElement and
// OffscreenCanvas use the same Blink dictionary and must retain the first
// successfully created context's normalized values.

const std = @import("std");

const js = @import("../../js/js.zig");
const adapter = @import("../../../canvas_backend/adapter.zig");
const CanvasException = @import("CanvasException.zig");

const Execution = js.Execution;

pub const SurfaceFlag = adapter.SurfaceFlag;

pub const Attributes = struct {
    alpha: bool = true,
    colorSpace: []const u8 = "srgb",
    colorType: []const u8 = "unorm8",
    desynchronized: bool = false,
    toneMapping: ToneMapping = .{},
    willReadFrequently: bool = false,

    pub const ToneMapping = struct {
        mode: []const u8 = "standard",
    };

    pub fn surfaceFlags(self: Attributes) u32 {
        var flags: u32 = 0;
        if (!self.alpha) flags |= SurfaceFlag.OPAQUE;
        if (std.mem.eql(u8, self.colorSpace, "display-p3")) flags |= SurfaceFlag.DISPLAY_P3;
        if (std.mem.eql(u8, self.colorType, "float16")) flags |= SurfaceFlag.FLOAT16;
        return flags;
    }
};

pub const Receiver = enum {
    html_canvas,
    offscreen_canvas,

    fn name(self: Receiver) []const u8 {
        return switch (self) {
            .html_canvas => "HTMLCanvasElement",
            .offscreen_canvas => "OffscreenCanvas",
        };
    }
};

const dictionary_name = "CanvasContextCreationAttributesModule";

fn dictionaryMemberContext(
    receiver: Receiver,
    member: []const u8,
) js.WebIDL.ConversionContext {
    return .{ .dictionary_member = .{
        .parent = .{ .operation = .{
            .interface = receiver.name(),
            .name = "getContext",
        } },
        .dictionary = dictionary_name,
        .member = member,
    } };
}

fn dictionaryTypeError(
    exec: *Execution,
    receiver: Receiver,
    member: []const u8,
    stack_reason: []const u8,
) anyerror {
    const exposed_reason = try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to read the '{s}' property from '{s}': {s}",
        .{ member, dictionary_name, stack_reason },
    );
    return CanvasException.typeErrorWithStackReason(
        exec,
        receiver.name(),
        "getContext",
        exposed_reason,
        stack_reason,
    );
}

fn readStringMember(
    object: js.Object,
    member: []const u8,
    exec: *Execution,
    receiver: Receiver,
) !?[]const u8 {
    const value = object.get(member) catch return error.TryCatchRethrow;
    if (value.isUndefined()) return null;
    return @as(?[]const u8, try js.WebIDL.toDOMStringWithContext(
        value,
        exec,
        dictionaryMemberContext(receiver, member),
    ));
}

fn invalidEnum(
    exec: *Execution,
    receiver: Receiver,
    member: []const u8,
    value: []const u8,
    enum_name: []const u8,
) anyerror {
    const reason = try std.fmt.allocPrint(
        exec.call_arena,
        "The provided value '{s}' is not a valid enum value of type {s}.",
        .{ value, enum_name },
    );
    return dictionaryTypeError(exec, receiver, member, reason);
}

/// Parse Blink's permissive context-creation dictionary. Non-object values are
/// treated as an empty dictionary; null and undefined are likewise defaults.
pub fn parse(
    raw_options: ?js.Value,
    exec: *Execution,
    receiver: Receiver,
) !Attributes {
    const raw = raw_options orelse return .{};
    if (raw.isNullOrUndefined() or !raw.isObject()) return .{};
    const object = raw.toObject();

    // Generated Blink dictionary bindings read the supported members in
    // canonical name order. Chrome 149 exposes a constant `toneMapping`
    // attribute from getContextAttributes(), but does not read an author's
    // `toneMapping` creation member at all.
    const raw_alpha = object.get("alpha") catch return error.TryCatchRethrow;
    const color_space = try readStringMember(object, "colorSpace", exec, receiver);
    const color_type = try readStringMember(object, "colorType", exec, receiver);
    const raw_desynchronized = object.get("desynchronized") catch return error.TryCatchRethrow;
    const will_read_frequently = try readStringMember(object, "willReadFrequently", exec, receiver);

    var result: Attributes = .{
        .alpha = if (raw_alpha.isUndefined()) true else raw_alpha.toBool(),
        .desynchronized = if (raw_desynchronized.isUndefined()) false else raw_desynchronized.toBool(),
    };

    if (color_space) |value| {
        if (std.mem.eql(u8, value, "srgb")) {
            result.colorSpace = "srgb";
        } else if (std.mem.eql(u8, value, "display-p3")) {
            result.colorSpace = "display-p3";
        } else {
            return invalidEnum(exec, receiver, "colorSpace", value, "PredefinedColorSpace");
        }
    }

    if (color_type) |value| {
        if (std.mem.eql(u8, value, "unorm8")) {
            result.colorType = "unorm8";
        } else if (std.mem.eql(u8, value, "float16")) {
            result.colorType = "float16";
        } else {
            return invalidEnum(exec, receiver, "colorType", value, "CanvasPixelFormat");
        }
    }

    if (will_read_frequently) |value| {
        if (std.mem.eql(u8, value, "true")) {
            result.willReadFrequently = true;
        } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "undefined")) {
            result.willReadFrequently = false;
        } else {
            return invalidEnum(
                exec,
                receiver,
                "willReadFrequently",
                value,
                "CanvasWillReadFrequently",
            );
        }
    }

    return result;
}

test "surface flags match the native descriptor contract" {
    try std.testing.expectEqual(@as(u32, 0), (Attributes{}).surfaceFlags());
    try std.testing.expectEqual(
        SurfaceFlag.OPAQUE | SurfaceFlag.DISPLAY_P3 | SurfaceFlag.FLOAT16,
        (Attributes{
            .alpha = false,
            .colorSpace = "display-p3",
            .colorType = "float16",
        }).surfaceFlags(),
    );
}
