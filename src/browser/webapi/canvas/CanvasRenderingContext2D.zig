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
const HTMLImage = @import("../element/html/Image.zig");
const OffscreenCanvas = @import("OffscreenCanvas.zig");
const ImageData = @import("../ImageData.zig");
const CanvasException = @import("CanvasException.zig");
const CanvasFillRule = @import("CanvasFillRule.zig");
const CanvasFilter = @import("CanvasFilter.zig");
const CanvasGradient = @import("CanvasGradient.zig");
const CanvasLineDash = @import("CanvasLineDash.zig");
const CanvasMatrix2DInit = @import("CanvasMatrix2DInit.zig");
const CanvasPattern = @import("CanvasPattern.zig");
const CanvasRadii = @import("CanvasRadii.zig");
const ContextOptions = @import("ContextOptions.zig");
const TextMetrics = @import("TextMetrics.zig");
const DOMMatrix = @import("../DOMMatrix.zig");
const CanvasSurface = @import("../../canvas_backend/Surface.zig");
const adapter = @import("../../../canvas_backend/adapter.zig");

const Execution = js.Execution;

/// This class doesn't implement a `constructor`.
/// It can be obtained with a call to `HTMLCanvasElement#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D
const CanvasRenderingContext2D = @This();
/// Reference to the parent canvas element.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/canvas
_canvas: *Canvas,
_context_attributes: ContextOptions.Attributes,
/// Last dimensions observed by this context.  A dimension mutation through
/// setAttribute() bypasses the reflected width/height setters, so every state
/// or bitmap operation compares these values before proceeding.
_observed_width: u32,
_observed_height: u32,
/// fillStyle / strokeStyle tri-state: CSS color | CanvasGradient | CanvasPattern.
_fill_style: Style = .{ .color = .{ .rgba = color.RGBA.Named.black, .f = .{ 0, 0, 0, 1 } } },
_stroke_style: Style = .{ .color = .{ .rgba = color.RGBA.Named.black, .f = .{ 0, 0, 0, 1 } } },
_global_alpha: f64 = 1,
_font: []const u8 = "10px sans-serif",
_global_composite_operation: []const u8 = "source-over",
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
_shadow_color: color.RGBA.Float = .{ .rgba = color.RGBA.Named.transparent, .f = .{ 0, 0, 0, 0 } },
_image_smoothing_enabled: bool = true,
_shadow_offset_x: f64 = 0,
_shadow_offset_y: f64 = 0,
_shadow_blur: f64 = 0,
_line_dash_offset: f64 = 0,
_line_dash: []const f64 = &.{},
/// Exact accepted source string plus its atomically parsed renderer chain.
_filter: []const u8 = "none",
_filter_operations: []const CanvasFilter.Operation = &.{},
_letter_spacing: []const u8 = "0px",
_word_spacing: []const u8 = "0px",
_lang: []const u8 = "",
/// Current transformation matrix [a,b,c,d,e,f], tracked JS-side for getTransform
/// (the dynamic backend keeps its own matrix for rasterization).
_ctm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
/// Set when a state change could not reach the backend (no ABI v5 surface yet);
/// the next backend access bulk-applies the whole drawing state.
_backend_state_dirty: bool = false,
/// Number of save() calls that reached the backend. restore() only pops the
/// backend stack when this is non-zero; otherwise it re-applies the restored
/// JS state wholesale via the dirty path. Keeps the two stacks consistent
/// even when save() ran before the surface existed.
_backend_save_depth: u32 = 0,
_state_stack: std.ArrayList(SavedState) = .empty,

/// Style union exposed to JS (getter returns string | gradient | pattern).
pub const Style = union(enum) {
    color: color.RGBA.Float,
    gradient: *CanvasGradient,
    pattern: *CanvasPattern,
};

const SavedState = struct {
    fill_style: Style,
    stroke_style: Style,
    global_alpha: f64,
    font: []const u8,
    global_composite_operation: []const u8,
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
    shadow_color: color.RGBA.Float,
    image_smoothing_enabled: bool,
    shadow_offset_x: f64,
    shadow_offset_y: f64,
    shadow_blur: f64,
    line_dash_offset: f64,
    line_dash: []const f64,
    filter: []const u8,
    filter_operations: []const CanvasFilter.Operation,
    letter_spacing: []const u8,
    word_spacing: []const u8,
    lang: []const u8,
    ctm: [6]f64,
};

pub fn init(
    canvas: *Canvas,
    attributes: ContextOptions.Attributes,
) CanvasRenderingContext2D {
    const width = canvas.getWidth();
    const height = canvas.getHeight();
    // Parsed width/height content attributes can predate getContext(), while
    // the Canvas struct starts with the HTML default dimensions.
    canvas.resetBitmapStorage(width, height);
    return .{
        ._canvas = canvas,
        ._context_attributes = attributes,
        ._observed_width = width,
        ._observed_height = height,
    };
}

fn resetDrawingState(self: *CanvasRenderingContext2D) void {
    self._fill_style = .{ .color = .{ .rgba = color.RGBA.Named.black, .f = .{ 0, 0, 0, 1 } } };
    self._stroke_style = .{ .color = .{ .rgba = color.RGBA.Named.black, .f = .{ 0, 0, 0, 1 } } };
    self._global_alpha = 1;
    self._font = "10px sans-serif";
    self._global_composite_operation = "source-over";
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
    self._shadow_color = .{ .rgba = color.RGBA.Named.transparent, .f = .{ 0, 0, 0, 0 } };
    self._image_smoothing_enabled = true;
    self._shadow_offset_x = 0;
    self._shadow_offset_y = 0;
    self._shadow_blur = 0;
    self._line_dash_offset = 0;
    self._line_dash = &.{};
    self._filter = "none";
    self._filter_operations = &.{};
    self._letter_spacing = "0px";
    self._word_spacing = "0px";
    self._lang = "";
    self._ctm = .{ 1, 0, 0, 1, 0, 0 };
    self._backend_state_dirty = false;
}

/// Called for every HTMLCanvasElement width/height content-attribute mutation.
/// This is deliberately unconditional because both `canvas.width =
/// canvas.width` and `setAttribute("width", theCurrentValue)` reset the bitmap
/// and context state in Chrome.
pub fn onCanvasResize(self: *CanvasRenderingContext2D, width: u32, height: u32) void {
    self._observed_width = width;
    self._observed_height = height;
    self.resetDrawingState();
    self._state_stack.clearRetainingCapacity();
    self._backend_save_depth = 0;
}

fn syncCanvasDimensions(self: *CanvasRenderingContext2D) void {
    const width = self._canvas.getWidth();
    const height = self._canvas.getHeight();
    if (width == self._observed_width and height == self._observed_height) return;

    self._canvas.resetBitmapStorage(width, height);
    self.onCanvasResize(width, height);
}

/// Map a globalCompositeOperation string to the ABI blend enum + the canonical
/// string literal (JS argument slices are not retained); null = invalid.
fn blendOp(value: []const u8) ?struct { []const u8, adapter.Blend } {
    const map = .{
        .{ "source-over", adapter.Blend.src_over },      .{ "source-in", adapter.Blend.src_in },
        .{ "source-out", adapter.Blend.src_out },        .{ "source-atop", adapter.Blend.src_atop },
        .{ "destination-over", adapter.Blend.dst_over }, .{ "destination-in", adapter.Blend.dst_in },
        .{ "destination-out", adapter.Blend.dst_out },   .{ "destination-atop", adapter.Blend.dst_atop },
        .{ "lighter", adapter.Blend.plus },              .{ "copy", adapter.Blend.src },
        .{ "xor", adapter.Blend.xor },                   .{ "multiply", adapter.Blend.multiply },
        .{ "screen", adapter.Blend.screen },             .{ "overlay", adapter.Blend.overlay },
        .{ "darken", adapter.Blend.darken },             .{ "lighten", adapter.Blend.lighten },
        .{ "color-dodge", adapter.Blend.color_dodge },   .{ "color-burn", adapter.Blend.color_burn },
        .{ "hard-light", adapter.Blend.hard_light },     .{ "soft-light", adapter.Blend.soft_light },
        .{ "difference", adapter.Blend.difference },     .{ "exclusion", adapter.Blend.exclusion },
        .{ "hue", adapter.Blend.hue },                   .{ "saturation", adapter.Blend.saturation },
        .{ "color", adapter.Blend.color },               .{ "luminosity", adapter.Blend.luminosity },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, value, entry[0])) return .{ entry[0], entry[1] };
    }
    return null;
}

