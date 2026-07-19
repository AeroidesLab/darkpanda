// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("../../js/js.zig");

const color = @import("../../color.zig");

const Canvas = @import("../element/html/Canvas.zig");
const ImageData = @import("../ImageData.zig");
const CanvasSurface = @import("../../canvas_backend/Surface.zig");

const Execution = js.Execution;

/// This class doesn't implement a `constructor`.
/// It can be obtained with a call to `HTMLCanvasElement#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D
const CanvasRenderingContext2D = @This();
/// Reference to the parent canvas element.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/canvas
_canvas: *Canvas,
/// Last dimensions observed by this context.  A dimension mutation through
/// setAttribute() bypasses the reflected width/height setters, so every state
/// or bitmap operation compares these values before proceeding.
_observed_width: u32,
_observed_height: u32,
/// Fill color.
/// TODO: Add support for `CanvasGradient` and `CanvasPattern`.
_fill_style: color.RGBA = color.RGBA.Named.black,
_global_alpha: f64 = 1,
_font: []const u8 = "10px sans-serif",
_global_composite_operation: []const u8 = "source-over",
_stroke_style: color.RGBA = color.RGBA.Named.black,
_line_width: f64 = 1,
_line_cap: []const u8 = "butt",
_line_join: []const u8 = "miter",
_miter_limit: f64 = 10,
_text_align: []const u8 = "start",
_text_baseline: []const u8 = "alphabetic",
_direction: []const u8 = "ltr",
_font_kerning: []const u8 = "auto",
_font_stretch: []const u8 = "normal",
_font_variant_caps: []const u8 = "normal",
_text_rendering: []const u8 = "auto",
_image_smoothing_quality: []const u8 = "low",
_shadow_color: color.RGBA = color.RGBA.Named.transparent,
_image_smoothing_enabled: bool = true,
_shadow_offset_x: f64 = 0,
_shadow_offset_y: f64 = 0,
_shadow_blur: f64 = 0,
_line_dash_offset: f64 = 0,
_line_dash: []const f64 = &.{},
_state_stack: std.ArrayList(SavedState) = .empty,

const SavedState = struct {
    fill_style: color.RGBA,
    global_alpha: f64,
    font: []const u8,
    global_composite_operation: []const u8,
    stroke_style: color.RGBA,
    line_width: f64,
    line_cap: []const u8,
    line_join: []const u8,
    miter_limit: f64,
    text_align: []const u8,
    text_baseline: []const u8,
    direction: []const u8,
    font_kerning: []const u8,
    font_stretch: []const u8,
    font_variant_caps: []const u8,
    text_rendering: []const u8,
    image_smoothing_quality: []const u8,
    shadow_color: color.RGBA,
    image_smoothing_enabled: bool,
    shadow_offset_x: f64,
    shadow_offset_y: f64,
    shadow_blur: f64,
    line_dash_offset: f64,
    line_dash: []const f64,
};

pub fn init(canvas: *Canvas) CanvasRenderingContext2D {
    const width = canvas.getWidth();
    const height = canvas.getHeight();
    // Parsed width/height content attributes can predate getContext(), while
    // the Canvas struct starts with the HTML default dimensions.
    canvas.resetBitmapStorage(width, height);
    return .{
        ._canvas = canvas,
        ._observed_width = width,
        ._observed_height = height,
    };
}

fn resetDrawingState(self: *CanvasRenderingContext2D) void {
    self._fill_style = color.RGBA.Named.black;
    self._global_alpha = 1;
    self._font = "10px sans-serif";
    self._global_composite_operation = "source-over";
    self._stroke_style = color.RGBA.Named.black;
    self._line_width = 1;
    self._line_cap = "butt";
    self._line_join = "miter";
    self._miter_limit = 10;
    self._text_align = "start";
    self._text_baseline = "alphabetic";
    self._direction = "ltr";
    self._font_kerning = "auto";
    self._font_stretch = "normal";
    self._font_variant_caps = "normal";
    self._text_rendering = "auto";
    self._image_smoothing_quality = "low";
    self._shadow_color = color.RGBA.Named.transparent;
    self._image_smoothing_enabled = true;
    self._shadow_offset_x = 0;
    self._shadow_offset_y = 0;
    self._shadow_blur = 0;
    self._line_dash_offset = 0;
    self._line_dash = &.{};
}

