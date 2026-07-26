const std = @import("std");

const adapter = @import("../../canvas_backend/adapter.zig");

pub const BackendKind = adapter.BackendKind;
pub const RGBA8 = adapter.RGBA8;
pub const Blend = adapter.Blend;
pub const StyleKind = adapter.StyleKind;
pub const GradientKind = adapter.GradientKind;
pub const PatternRepetition = adapter.PatternRepetition;
pub const StyleHandle = adapter.StyleHandle;
pub const ReadPixelFormat = adapter.ReadPixelFormat;
pub const ColorSpace = adapter.ColorSpace;

pub const max_dimension: u32 = 32_768;
pub const max_surface_bytes: usize = 512 * 1024 * 1024;

const Surface = @This();

allocator: std.mem.Allocator,
kind: BackendKind,
width: u32,
height: u32,
flags: u32,
profile_seed: u64,
canvas_seed: u64,
implementation: Implementation,
fault: ?anyerror = null,

fn isOpaque(self: *const Surface) bool {
    return self.flags & adapter.SurfaceFlag.OPAQUE != 0;
}

const Implementation = union(enum) {
    dynamic: adapter.OwnedSurface,
    software: []u8,
};

/// chrome-skia ABI v5 backend: full Canvas 2D state machine.
pub fn initDynamic(
    allocator: std.mem.Allocator,
    api: *const adapter.Api,
    kind: BackendKind,
    width: u32,
    height: u32,
    flags: u32,
    profile_seed: u64,
    canvas_seed: u64,
) !Surface {
    _ = try validateDimensions(width, height, flags);
    var owned = try api.create(&.{
        .backend_kind = @enumFromInt(@intFromEnum(kind)),
        .width = width,
        .height = height,
        .flags = flags,
        .profile_seed = profile_seed,
        .canvas_seed = canvas_seed,
    });
    errdefer owned.deinit() catch {};

    const info = try owned.info();
    if (@intFromEnum(info.backend_kind) != @intFromEnum(kind) or info.width != width or info.height != height or
        info.pixel_format != .rgba8_premul_srgb or
        info.profile_seed != profile_seed or info.canvas_seed != canvas_seed)
    {
        return error.CanvasBackendContractMismatch;
    }

    return .{
        .allocator = allocator,
        .kind = kind,
        .width = width,
        .height = height,
        .flags = flags,
        .profile_seed = profile_seed,
        .canvas_seed = canvas_seed,
        .implementation = .{ .dynamic = owned },
    };
}

pub fn initSoftware(
    allocator: std.mem.Allocator,
    kind: BackendKind,
    width: u32,
    height: u32,
    flags: u32,
    profile_seed: u64,
    canvas_seed: u64,
) !Surface {
    const pixels = try allocateSoftwarePixels(
        allocator,
        kind,
        width,
        height,
        flags,
        profile_seed,
        canvas_seed,
    );
    return .{
        .allocator = allocator,
        .kind = kind,
        .width = width,
        .height = height,
        .flags = flags,
        .profile_seed = profile_seed,
        .canvas_seed = canvas_seed,
        .implementation = .{ .software = pixels },
    };
}

pub fn deinit(self: *Surface) !void {
    switch (self.implementation) {
        .dynamic => |*owned| try owned.deinit(),
        .software => |pixels| self.allocator.free(pixels),
    }
    self.* = undefined;
}

pub fn markFault(self: *Surface, err: anyerror) void {
    if (self.fault == null) self.fault = err;
}

pub fn isLost(self: *const Surface) bool {
    return self.fault != null;
}

pub fn requireHealthy(self: *const Surface) !void {
    if (self.fault) |err| return err;
}

pub fn resize(self: *Surface, width: u32, height: u32) !void {
    try self.requireHealthy();
    _ = try validateDimensions(width, height, self.flags);
    switch (self.implementation) {
        .dynamic => |*owned| try owned.resize(width, height),
        .software => |old_pixels| {
            const replacement = try allocateSoftwarePixels(
                self.allocator,
                self.kind,
                width,
                height,
                self.flags,
                self.profile_seed,
                self.canvas_seed,
            );
            self.allocator.free(old_pixels);
            self.implementation = .{ .software = replacement };
        },
    }
    self.width = width;
    self.height = height;
}

