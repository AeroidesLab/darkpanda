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
const lp = @import("darkpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const DOMException = @import("DOMException.zig");

const String = lp.String;
const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/ImageData/ImageData
const ImageData = @This();
_width: u32,
_height: u32,
_color_space: ColorSpace,
_pixel_format: PixelFormat,
_data: Data,

const ColorSpace = enum(u8) {
    srgb,
    display_p3,

    fn toString(self: ColorSpace) []const u8 {
        return switch (self) {
            .srgb => "srgb",
            .display_p3 => "display-p3",
        };
    }
};

const PixelFormat = enum(u8) {
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

pub const ConstructorSettings = struct {
    /// Specifies the color space of the image data.
    /// Can be set to "srgb" for the sRGB color space or "display-p3" for the display-p3 color space.
    colorSpace: String = .wrap("srgb"),
    /// Specifies the pixel format.
    /// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/createImageData#pixelformat
    pixelFormat: String = .wrap("rgba-unorm8"),
};

const ParsedSettings = struct {
    color_space: ColorSpace,
    pixel_format: PixelFormat,
};

fn parseSettingsRaw(maybe_settings: ?ConstructorSettings) !ParsedSettings {
    const settings = maybe_settings orelse ConstructorSettings{};
    const color_space: ColorSpace = if (settings.colorSpace.eql(comptime .wrap("srgb")))
        .srgb
    else if (settings.colorSpace.eql(comptime .wrap("display-p3")))
        .display_p3
    else
        return error.InvalidColorSpace;

    const pixel_format: PixelFormat = if (settings.pixelFormat.eql(comptime .wrap("rgba-unorm8")))
        .rgba_unorm8
    else if (settings.pixelFormat.eql(comptime .wrap("rgba-float16")))
        .rgba_float16
    else if (settings.pixelFormat.eql(comptime .wrap("rgba-float32")))
        .rgba_float32
    else
        return error.InvalidPixelFormat;

    return .{ .color_space = color_space, .pixel_format = pixel_format };
}

fn parseSettings(maybe_settings: ?ConstructorSettings) !ParsedSettings {
    return parseSettingsRaw(maybe_settings) catch return error.TypeError;
}

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

fn parseConstructorSettings(maybe_settings: ?ConstructorSettings, exec: *Execution) !ParsedSettings {
    return parseSettingsRaw(maybe_settings) catch |err| switch (err) {
        error.InvalidColorSpace => {
            const value = (maybe_settings orelse ConstructorSettings{}).colorSpace.str();
            const reason = try std.fmt.allocPrint(
                exec.call_arena,
                "The provided value '{s}' is not a valid enum value of the type PredefinedColorSpace.",
                .{value},
            );
            return throwConstructorTypeError(exec, reason, reason);
        },
        error.InvalidPixelFormat => {
            const value = (maybe_settings orelse ConstructorSettings{}).pixelFormat.str();
            const stack_reason = try std.fmt.allocPrint(
                exec.call_arena,
                "The provided value '{s}' is not a valid enum value of type ImageDataPixelFormat.",
                .{value},
            );
            const message_reason = try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to read the 'pixelFormat' property from 'ImageDataSettings': {s}",
                .{stack_reason},
            );
            return throwConstructorTypeError(exec, stack_reason, message_reason);
        },
    };
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
pub fn init(
    width: u32,
    height: u32,
    maybe_settings: ?ConstructorSettings,
    exec: *Execution,
) !*ImageData {
    const size = try checkedElementCount(width, height);
    const settings = try parseSettings(maybe_settings);
    const local = exec.js.local.?;

    return exec._factory.create(ImageData{
        ._width = width,
        ._height = height,
        ._color_space = settings.color_space,
        ._pixel_format = settings.pixel_format,
        ._data = try allocateData(local, settings.pixel_format, size),
    });
}

fn initConstructor(
    width: u32,
    height: u32,
    maybe_settings: ?ConstructorSettings,
    exec: *Execution,
) !*ImageData {
    const settings = try parseConstructorSettings(maybe_settings, exec);
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

fn settingsFromValue(value: ?js.Value) !?ConstructorSettings {
    const supplied = value orelse return null;
    if (supplied.isNullOrUndefined()) return null;
    return try supplied.toZig(ConstructorSettings);
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
        const width = try first.local.jsValueToZig(u32, second);
        const fourth_is_undefined = fourth == null or fourth.?.isUndefined();
        const maybe_height: ?u32 = if (third) |height|
            if (height.isUndefined() and fourth_is_undefined)
                null
            else
                try height.local.jsValueToZig(u32, height)
        else
            null;
        const settings = try parseConstructorSettings(try settingsFromValue(fourth), exec);

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

    const width = try first.local.jsValueToZig(u32, first);
    const height = try second.local.jsValueToZig(u32, second);
    return initConstructor(width, height, try settingsFromValue(third), exec);
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

pub fn rgbaUnorm8Mutable(self: *ImageData, local: *const js.Local) ![]u8 {
    return switch (self._data) {
        .rgba_unorm8 => |data| data.local(local).slice(),
        else => error.InvalidStateError,
    };
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