/// Called by HTMLCanvasElement's reflected dimension setters.  This is
/// deliberately unconditional because `canvas.width = canvas.width` also
/// resets the bitmap and the context state in Chrome.
pub fn onCanvasResize(self: *CanvasRenderingContext2D, width: u32, height: u32) void {
    self._observed_width = width;
    self._observed_height = height;
    self.resetDrawingState();
    self._state_stack.clearRetainingCapacity();
}

fn syncCanvasDimensions(self: *CanvasRenderingContext2D) void {
    const width = self._canvas.getWidth();
    const height = self._canvas.getHeight();
    if (width == self._observed_width and height == self._observed_height) return;

    self._canvas.resetBitmapStorage(width, height);
    self.onCanvasResize(width, height);
}

pub fn getCanvas(self: *const CanvasRenderingContext2D) *Canvas {
    return self._canvas;
}

pub fn getFillStyle(self: *CanvasRenderingContext2D, exec: *Execution) ![]const u8 {
    self.syncCanvasDimensions();
    var w = std.Io.Writer.Allocating.init(exec.call_arena);
    try self._fill_style.format(&w.writer);
    return w.written();
}

pub fn setFillStyle(
    self: *CanvasRenderingContext2D,
    value: []const u8,
    _: *Execution,
) !void {
    self.syncCanvasDimensions();
    // Prefer the same fill_style if fails.
    self._fill_style = color.RGBA.parse(value) catch self._fill_style;
}

pub fn getGlobalAlpha(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._global_alpha;
}

pub fn setGlobalAlpha(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    // HTML Canvas silently ignores non-finite and out-of-range assignments.
    if (!std.math.isFinite(value) or value < 0 or value > 1) return;
    self._global_alpha = value;
}

pub fn getFont(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._font;
}

pub fn setFont(self: *CanvasRenderingContext2D, value: []const u8, exec: *Execution) !void {
    self.syncCanvasDimensions();
    const trimmed = std.mem.trim(u8, value, " \t\r\n\x0c");
    // A full CSS font shorthand parser belongs in the style layer.  Reject the
    // definitely-invalid forms here while retaining ordinary CSS shorthands.
    if (trimmed.len == 0 or std.mem.indexOfAny(u8, trimmed, "0123456789") == null) return;
    self._font = try exec.dupeString(trimmed);
}

pub fn getGlobalCompositeOperation(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._global_composite_operation;
}

pub fn setGlobalCompositeOperation(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{
        "source-over",    "source-in",       "source-out",       "source-atop", "destination-over",
        "destination-in", "destination-out", "destination-atop", "lighter",     "copy",
        "xor",            "multiply",        "screen",           "overlay",     "darken",
        "lighten",        "color-dodge",     "color-burn",       "hard-light",  "soft-light",
        "difference",     "exclusion",       "hue",              "saturation",  "color",
        "luminosity",
    }) |operation| {
        if (std.mem.eql(u8, value, operation)) {
            self._global_composite_operation = operation;
            return;
        }
    }
}

pub fn getStrokeStyle(self: *CanvasRenderingContext2D, exec: *Execution) ![]const u8 {
    self.syncCanvasDimensions();
    var writer = std.Io.Writer.Allocating.init(exec.call_arena);
    try self._stroke_style.format(&writer.writer);
    return writer.written();
}

pub fn setStrokeStyle(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    self._stroke_style = color.RGBA.parse(value) catch self._stroke_style;
}

pub fn getLineWidth(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._line_width;
}

pub fn setLineWidth(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(value) or value <= 0) return;
    self._line_width = value;
}

pub fn getLineCap(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._line_cap;
}