pub fn clear(self: *Surface, color: RGBA8) !void {
    try self.requireHealthy();
    switch (self.implementation) {
        .dynamic => |*owned| {
            // No whole-surface clear in v3: composite kSrc + fillRect, state untouched.
            try owned.save();
            defer owned.restore() catch {};
            try owned.setGlobalCompositeOperation(.src);
            try owned.setFillStyleColor(color);
            try owned.fillRect(0, 0, @floatFromInt(self.width), @floatFromInt(self.height));
        },
        .software => |pixels| {
            const effective = if (self.isOpaque())
                RGBA8{ .r = color.r, .g = color.g, .b = color.b, .a = 255 }
            else
                color;
            const premultiplied = premultiply(effective);
            var offset: usize = 0;
            while (offset < pixels.len) : (offset += 4) {
                @memcpy(pixels[offset .. offset + 4], &premultiplied);
            }
        },
    }
}

pub fn clearRect(self: *Surface, x: f64, y: f64, width: f64, height: f64) !void {
    try self.requireHealthy();
    switch (self.implementation) {
        .dynamic => |*owned| try owned.clearRect(x, y, width, height),
        .software => |pixels| if (self.isOpaque())
            try fillSoftwareRect(
                pixels,
                self.width,
                self.height,
                x,
                y,
                width,
                height,
                .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                1,
            )
        else
            try clearSoftwareRect(
                pixels,
                self.width,
                self.height,
                x,
                y,
                width,
                height,
            ),
    }
}

pub fn fillRect(
    self: *Surface,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    color: RGBA8,
    opacity: f64,
) !void {
    try self.requireHealthy();
    if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) {
        return error.InvalidCanvasOpacity;
    }
    switch (self.implementation) {
        .dynamic => |*owned| {
            try owned.save();
            defer owned.restore() catch {};
            try owned.setGlobalAlpha(opacity);
            try owned.setFillStyleColor(color);
            try owned.fillRect(x, y, width, height);
        },
        .software => |pixels| try fillSoftwareRect(
            pixels,
            self.width,
            self.height,
            x,
            y,
            width,
            height,
            color,
            opacity,
        ),
    }
}

/// Access the chrome-skia ABI v5 state machine, when this surface is ABI v5-backed.
/// Returns null for the software fallback; callers should degrade to the
/// legacy noop behaviour in that case.
pub fn backend(self: *Surface) ?*adapter.OwnedSurface {
    return switch (self.implementation) {
        .dynamic => |*owned| owned,
        else => null,
    };
}

pub fn readPixels(
    self: *Surface,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    destination: []u8,
    row_bytes: usize,
) !void {
    try self.requireHealthy();
    try validateRectAndBuffer(
        self.width,
        self.height,
        x,
        y,
        width,
        height,
        destination.len,
        row_bytes,
    );
    switch (self.implementation) {
        .dynamic => |*owned| try owned.readPixels(x, y, width, height, destination, row_bytes),
        .software => |pixels| copyRowsFromSurface(
            pixels,
            self.width,
            x,
            y,
            width,
            height,
            destination,
            row_bytes,
        ),
    }
}

/// Straight-alpha readback used by getImageData's wide-gamut and float pixel
/// formats. The dynamic backend performs both unpremultiplication and color
/// conversion in Skia, before quantizing to the requested element type.
pub fn readPixelsFormat(
    self: *Surface,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    destination: []u8,
    row_bytes: usize,
    format: ReadPixelFormat,
    color_space: ColorSpace,
) !void {
    try self.requireHealthy();
    try validateRectAndBufferWithBpp(
        self.width,
        self.height,
        x,
        y,
        width,
        height,
        destination.len,
        row_bytes,
        format.bytesPerPixel(),
    );
    switch (self.implementation) {
        .dynamic => |*owned| try owned.readPixelsFormat(
            x,
            y,
            width,
            height,
            destination,
            row_bytes,
            format,
            color_space,
        ),
        .software => |pixels| readSoftwarePixelsFormat(
            pixels,
            self.width,
            x,
            y,
            width,
            height,
            destination,
            row_bytes,
            format,
        ),
    }
}