fn smoothingQuality(value: []const u8) i32 {
    if (std.mem.eql(u8, value, "medium")) return 1;
    if (std.mem.eql(u8, value, "high")) return 2;
    return 0;
}

fn lineCapValue(value: []const u8) i32 {
    if (std.mem.eql(u8, value, "round")) return 1;
    if (std.mem.eql(u8, value, "square")) return 2;
    return 0;
}

fn lineJoinValue(value: []const u8) i32 {
    if (std.mem.eql(u8, value, "round")) return 1;
    if (std.mem.eql(u8, value, "bevel")) return 2;
    return 0;
}

fn rgbaOf(c: color.RGBA) adapter.RGBA8 {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

fn backendColorSpace(value: color.RGBA.ColorSpace) adapter.ColorSpace {
    return @enumFromInt(@intFromEnum(value));
}

fn pushFillStyle(self: *CanvasRenderingContext2D, owned: *adapter.OwnedSurface, surface: *CanvasSurface) !void {
    switch (self._fill_style) {
        .color => |c| try owned.setFillStyleColorSpaceF(&c.f, backendColorSpace(c.color_space)),
        .gradient => |g| {
            if (try g.realize(surface)) |h| {
                try owned.setFillStyleObject(.gradient, h);
            } else {
                const transparent: [4]f32 = .{ 0, 0, 0, 0 };
                try owned.setFillStyleColorSpaceF(&transparent, .srgb);
            }
        },
        .pattern => |p| if (try p.realize(surface)) |h| {
            try owned.setFillStyleObject(.pattern, h);
        },
    }
}

fn pushStrokeStyle(self: *CanvasRenderingContext2D, owned: *adapter.OwnedSurface, surface: *CanvasSurface) !void {
    switch (self._stroke_style) {
        .color => |c| try owned.setStrokeStyleColorSpaceF(&c.f, backendColorSpace(c.color_space)),
        .gradient => |g| {
            if (try g.realize(surface)) |h| {
                try owned.setStrokeStyleObject(.gradient, h);
            } else {
                const transparent: [4]f32 = .{ 0, 0, 0, 0 };
                try owned.setStrokeStyleColorSpaceF(&transparent, .srgb);
            }
        },
        .pattern => |p| if (try p.realize(surface)) |h| {
            try owned.setStrokeStyleObject(.pattern, h);
        },
    }
}

/// Push the whole JS drawing state to the backend (used after the backend
/// surface was (re)created while state setters ran without it).
fn applyStateToBackend(self: *CanvasRenderingContext2D, owned: *adapter.OwnedSurface, surface: *CanvasSurface) !void {
    try self.pushFillStyle(owned, surface);
    try self.pushStrokeStyle(owned, surface);
    try owned.setGlobalAlpha(self._global_alpha);
    if (blendOp(self._global_composite_operation)) |entry| try owned.setGlobalCompositeOperation(entry[1]);
    try owned.setLineWidth(self._line_width);
    try owned.setLineCap(lineCapValue(self._line_cap));
    try owned.setLineJoin(lineJoinValue(self._line_join));
    try owned.setMiterLimit(self._miter_limit);
    try pushLineDash(owned, self._line_dash, self._line_dash_offset);
    try owned.setImageSmoothingQuality(smoothingQuality(self._image_smoothing_quality));
    try owned.setShadowF(self._shadow_blur, self._shadow_offset_x, self._shadow_offset_y, &self._shadow_color.f);
    try owned.setFilter(self._filter_operations);
    const m = self._ctm;
    try owned.setTransform(m[0], m[1], m[2], m[3], m[4], m[5]);
}

fn pushLineDash(owned: *adapter.OwnedSurface, dash: []const f64, phase: f64) !void {
    if (dash.len == 0) return owned.setLineDash(&.{}, phase);
    const converted = try std.heap.page_allocator.alloc(f32, dash.len);
    defer std.heap.page_allocator.free(converted);
    for (dash, converted) |value, *out| out.* = @floatCast(value);
    try owned.setLineDash(converted, phase);
}

/// The dynamic backend surface for this context, or null for software
/// fallback. Bulk-applies JS drawing state when setters ran without one.
fn backend(self: *CanvasRenderingContext2D) ?*adapter.OwnedSurface {
    self.syncCanvasDimensions();
    const surface = (self._canvas.ensureSurface() catch return null) orelse return null;
    const owned = surface.backend() orelse return null;
    if (self._backend_state_dirty) {
        self.applyStateToBackend(owned, surface) catch {};
        self._backend_state_dirty = false;
    }
    return owned;
}

pub fn getCanvas(self: *const CanvasRenderingContext2D) *Canvas {
    return self._canvas;
}

/// fillStyle getter: string for colors, the object itself for gradient/pattern.
pub const StyleReturn = union(enum) {
    string: []const u8,
    gradient: *CanvasGradient,
    pattern: *CanvasPattern,
};

pub fn getFillStyle(self: *CanvasRenderingContext2D, exec: *Execution) !StyleReturn {
    self.syncCanvasDimensions();
    switch (self._fill_style) {
        .color => |c| {
            var w = std.Io.Writer.Allocating.init(exec.call_arena);
            try c.format(&w.writer);
            return .{ .string = w.written() };
        },
        .gradient => |g| return .{ .gradient = g },
        .pattern => |p| return .{ .pattern = p },
    }
}

pub const StyleArg = union(enum) {
    string: []const u8,
    gradient: *CanvasGradient,
    pattern: *CanvasPattern,
};

pub fn setFillStyle(self: *CanvasRenderingContext2D, value: StyleArg, _: *Execution) !void {
    self.syncCanvasDimensions();
    switch (value) {
        .string => |s| {
            // Invalid colors are ignored, keeping the previous style.
            self._fill_style = .{ .color = color.RGBA.parseFloat(s) catch return };
        },
        .gradient => |g| self._fill_style = .{ .gradient = g },
        .pattern => |p| self._fill_style = .{ .pattern = p },
    }
    if (self.backend()) |owned| {
        const surface = self._canvas.surface() orelse return;
        self.pushFillStyle(owned, surface) catch {};
    } else {
        self._backend_state_dirty = true;
    }
}

pub fn getStrokeStyle(self: *CanvasRenderingContext2D, exec: *Execution) !StyleReturn {
    self.syncCanvasDimensions();
    switch (self._stroke_style) {
        .color => |c| {
            var writer = std.Io.Writer.Allocating.init(exec.call_arena);
            try c.format(&writer.writer);
            return .{ .string = writer.written() };
        },
        .gradient => |g| return .{ .gradient = g },
        .pattern => |p| return .{ .pattern = p },
    }
}

pub fn setStrokeStyle(self: *CanvasRenderingContext2D, value: StyleArg, _: *Execution) !void {
    self.syncCanvasDimensions();
    switch (value) {
        .string => |s| {
            self._stroke_style = .{ .color = color.RGBA.parseFloat(s) catch return };
        },
        .gradient => |g| self._stroke_style = .{ .gradient = g },
        .pattern => |p| self._stroke_style = .{ .pattern = p },
    }
    if (self.backend()) |owned| {
        const surface = self._canvas.surface() orelse return;
        self.pushStrokeStyle(owned, surface) catch {};
    } else {
        self._backend_state_dirty = true;
    }
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
    if (self.backend()) |owned| {
        owned.setGlobalAlpha(value) catch {};
    } else {
        self._backend_state_dirty = true;
    }
}

pub fn getFont(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._font;
}

pub fn setFont(self: *CanvasRenderingContext2D, value: js.DOMString, exec: *Execution) !void {
    self.syncCanvasDimensions();
    const trimmed = std.mem.trim(u8, value.value, " \t\r\n\x0c");
    // A full CSS font shorthand parser belongs in the style layer.  Reject the
    // definitely-invalid forms here while retaining ordinary CSS shorthands.
    if (trimmed.len == 0 or std.mem.indexOfAny(u8, trimmed, "0123456789") == null) return;
    self._font = try exec.dupeString(trimmed);
}

pub fn getGlobalCompositeOperation(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._global_composite_operation;
}

pub fn setGlobalCompositeOperation(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    const entry = blendOp(value.value) orelse return;
    self._global_composite_operation = entry[0];
    if (self.backend()) |owned| {
        owned.setGlobalCompositeOperation(entry[1]) catch {};
    } else {
        self._backend_state_dirty = true;
    }
}

pub fn getLineWidth(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._line_width;
}

pub fn setLineWidth(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(value) or value <= 0) return;
    self._line_width = value;
    if (self.backend()) |owned| {
        owned.setLineWidth(value) catch {};
    } else {
        self._backend_state_dirty = true;
    }
}