pub fn setLineCap(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{ "butt", "round", "square" }) |line_cap| {
        if (std.mem.eql(u8, value, line_cap)) {
            self._line_cap = line_cap;
            return;
        }
    }
}

pub fn getLineJoin(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._line_join;
}

pub fn setLineJoin(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{ "round", "bevel", "miter" }) |line_join| {
        if (std.mem.eql(u8, value, line_join)) {
            self._line_join = line_join;
            return;
        }
    }
}

pub fn getMiterLimit(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._miter_limit;
}

pub fn setMiterLimit(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(value) or value <= 0) return;
    self._miter_limit = value;
}

pub fn getTextAlign(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._text_align;
}

pub fn setTextAlign(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{ "start", "end", "left", "right", "center" }) |text_align| {
        if (std.mem.eql(u8, value, text_align)) {
            self._text_align = text_align;
            return;
        }
    }
}

pub fn getTextBaseline(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._text_baseline;
}

pub fn setTextBaseline(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{ "top", "hanging", "middle", "alphabetic", "ideographic", "bottom" }) |text_baseline| {
        if (std.mem.eql(u8, value, text_baseline)) {
            self._text_baseline = text_baseline;
            return;
        }
    }
}

pub fn getDirection(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._direction;
}

pub fn setDirection(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{ "ltr", "rtl" }) |direction| {
        if (std.mem.eql(u8, value, direction)) {
            self._direction = direction;
            return;
        }
    }
    // With no CSS/layout direction backend, Canvas's inherited direction is
    // the document default, which is ltr in the profile we currently expose.
    if (std.mem.eql(u8, value, "inherit")) self._direction = "ltr";
}

pub fn getFontKerning(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._font_kerning;
}

pub fn setFontKerning(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{ "auto", "normal", "none" }) |keyword| {
        if (std.mem.eql(u8, value, keyword)) {
            self._font_kerning = keyword;
            return;
        }
    }
}

pub fn getFontStretch(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._font_stretch;
}

pub fn setFontStretch(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{
        "ultra-condensed", "extra-condensed", "condensed",      "semi-condensed", "normal",
        "semi-expanded",   "expanded",        "extra-expanded", "ultra-expanded",
    }) |keyword| {
        if (std.mem.eql(u8, value, keyword)) {
            self._font_stretch = keyword;
            return;
        }
    }
}

pub fn getFontVariantCaps(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._font_variant_caps;
}

pub fn setFontVariantCaps(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{
        "normal",  "small-caps",   "all-small-caps", "petite-caps", "all-petite-caps",
        "unicase", "titling-caps",
    }) |keyword| {
        if (std.mem.eql(u8, value, keyword)) {
            self._font_variant_caps = keyword;
            return;
        }
    }
}

pub fn getTextRendering(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._text_rendering;
}

pub fn setTextRendering(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{ "auto", "optimizeSpeed", "optimizeLegibility", "geometricPrecision" }) |keyword| {
        if (std.mem.eql(u8, value, keyword)) {
            self._text_rendering = keyword;
            return;
        }
    }
}

pub fn getImageSmoothingQuality(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._image_smoothing_quality;
}

pub fn setImageSmoothingQuality(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    inline for (.{ "low", "medium", "high" }) |keyword| {
        if (std.mem.eql(u8, value, keyword)) {
            self._image_smoothing_quality = keyword;
            return;
        }
    }
}

pub fn getShadowColor(self: *CanvasRenderingContext2D, exec: *Execution) ![]const u8 {
    self.syncCanvasDimensions();
    var writer = std.Io.Writer.Allocating.init(exec.call_arena);
    try self._shadow_color.format(&writer.writer);
    return writer.written();
}

pub fn setShadowColor(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.syncCanvasDimensions();
    self._shadow_color = color.RGBA.parse(value) catch self._shadow_color;
}

pub fn getImageSmoothingEnabled(self: *CanvasRenderingContext2D) bool {
    self.syncCanvasDimensions();
    return self._image_smoothing_enabled;
}

pub fn setImageSmoothingEnabled(self: *CanvasRenderingContext2D, value: bool) void {
    self.syncCanvasDimensions();
    self._image_smoothing_enabled = value;
}