pub fn writePixels(
    self: *Surface,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    source: []const u8,
    row_bytes: usize,
) !void {
    try self.requireHealthy();
    try validateRectAndBuffer(
        self.width,
        self.height,
        x,
        y,
        width,
        height,
        source.len,
        row_bytes,
    );
    switch (self.implementation) {
        .dynamic => |*owned| try owned.writePixels(x, y, width, height, source, row_bytes),
        .software => |pixels| copyRowsToSurface(
            pixels,
            self.width,
            x,
            y,
            width,
            height,
            source,
            row_bytes,
        ),
    }
}

pub fn premultiplyPixel(straight: *const [4]u8) [4]u8 {
    return premultiply(.{
        .r = straight[0],
        .g = straight[1],
        .b = straight[2],
        .a = straight[3],
    });
}

pub fn unpremultiplyPixel(premultiplied: *const [4]u8) [4]u8 {
    const alpha = premultiplied[3];
    if (alpha == 0) return .{ 0, 0, 0, 0 };
    return .{
        unpremultiplyChannel(premultiplied[0], alpha),
        unpremultiplyChannel(premultiplied[1], alpha),
        unpremultiplyChannel(premultiplied[2], alpha),
        alpha,
    };
}

fn premultiply(color: RGBA8) [4]u8 {
    return .{
        premultiplyChannel(color.r, color.a),
        premultiplyChannel(color.g, color.a),
        premultiplyChannel(color.b, color.a),
        color.a,
    };
}

fn premultiplyChannel(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u16, channel) * @as(u16, alpha) + 127) / 255);
}

fn unpremultiplyChannel(channel: u8, alpha: u8) u8 {
    // Match SkConvertPixels' high-precision raster-pipeline path used by
    // Chrome getImageData(): normalize bytes as f32, unpremultiply, scale,
    // then round to nearest-even (the x86 cvtps instruction).
    const inverse_255: f32 = 1.0 / 255.0;
    const component = @as(f32, @floatFromInt(channel)) * inverse_255;
    const normalized_alpha = @as(f32, @floatFromInt(alpha)) * inverse_255;
    const expanded = component * (1.0 / normalized_alpha) * 255.0;
    const lower = @floor(expanded);
    const lower_int: u32 = @intFromFloat(lower);
    const fraction = expanded - lower;
    const rounded = if (fraction > 0.5 or (fraction == 0.5 and lower_int & 1 != 0))
        lower_int + 1
    else
        lower_int;
    return @intCast(@min(rounded, 255));
}

fn validateDimensions(width: u32, height: u32, flags: u32) !usize {
    if (flags & ~adapter.SurfaceFlag.VALID_MASK != 0) return error.InvalidCanvasSurfaceFlags;
    if (width > max_dimension or height > max_dimension) return error.CanvasSizeOverflow;
    const pixels = try std.math.mul(usize, width, height);
    const budget_bpp: usize = if (flags & adapter.SurfaceFlag.FLOAT16 != 0) 8 else 4;
    const budget_bytes = try std.math.mul(usize, pixels, budget_bpp);
    if (budget_bytes > max_surface_bytes) return error.CanvasSizeOverflow;
    // The software fallback and public pixel ABI remain RGBA8 even when the
    // real Skia backing uses F16.
    return std.math.mul(usize, pixels, 4);
}

fn validateRectAndBuffer(
    surface_width: u32,
    surface_height: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    buffer_len: usize,
    row_bytes: usize,
) !void {
    return validateRectAndBufferWithBpp(
        surface_width,
        surface_height,
        x,
        y,
        width,
        height,
        buffer_len,
        row_bytes,
        4,
    );
}

fn validateRectAndBufferWithBpp(
    surface_width: u32,
    surface_height: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    buffer_len: usize,
    row_bytes: usize,
    bytes_per_pixel: usize,
) !void {
    const right = std.math.add(u32, x, width) catch return error.CanvasOutOfBounds;
    const bottom = std.math.add(u32, y, height) catch return error.CanvasOutOfBounds;
    if (right > surface_width or bottom > surface_height) return error.CanvasOutOfBounds;
    const tight = try std.math.mul(usize, width, bytes_per_pixel);
    if (height != 0 and row_bytes < tight) return error.CanvasBufferTooSmall;
    const required = if (width == 0 or height == 0)
        0
    else
        try std.math.add(
            usize,
            try std.math.mul(usize, row_bytes, @as(usize, height) - 1),
            tight,
        );
    if (buffer_len < required) return error.CanvasBufferTooSmall;
}