pub fn getLineCap(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._line_cap;
}

pub fn setLineCap(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{ "butt", "round", "square" }) |line_cap| {
        if (std.mem.eql(u8, value.value, line_cap)) {
            self._line_cap = line_cap;
            if (self.backend()) |owned| {
                owned.setLineCap(lineCapValue(line_cap)) catch {};
            } else {
                self._backend_state_dirty = true;
            }
            return;
        }
    }
}

pub fn getLineJoin(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._line_join;
}

pub fn setLineJoin(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{ "round", "bevel", "miter" }) |line_join| {
        if (std.mem.eql(u8, value.value, line_join)) {
            self._line_join = line_join;
            if (self.backend()) |owned| {
                owned.setLineJoin(lineJoinValue(line_join)) catch {};
            } else {
                self._backend_state_dirty = true;
            }
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
    if (self.backend()) |owned| {
        owned.setMiterLimit(value) catch {};
    } else {
        self._backend_state_dirty = true;
    }
}

pub fn getTextAlign(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._text_align;
}

pub fn setTextAlign(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{ "start", "end", "left", "right", "center" }) |text_align| {
        if (std.mem.eql(u8, value.value, text_align)) {
            self._text_align = text_align;
            return;
        }
    }
}

pub fn getTextBaseline(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._text_baseline;
}

pub fn setTextBaseline(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{ "top", "hanging", "middle", "alphabetic", "ideographic", "bottom" }) |text_baseline| {
        if (std.mem.eql(u8, value.value, text_baseline)) {
            self._text_baseline = text_baseline;
            return;
        }
    }
}

pub fn getDirection(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._direction;
}

pub fn setDirection(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{ "ltr", "rtl" }) |direction| {
        if (std.mem.eql(u8, value.value, direction)) {
            self._direction = direction;
            return;
        }
    }
    // With no CSS/layout direction backend, Canvas's inherited direction is
    // the document default, which is ltr in the profile we currently expose.
    if (std.mem.eql(u8, value.value, "inherit")) self._direction = "ltr";
}

pub fn getFontKerning(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._font_kerning;
}

pub fn setFontKerning(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{ "auto", "normal", "none" }) |keyword| {
        if (std.mem.eql(u8, value.value, keyword)) {
            self._font_kerning = keyword;
            return;
        }
    }
}

pub fn getFontStretch(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._font_stretch;
}

pub fn setFontStretch(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{
        "ultra-condensed", "extra-condensed", "condensed",      "semi-condensed", "normal",
        "semi-expanded",   "expanded",        "extra-expanded", "ultra-expanded",
    }) |keyword| {
        if (std.mem.eql(u8, value.value, keyword)) {
            self._font_stretch = keyword;
            return;
        }
    }
}

pub fn getFontVariantCaps(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._font_variant_caps;
}

pub fn setFontVariantCaps(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{
        "normal",  "small-caps",   "all-small-caps", "petite-caps", "all-petite-caps",
        "unicase", "titling-caps",
    }) |keyword| {
        if (std.mem.eql(u8, value.value, keyword)) {
            self._font_variant_caps = keyword;
            return;
        }
    }
}

pub fn getTextRendering(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._text_rendering;
}

pub fn setTextRendering(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{ "auto", "optimizeSpeed", "optimizeLegibility", "geometricPrecision" }) |keyword| {
        if (std.mem.eql(u8, value.value, keyword)) {
            self._text_rendering = keyword;
            return;
        }
    }
}

pub fn getImageSmoothingQuality(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._image_smoothing_quality;
}

pub fn setImageSmoothingQuality(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    inline for (.{ "low", "medium", "high" }) |keyword| {
        if (std.mem.eql(u8, value.value, keyword)) {
            self._image_smoothing_quality = keyword;
            if (self.backend()) |owned| {
                owned.setImageSmoothingQuality(smoothingQuality(keyword)) catch {};
            } else {
                self._backend_state_dirty = true;
            }
            return;
        }
    }
}

pub fn getShadowColor(self: *CanvasRenderingContext2D, exec: *Execution) ![]const u8 {
    self.syncCanvasDimensions();
    var writer = std.Io.Writer.Allocating.init(exec.call_arena);
    try self._shadow_color.rgba.format(&writer.writer);
    return writer.written();
}

pub fn setShadowColor(self: *CanvasRenderingContext2D, value: js.DOMString) void {
    self.syncCanvasDimensions();
    self._shadow_color = color.RGBA.parseFloat(value.value) catch self._shadow_color;
    self.pushShadow();
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
    if (std.math.isFinite(value)) {
        self._shadow_offset_x = value;
        self.pushShadow();
    }
}

pub fn getShadowOffsetY(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._shadow_offset_y;
}

pub fn setShadowOffsetY(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (std.math.isFinite(value)) {
        self._shadow_offset_y = value;
        self.pushShadow();
    }
}

pub fn getShadowBlur(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._shadow_blur;
}

pub fn setShadowBlur(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (std.math.isFinite(value) and value >= 0) {
        self._shadow_blur = value;
        self.pushShadow();
    }
}

fn pushShadow(self: *CanvasRenderingContext2D) void {
    if (self.backend()) |owned| {
        owned.setShadowF(self._shadow_blur, self._shadow_offset_x, self._shadow_offset_y, &self._shadow_color.f) catch {};
    } else {
        self._backend_state_dirty = true;
    }
}

pub fn getLineDashOffset(self: *CanvasRenderingContext2D) f64 {
    self.syncCanvasDimensions();
    return self._line_dash_offset;
}

pub fn setLineDashOffset(self: *CanvasRenderingContext2D, value: f64) void {
    self.syncCanvasDimensions();
    if (std.math.isFinite(value)) {
        self._line_dash_offset = value;
        if (self.backend()) |owned| {
            pushLineDash(owned, self._line_dash, value) catch {};
        } else {
            self._backend_state_dirty = true;
        }
    }
}

pub fn createImageData(
    _: *const CanvasRenderingContext2D,
    args: []const js.Value,
    exec: *Execution,
) !*ImageData {
    return ImageData.createForCanvas(args, .canvas, exec);
}

pub fn putImageData(
    self: *CanvasRenderingContext2D,
    args: []const js.Value,
    exec: *Execution,
) !void {
    if (args.len != 3 and args.len < 7) {
        return CanvasException.typeError(
            exec,
            .canvas,
            "putImageData",
            "Overload resolution failed.",
        );
    }

    const image_data = args[0].local.jsValueToZig(*ImageData, args[0]) catch |err| {
        if (err == error.InvalidArgument) {
            return js.WebIDL.argumentNotOfType(
                exec,
                .{ .operation = .{
                    .interface = "CanvasRenderingContext2D",
                    .name = "putImageData",
                } },
                0,
                "ImageData",
            );
        }
        return err;
    };

    self.syncCanvasDimensions();
    const dx = try ImageData.canvasLong(args[1], .canvas, "putImageData", exec);
    const dy = try ImageData.canvasLong(args[2], .canvas, "putImageData", exec);

    const converted_dirty: ?[4]i32 = if (args.len >= 7) .{
        try ImageData.canvasLong(args[3], .canvas, "putImageData", exec),
        try ImageData.canvasLong(args[4], .canvas, "putImageData", exec),
        try ImageData.canvasLong(args[5], .canvas, "putImageData", exec),
        try ImageData.canvasLong(args[6], .canvas, "putImageData", exec),
    } else null;

    const source_width: i64 = image_data._width;
    const source_height: i64 = image_data._height;
    const source = try image_data.rgbaUnorm8(exec.js.local.?, exec.call_arena);
    const expected_len = try std.math.mul(usize, @as(usize, image_data._width), @as(usize, image_data._height));
    if (source.len < try std.math.mul(usize, expected_len, 4)) {
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "putImageData",
            "InvalidStateError",
            "The source data has been detached.",
        );
    }

    var dirty_x: i64 = if (converted_dirty) |dirty| dirty[0] else 0;
    var dirty_y: i64 = if (converted_dirty) |dirty| dirty[1] else 0;
    var dirty_width: i64 = if (converted_dirty) |dirty| dirty[2] else source_width;
    var dirty_height: i64 = if (converted_dirty) |dirty| dirty[3] else source_height;

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

const ImageSource = union(enum) {
    canvas: *Canvas,
    offscreen: *OffscreenCanvas,
    html_image: *HTMLImage,
};

const canvas_image_source_reason = "The provided value is not of type '(CSSImageValue or HTMLCanvasElement or HTMLImageElement or HTMLVideoElement or ImageBitmap or OffscreenCanvas or SVGImageElement or VideoFrame)'.";