pub fn getShadowOffsetX(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._shadow_offset_x;
}

pub fn setShadowOffsetX(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (std.math.isFinite(value)) self._shadow_offset_x = value;
}

pub fn getShadowOffsetY(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._shadow_offset_y;
}

pub fn setShadowOffsetY(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (std.math.isFinite(value)) self._shadow_offset_y = value;
}

pub fn getShadowBlur(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._shadow_blur;
}

pub fn setShadowBlur(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (std.math.isFinite(value) and value >= 0) self._shadow_blur = value;
}

pub fn getLineDashOffset(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._line_dash_offset;
}

pub fn setLineDashOffset(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (std.math.isFinite(value)) self._line_dash_offset = value;
}

const WidthOrImageData = union(enum) {
    width: i32,
    image_data: *ImageData,
};

pub fn createImageData(
    _: *const CanvasRenderingContext2D,
    width_or_image_data: WidthOrImageData,
    /// If `ImageData` variant preferred, this is null.
    maybe_height: ?i32,
    /// Can be used if width and height provided.
    maybe_settings: ?ImageData.ConstructorSettings,
    exec: *Execution,
) !*ImageData {
    switch (width_or_image_data) {
        .width => |width| {
            const height = maybe_height orelse return error.TypeError;
            const normalized_width: i64 = if (width < 0) -@as(i64, width) else width;
            const normalized_height: i64 = if (height < 0) -@as(i64, height) else height;
            return ImageData.init(@intCast(normalized_width), @intCast(normalized_height), maybe_settings, exec);
        },
        .image_data => |image_data| {
            return ImageData.init(image_data._width, image_data._height, null, exec);
        },
    }
}

pub fn putImageData(
    self: *CanvasRenderingContext2D,
    image_data: *ImageData,
    dx: i32,
    dy: i32,
    maybe_dirty_x: ?i32,
    maybe_dirty_y: ?i32,
    maybe_dirty_width: ?i32,
    maybe_dirty_height: ?i32,
    exec: *Execution,
) !void {
    self.syncCanvasDimensions();

    const source_width: i64 = image_data._width;
    const source_height: i64 = image_data._height;
    const source = try image_data.rgbaUnorm8(exec.js.local.?, exec.call_arena);
    const expected_len = try std.math.mul(usize, @as(usize, image_data._width), @as(usize, image_data._height));
    if (source.len < try std.math.mul(usize, expected_len, 4)) return error.InvalidStateError;

    var dirty_x: i64 = 0;
    var dirty_y: i64 = 0;
    var dirty_width: i64 = source_width;
    var dirty_height: i64 = source_height;
    if (maybe_dirty_x) |x| {
        dirty_x = x;
        dirty_y = maybe_dirty_y orelse return error.TypeError;
        dirty_width = maybe_dirty_width orelse return error.TypeError;
        dirty_height = maybe_dirty_height orelse return error.TypeError;
    } else if (maybe_dirty_y != null or maybe_dirty_width != null or maybe_dirty_height != null) {
        return error.TypeError;
    }

    if (dirty_width == 0 or dirty_height == 0) return;
    if (dirty_width < 0) {
        dirty_x += dirty_width;
        dirty_width = -dirty_width;
    }
    if (dirty_height < 0) {
        dirty_y += dirty_height;
        dirty_height = -dirty_height;
    }

    const source_left = @max(@as(i64, 0), dirty_x);
    const source_top = @max(@as(i64, 0), dirty_y);
    const source_right = @min(source_width, dirty_x + dirty_width);
    const source_bottom = @min(source_height, dirty_y + dirty_height);
    if (source_left >= source_right or source_top >= source_bottom) return;

    const canvas_width: i64 = self._observed_width;
    const canvas_height: i64 = self._observed_height;
    if (canvas_width == 0 or canvas_height == 0) return;

    // Clip after translation so the backend receives one strict in-bounds
    // write. The conversion boundary is deliberately straight -> premul.
    const copy_left = @max(source_left, -@as(i64, dx));
    const copy_top = @max(source_top, -@as(i64, dy));
    const copy_right = @min(source_right, canvas_width - @as(i64, dx));
    const copy_bottom = @min(source_bottom, canvas_height - @as(i64, dy));
    if (copy_left >= copy_right or copy_top >= copy_bottom) return;

    const copy_width: usize = @intCast(copy_right - copy_left);
    const copy_height: usize = @intCast(copy_bottom - copy_top);
    const row_bytes = try std.math.mul(usize, copy_width, 4);
    const premultiplied = try exec.call_arena.alloc(
        u8,
        try std.math.mul(usize, row_bytes, copy_height),
    );
    for (0..copy_height) |row| {
        for (0..copy_width) |column| {
            const source_x = copy_left + @as(i64, @intCast(column));
            const source_y = copy_top + @as(i64, @intCast(row));
            const source_index: usize = @intCast((source_y * source_width + source_x) * 4);
            const straight: *const [4]u8 = @ptrCast(source.ptr + source_index);
            const pixel = CanvasSurface.premultiplyPixel(straight);
            const destination_index = row * row_bytes + column * 4;
            @memcpy(premultiplied[destination_index .. destination_index + 4], &pixel);
        }
    }

    const surface = (try self._canvas.ensureSurface()) orelse return;
    try surface.writePixels(
        @intCast(@as(i64, dx) + copy_left),
        @intCast(@as(i64, dy) + copy_top),
        @intCast(copy_width),
        @intCast(copy_height),
        premultiplied,
        row_bytes,
    );
}