fn allocateSoftwarePixels(
    allocator: std.mem.Allocator,
    kind: BackendKind,
    width: u32,
    height: u32,
    flags: u32,
    profile_seed: u64,
    canvas_seed: u64,
) ![]u8 {
    const byte_count = try validateDimensions(width, height, flags);
    const pixels = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(pixels);
    switch (kind) {
        .skia => @memset(pixels, 0),
        .fake => seedFakePixels(pixels, width, height, profile_seed, canvas_seed),
    }
    if (flags & adapter.SurfaceFlag.OPAQUE != 0) {
        var alpha_index: usize = 3;
        while (alpha_index < pixels.len) : (alpha_index += 4) {
            pixels[alpha_index] = 255;
        }
    }
    return pixels;
}

fn seedFakePixels(
    pixels: []u8,
    width: u32,
    height: u32,
    profile_seed: u64,
    canvas_seed: u64,
) void {
    const seed = splitMix64(profile_seed ^ std.math.rotl(u64, canvas_seed, 29) ^ 0x4450_4341_4e56_4153);
    for (0..height) |row| {
        for (0..width) |column| {
            const coordinate = (@as(u64, row) << 32) | @as(u64, column);
            const value = splitMix64(seed ^ coordinate *% 0x9e37_79b9_7f4a_7c15);
            const straight: [4]u8 = .{
                @truncate(value),
                @truncate(value >> 8),
                @truncate(value >> 16),
                @truncate(value >> 56),
            };
            const pixel = premultiplyPixel(&straight);
            const offset = (@as(usize, row) * @as(usize, width) + @as(usize, column)) * 4;
            @memcpy(pixels[offset .. offset + 4], &pixel);
        }
    }
}

fn splitMix64(input: u64) u64 {
    var value = input +% 0x9e37_79b9_7f4a_7c15;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

const FloatRect = struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
};

fn normalizedRect(x: f64, y: f64, width: f64, height: f64) !?FloatRect {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(width) or !std.math.isFinite(height))
    {
        return error.InvalidCanvasRect;
    }
    if (width == 0 or height == 0) return null;
    const x2 = x + width;
    const y2 = y + height;
    if (!std.math.isFinite(x2) or !std.math.isFinite(y2)) return error.InvalidCanvasRect;
    return .{
        .left = @min(x, x2),
        .top = @min(y, y2),
        .right = @max(x, x2),
        .bottom = @max(y, y2),
    };
}

fn clippedRect(x: f64, y: f64, width: f64, height: f64, surface_width: u32, surface_height: u32) !?FloatRect {
    const rect = try normalizedRect(x, y, width, height) orelse return null;
    const clipped: FloatRect = .{
        .left = std.math.clamp(rect.left, 0, @as(f64, @floatFromInt(surface_width))),
        .top = std.math.clamp(rect.top, 0, @as(f64, @floatFromInt(surface_height))),
        .right = std.math.clamp(rect.right, 0, @as(f64, @floatFromInt(surface_width))),
        .bottom = std.math.clamp(rect.bottom, 0, @as(f64, @floatFromInt(surface_height))),
    };
    if (clipped.left >= clipped.right or clipped.top >= clipped.bottom) return null;
    return clipped;
}