fn resolveImageSource(
    value: js.Value,
    operation: []const u8,
    exec: *Execution,
) !ImageSource {
    if (value.isObject()) {
        if (value.local.jsValueToZig(*Canvas, value) catch null) |canvas| {
            return .{ .canvas = canvas };
        }
        if (value.local.jsValueToZig(*OffscreenCanvas, value) catch null) |canvas| {
            return .{ .offscreen = canvas };
        }
        if (value.local.jsValueToZig(*HTMLImage, value) catch null) |image| {
            return .{ .html_image = image };
        }
    }
    return CanvasException.typeError(
        exec,
        .canvas,
        operation,
        canvas_image_source_reason,
    );
}

fn imageSourceWidth(source: ImageSource) u32 {
    return switch (source) {
        .canvas => |canvas| canvas.getWidth(),
        .offscreen => |canvas| canvas.getWidth(),
        .html_image => 0,
    };
}

fn imageSourceHeight(source: ImageSource) u32 {
    return switch (source) {
        .canvas => |canvas| canvas.getHeight(),
        .offscreen => |canvas| canvas.getHeight(),
        .html_image => 0,
    };
}

fn zeroSizeCanvasSourceReason(source: ImageSource) ?[]const u8 {
    if (imageSourceWidth(source) != 0 and imageSourceHeight(source) != 0) return null;
    return switch (source) {
        .canvas => "The image argument is a canvas element with a width or height of 0.",
        .offscreen => "The image argument is an OffscreenCanvas element with a width or height of 0.",
        .html_image => null,
    };
}

fn imageSourceSurface(source: ImageSource) !?*CanvasSurface {
    return switch (source) {
        .canvas => |canvas| blk: {
            try canvas.syncBitmapDimensions();
            break :blk canvas.surface();
        },
        .offscreen => |canvas| canvas.surface(),
        .html_image => null,
    };
}

fn drawImageNumber(value: js.Value, exec: *Execution) !f64 {
    return js.WebIDL.toNumber(value, exec, .{
        .interface = "CanvasRenderingContext2D",
        .name = "drawImage",
    });
}

const ClippedDrawImageRect = struct {
    source_x: f64,
    source_y: f64,
    source_width: f64,
    source_height: f64,
    destination_x: f64,
    destination_y: f64,
    destination_width: f64,
    destination_height: f64,
};

/// Normalize negative dimensions without mirroring, then clip the source
/// rectangle to the source bitmap and apply the same proportional clipping to
/// the destination rectangle.
fn clippedDrawImageRect(
    source_bitmap_width: u32,
    source_bitmap_height: u32,
    source_x_arg: f64,
    source_y_arg: f64,
    source_width_arg: f64,
    source_height_arg: f64,
    destination_x_arg: f64,
    destination_y_arg: f64,
    destination_width_arg: f64,
    destination_height_arg: f64,
) ?ClippedDrawImageRect {
    var source_x = source_x_arg;
    var source_y = source_y_arg;
    var source_width = source_width_arg;
    var source_height = source_height_arg;
    var destination_x = destination_x_arg;
    var destination_y = destination_y_arg;
    var destination_width = destination_width_arg;
    var destination_height = destination_height_arg;

    if (source_width < 0) {
        source_x += source_width;
        source_width = -source_width;
    }
    if (source_height < 0) {
        source_y += source_height;
        source_height = -source_height;
    }
    if (destination_width < 0) {
        destination_x += destination_width;
        destination_width = -destination_width;
    }
    if (destination_height < 0) {
        destination_y += destination_height;
        destination_height = -destination_height;
    }
    if (source_width == 0 or source_height == 0 or
        destination_width == 0 or destination_height == 0)
    {
        return null;
    }

    const bitmap_right: f64 = @floatFromInt(source_bitmap_width);
    const bitmap_bottom: f64 = @floatFromInt(source_bitmap_height);
    const clipped_left = @max(source_x, 0);
    const clipped_top = @max(source_y, 0);
    const clipped_right = @min(source_x + source_width, bitmap_right);
    const clipped_bottom = @min(source_y + source_height, bitmap_bottom);
    if (!(clipped_right > clipped_left) or !(clipped_bottom > clipped_top)) return null;

    const scale_x = destination_width / source_width;
    const scale_y = destination_height / source_height;
    destination_x += (clipped_left - source_x) * scale_x;
    destination_y += (clipped_top - source_y) * scale_y;
    destination_width = (clipped_right - clipped_left) * scale_x;
    destination_height = (clipped_bottom - clipped_top) * scale_y;
    if (!std.math.isFinite(destination_x) or !std.math.isFinite(destination_y) or
        !std.math.isFinite(destination_width) or !std.math.isFinite(destination_height))
    {
        return null;
    }

    return .{
        .source_x = clipped_left,
        .source_y = clipped_top,
        .source_width = clipped_right - clipped_left,
        .source_height = clipped_bottom - clipped_top,
        .destination_x = destination_x,
        .destination_y = destination_y,
        .destination_width = destination_width,
        .destination_height = destination_height,
    };
}

pub fn drawImage(
    self: *CanvasRenderingContext2D,
    args: []const js.Value,
    exec: *Execution,
) !void {
    self.syncCanvasDimensions();
    if (args.len != 3 and args.len != 5 and args.len < 9) {
        return CanvasException.typeError(
            exec,
            .canvas,
            "drawImage",
            "Overload resolution failed.",
        );
    }
    const source = try resolveImageSource(args[0], "drawImage", exec);
    const numeric_count: usize = if (args.len >= 9) 8 else args.len - 1;
    var numbers: [8]f64 = @splat(0);
    for (args[1 .. numeric_count + 1], 0..) |value, index| {
        numbers[index] = try drawImageNumber(value, exec);
    }
    if (zeroSizeCanvasSourceReason(source)) |reason| {
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "drawImage",
            "InvalidStateError",
            reason,
        );
    }
    for (numbers[0..numeric_count]) |number| {
        if (!std.math.isFinite(number)) return;
    }

    var sx: f64 = 0;
    var sy: f64 = 0;
    var sw: f64 = @floatFromInt(imageSourceWidth(source));
    var sh: f64 = @floatFromInt(imageSourceHeight(source));
    var dx: f64 = numbers[0];
    var dy: f64 = numbers[1];
    var dw: f64 = sw;
    var dh: f64 = sh;
    if (numeric_count == 4) {
        dw = numbers[2];
        dh = numbers[3];
    } else if (numeric_count == 8) {
        sx = numbers[0];
        sy = numbers[1];
        sw = numbers[2];
        sh = numbers[3];
        dx = numbers[4];
        dy = numbers[5];
        dw = numbers[6];
        dh = numbers[7];
    }
    const draw_rect = clippedDrawImageRect(
        imageSourceWidth(source),
        imageSourceHeight(source),
        sx,
        sy,
        sw,
        sh,
        dx,
        dy,
        dw,
        dh,
    ) orelse return;

    const owned = self.backend() orelse return;
    const src_surface = imageSourceSurface(source) catch return;
    if (src_surface == null) {
        // The pixels are uniformly transparent, so a 1x1 source is exactly
        // equivalent after scaling and avoids allocating the full logical
        // bitmap (which may be extremely large).
        const transparent = [_]u8{ 0, 0, 0, 0 };
        owned.drawImage(
            transparent[0..],
            1,
            1,
            4,
            0,
            0,
            1,
            1,
            draw_rect.destination_x,
            draw_rect.destination_y,
            draw_rect.destination_width,
            draw_rect.destination_height,
            self._image_smoothing_enabled,
        ) catch return;
        return;
    }

    const source_width = imageSourceWidth(source);
    const source_height = imageSourceHeight(source);
    const row_bytes = std.math.mul(usize, @as(usize, source_width), 4) catch return;
    const pixel_bytes = std.math.mul(usize, row_bytes, @as(usize, source_height)) catch return;
    const pixels = try exec.call_arena.alloc(u8, pixel_bytes);
    src_surface.?.readPixels(
        0,
        0,
        source_width,
        source_height,
        pixels,
        row_bytes,
    ) catch return;
    owned.drawImage(
        pixels,
        source_width,
        source_height,
        row_bytes,
        draw_rect.source_x,
        draw_rect.source_y,
        draw_rect.source_width,
        draw_rect.source_height,
        draw_rect.destination_x,
        draw_rect.destination_y,
        draw_rect.destination_width,
        draw_rect.destination_height,
        self._image_smoothing_enabled,
    ) catch return;
}