// CanvasImageSource (HTMLImageElement, HTMLCanvasElement, ImageBitmap, ...) is
// just taken as a js.Value for now since we don't use it, and that's much easier.
pub fn drawImage(_: *const CanvasRenderingContext2D, _: js.Value, _: f64, _: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {}

pub fn getImageData(
    self: *CanvasRenderingContext2D,
    sx_arg: i32,
    sy_arg: i32,
    sw: i32,
    sh: i32,
    exec: *Execution,
) !*ImageData {
    self.syncCanvasDimensions();
    if (sw == 0 or sh == 0) return error.IndexSizeError;

    var sx: i64 = sx_arg;
    var sy: i64 = sy_arg;
    var width: i64 = sw;
    var height: i64 = sh;
    if (width < 0) {
        sx += width;
        width = -width;
    }
    if (height < 0) {
        sy += height;
        height = -height;
    }

    const image_data = try ImageData.init(@intCast(width), @intCast(height), null, exec);
    const destination = try image_data.rgbaUnorm8Mutable(exec.js.local.?);
    const canvas_width: i64 = self._observed_width;
    const canvas_height: i64 = self._observed_height;
    const source_left = @max(sx, 0);
    const source_top = @max(sy, 0);
    const source_right = @min(sx + width, canvas_width);
    const source_bottom = @min(sy + height, canvas_height);
    if (source_left >= source_right or source_top >= source_bottom) return image_data;

    const read_width: usize = @intCast(source_right - source_left);
    const read_height: usize = @intCast(source_bottom - source_top);
    const row_bytes = try std.math.mul(usize, read_width, 4);
    const premultiplied = try exec.call_arena.alloc(
        u8,
        try std.math.mul(usize, row_bytes, read_height),
    );
    const surface = (try self._canvas.ensureSurface()) orelse return image_data;
    try surface.readPixels(
        @intCast(source_left),
        @intCast(source_top),
        @intCast(read_width),
        @intCast(read_height),
        premultiplied,
        row_bytes,
    );

    const destination_x: usize = @intCast(source_left - sx);
    const destination_y: usize = @intCast(source_top - sy);
    const destination_width: usize = @intCast(width);
    for (0..read_height) |row| {
        for (0..read_width) |column| {
            const source_index = row * row_bytes + column * 4;
            const stored: *const [4]u8 = @ptrCast(premultiplied.ptr + source_index);
            const pixel = CanvasSurface.unpremultiplyPixel(stored);
            const destination_index = ((destination_y + row) * destination_width + destination_x + column) * 4;
            @memcpy(destination[destination_index .. destination_index + 4], &pixel);
        }
    }
    return image_data;
}

const ClippedRect = struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
};

