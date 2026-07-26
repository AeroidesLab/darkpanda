// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const DOMException = @import("DOMException.zig");
const CanvasException = @import("canvas/CanvasException.zig");

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/ImageData/ImageData
const ImageData = @This();
_width: u32,
_height: u32,
_color_space: ColorSpace,
_pixel_format: PixelFormat,
_data: Data,

pub const ColorSpace = enum(u8) {
    srgb,
    display_p3,

    fn toString(self: ColorSpace) []const u8 {
        return switch (self) {
            .srgb => "srgb",
            .display_p3 => "display-p3",
        };
    }
};

pub const PixelFormat = enum(u8) {
    rgba_unorm8,
    rgba_float16,
    rgba_float32,

    fn toString(self: PixelFormat) []const u8 {
        return switch (self) {
            .rgba_unorm8 => "rgba-unorm8",
            .rgba_float16 => "rgba-float16",
            .rgba_float32 => "rgba-float32",
        };
    }
};

const Data = union(PixelFormat) {
    rgba_unorm8: js.ArrayBufferRef(.uint8_clamped).Global,
    rgba_float16: js.ArrayBufferRef(.float16).Global,
    rgba_float32: js.ArrayBufferRef(.float32).Global,

    fn value(self: *const Data, local: *const js.Local) js.Value {
        const handle = switch (self.*) {
            inline else => |data| data.local(local).handle,
        };
        return .{ .local = local, .handle = handle };
    }

    fn rawBytes(self: *const Data, local: *const js.Local) []const u8 {
        return switch (self.*) {
            inline else => |data| std.mem.sliceAsBytes(data.local(local).slice()),
        };
    }
};

pub const ParsedSettings = struct {
    color_space: ColorSpace,
    pixel_format: PixelFormat,
};

fn constructorMessage(exec: *Execution, reason: []const u8) ![]const u8 {
    return std.fmt.allocPrint(exec.call_arena, "Failed to construct 'ImageData': {s}", .{reason});
}

fn throwConstructorTypeError(exec: *Execution, stack_reason: []const u8, message_reason: []const u8) anyerror {
    const local = exec.js.local orelse return error.TypeError;
    const exception = local.isolate.createTypeError(stack_reason);

    // Materialize V8's concise stack before replacing the public message,
    // matching Blink's constructor binding split.
    const stack_key = local.isolate.initStringHandle("stack");
    _ = js.v8.v8__Object__Get(@ptrCast(exception), local.handle, stack_key);
    const message_key = local.isolate.initStringHandle("message");
    const message = local.isolate.initStringHandle(try constructorMessage(exec, message_reason));
    var defined: js.v8.MaybeBool = undefined;
    js.v8.v8__Object__DefineOwnProperty(
        @ptrCast(exception),
        local.handle,
        @ptrCast(message_key),
        @ptrCast(message),
        js.v8.None,
        &defined,
    );
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

fn throwConstructorDOMException(exec: *Execution, name: []const u8, reason: []const u8) anyerror {
    const local = exec.js.local orelse return error.TypeError;
    const exception = try local.zigValueToJs(
        DOMException.init(try constructorMessage(exec, reason), name),
        .{},
    );
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

fn checkedElementCount(width: u32, height: u32) !u32 {
    // Though arguments are unsigned long, these are capped to max. i32 on Chrome.
    // https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/html/canvas/image_data.cc#L61
    const max_i32 = std.math.maxInt(i32);
    if (width == 0 or width > max_i32 or height == 0 or height > max_i32) {
        return error.IndexSizeError;
    }

    var size, var overflown = @mulWithOverflow(width, height);
    if (overflown == 1) return error.IndexSizeError;
    size, overflown = @mulWithOverflow(size, 4);
    if (overflown == 1) return error.IndexSizeError;
    return size;
}

fn validateConstructorWidth(width: u32, exec: *Execution) !void {
    if (width == 0) {
        return throwConstructorDOMException(exec, "IndexSizeError", "The source width is zero or not a number.");
    }
    if (width > std.math.maxInt(i32)) {
        return throwConstructorDOMException(exec, "IndexSizeError", "The requested image size exceeds the supported range.");
    }
}

fn validateConstructorHeight(height: u32, exec: *Execution) !void {
    if (height == 0) {
        return throwConstructorDOMException(exec, "IndexSizeError", "The source height is zero or not a number.");
    }
    if (height > std.math.maxInt(i32)) {
        return throwConstructorDOMException(exec, "IndexSizeError", "The requested image size exceeds the supported range.");
    }
}

fn constructorElementCount(width: u32, height: u32, exec: *Execution) !u32 {
    try validateConstructorWidth(width, exec);
    try validateConstructorHeight(height, exec);
    return checkedElementCount(width, height) catch {
        return throwConstructorDOMException(exec, "IndexSizeError", "The requested image size exceeds the supported range.");
    };
}

fn allocateData(local: *const js.Local, pixel_format: PixelFormat, size: u32) !Data {
    return switch (pixel_format) {
        .rgba_unorm8 => .{ .rgba_unorm8 = try local.createTypedArray(.uint8_clamped, size).persist() },
        .rgba_float16 => .{ .rgba_float16 = try local.createTypedArray(.float16, size).persist() },
        .rgba_float32 => .{ .rgba_float32 = try local.createTypedArray(.float32, size).persist() },
    };
}

fn initParsed(
    width: u32,
    height: u32,
    settings: ParsedSettings,
    exec: *Execution,
) !*ImageData {
    const size = try checkedElementCount(width, height);
    const local = exec.js.local.?;

    return exec._factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._color_space = settings.color_space,
        ._pixel_format = settings.pixel_format,
        ._data = try allocateData(local, settings.pixel_format, size),
    });
}