fn gradientNumber(value: js.Value, operation: []const u8, exec: *Execution) !f64 {
    const number = try js.WebIDL.toNumber(value, exec, .{
        .interface = "CanvasRenderingContext2D",
        .name = operation,
    });
    if (!std.math.isFinite(number)) {
        return CanvasException.typeError(
            exec,
            .canvas,
            operation,
            "The provided double value is non-finite.",
        );
    }
    return number;
}

pub fn createLinearGradient(self: *CanvasRenderingContext2D, args: []const js.Value, exec: *Execution) !*CanvasGradient {
    _ = self;
    const x0 = try gradientNumber(args[0], "createLinearGradient", exec);
    const y0 = try gradientNumber(args[1], "createLinearGradient", exec);
    const x1 = try gradientNumber(args[2], "createLinearGradient", exec);
    const y1 = try gradientNumber(args[3], "createLinearGradient", exec);
    return exec._factory.create(CanvasGradient.init(.linear, .{ @floatCast(x0), @floatCast(y0), @floatCast(x1), @floatCast(y1), 0, 0 }));
}

pub fn createRadialGradient(self: *CanvasRenderingContext2D, args: []const js.Value, exec: *Execution) !*CanvasGradient {
    _ = self;
    const x0 = try gradientNumber(args[0], "createRadialGradient", exec);
    const y0 = try gradientNumber(args[1], "createRadialGradient", exec);
    const r0 = try gradientNumber(args[2], "createRadialGradient", exec);
    const x1 = try gradientNumber(args[3], "createRadialGradient", exec);
    const y1 = try gradientNumber(args[4], "createRadialGradient", exec);
    const r1 = try gradientNumber(args[5], "createRadialGradient", exec);
    if (r0 < 0) {
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "createRadialGradient",
            "IndexSizeError",
            "The r0 provided is less than 0.",
        );
    }
    if (r1 < 0) {
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "createRadialGradient",
            "IndexSizeError",
            "The r1 provided is less than 0.",
        );
    }
    return exec._factory.create(CanvasGradient.init(.radial, .{ @floatCast(x0), @floatCast(y0), @floatCast(r0), @floatCast(x1), @floatCast(y1), @floatCast(r1) }));
}

pub fn createConicGradient(self: *CanvasRenderingContext2D, args: []const js.Value, exec: *Execution) !*CanvasGradient {
    _ = self;
    const start_angle = try gradientNumber(args[0], "createConicGradient", exec);
    const x = try gradientNumber(args[1], "createConicGradient", exec);
    const y = try gradientNumber(args[2], "createConicGradient", exec);
    return exec._factory.create(CanvasGradient.init(.conic, .{ @floatCast(start_angle), @floatCast(x), @floatCast(y), 0, 0, 0 }));
}

pub fn createPattern(
    self: *CanvasRenderingContext2D,
    source_value: js.Value,
    repetition_value: js.Value,
    exec: *Execution,
) !*CanvasPattern {
    self.syncCanvasDimensions();
    const source = try resolveImageSource(source_value, "createPattern", exec);
    const repetition = if (repetition_value.isNull())
        ""
    else
        try js.WebIDL.toDOMString(repetition_value, exec, .{
            .interface = "CanvasRenderingContext2D",
            .name = "createPattern",
        });
    const w = imageSourceWidth(source);
    const h = imageSourceHeight(source);
    if (zeroSizeCanvasSourceReason(source)) |reason| {
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "createPattern",
            "InvalidStateError",
            reason,
        );
    }
    const rep: CanvasPattern.Repetition = blk: {
        const r = repetition;
        if (r.len == 0 or std.mem.eql(u8, r, "repeat")) break :blk .repeat;
        if (std.mem.eql(u8, r, "repeat-x")) break :blk .repeat_x;
        if (std.mem.eql(u8, r, "repeat-y")) break :blk .repeat_y;
        if (std.mem.eql(u8, r, "no-repeat")) break :blk .no_repeat;
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The provided type ('{s}') is not one of 'repeat', 'no-repeat', 'repeat-x', or 'repeat-y'.",
            .{r},
        );
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "createPattern",
            "SyntaxError",
            reason,
        );
    };
    if (imageSourceSurface(source) catch null) |src_surface| {
        const row_bytes = try std.math.mul(usize, @as(usize, w), 4);
        const pixel_bytes = try std.math.mul(usize, row_bytes, @as(usize, h));
        const pixels = try exec.arena.alloc(u8, pixel_bytes);
        try src_surface.readPixels(0, 0, w, h, pixels, row_bytes);
        return exec._factory.create(CanvasPattern.init(pixels, w, h, rep));
    }

    // An unmaterialized source is uniformly transparent. Preserve the visual
    // snapshot without allocating its potentially enormous logical extent.
    const transparent = try exec.arena.alloc(u8, 4);
    @memset(transparent, 0);
    return exec._factory.create(CanvasPattern.init(transparent, 1, 1, rep));
}

pub fn getFilter(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._filter;
}

pub fn setFilter(self: *CanvasRenderingContext2D, value: js.DOMString, exec: *Execution) !void {
    self.syncCanvasDimensions();
    const operations = (try CanvasFilter.parse(exec.arena, value.value)) orelse return;
    const source = try exec.dupeString(value.value);
    self._filter = source;
    self._filter_operations = operations;
    if (self.backend()) |owned| {
        owned.setFilter(operations) catch {
            self._backend_state_dirty = true;
        };
    } else {
        self._backend_state_dirty = true;
    }
}

pub fn getLetterSpacing(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._letter_spacing;
}

pub fn setLetterSpacing(self: *CanvasRenderingContext2D, value: js.DOMString, exec: *Execution) !void {
    self.syncCanvasDimensions();
    self._letter_spacing = try exec.dupeString(std.mem.trim(u8, value.value, " \t\r\n"));
}

pub fn getWordSpacing(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._word_spacing;
}

pub fn setWordSpacing(self: *CanvasRenderingContext2D, value: js.DOMString, exec: *Execution) !void {
    self.syncCanvasDimensions();
    self._word_spacing = try exec.dupeString(std.mem.trim(u8, value.value, " \t\r\n"));
}

pub fn getLang(self: *CanvasRenderingContext2D) []const u8 {
    self.syncCanvasDimensions();
    return self._lang;
}

pub fn setLang(self: *CanvasRenderingContext2D, value: js.DOMString, exec: *Execution) !void {
    self.syncCanvasDimensions();
    self._lang = try exec.dupeString(std.mem.trim(u8, value.value, " \t\r\n"));
}

const ImageDestination = union(enum) {
    unorm8: []u8,
    float16: []f16,
    float32: []f32,

    fn writePixel(self: ImageDestination, index: usize, pixel: [4]u8) void {
        switch (self) {
            .unorm8 => |destination| @memcpy(destination[index .. index + 4], &pixel),
            .float16 => |destination| for (pixel, 0..) |channel, offset| {
                const normalized: f32 = @as(f32, @floatFromInt(channel)) / 255.0;
                destination[index + offset] = @floatCast(normalized);
            },
            .float32 => |destination| for (pixel, 0..) |channel, offset| {
                destination[index + offset] = @as(f32, @floatFromInt(channel)) / 255.0;
            },
        }
    }
};

fn imageDestination(image_data: *ImageData, exec: *Execution) ImageDestination {
    const local = exec.js.local.?;
    const value = image_data.getData(exec);
    if (std.mem.eql(u8, image_data.getPixelFormat(), "rgba-float16")) {
        var data = js.ArrayBufferRef(.float16){ .local = local, .handle = value.handle };
        return .{ .float16 = data.slice() };
    }
    if (std.mem.eql(u8, image_data.getPixelFormat(), "rgba-float32")) {
        var data = js.ArrayBufferRef(.float32){ .local = local, .handle = value.handle };
        return .{ .float32 = data.slice() };
    }
    var data = js.ArrayBufferRef(.uint8_clamped){ .local = local, .handle = value.handle };
    return .{ .unorm8 = data.slice() };
}