fn clippedRect(x: f64, y: f64, width: f64, height: f64, canvas_width: u32, canvas_height: u32) ?ClippedRect {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(width) or !std.math.isFinite(height) or
        width == 0 or height == 0 or canvas_width == 0 or canvas_height == 0)
    {
        return null;
    }

    const x2 = x + width;
    const y2 = y + height;
    if (!std.math.isFinite(x2) or !std.math.isFinite(y2)) return null;

    const max_x: f64 = @floatFromInt(canvas_width);
    const max_y: f64 = @floatFromInt(canvas_height);
    const left = std.math.clamp(@min(x, x2), 0, max_x);
    const right = std.math.clamp(@max(x, x2), 0, max_x);
    const top = std.math.clamp(@min(y, y2), 0, max_y);
    const bottom = std.math.clamp(@max(y, y2), 0, max_y);
    if (left >= right or top >= bottom) return null;
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn snapshotState(self: *const CanvasRenderingContext2D) SavedState {
    return .{
        .fill_style = self._fill_style,
        .global_alpha = self._global_alpha,
        .font = self._font,
        .global_composite_operation = self._global_composite_operation,
        .stroke_style = self._stroke_style,
        .line_width = self._line_width,
        .line_cap = self._line_cap,
        .line_join = self._line_join,
        .miter_limit = self._miter_limit,
        .text_align = self._text_align,
        .text_baseline = self._text_baseline,
        .direction = self._direction,
        .font_kerning = self._font_kerning,
        .font_stretch = self._font_stretch,
        .font_variant_caps = self._font_variant_caps,
        .text_rendering = self._text_rendering,
        .image_smoothing_quality = self._image_smoothing_quality,
        .shadow_color = self._shadow_color,
        .image_smoothing_enabled = self._image_smoothing_enabled,
        .shadow_offset_x = self._shadow_offset_x,
        .shadow_offset_y = self._shadow_offset_y,
        .shadow_blur = self._shadow_blur,
        .line_dash_offset = self._line_dash_offset,
        .line_dash = self._line_dash,
    };
}

fn applyState(self: *CanvasRenderingContext2D, state: SavedState) void {
    self._fill_style = state.fill_style;
    self._global_alpha = state.global_alpha;
    self._font = state.font;
    self._global_composite_operation = state.global_composite_operation;
    self._stroke_style = state.stroke_style;
    self._line_width = state.line_width;
    self._line_cap = state.line_cap;
    self._line_join = state.line_join;
    self._miter_limit = state.miter_limit;
    self._text_align = state.text_align;
    self._text_baseline = state.text_baseline;
    self._direction = state.direction;
    self._font_kerning = state.font_kerning;
    self._font_stretch = state.font_stretch;
    self._font_variant_caps = state.font_variant_caps;
    self._text_rendering = state.text_rendering;
    self._image_smoothing_quality = state.image_smoothing_quality;
    self._shadow_color = state.shadow_color;
    self._image_smoothing_enabled = state.image_smoothing_enabled;
    self._shadow_offset_x = state.shadow_offset_x;
    self._shadow_offset_y = state.shadow_offset_y;
    self._shadow_blur = state.shadow_blur;
    self._line_dash_offset = state.line_dash_offset;
    self._line_dash = state.line_dash;
}

pub fn save(self: *CanvasRenderingContext2D, exec: *Execution) !void {
    self.syncCanvasDimensions();
    try self._state_stack.append(exec.arena, self.snapshotState());
}

pub fn restore(self: *CanvasRenderingContext2D) void {
    self.syncCanvasDimensions();
    if (self._state_stack.pop()) |state| self.applyState(state);
}

pub fn getLineDash(self: *CanvasRenderingContext2D) []const f64 {
    self.syncCanvasDimensions();
    return self._line_dash;
}