/// This has many constructors:
///
/// ```js
/// new ImageData(width, height)
/// new ImageData(width, height, settings)
///
/// new ImageData(dataArray, width)
/// new ImageData(dataArray, width, height)
/// new ImageData(dataArray, width, height, settings)
/// ```
fn canvasSettingsTypeError(
    exec: *Execution,
    receiver: CanvasException.Receiver,
    operation: []const u8,
    field_name: []const u8,
    stack_reason: []const u8,
) anyerror {
    const exposed_reason = try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to read the '{s}' property from 'ImageDataSettings': {s}",
        .{ field_name, stack_reason },
    );
    return CanvasException.typeErrorWithStackReason(
        exec,
        receiver.name(),
        operation,
        exposed_reason,
        stack_reason,
    );
}

fn canvasEnumMember(
    object: js.Object,
    field_name: []const u8,
    enum_name: []const u8,
    default_value: []const u8,
    exec: *Execution,
    receiver: CanvasException.Receiver,
    operation: []const u8,
) ![]const u8 {
    const value = try object.get(field_name);
    if (value.isUndefined()) return default_value;
    const string_value = try js.WebIDL.toDOMStringWithContext(
        value,
        exec,
        .{ .dictionary_member = .{
            .parent = .{ .operation = .{
                .interface = receiver.name(),
                .name = operation,
            } },
            .dictionary = "ImageDataSettings",
            .member = field_name,
        } },
    );
    if ((std.mem.eql(u8, enum_name, "PredefinedColorSpace") and
        (std.mem.eql(u8, string_value, "srgb") or std.mem.eql(u8, string_value, "display-p3"))) or
        (std.mem.eql(u8, enum_name, "ImageDataPixelFormat") and
            (std.mem.eql(u8, string_value, "rgba-unorm8") or
                std.mem.eql(u8, string_value, "rgba-float16") or
                std.mem.eql(u8, string_value, "rgba-float32"))))
    {
        return string_value;
    }

    const reason = try std.fmt.allocPrint(
        exec.call_arena,
        "The provided value '{s}' is not a valid enum value of type {s}.",
        .{ string_value, enum_name },
    );
    return canvasSettingsTypeError(
        exec,
        receiver,
        operation,
        field_name,
        reason,
    );
}

pub fn parseCanvasSettingsValue(
    maybe_settings: ?js.Value,
    omitted_color_space: ColorSpace,
    receiver: CanvasException.Receiver,
    operation: []const u8,
    exec: *Execution,
) !ParsedSettings {
    const supplied = maybe_settings orelse return .{
        .color_space = omitted_color_space,
        .pixel_format = .rgba_unorm8,
    };
    if (supplied.isNullOrUndefined()) {
        return .{
            .color_space = omitted_color_space,
            .pixel_format = .rgba_unorm8,
        };
    }
    if (!supplied.isObject()) {
        return CanvasException.typeError(
            exec,
            receiver,
            operation,
            "The provided value is not of type 'ImageDataSettings'.",
        );
    }

    const object = supplied.toObject();
    const color_space_value = try canvasEnumMember(
        object,
        "colorSpace",
        "PredefinedColorSpace",
        "srgb",
        exec,
        receiver,
        operation,
    );
    const pixel_format_value = try canvasEnumMember(
        object,
        "pixelFormat",
        "ImageDataPixelFormat",
        "rgba-unorm8",
        exec,
        receiver,
        operation,
    );
    return .{
        .color_space = if (std.mem.eql(u8, color_space_value, "display-p3"))
            .display_p3
        else
            .srgb,
        .pixel_format = if (std.mem.eql(u8, pixel_format_value, "rgba-float16"))
            .rgba_float16
        else if (std.mem.eql(u8, pixel_format_value, "rgba-float32"))
            .rgba_float32
        else
            .rgba_unorm8,
    };
}