fn fillSoftwareRect(
    pixels: []u8,
    surface_width: u32,
    surface_height: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    color: RGBA8,
    opacity: f64,
) !void {
    const rect = try clippedRect(x, y, width, height, surface_width, surface_height) orelse return;
    const start_x: usize = @intFromFloat(@floor(rect.left));
    const end_x: usize = @intFromFloat(@ceil(rect.right));
    const start_y: usize = @intFromFloat(@floor(rect.top));
    const end_y: usize = @intFromFloat(@ceil(rect.bottom));
    for (start_y..end_y) |pixel_y| {
        const pixel_top: f64 = @floatFromInt(pixel_y);
        const y_coverage = std.math.clamp(
            @min(rect.bottom, pixel_top + 1) - @max(rect.top, pixel_top),
            0,
            1,
        );
        for (start_x..end_x) |pixel_x| {
            const pixel_left: f64 = @floatFromInt(pixel_x);
            const x_coverage = std.math.clamp(
                @min(rect.right, pixel_left + 1) - @max(rect.left, pixel_left),
                0,
                1,
            );
            const effective_alpha: u8 = @intFromFloat(@round(
                @as(f64, @floatFromInt(color.a)) * opacity * x_coverage * y_coverage,
            ));
            if (effective_alpha == 0) continue;
            const source = premultiply(.{
                .r = color.r,
                .g = color.g,
                .b = color.b,
                .a = effective_alpha,
            });
            const offset = (pixel_y * @as(usize, surface_width) + pixel_x) * 4;
            sourceOver(pixels[offset .. offset + 4], source);
        }
    }
}

fn clearSoftwareRect(
    pixels: []u8,
    surface_width: u32,
    surface_height: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) !void {
    const rect = try clippedRect(x, y, width, height, surface_width, surface_height) orelse return;
    const start_x: usize = @intFromFloat(@floor(rect.left));
    const end_x: usize = @intFromFloat(@ceil(rect.right));
    const start_y: usize = @intFromFloat(@floor(rect.top));
    const end_y: usize = @intFromFloat(@ceil(rect.bottom));
    for (start_y..end_y) |pixel_y| {
        const centre_y = @as(f64, @floatFromInt(pixel_y)) + 0.5;
        if (centre_y < rect.top or centre_y >= rect.bottom) continue;
        for (start_x..end_x) |pixel_x| {
            const centre_x = @as(f64, @floatFromInt(pixel_x)) + 0.5;
            if (centre_x < rect.left or centre_x >= rect.right) continue;
            const offset = (pixel_y * @as(usize, surface_width) + pixel_x) * 4;
            @memset(pixels[offset .. offset + 4], 0);
        }
    }
}

fn sourceOver(destination: []u8, source: [4]u8) void {
    const inverse_alpha = 255 - @as(u16, source[3]);
    for (0..3) |channel| {
        const kept = (@as(u16, destination[channel]) * inverse_alpha + 127) / 255;
        destination[channel] = @intCast(@min(@as(u16, source[channel]) + kept, 255));
    }
    const kept_alpha = (@as(u16, destination[3]) * inverse_alpha + 127) / 255;
    destination[3] = @intCast(@min(@as(u16, source[3]) + kept_alpha, 255));
}

fn copyRowsFromSurface(
    surface: []const u8,
    surface_width: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    destination: []u8,
    destination_row_bytes: usize,
) void {
    const tight = @as(usize, width) * 4;
    const surface_row_bytes = @as(usize, surface_width) * 4;
    for (0..height) |row| {
        const source_offset = (@as(usize, y) + row) * surface_row_bytes + @as(usize, x) * 4;
        const destination_offset = row * destination_row_bytes;
        @memcpy(
            destination[destination_offset .. destination_offset + tight],
            surface[source_offset .. source_offset + tight],
        );
    }
}

fn readSoftwarePixelsFormat(
    surface: []const u8,
    surface_width: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    destination: []u8,
    destination_row_bytes: usize,
    format: ReadPixelFormat,
) void {
    const surface_row_bytes = @as(usize, surface_width) * 4;
    const output_bpp = format.bytesPerPixel();
    for (0..height) |row| {
        for (0..width) |column| {
            const source_offset =
                (@as(usize, y) + row) * surface_row_bytes +
                (@as(usize, x) + column) * 4;
            const source: *const [4]u8 = @ptrCast(surface.ptr + source_offset);
            const straight = unpremultiplyPixel(source);
            const output_offset = row * destination_row_bytes + column * output_bpp;
            switch (format) {
                .rgba8_unorm => @memcpy(
                    destination[output_offset .. output_offset + 4],
                    &straight,
                ),
                .rgba_float16 => for (straight, 0..) |channel, component| {
                    const value: f16 = @floatCast(
                        @as(f32, @floatFromInt(channel)) / 255.0,
                    );
                    const component_offset = output_offset + component * @sizeOf(f16);
                    @memcpy(
                        destination[component_offset .. component_offset + @sizeOf(f16)],
                        std.mem.asBytes(&value),
                    );
                },
                .rgba_float32 => for (straight, 0..) |channel, component| {
                    const value = @as(f32, @floatFromInt(channel)) / 255.0;
                    const component_offset = output_offset + component * @sizeOf(f32);
                    @memcpy(
                        destination[component_offset .. component_offset + @sizeOf(f32)],
                        std.mem.asBytes(&value),
                    );
                },
            }
        }
    }
}