pub fn setLineDash(self: *CanvasRenderingContext2D, segments: []const f64, exec: *Execution) !void {
    self.syncCanvasDimensions();
    for (segments) |segment| {
        // Chromium silently ignores the complete assignment when one member
        // is negative or non-finite.
        if (!std.math.isFinite(segment) or segment < 0) return;
    }

    if (segments.len == 0) {
        self._line_dash = &.{};
        return;
    }
    if (segments.len % 2 == 0) {
        self._line_dash = try exec.arena.dupe(f64, segments);
        return;
    }

    const repeated = try exec.arena.alloc(f64, try std.math.mul(usize, segments.len, 2));
    @memcpy(repeated[0..segments.len], segments);
    @memcpy(repeated[segments.len..], segments);
    self._line_dash = repeated;
}

const ContextAttributes = struct {
    alpha: bool = true,
    colorSpace: []const u8 = "srgb",
    colorType: []const u8 = "unorm8",
    desynchronized: bool = false,
    toneMapping: ToneMapping = .{},
    willReadFrequently: bool = false,

    const ToneMapping = struct {
        mode: []const u8 = "standard",
    };
};

pub fn getContextAttributes(self: *CanvasRenderingContext2D) ContextAttributes {
    self.syncCanvasDimensions();
    return .{};
}

pub fn isContextLost(self: *CanvasRenderingContext2D) bool {
    self.syncCanvasDimensions();
    return if (self._canvas.surface()) |surface| surface.isLost() else false;
}

pub fn reset(self: *CanvasRenderingContext2D) !void {
    self.syncCanvasDimensions();
    try self._canvas.resetSurfaceStorage();
    self.resetDrawingState();
    self._state_stack.clearRetainingCapacity();
}