pub fn initForCanvasSettings(
    width: u32,
    height: u32,
    settings: ParsedSettings,
    receiver: CanvasException.Receiver,
    operation: []const u8,
    exec: *Execution,
) !*ImageData {
    _ = checkedElementCount(width, height) catch {
        const reason = if (std.mem.eql(u8, operation, "createImageData"))
            "Out of memory at ImageData creation."
        else
            "Out of memory at ImageData creation";
        return CanvasException.rangeError(exec, receiver, operation, reason);
    };
    return initParsed(width, height, settings, exec);
}

/// Blink's Canvas pixel bindings use an enforce-range Web IDL `long` adapter
/// with three distinct native conversion diagnostics.
pub fn canvasLong(
    value: js.Value,
    receiver: CanvasException.Receiver,
    operation: []const u8,
    exec: *Execution,
) !i32 {
    const number = try js.WebIDL.toNumber(value, exec, .{
        .interface = receiver.name(),
        .name = operation,
    });
    const reason: ?[]const u8 = if (std.math.isNan(number))
        "Value is not of type 'long'."
    else if (std.math.isInf(number))
        "Value is infinite and not of type 'long'."
    else if (@trunc(number) < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        @trunc(number) > @as(f64, @floatFromInt(std.math.maxInt(i32))))
        "Value is outside the 'long' value range."
    else
        null;
    if (reason) |message| {
        return CanvasException.typeError(exec, receiver, operation, message);
    }
    return @intFromFloat(@trunc(number));
}

/// Complete overload dispatcher for CanvasRenderingContext2D.createImageData.
/// One supplied argument selects the ImageData overload; two or more select
/// the numeric overload, exactly as Blink's generated binding does.
pub fn createForCanvas(
    args: []const js.Value,
    receiver: CanvasException.Receiver,
    exec: *Execution,
) !*ImageData {
    if (args.len == 1) {
        const source = args[0].local.jsValueToZig(*ImageData, args[0]) catch {
            return js.WebIDL.argumentNotOfType(
                exec,
                .{ .operation = .{
                    .interface = receiver.name(),
                    .name = "createImageData",
                } },
                0,
                "ImageData",
            );
        };
        return source.cloneBlank(exec);
    }

    const width = try canvasLong(args[0], receiver, "createImageData", exec);
    const height = try canvasLong(args[1], receiver, "createImageData", exec);
    // Web IDL converts the complete argument list before native dimension and
    // allocation validation. A throwing dictionary getter therefore wins over
    // zero-size and out-of-memory diagnostics.
    const settings = try parseCanvasSettingsValue(
        if (args.len >= 3) args[2] else null,
        .srgb,
        receiver,
        "createImageData",
        exec,
    );
    const normalized_width: i64 = if (width < 0) -@as(i64, width) else width;
    const normalized_height: i64 = if (height < 0) -@as(i64, height) else height;
    if (normalized_width == 0) {
        return CanvasException.canvasDOMException(
            exec,
            receiver,
            "createImageData",
            "IndexSizeError",
            "The source width is zero or not a number.",
        );
    }
    if (normalized_height == 0) {
        return CanvasException.canvasDOMException(
            exec,
            receiver,
            "createImageData",
            "IndexSizeError",
            "The source height is zero or not a number.",
        );
    }
    return initForCanvasSettings(
        @intCast(normalized_width),
        @intCast(normalized_height),
        settings,
        receiver,
        "createImageData",
        exec,
    );
}

/// The ImageData overload of createImageData copies dimensions and storage
/// metadata, but allocates a fresh zero-filled buffer.
pub fn cloneBlank(self: *const ImageData, exec: *Execution) !*ImageData {
    return initParsed(
        self._width,
        self._height,
        .{
            .color_space = self._color_space,
            .pixel_format = self._pixel_format,
        },
        exec,
    );
}