fn copyRowsToSurface(
    surface: []u8,
    surface_width: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    source: []const u8,
    source_row_bytes: usize,
) void {
    const tight = @as(usize, width) * 4;
    const surface_row_bytes = @as(usize, surface_width) * 4;
    for (0..height) |row| {
        const source_offset = row * source_row_bytes;
        const destination_offset = (@as(usize, y) + row) * surface_row_bytes + @as(usize, x) * 4;
        @memcpy(
            surface[destination_offset .. destination_offset + tight],
            source[source_offset .. source_offset + tight],
        );
    }
}

test "premultiply and unpremultiply match Chrome 149 ImageData quantization" {
    // Direct integer division rounds this tie up to 77; Skia's float32
    // raster pipeline rounds it to even (76), as observed in Chrome 149.
    try std.testing.expectEqual(@as(u8, 76), unpremultiplyChannel(42, 140));

    const Case = struct { straight: [4]u8, observable: [4]u8 };
    const cases = [_]Case{
        .{ .straight = .{ 1, 2, 3, 0 }, .observable = .{ 0, 0, 0, 0 } },
        .{ .straight = .{ 255, 1, 128, 1 }, .observable = .{ 255, 0, 255, 1 } },
        .{ .straight = .{ 1, 128, 255, 2 }, .observable = .{ 0, 128, 255, 2 } },
        .{ .straight = .{ 127, 128, 129, 3 }, .observable = .{ 85, 170, 170, 3 } },
        .{ .straight = .{ 17, 99, 201, 7 }, .observable = .{ 0, 109, 219, 7 } },
        .{ .straight = .{ 1, 2, 3, 127 }, .observable = .{ 0, 2, 2, 127 } },
        .{ .straight = .{ 254, 128, 1, 128 }, .observable = .{ 253, 128, 2, 128 } },
        .{ .straight = .{ 1, 127, 255, 254 }, .observable = .{ 1, 128, 255, 254 } },
    };
    for (cases) |case| {
        const premultiplied = premultiplyPixel(&case.straight);
        try std.testing.expectEqual(case.observable, unpremultiplyPixel(&premultiplied));
    }
}

test "all valid premultiplied channels survive Chrome 149 roundtrip" {
    for (1..256) |alpha_value| {
        const alpha: u8 = @intCast(alpha_value);
        var previous: u8 = 0;
        for (0..alpha_value + 1) |channel_value| {
            const channel: u8 = @intCast(channel_value);
            const straight = unpremultiplyChannel(channel, alpha);
            try std.testing.expect(straight >= previous);
            try std.testing.expectEqual(channel, premultiplyChannel(straight, alpha));
            previous = straight;
        }
    }
}

test "software fake is seeded, stable, and uses one coherent surface" {
    var first = try Surface.initSoftware(std.testing.allocator, .fake, 2, 1, 0, 11, 22);
    defer first.deinit() catch unreachable;
    var second = try Surface.initSoftware(std.testing.allocator, .fake, 2, 1, 0, 11, 22);
    defer second.deinit() catch unreachable;
    var different = try Surface.initSoftware(std.testing.allocator, .fake, 2, 1, 0, 11, 23);
    defer different.deinit() catch unreachable;

    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    var c: [8]u8 = undefined;
    try first.readPixels(0, 0, 2, 1, &a, 8);
    try second.readPixels(0, 0, 2, 1, &b, 8);
    try different.readPixels(0, 0, 2, 1, &c, 8);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));

    try first.clearRect(0, 0, 1, 1);
    try first.readPixels(0, 0, 2, 1, &b, 8);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, b[0..4]);
    try std.testing.expectEqualSlices(u8, a[4..8], b[4..8]);
}