pub fn scale(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn rotate(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn translate(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn transform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn setTransform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn resetTransform(_: *CanvasRenderingContext2D) void {}
pub fn clearRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) !void {
    self.syncCanvasDimensions();
    _ = clippedRect(x, y, width, height, self._observed_width, self._observed_height) orelse return;
    const surface = (try self._canvas.ensureSurface()) orelse return;
    try surface.clearRect(x, y, width, height);
}

pub fn fillRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) !void {
    self.syncCanvasDimensions();
    if (self._fill_style.a == 0 or self._global_alpha == 0) return;
    _ = clippedRect(x, y, width, height, self._observed_width, self._observed_height) orelse return;
    const surface = (try self._canvas.ensureSurface()) orelse return;
    try surface.fillRect(x, y, width, height, .{
        .r = self._fill_style.r,
        .g = self._fill_style.g,
        .b = self._fill_style.b,
        .a = self._fill_style.a,
    }, self._global_alpha);
}
pub fn strokeRect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn beginPath(_: *CanvasRenderingContext2D) void {}
pub fn closePath(_: *CanvasRenderingContext2D) void {}
pub fn moveTo(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn lineTo(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn quadraticCurveTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn bezierCurveTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn arc(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: ?bool) void {}
pub fn arcTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn rect(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64) void {}
pub fn fill(_: *CanvasRenderingContext2D) void {}
pub fn stroke(_: *CanvasRenderingContext2D) void {}
pub fn clip(_: *CanvasRenderingContext2D) void {}
pub fn fillText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}
pub fn strokeText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(CanvasRenderingContext2D.getCanvas, null, .{});
    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});
    pub const textAlign = bridge.accessor(CanvasRenderingContext2D.getTextAlign, CanvasRenderingContext2D.setTextAlign, .{});
    pub const textBaseline = bridge.accessor(CanvasRenderingContext2D.getTextBaseline, CanvasRenderingContext2D.setTextBaseline, .{});
    pub const direction = bridge.accessor(CanvasRenderingContext2D.getDirection, CanvasRenderingContext2D.setDirection, .{});
    pub const fontKerning = bridge.accessor(CanvasRenderingContext2D.getFontKerning, CanvasRenderingContext2D.setFontKerning, .{});
    pub const fontStretch = bridge.accessor(CanvasRenderingContext2D.getFontStretch, CanvasRenderingContext2D.setFontStretch, .{});
    pub const fontVariantCaps = bridge.accessor(CanvasRenderingContext2D.getFontVariantCaps, CanvasRenderingContext2D.setFontVariantCaps, .{});
    pub const textRendering = bridge.accessor(CanvasRenderingContext2D.getTextRendering, CanvasRenderingContext2D.setTextRendering, .{});
    pub const globalCompositeOperation = bridge.accessor(CanvasRenderingContext2D.getGlobalCompositeOperation, CanvasRenderingContext2D.setGlobalCompositeOperation, .{});
    pub const imageSmoothingQuality = bridge.accessor(CanvasRenderingContext2D.getImageSmoothingQuality, CanvasRenderingContext2D.setImageSmoothingQuality, .{});
    pub const strokeStyle = bridge.accessor(CanvasRenderingContext2D.getStrokeStyle, CanvasRenderingContext2D.setStrokeStyle, .{});
    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const shadowColor = bridge.accessor(CanvasRenderingContext2D.getShadowColor, CanvasRenderingContext2D.setShadowColor, .{});
    pub const lineCap = bridge.accessor(CanvasRenderingContext2D.getLineCap, CanvasRenderingContext2D.setLineCap, .{});
    pub const lineJoin = bridge.accessor(CanvasRenderingContext2D.getLineJoin, CanvasRenderingContext2D.setLineJoin, .{});
    pub const globalAlpha = bridge.accessor(CanvasRenderingContext2D.getGlobalAlpha, CanvasRenderingContext2D.setGlobalAlpha, .{});
    pub const imageSmoothingEnabled = bridge.accessor(CanvasRenderingContext2D.getImageSmoothingEnabled, CanvasRenderingContext2D.setImageSmoothingEnabled, .{});
    pub const shadowOffsetX = bridge.accessor(CanvasRenderingContext2D.getShadowOffsetX, CanvasRenderingContext2D.setShadowOffsetX, .{});
    pub const shadowOffsetY = bridge.accessor(CanvasRenderingContext2D.getShadowOffsetY, CanvasRenderingContext2D.setShadowOffsetY, .{});
    pub const shadowBlur = bridge.accessor(CanvasRenderingContext2D.getShadowBlur, CanvasRenderingContext2D.setShadowBlur, .{});
    pub const lineWidth = bridge.accessor(CanvasRenderingContext2D.getLineWidth, CanvasRenderingContext2D.setLineWidth, .{});
    pub const miterLimit = bridge.accessor(CanvasRenderingContext2D.getMiterLimit, CanvasRenderingContext2D.setMiterLimit, .{});
    pub const lineDashOffset = bridge.accessor(CanvasRenderingContext2D.getLineDashOffset, CanvasRenderingContext2D.setLineDashOffset, .{});

    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{ .noop = true });
    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{});
    pub const drawImage = bridge.function(CanvasRenderingContext2D.drawImage, .{ .noop = true });
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{ .noop = true });
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{ .noop = true });
    pub const getContextAttributes = bridge.function(CanvasRenderingContext2D.getContextAttributes, .{});
    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{});
    pub const getLineDash = bridge.function(CanvasRenderingContext2D.getLineDash, .{});
    pub const isContextLost = bridge.function(CanvasRenderingContext2D.isContextLost, .{});
    pub const reset = bridge.function(CanvasRenderingContext2D.reset, .{});
    pub const setLineDash = bridge.function(CanvasRenderingContext2D.setLineDash, .{});
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{ .noop = true });

    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{ .noop = true });
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{ .noop = true });
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{ .noop = true });
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{ .noop = true });
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{ .noop = true });
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{ .noop = true });
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{ .noop = true });
    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{});
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{ .noop = true });
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{ .noop = true });
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{ .noop = true });
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{});
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{ .noop = true });
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{});
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{ .noop = true });
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{ .noop = true });
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{ .noop = true });
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{ .noop = true });
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{ .noop = true });
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{ .noop = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}