fn initConstructor(
    width: u32,
    height: u32,
    settings: ParsedSettings,
    exec: *Execution,
) !*ImageData {
    const size = try constructorElementCount(width, height, exec);
    const local = exec.js.local.?;

    return exec._factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._color_space = settings.color_space,
        ._pixel_format = settings.pixel_format,
        ._data = try allocateData(local, settings.pixel_format, size),
    });
}

fn isFloat16Array(value: js.Value) bool {
    // zig-v8 currently has no Value::IsFloat16Array binding. Float16Array is
    // nevertheless the only V8 typed-array kind not covered by the predicates
    // below, so this remains an internal-slot test rather than a constructor-
    // name or Symbol.toStringTag heuristic.
    return value.isTypedArray() and
        !value.isUint8Array() and
        !value.isUint8ClampedArray() and
        !value.isInt8Array() and
        !value.isUint16Array() and
        !value.isInt16Array() and
        !value.isUint32Array() and
        !value.isInt32Array() and
        !value.isBigUint64Array() and
        !value.isBigInt64Array() and
        !value.isFloat32Array() and
        !value.isFloat64Array();
}

fn constructorSettingsMemberTypeError(
    exec: *Execution,
    member: []const u8,
    stack_reason: []const u8,
) anyerror {
    const exposed_reason = try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to read the '{s}' property from 'ImageDataSettings': {s}",
        .{ member, stack_reason },
    );
    return throwConstructorTypeError(exec, stack_reason, exposed_reason);
}

fn parseConstructorSettingsValue(value: ?js.Value, exec: *Execution) !ParsedSettings {
    const supplied = value orelse return .{
        .color_space = .srgb,
        .pixel_format = .rgba_unorm8,
    };
    if (supplied.isNullOrUndefined()) {
        return .{ .color_space = .srgb, .pixel_format = .rgba_unorm8 };
    }
    if (!supplied.isObject()) {
        const reason = "The provided value is not of type 'ImageDataSettings'.";
        return throwConstructorTypeError(exec, reason, reason);
    }

    const object = supplied.toObject();
    const raw_color_space = object.get("colorSpace") catch return error.TryCatchRethrow;
    const color_space_text = if (raw_color_space.isUndefined())
        "srgb"
    else
        try js.WebIDL.toDOMStringWithContext(
            raw_color_space,
            exec,
            .{ .dictionary_member = .{
                .parent = .{ .constructor = "ImageData" },
                .dictionary = "ImageDataSettings",
                .member = "colorSpace",
            } },
        );
    const color_space: ColorSpace = if (std.mem.eql(u8, color_space_text, "srgb"))
        .srgb
    else if (std.mem.eql(u8, color_space_text, "display-p3"))
        .display_p3
    else {
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The provided value '{s}' is not a valid enum value of type PredefinedColorSpace.",
            .{color_space_text},
        );
        return constructorSettingsMemberTypeError(exec, "colorSpace", reason);
    };

    const raw_pixel_format = object.get("pixelFormat") catch return error.TryCatchRethrow;
    const pixel_format_text = if (raw_pixel_format.isUndefined())
        "rgba-unorm8"
    else
        try js.WebIDL.toDOMStringWithContext(
            raw_pixel_format,
            exec,
            .{ .dictionary_member = .{
                .parent = .{ .constructor = "ImageData" },
                .dictionary = "ImageDataSettings",
                .member = "pixelFormat",
            } },
        );
    const pixel_format: PixelFormat = if (std.mem.eql(u8, pixel_format_text, "rgba-unorm8"))
        .rgba_unorm8
    else if (std.mem.eql(u8, pixel_format_text, "rgba-float16"))
        .rgba_float16
    else if (std.mem.eql(u8, pixel_format_text, "rgba-float32"))
        .rgba_float32
    else {
        const stack_reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The provided value '{s}' is not a valid enum value of type ImageDataPixelFormat.",
            .{pixel_format_text},
        );
        return constructorSettingsMemberTypeError(exec, "pixelFormat", stack_reason);
    };

    return .{ .color_space = color_space, .pixel_format = pixel_format };
}