pub fn getImageData(
    self: *CanvasRenderingContext2D,
    sx_value: js.Value,
    sy_value: js.Value,
    sw_value: js.Value,
    sh_value: js.Value,
    maybe_settings: ?js.Value,
    exec: *Execution,
) !*ImageData {
    self.syncCanvasDimensions();
    const sx_arg = try ImageData.canvasLong(sx_value, .canvas, "getImageData", exec);
    const sy_arg = try ImageData.canvasLong(sy_value, .canvas, "getImageData", exec);
    const sw = try ImageData.canvasLong(sw_value, .canvas, "getImageData", exec);
    const sh = try ImageData.canvasLong(sh_value, .canvas, "getImageData", exec);
    const omitted_color_space: ImageData.ColorSpace =
        if (std.mem.eql(u8, self._context_attributes.colorSpace, "display-p3"))
            .display_p3
        else
            .srgb;
    const settings = try ImageData.parseCanvasSettingsValue(
        maybe_settings,
        omitted_color_space,
        .canvas,
        "getImageData",
        exec,
    );
    if (sw == 0) {
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "getImageData",
            "IndexSizeError",
            "The source width is 0.",
        );
    }
    if (sh == 0) {
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "getImageData",
            "IndexSizeError",
            "The source height is 0.",
        );
    }

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

    const image_data = try ImageData.initForCanvasSettings(
        @intCast(width),
        @intCast(height),
        settings,
        .canvas,
        "getImageData",
        exec,
    );
    const canvas_width: i64 = self._observed_width;
    const canvas_height: i64 = self._observed_height;
    const source_left = @max(sx, 0);
    const source_top = @max(sy, 0);
    const source_right = @min(sx + width, canvas_width);
    const source_bottom = @min(sy + height, canvas_height);
    if (source_left >= source_right or source_top >= source_bottom) return image_data;

    const read_width: usize = @intCast(source_right - source_left);
    const read_height: usize = @intCast(source_bottom - source_top);
    const destination_x: usize = @intCast(source_left - sx);
    const destination_y: usize = @intCast(source_top - sy);
    const destination_width: usize = @intCast(width);
    // Reading an untouched canvas must not allocate its backing. This is
    // observable for alpha:false: Chrome reports transparent black before the
    // first allocation, then opaque black after drawing creates the surface.
    const surface = self._canvas.surface() orelse return image_data;

    const wide_format: ?CanvasSurface.ReadPixelFormat = switch (image_data.pixelFormat()) {
        .rgba_unorm8 => if (image_data.colorSpace() == .display_p3) .rgba8_unorm else null,
        .rgba_float16 => .rgba_float16,
        .rgba_float32 => .rgba_float32,
    };
    if (wide_format) |format| {
        const bytes_per_pixel = format.bytesPerPixel();
        const destination_row_bytes = try std.math.mul(usize, destination_width, bytes_per_pixel);
        const destination_offset = try std.math.mul(
            usize,
            destination_y * destination_width + destination_x,
            bytes_per_pixel,
        );
        const color_space: CanvasSurface.ColorSpace = switch (image_data.colorSpace()) {
            .srgb => .srgb,
            .display_p3 => .display_p3,
        };
        const destination_bytes = image_data.rawBytesMutable(exec.js.local.?);
        try surface.readPixelsFormat(
            @intCast(source_left),
            @intCast(source_top),
            @intCast(read_width),
            @intCast(read_height),
            destination_bytes[destination_offset..],
            destination_row_bytes,
            format,
            color_space,
        );
        return image_data;
    }

    const row_bytes = try std.math.mul(usize, read_width, 4);
    const premultiplied = try exec.call_arena.alloc(
        u8,
        try std.math.mul(usize, row_bytes, read_height),
    );
    try surface.readPixels(
        @intCast(source_left),
        @intCast(source_top),
        @intCast(read_width),
        @intCast(read_height),
        premultiplied,
        row_bytes,
    );

    const destination = imageDestination(image_data, exec);
    for (0..read_height) |row| {
        for (0..read_width) |column| {
            const source_index = row * row_bytes + column * 4;
            const stored: *const [4]u8 = @ptrCast(premultiplied.ptr + source_index);
            const pixel = CanvasSurface.unpremultiplyPixel(stored);
            const destination_index = ((destination_y + row) * destination_width + destination_x + column) * 4;
            destination.writePixel(destination_index, pixel);
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
        .stroke_style = self._stroke_style,
        .global_alpha = self._global_alpha,
        .font = self._font,
        .global_composite_operation = self._global_composite_operation,
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
        .filter = self._filter,
        .filter_operations = self._filter_operations,
        .letter_spacing = self._letter_spacing,
        .word_spacing = self._word_spacing,
        .lang = self._lang,
        .ctm = self._ctm,
    };
}

fn applyState(self: *CanvasRenderingContext2D, state: SavedState) void {
    self._fill_style = state.fill_style;
    self._stroke_style = state.stroke_style;
    self._global_alpha = state.global_alpha;
    self._font = state.font;
    self._global_composite_operation = state.global_composite_operation;
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
    self._filter = state.filter;
    self._filter_operations = state.filter_operations;
    self._letter_spacing = state.letter_spacing;
    self._word_spacing = state.word_spacing;
    self._lang = state.lang;
    self._ctm = state.ctm;
}

pub fn save(self: *CanvasRenderingContext2D, exec: *Execution) !void {
    self.syncCanvasDimensions();
    try self._state_stack.append(exec.arena, self.snapshotState());
    if (self.backend()) |owned| {
        owned.save() catch return;
        self._backend_save_depth += 1;
    }
}

pub fn restore(self: *CanvasRenderingContext2D) void {
    self.syncCanvasDimensions();
    if (self._state_stack.pop()) |state| self.applyState(state);
    if (self._backend_save_depth > 0) {
        if (self.backend()) |owned| owned.restore() catch {};
        self._backend_save_depth -= 1;
    } else {
        // The matching save() never reached the backend (or the stack was reset);
        // re-apply the restored JS state wholesale on next backend access.
        self._backend_state_dirty = true;
    }
}

pub fn getLineDash(self: *CanvasRenderingContext2D) []const f64 {
    self.syncCanvasDimensions();
    return self._line_dash;
}

pub fn setLineDash(self: *CanvasRenderingContext2D, raw: js.Value, exec: *Execution) !void {
    const segments = try CanvasLineDash.parse(raw, .canvas, exec);
    self.syncCanvasDimensions();
    for (segments) |segment| {
        // Chromium silently ignores the complete assignment when one member
        // is negative or non-finite.
        if (!std.math.isFinite(segment) or segment < 0) return;
    }

    if (segments.len == 0) {
        self._line_dash = &.{};
    } else if (segments.len % 2 == 0) {
        self._line_dash = try exec.arena.dupe(f64, segments);
    } else {
        const repeated = try exec.arena.alloc(f64, try std.math.mul(usize, segments.len, 2));
        @memcpy(repeated[0..segments.len], segments);
        @memcpy(repeated[segments.len..], segments);
        self._line_dash = repeated;
    }
    if (self.backend()) |owned| {
        pushLineDash(owned, self._line_dash, self._line_dash_offset) catch {};
    } else {
        self._backend_state_dirty = true;
    }
}

pub fn getContextAttributes(self: *CanvasRenderingContext2D) ContextOptions.Attributes {
    self.syncCanvasDimensions();
    return self._context_attributes;
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
    self._backend_save_depth = 0;
}

/// CTM helpers (Canvas 2D post-multiplies: new = current × added).
fn ctmMultiply(m: *[6]f64, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    const r = m.*;
    m[0] = r[0] * a + r[2] * b;
    m[1] = r[1] * a + r[3] * b;
    m[2] = r[0] * c + r[2] * d;
    m[3] = r[1] * c + r[3] * d;
    m[4] = r[0] * e + r[2] * f + r[4];
    m[5] = r[1] * e + r[3] * f + r[5];
}

pub fn scale(self: *CanvasRenderingContext2D, sx_value: js.Value, sy_value: js.Value, exec: *Execution) !void {
    const sx = try js.WebIDL.toNumber(sx_value, exec, .{
        .interface = "CanvasRenderingContext2D",
        .name = "scale",
    });
    const sy = try js.WebIDL.toNumber(sy_value, exec, .{
        .interface = "CanvasRenderingContext2D",
        .name = "scale",
    });
    self.syncCanvasDimensions();
    if (!std.math.isFinite(sx) or !std.math.isFinite(sy)) return;
    ctmMultiply(&self._ctm, sx, 0, 0, sy, 0, 0);
    if (self.backend()) |owned| owned.scale(sx, sy) catch {};
}

pub fn rotate(self: *CanvasRenderingContext2D, radians: f64) void {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(radians)) return;
    const cs = @cos(radians);
    const sn = @sin(radians);
    ctmMultiply(&self._ctm, cs, sn, -sn, cs, 0, 0);
    if (self.backend()) |owned| owned.rotate(radians) catch {};
}

pub fn translate(self: *CanvasRenderingContext2D, dx: f64, dy: f64) void {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return;
    ctmMultiply(&self._ctm, 1, 0, 0, 1, dx, dy);
    if (self.backend()) |owned| owned.translate(dx, dy) catch {};
}

