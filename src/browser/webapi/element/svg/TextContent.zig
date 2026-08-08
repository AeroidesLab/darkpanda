// Copyright (C) 2026 Lightpanda contributors

const std = @import("std");
const lp = @import("darkpanda");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const DOMRect = @import("../../DOMRect.zig");
const CSS = @import("../../CSS.zig");
const SvgElement = @import("../Svg.zig");

const TextContent = @This();
_proto: *SvgElement,
_type: Type,

pub const Text = @import("Text.zig");
pub const Type = union(enum) {
    text: *Text,
};

pub fn is(self: *TextContent, comptime T: type) ?*T {
    return if (T == Text and self._type == .text) self._type.text else null;
}

pub fn asElement(self: *TextContent) *Element {
    return self._proto.asElement();
}

pub fn asNode(self: *TextContent) *Node {
    return self.asElement().asNode();
}

const Measure = struct {
    width: f64,
    ascent: f64,
    descent: f64,
};

fn utf8Range(text: []const u8, start: u32, count: u32) []const u8 {
    var offset: usize = 0;
    var index: u32 = 0;
    while (offset < text.len and index < start) : (index += 1) {
        offset += std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    }
    const first = offset;
    index = 0;
    while (offset < text.len and index < count) : (index += 1) {
        offset += std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    }
    return text[first..offset];
}

fn measure(self: *TextContent, start: u32, count: u32, frame: *Frame) !Measure {
    const text = try self.asNode().getTextContentAlloc(frame.local_arena);
    const selected = utf8Range(text, start, count);
    const element = self.asElement();
    const font_size = CSS.parseDimension(frame._style_manager.resolvedAuthoredPropertyValue(
        element,
        comptime lp.String.wrap("font-size"),
        true,
    ) orelse element.getAttributeSafe(comptime lp.String.wrap("font-size")) orelse "16px") orelse 16;
    const family_list = frame._style_manager.resolvedAuthoredPropertyValue(
        element,
        comptime lp.String.wrap("font-family"),
        true,
    ) orelse element.getAttributeSafe(comptime lp.String.wrap("font-family")) orelse "sans-serif";
    const family_end = std.mem.indexOfScalar(u8, family_list, ',') orelse family_list.len;
    const family = std.mem.trim(u8, family_list[0..family_end], " \t\"'");
    const family_z = try frame.local_arena.dupeZ(u8, if (family.len == 0) "sans-serif" else family);
    var metrics: [5]f32 = .{ 0, 0, 0, 0, 0 };
    const width = frame._page.canvas_backend.measureText(selected, font_size, family_z, &metrics) orelse
        @as(f64, @floatFromInt(selected.len)) * font_size / 2;
    return .{
        .width = width,
        .ascent = if (metrics[0] > 0) metrics[0] else font_size * 0.8,
        .descent = if (metrics[1] > 0) metrics[1] else font_size * 0.2,
    };
}

pub fn getComputedTextLength(self: *TextContent, frame: *Frame) !f64 {
    return (try self.measure(0, std.math.maxInt(u32), frame)).width;
}

pub fn getSubStringLength(self: *TextContent, char_num: u32, number_of_chars: u32, frame: *Frame) !f64 {
    return (try self.measure(char_num, number_of_chars, frame)).width;
}

pub fn getExtentOfChar(self: *TextContent, char_num: u32, frame: *Frame) !*DOMRect {
    const measured = try self.measure(char_num, 1, frame);
    const x = if (self.asElement().getAttributeSafe(comptime lp.String.wrap("x"))) |value|
        std.fmt.parseFloat(f64, value) catch 0
    else
        0;
    const y = if (self.asElement().getAttributeSafe(comptime lp.String.wrap("y"))) |value|
        std.fmt.parseFloat(f64, value) catch 0
    else
        0;
    return DOMRect.init(x, y - measured.ascent, measured.width, measured.ascent + measured.descent, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextContent);

    pub const Meta = struct {
        pub const name = "SVGTextContentElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getComputedTextLength = bridge.function(TextContent.getComputedTextLength, .{});
    pub const getSubStringLength = bridge.function(TextContent.getSubStringLength, .{ .required_args = 2 });
    pub const getExtentOfChar = bridge.function(TextContent.getExtentOfChar, .{ .required_args = 1 });
};