fn constructorUnsignedLong(value: js.Value, exec: *Execution) !u32 {
    const number = try js.WebIDL.toNumberWithContext(
        value,
        exec,
        .{ .constructor = "ImageData" },
    );
    if (!std.math.isFinite(number) or number == 0) return 0;

    var modulo = @mod(@trunc(number), 4_294_967_296.0);
    if (modulo < 0) modulo += 4_294_967_296.0;
    return @intFromFloat(modulo);
}

fn dataElementLength(value: js.Value) usize {
    const view: *const js.v8.ArrayBufferView = @ptrCast(value.handle);
    const bytes = js.v8.v8__ArrayBufferView__ByteLength(view);
    const element_size: usize = if (value.isFloat32Array()) 4 else if (isFloat16Array(value)) 2 else 1;
    return bytes / element_size;
}

fn persistInputData(value: js.Value, pixel_format: PixelFormat) !Data {
    return switch (pixel_format) {
        .rgba_unorm8 => blk: {
            var data = js.ArrayBufferRef(.uint8_clamped){ .local = value.local, .handle = value.handle };
            break :blk .{ .rgba_unorm8 = try data.persist() };
        },
        .rgba_float16 => blk: {
            var data = js.ArrayBufferRef(.float16){ .local = value.local, .handle = value.handle };
            break :blk .{ .rgba_float16 = try data.persist() };
        },
        .rgba_float32 => blk: {
            var data = js.ArrayBufferRef(.float32){ .local = value.local, .handle = value.handle };
            break :blk .{ .rgba_float32 = try data.persist() };
        },
    };
}

/// Web IDL constructor dispatcher. Keeping the first two parameters required
/// preserves ImageData.length === 2 while supporting both numeric and typed-
/// array overload families.
pub fn construct(
    first: js.Value,
    second: js.Value,
    third: ?js.Value,
    fourth: ?js.Value,
    exec: *Execution,
) !*ImageData {
    const input_pixel_format: ?PixelFormat = if (first.isUint8ClampedArray())
        .rgba_unorm8
    else if (isFloat16Array(first))
        .rgba_float16
    else if (first.isFloat32Array())
        .rgba_float32
    else
        null;

    if (input_pixel_format) |input_format| {
        const width = try constructorUnsignedLong(second, exec);
        const fourth_is_undefined = fourth == null or fourth.?.isUndefined();
        const maybe_height: ?u32 = if (third) |height|
            if (height.isUndefined() and fourth_is_undefined)
                null
            else
                try constructorUnsignedLong(height, exec)
        else
            null;
        const settings = try parseConstructorSettingsValue(fourth, exec);

        // Web IDL has already converted the complete argument list at this
        // point. Blink's native validation then checks dimensions before data
        // format and length.
        try validateConstructorWidth(width, exec);
        if (maybe_height) |height| {
            _ = try constructorElementCount(width, height, exec);
        }

        if (settings.pixel_format != input_format) {
            const reason = switch (input_format) {
                .rgba_unorm8 => "Uint8ClampedArray must use rgba-unorm8 pixelFormat.",
                .rgba_float16 => "Float16Array must use rgba-float16 pixelFormat.",
                .rgba_float32 => "Float32Array must use rgba-float32 pixelFormat.",
            };
            return throwConstructorDOMException(exec, "InvalidStateError", reason);
        }

        const data_len = dataElementLength(first);
        if (data_len == 0) {
            return throwConstructorDOMException(exec, "InvalidStateError", "The input data has zero elements.");
        }
        if (data_len % 4 != 0) {
            return throwConstructorDOMException(exec, "InvalidStateError", "The input data length is not a multiple of 4.");
        }
        const pixel_count = data_len / 4;
        const width_usize: usize = width;
        if (pixel_count % width_usize != 0) {
            return throwConstructorDOMException(exec, "IndexSizeError", "The input data length is not a multiple of (4 * width).");
        }
        const inferred_height: u32 = @intCast(pixel_count / width_usize);
        const height = maybe_height orelse inferred_height;
        if (maybe_height != null and height != inferred_height) {
            return throwConstructorDOMException(exec, "IndexSizeError", "The input data length is not equal to (4 * width * height).");
        }
        try validateConstructorHeight(height, exec);

        return exec._factory.create(ImageData{
            ._width = width,
            ._height = height,
            ._color_space = settings.color_space,
            ._pixel_format = input_format,
            ._data = try persistInputData(first, input_format),
        });
    }

    const width = try constructorUnsignedLong(first, exec);
    const height = try constructorUnsignedLong(second, exec);
    return initConstructor(width, height, try parseConstructorSettingsValue(third, exec), exec);
}