pub fn transform(
    self: *CanvasRenderingContext2D,
    a_value: js.Value,
    b_value: js.Value,
    c_value: js.Value,
    d_value: js.Value,
    e_value: js.Value,
    f_value: js.Value,
    exec: *Execution,
) !void {
    const operation = js.WebIDL.Operation{
        .interface = "CanvasRenderingContext2D",
        .name = "transform",
    };
    const a = try js.WebIDL.toNumber(a_value, exec, operation);
    const b = try js.WebIDL.toNumber(b_value, exec, operation);
    const c = try js.WebIDL.toNumber(c_value, exec, operation);
    const d = try js.WebIDL.toNumber(d_value, exec, operation);
    const e = try js.WebIDL.toNumber(e_value, exec, operation);
    const f = try js.WebIDL.toNumber(f_value, exec, operation);
    self.syncCanvasDimensions();
    if (!std.math.isFinite(a) or !std.math.isFinite(b) or !std.math.isFinite(c) or
        !std.math.isFinite(d) or !std.math.isFinite(e) or !std.math.isFinite(f)) return;
    ctmMultiply(&self._ctm, a, b, c, d, e, f);
    if (self.backend()) |owned| {
        // The backend composes its own matrix; replicate the post-multiply.
        owned.setTransform(self._ctm[0], self._ctm[1], self._ctm[2], self._ctm[3], self._ctm[4], self._ctm[5]) catch {};
    }
}

pub fn setTransform(
    self: *CanvasRenderingContext2D,
    first: ?js.Value,
    second: ?js.Value,
    third: ?js.Value,
    fourth: ?js.Value,
    fifth: ?js.Value,
    sixth: ?js.Value,
    exec: *Execution,
) !void {
    const present: usize = if (sixth != null)
        6
    else if (fifth != null)
        5
    else if (fourth != null)
        4
    else if (third != null)
        3
    else if (second != null)
        2
    else if (first != null)
        1
    else
        0;

    const matrix: [6]f64 = if (present <= 1)
        try CanvasMatrix2DInit.parse(first, .canvas, "setTransform", exec)
    else blk: {
        if (present < 6) {
            return js.WebIDL.requiredArgument(exec, .{
                .interface = "CanvasRenderingContext2D",
                .name = "setTransform",
            }, 6, present);
        }
        const operation = js.WebIDL.Operation{
            .interface = "CanvasRenderingContext2D",
            .name = "setTransform",
        };
        break :blk .{
            try js.WebIDL.toNumber(first.?, exec, operation),
            try js.WebIDL.toNumber(second.?, exec, operation),
            try js.WebIDL.toNumber(third.?, exec, operation),
            try js.WebIDL.toNumber(fourth.?, exec, operation),
            try js.WebIDL.toNumber(fifth.?, exec, operation),
            try js.WebIDL.toNumber(sixth.?, exec, operation),
        };
    };
    for (matrix) |component| {
        if (!std.math.isFinite(component)) return;
    }
    self.syncCanvasDimensions();
    self._ctm = matrix;
    if (self.backend()) |owned| {
        owned.setTransform(matrix[0], matrix[1], matrix[2], matrix[3], matrix[4], matrix[5]) catch {};
    }
}

pub fn resetTransform(self: *CanvasRenderingContext2D) void {
    self.syncCanvasDimensions();
    self._ctm = .{ 1, 0, 0, 1, 0, 0 };
    if (self.backend()) |owned| owned.setTransform(1, 0, 0, 1, 0, 0) catch {};
}

pub fn getTransform(self: *CanvasRenderingContext2D, exec: *Execution) !*DOMMatrix {
    self.syncCanvasDimensions();
    const m = self._ctm;
    return DOMMatrix.create(.{
        m[0], m[1], 0, 0,
        m[2], m[3], 0, 0,
        0,    0,    1, 0,
        m[4], m[5], 0, 1,
    }, true, exec.page);
}
pub fn clearRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) !void {
    self.syncCanvasDimensions();
    _ = clippedRect(x, y, width, height, self._observed_width, self._observed_height) orelse return;
    const surface = (try self._canvas.ensureSurface()) orelse return;
    try surface.clearRect(x, y, width, height);
}

pub fn fillRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) !void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| {
        const surface = self._canvas.surface() orelse return;
        try self.pushFillStyle(owned, surface);
        try owned.fillRect(x, y, width, height);
    } else {
        // Legacy software path (v2/backend-less): color-only fillRect.
        if (self._fill_style != .color or self._fill_style.color.rgba.a == 0 or self._global_alpha == 0) return;
        _ = clippedRect(x, y, width, height, self._observed_width, self._observed_height) orelse return;
        const surface = (try self._canvas.ensureSurface()) orelse return;
        try surface.fillRect(x, y, width, height, .{ .r = self._fill_style.color.rgba.r, .g = self._fill_style.color.rgba.g, .b = self._fill_style.color.rgba.b, .a = self._fill_style.color.rgba.a }, self._global_alpha);
    }
}

pub fn strokeRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| {
        const surface = self._canvas.surface() orelse return;
        self.pushStrokeStyle(owned, surface) catch return;
        owned.strokeRect(x, y, width, height) catch {};
    }
}

pub fn beginPath(self: *CanvasRenderingContext2D) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| owned.beginPath() catch {};
}

pub fn closePath(self: *CanvasRenderingContext2D) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| owned.closePath() catch {};
}

pub fn moveTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| owned.moveTo(x, y) catch {};
}

pub fn lineTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| owned.lineTo(x, y) catch {};
}

pub fn quadraticCurveTo(self: *CanvasRenderingContext2D, cpx: f64, cpy: f64, x: f64, y: f64) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| owned.quadraticCurveTo(cpx, cpy, x, y) catch {};
}

pub fn bezierCurveTo(self: *CanvasRenderingContext2D, cp1x: f64, cp1y: f64, cp2x: f64, cp2y: f64, x: f64, y: f64) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| owned.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, x, y) catch {};
}

pub fn arc(self: *CanvasRenderingContext2D, x: f64, y: f64, radius: f64, start: f64, end: f64, ccw: ?bool, exec: *Execution) !void {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(radius) or !std.math.isFinite(start) or
        !std.math.isFinite(end)) return;
    if (radius < 0) {
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The radius provided ({d}) is negative.",
            .{radius},
        );
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "arc",
            "IndexSizeError",
            reason,
        );
    }
    if (self.backend()) |owned| owned.arc(x, y, radius, start, end, ccw orelse false) catch {};
}

pub fn ellipse(self: *CanvasRenderingContext2D, x: f64, y: f64, rx: f64, ry: f64, rotation: f64, start: f64, end: f64, ccw: ?bool, exec: *Execution) !void {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(rx) or !std.math.isFinite(ry) or
        !std.math.isFinite(rotation) or !std.math.isFinite(start) or
        !std.math.isFinite(end)) return;
    if (rx < 0) {
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The major-axis radius provided ({d}) is negative.",
            .{rx},
        );
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "ellipse",
            "IndexSizeError",
            reason,
        );
    }
    if (ry < 0) {
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The minor-axis radius provided ({d}) is negative.",
            .{ry},
        );
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "ellipse",
            "IndexSizeError",
            reason,
        );
    }
    if (self.backend()) |owned| owned.ellipse(x, y, rx, ry, rotation, start, end, ccw orelse false) catch {};
}

pub fn arcTo(self: *CanvasRenderingContext2D, x1: f64, y1: f64, x2: f64, y2: f64, radius: f64, exec: *Execution) !void {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(x1) or !std.math.isFinite(y1) or !std.math.isFinite(x2) or
        !std.math.isFinite(y2) or !std.math.isFinite(radius)) return;
    if (radius < 0) {
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The radius provided ({d}) is negative.",
            .{radius},
        );
        return CanvasException.canvasDOMException(
            exec,
            .canvas,
            "arcTo",
            "IndexSizeError",
            reason,
        );
    }
    if (self.backend()) |owned| owned.arcTo(x1, y1, x2, y2, radius) catch {};
}

pub fn rect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| owned.rect(x, y, width, height) catch {};
}

pub fn roundRect(self: *CanvasRenderingContext2D, x: f64, y: f64, width: f64, height: f64, radii: ?js.Value, exec: *Execution) !void {
    self.syncCanvasDimensions();
    const corners = (try CanvasRadii.parse(radii, .canvas, exec)) orelse return;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(width) or !std.math.isFinite(height)) return;
    if (self.backend()) |owned| {
        owned.roundRectRadii(x, y, width, height, &corners) catch {};
    }
}

pub fn fill(self: *CanvasRenderingContext2D, fill_rule: ?js.Value, exec: *Execution) !void {
    self.syncCanvasDimensions();
    const rule = try CanvasFillRule.parse(fill_rule, .canvas, "fill", exec);
    if (self.backend()) |owned| {
        const surface = self._canvas.surface() orelse return;
        try self.pushFillStyle(owned, surface);
        owned.fill(rule) catch {};
    }
}

pub fn stroke(self: *CanvasRenderingContext2D) void {
    self.syncCanvasDimensions();
    if (self.backend()) |owned| {
        const surface = self._canvas.surface() orelse return;
        self.pushStrokeStyle(owned, surface) catch return;
        owned.stroke() catch {};
    }
}

pub fn clip(self: *CanvasRenderingContext2D, fill_rule: ?js.Value, exec: *Execution) !void {
    self.syncCanvasDimensions();
    const rule = try CanvasFillRule.parse(fill_rule, .canvas, "clip", exec);
    if (self.backend()) |owned| owned.clip(rule) catch {};
}

/// fillText/strokeText: parse "Npx family" from the font shorthand (basic
/// Latin text only; full CSS font parsing + HarfBuzz shaping is the documented
/// font divergence).
const ParsedFont = struct { size: f64, family: []const u8 };

fn parseFont(font: []const u8) ParsedFont {
    var size: f64 = 10;
    var family: []const u8 = "sans-serif";
    var it = std.mem.tokenizeScalar(u8, font, ' ');
    while (it.next()) |token| {
        if (std.mem.endsWith(u8, token, "px")) {
            size = std.fmt.parseFloat(f64, token[0 .. token.len - 2]) catch size;
        } else {
            // Everything from the first non-keyword token onwards is the family
            // list; take the first family, stripped of quotes/commas.
            var fit = std.mem.tokenizeAny(u8, font[it.index..], ",");
            if (fit.next()) |first| {
                const trimmed = std.mem.trim(u8, first, " \t\"'");
                if (trimmed.len > 0) family = trimmed;
            }
            break;
        }
    }
    return .{ .size = size, .family = family };
}

pub fn fillText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, _: ?f64, exec: *Execution) !void {
    self.syncCanvasDimensions();
    if (text.len == 0) return;
    const owned = self.backend() orelse return;
    const surface = self._canvas.surface() orelse return;
    try self.pushFillStyle(owned, surface);
    const parsed = parseFont(self._font);
    const family_z = try exec.call_arena.dupeZ(u8, parsed.family);
    owned.fillText(text, x, y, parsed.size, family_z) catch {};
}

pub fn strokeText(_: *CanvasRenderingContext2D, _: []const u8, _: f64, _: f64, _: ?f64) void {}

pub fn measureText(self: *CanvasRenderingContext2D, text: []const u8, exec: *Execution) !*TextMetrics {
    self.syncCanvasDimensions();
    var width: f64 = 0;
    var metrics: TextMetrics = TextMetrics.init(0);
    if (self.backend()) |owned| {
        const parsed = parseFont(self._font);
        const family_z = try exec.call_arena.dupeZ(u8, parsed.family);
        var m: [5]f32 = .{ 0, 0, 0, 0, 0 };
        const advance = owned.measureText(text, parsed.size, family_z, &m);
        if (advance >= 0) {
            width = advance;
            // ascent, descent, leading, capHeight, xHeight from DirectWrite.
            metrics._font_bounding_box_ascent = m[0];
            metrics._font_bounding_box_descent = m[1];
            metrics._actual_bounding_box_ascent = m[0];
            metrics._actual_bounding_box_descent = m[1];
            metrics._actual_bounding_box_left = 0;
            metrics._actual_bounding_box_right = advance;
            metrics._em_height_ascent = m[3];
            metrics._alphabetic_baseline = 0;
        }
    }
    metrics._width = width;
    return exec._factory.create(metrics);
}

pub fn isPointInPath(self: *CanvasRenderingContext2D, x: f64, y: f64, fill_rule: ?js.Value, exec: *Execution) !bool {
    self.syncCanvasDimensions();
    const rule = try CanvasFillRule.parse(fill_rule, .canvas, "isPointInPath", exec);
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
    const owned = self.backend() orelse return false;
    return owned.isPointInPath(x, y, rule) catch false;
}

pub fn isPointInStroke(self: *CanvasRenderingContext2D, x: f64, y: f64) bool {
    self.syncCanvasDimensions();
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
    const owned = self.backend() orelse return false;
    return owned.isPointInStroke(x, y) catch false;
}

pub fn drawFocusIfNeeded(_: *CanvasRenderingContext2D, _: js.Value) void {}

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
    pub const filter = bridge.accessor(CanvasRenderingContext2D.getFilter, CanvasRenderingContext2D.setFilter, .{});
    pub const letterSpacing = bridge.accessor(CanvasRenderingContext2D.getLetterSpacing, CanvasRenderingContext2D.setLetterSpacing, .{});
    pub const wordSpacing = bridge.accessor(CanvasRenderingContext2D.getWordSpacing, CanvasRenderingContext2D.setWordSpacing, .{});
    pub const lang = bridge.accessor(CanvasRenderingContext2D.getLang, CanvasRenderingContext2D.setLang, .{});

    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{});
    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{
        .arity = 1,
        .required_args = 1,
        .variadic = true,
    });
    pub const createLinearGradient = bridge.function(CanvasRenderingContext2D.createLinearGradient, .{
        .arity = 4,
        .required_args = 4,
        .variadic = true,
    });
    pub const createRadialGradient = bridge.function(CanvasRenderingContext2D.createRadialGradient, .{
        .arity = 6,
        .required_args = 6,
        .variadic = true,
    });
    pub const createConicGradient = bridge.function(CanvasRenderingContext2D.createConicGradient, .{
        .arity = 3,
        .required_args = 3,
        .variadic = true,
    });
    pub const createPattern = bridge.function(CanvasRenderingContext2D.createPattern, .{ .required_args = 2 });
    pub const drawFocusIfNeeded = bridge.function(CanvasRenderingContext2D.drawFocusIfNeeded, .{});
    pub const drawImage = bridge.function(CanvasRenderingContext2D.drawImage, .{
        .arity = 3,
        .required_args = 3,
        .variadic = true,
    });
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{});
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{});
    pub const getContextAttributes = bridge.function(CanvasRenderingContext2D.getContextAttributes, .{});
    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{ .required_args = 4 });
    pub const getLineDash = bridge.function(CanvasRenderingContext2D.getLineDash, .{});
    pub const getTransform = bridge.function(CanvasRenderingContext2D.getTransform, .{});
    pub const isContextLost = bridge.function(CanvasRenderingContext2D.isContextLost, .{});
    pub const isPointInPath = bridge.function(CanvasRenderingContext2D.isPointInPath, .{ .required_args = 2 });
    pub const isPointInStroke = bridge.function(CanvasRenderingContext2D.isPointInStroke, .{ .required_args = 2 });
    pub const measureText = bridge.function(CanvasRenderingContext2D.measureText, .{});
    pub const reset = bridge.function(CanvasRenderingContext2D.reset, .{});
    pub const setLineDash = bridge.function(CanvasRenderingContext2D.setLineDash, .{ .required_args = 1 });
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{});

    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{ .required_args = 5 });
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{ .required_args = 5 });
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{});
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{});
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{});
    pub const ellipse = bridge.function(CanvasRenderingContext2D.ellipse, .{ .required_args = 7 });
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{});
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{});
    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{
        .arity = 3,
        .required_args = 3,
        .variadic = true,
    });
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{});
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{});
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{});
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{});
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{});
    pub const roundRect = bridge.function(CanvasRenderingContext2D.roundRect, .{ .required_args = 4 });
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{});
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{ .required_args = 2 });
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{ .arity = 0 });
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{});
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{});
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{ .required_args = 6 });
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}

test "WebApi: CanvasRenderingContext2D Skia backend" {
    const driver = std.process.getEnvVarOwned(
        std.testing.allocator,
        "DARKPANDA_CANVAS_DRIVER",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(driver);
    if (!std.ascii.eqlIgnoreCase(driver, "dynamic")) return error.SkipZigTest;

    const library = std.process.getEnvVarOwned(
        std.testing.allocator,
        "DARKPANDA_CANVAS_BACKEND_LIBRARY",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(library);
    if (!std.fs.path.isAbsolute(library)) return error.SkipZigTest;

    try testing.htmlRunner("canvas/canvas_backend_skia.html", .{});
    try testing.htmlRunner("canvas/canvas_draw_image_clipping.html", .{});
}