pub fn structuredSerialize(self: *const ImageData, writer: *js.StructuredWriter) !void {
    writer.writeUint32(self._width);
    writer.writeUint32(self._height);
    writer.writeUint32(@intFromEnum(self._color_space));
    writer.writeUint32(@intFromEnum(self._pixel_format));
    writer.writeBytes(self._data.rawBytes(writer.local));
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*ImageData {
    const width = try reader.readUint32();
    const height = try reader.readUint32();
    const color_space = std.meta.intToEnum(ColorSpace, try reader.readUint32()) catch return error.DataClone;
    const pixel_format = std.meta.intToEnum(PixelFormat, try reader.readUint32()) catch return error.DataClone;
    const bytes = try reader.readBytes();
    const size = try checkedElementCount(width, height);
    const expected_bytes = @as(usize, size) * switch (pixel_format) {
        .rgba_unorm8 => @as(usize, 1),
        .rgba_float16 => 2,
        .rgba_float32 => 4,
    };
    if (bytes.len != expected_bytes) return error.DataClone;

    const data = try allocateData(reader.local, pixel_format, size);
    switch (data) {
        inline else => |global| @memcpy(std.mem.sliceAsBytes(global.local(reader.local).slice()), bytes),
    }

    return page.factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._color_space = color_space,
        ._pixel_format = pixel_format,
        ._data = data,
    });
}

pub fn getWidth(self: *const ImageData) u32 {
    return self._width;
}

pub fn getHeight(self: *const ImageData) u32 {
    return self._height;
}

pub fn getColorSpace(self: *const ImageData) []const u8 {
    return self._color_space.toString();
}

pub fn getData(self: *const ImageData, exec: *const Execution) js.Value {
    return self._data.value(exec.js.local.?);
}

pub fn getPixelFormat(self: *const ImageData) []const u8 {
    return self._pixel_format.toString();
}

pub fn colorSpace(self: *const ImageData) ColorSpace {
    return self._color_space;
}

pub fn pixelFormat(self: *const ImageData) PixelFormat {
    return self._pixel_format;
}

pub fn rawBytesMutable(self: *ImageData, local: *const js.Local) []u8 {
    return switch (self._data) {
        inline else => |data| std.mem.sliceAsBytes(data.local(local).slice()),
    };
}

pub fn rgbaUnorm8(self: *const ImageData, local: *const js.Local, allocator: std.mem.Allocator) ![]const u8 {
    return switch (self._data) {
        .rgba_unorm8 => |data| data.local(local).slice(),
        .rgba_float16 => |data| try floatToUnorm8(f16, data.local(local).slice(), allocator),
        .rgba_float32 => |data| try floatToUnorm8(f32, data.local(local).slice(), allocator),
    };
}

fn floatToUnorm8(comptime T: type, source: []const T, allocator: std.mem.Allocator) ![]u8 {
    const destination = try allocator.alloc(u8, source.len);
    for (source, destination) |channel, *out| {
        const value: f32 = @floatCast(channel);
        out.* = if (std.math.isNan(value) or value <= 0)
            0
        else if (value >= 1)
            255
        else
            @intFromFloat(@round(value * 255));
    }
    return destination;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ImageData);

    pub const Meta = struct {
        pub const name = "ImageData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    /// Chromium caches only the historical Uint8ClampedArray `data` value as
    /// an own property. Float16/Float32 keep using the prototype accessor.
    pub fn associateWithWrapper(self: *ImageData, wrapper: js.Object, local: *const js.Local) error{TypeError}!void {
        if (self._pixel_format != .rgba_unorm8) return;
        const data_value = self._data.value(local);
        if (wrapper.defineOwnProperty("data", data_value, js.v8.ReadOnly) != true) {
            return error.TypeError;
        }
    }

    pub const constructor = bridge.constructor(ImageData.construct, .{});

    pub const width = bridge.accessor(ImageData.getWidth, null, .{});
    pub const height = bridge.accessor(ImageData.getHeight, null, .{});
    pub const colorSpace = bridge.accessor(ImageData.getColorSpace, null, .{});
    pub const data = bridge.accessor(ImageData.getData, null, .{});
    pub const pixelFormat = bridge.accessor(ImageData.getPixelFormat, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ImageData" {
    try testing.htmlRunner("image_data.html", .{});
}
