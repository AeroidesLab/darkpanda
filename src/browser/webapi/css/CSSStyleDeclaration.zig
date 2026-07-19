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
const lp = @import("darkpanda");

const CssParser = @import("../../css/Parser.zig");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const DOMException = @import("../DOMException.zig");
const Element = @import("../Element.zig");
const CSSRule = @import("CSSRule.zig");
const CSSPropertyRegistry = @import("CSSPropertyRegistry.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

const CSSStyleDeclaration = @This();

_element: ?*Element = null,
_properties: std.DoublyLinkedList = .{},
_is_computed: bool = false,
_owner_frame: ?*Frame = null,
_computed_target_valid: bool = true,
_parent_rule: ?*CSSRule = null,

pub fn init(element: ?*Element, is_computed: bool, frame: *Frame) !*CSSStyleDeclaration {
    const self = try frame._factory.create(CSSStyleDeclaration{
        ._element = element,
        ._is_computed = is_computed,
        ._owner_frame = if (is_computed) frame else null,
    });

    // Parse the element's existing style attribute into _properties so that
    // subsequent JS reads and writes see all CSS properties, not just newly
    // added ones.  Computed styles have no inline attribute to parse.
    if (!is_computed) {
        if (element) |el| {
            if (el.getAttributeSafe(comptime .wrap("style"))) |attr_value| {
                var it = CssParser.parseDeclarationsList(attr_value);
                while (it.next()) |declaration| {
                    try self.applyParsedDeclaration(declaration, frame);
                }
            }
        }
    }

    return self;
}

/// Allows the getComputedStyle entry point to mark unsupported pseudo-element
/// targets invalid without changing the declaration's read-only identity.
pub fn setComputedTargetValid(self: *CSSStyleDeclaration, valid: bool) void {
    self._computed_target_valid = valid;
}

/// Blink exposes an empty resolved declaration unless its target participates
/// in an active document. This check is deliberately live: removing and later
/// reattaching the same element makes a retained declaration empty, then active
/// again, without allocating a replacement wrapper.
fn computedFrame(self: *const CSSStyleDeclaration) ?*Frame {
    if (!self._is_computed or !self._computed_target_valid) return null;
    const element = self._element orelse return null;
    if (!element.asNode().isConnected()) return null;

    const owner_frame = self._owner_frame orelse return null;
    const document = element.asNode().ownerDocument(owner_frame) orelse return null;
    const active_frame = document._frame orelse return null;
    if (active_frame.isRetired() or active_frame.document != document) return null;
    return active_frame;
}

pub fn length(self: *const CSSStyleDeclaration) u32 {
    if (self._is_computed) {
        if (self.computedFrame() == null) return 0;
        return @intCast(CSSPropertyRegistry.computed_keys.len);
    }
    return @intCast(self._properties.len());
}

pub fn item(self: *const CSSStyleDeclaration, index: u32) []const u8 {
    if (self._is_computed) {
        if (self.computedFrame() == null) return "";
        if (index >= CSSPropertyRegistry.computed_keys.len) return "";
        return CSSPropertyRegistry.computed_keys[index];
    }

    var i: u32 = 0;
    var node = self._properties.first;
    while (node) |n| {
        if (i == index) {
            const prop = Property.fromNodeLink(n);
            return prop._name.str();
        }
        i += 1;
        node = n.next;
    }
    return "";
}

pub fn getPropertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
    const wrapped = String.wrap(normalized);

    // Computed styles reflect the bounded authored-property cascade tracked by
    // StyleManager, rather than consulting only the inline style declaration.
    if (self._is_computed) {
        const active_frame = self.computedFrame() orelse return "";
        if (self._element) |element| {
            // UA display:none rules sit below every author declaration.
            if (wrapped.eql(comptime .wrap("display")) and active_frame._style_manager.hasDisplayNone(element)) {
                return "none";
            }

            const inherited_by_default = wrapped.eql(comptime .wrap("color")) or
                wrapped.eql(comptime .wrap("visibility")) or
                wrapped.eqlSlice("pointer-events");
            if (active_frame._style_manager.resolvedAuthoredPropertyValue(element, wrapped, inherited_by_default)) |value| {
                return value;
            }
        }
    }

    const prop = self.findProperty(wrapped) orelse {
        // Only return default values for computed styles
        if (self._is_computed) {
            const active_frame = self.computedFrame() orelse return "";
            if (self._element) |element| {
                // Resolve inline `style=` declarations through the element's
                // parsed inline style, so computed values match `el.style`.
                if (active_frame._style_manager.inlineStyleValue(element, wrapped)) |value| {
                    return value;
                }

                // Computed width/height must agree with the synthetic layout
                // metrics (offsetWidth/getBoundingClientRect). Returning ""
                // makes measurement code see contradictory sizes — jQuery's
                // "shrink text until it fits" loops then never terminate.
                if (wrapped.eql(comptime .wrap("width"))) {
                    return resolvedDimension(element, .width, active_frame);
                }
                if (wrapped.eql(comptime .wrap("height"))) {
                    return resolvedDimension(element, .height, active_frame);
                }
            }
            return getDefaultPropertyValue(self, wrapped);
        }
        return "";
    };
    return prop._value.str();
}

fn resolvedDimension(element: *Element, dimension: enum { width, height }, frame: *Frame) []const u8 {
    if (!element.checkVisibilityCached(null, frame)) {
        // A hidden replaced element has no used layout size, so an iframe with
        // no presentational hint still computes to `auto`. Its HTML width and
        // height attributes are presentational hints, however, and remain in
        // the computed cascade even when an ancestor has display:none.
        // Authored CSS has already been resolved above this fallback and thus
        // keeps its normal precedence over these hints.
        if (element.getTag() == .iframe) {
            const attribute_name = switch (dimension) {
                .width => comptime String.wrap("width"),
                .height => comptime String.wrap("height"),
            };
            if (element.getAttributeSafe(attribute_name)) |attribute_value| {
                if (serializeHtmlDimension(attribute_value, frame)) |value| {
                    return value;
                }
            }
        }
        return "auto";
    }
    const dims = element.getElementDimensions(frame);
    const value = switch (dimension) {
        .width => dims.width,
        .height => dims.height,
    };
    return std.fmt.allocPrint(frame.local_arena, "{d}px", .{value}) catch "auto";
}

/// Blink's `ParseDimensionValue` grammar used by iframe presentation
/// attributes. It is deliberately not CSS number parsing: a leading sign or
/// dot is invalid, an immediate percent sign selects percentage units, `*` is
/// rejected, and any other trailing bytes are legacy garbage after an
/// absolute pixel value (for example, `12px` becomes `12px`).
fn serializeHtmlDimension(input: []const u8, frame: *Frame) ?[]const u8 {
    var current: usize = 0;
    while (current < input.len and isHtmlSpace(input[current])) : (current += 1) {}
    const number_start = current;
    if (current >= input.len or !std.ascii.isDigit(input[current])) return null;

    while (current < input.len and std.ascii.isDigit(input[current])) : (current += 1) {}
    if (current < input.len and input[current] == '.') {
        current += 1;
        while (current < input.len and std.ascii.isDigit(input[current])) : (current += 1) {}
    }

    const value = std.fmt.parseFloat(f64, input[number_start..current]) catch return null;
    if (current < input.len and input[current] == '*') return null;
    const unit: []const u8 = if (current < input.len and input[current] == '%') "%" else "px";
    return std.fmt.allocPrint(frame.local_arena, "{d}{s}", .{ value, unit }) catch null;
}

fn isHtmlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

pub fn getPropertyPriority(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    if (self._is_computed) {
        _ = self.computedFrame() orelse return "";
        return "";
    }
    const normalized = normalizePropertyName(property_name, &frame.buf);
    const prop = self.findProperty(.wrap(normalized)) orelse return "";
    return if (prop._important) "important" else "";
}

pub fn getParentRule(self: *const CSSStyleDeclaration) ?*CSSRule {
    return self._parent_rule;
}

pub fn setParentRule(self: *CSSStyleDeclaration, rule: *CSSRule) void {
    self._parent_rule = rule;
}

fn throwNoModificationAllowed(frame: *Frame, message: []const u8) !void {
    const local = frame.js.local orelse return error.NoModificationAllowed;
    const exception = try local.zigValueToJs(
        DOMException.init(message, "NoModificationAllowedError"),
        .{},
    );
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

fn denyComputedMethodMutation(
    self: *const CSSStyleDeclaration,
    operation: []const u8,
    property_name: []const u8,
    frame: *Frame,
) !void {
    if (!self._is_computed) return;
    const message = try std.fmt.allocPrint(
        frame.local_arena,
        "Failed to execute '{s}' on 'CSSStyleDeclaration': These styles are computed, and therefore the '{s}' property is read-only.",
        .{ operation, property_name },
    );
    return throwNoModificationAllowed(frame, message);
}

fn denyComputedAttributeMutation(
    self: *const CSSStyleDeclaration,
    attribute: []const u8,
    property_name: ?[]const u8,
    frame: *Frame,
) !void {
    if (!self._is_computed) return;
    const message = if (property_name) |property|
        try std.fmt.allocPrint(
            frame.local_arena,
            "Failed to set the '{s}' property on 'CSSStyleDeclaration': These styles are computed, and therefore the '{s}' property is read-only.",
            .{ attribute, property },
        )
    else
        try std.fmt.allocPrint(
            frame.local_arena,
            "Failed to set the '{s}' property on 'CSSStyleDeclaration': These styles are computed, and therefore read-only.",
            .{attribute},
        );
    return throwNoModificationAllowed(frame, message);
}

/// CSSStyleProperties hosts Blink-compatible named property interceptors for
/// this declaration. Keep that binding context distinct from setProperty():
/// Chromium exposes a different DOMException prefix for a named assignment.
pub fn denyComputedNamedMutation(
    self: *const CSSStyleDeclaration,
    exposed_name: []const u8,
    property_name: []const u8,
    frame: *Frame,
) !void {
    if (!self._is_computed) return;
    const message = try std.fmt.allocPrint(
        frame.local_arena,
        "Failed to set a named property '{s}' on 'CSSStyleDeclaration': These styles are computed, and therefore the '{s}' property is read-only.",
        .{ exposed_name, property_name },
    );
    return throwNoModificationAllowed(frame, message);
}

pub fn setProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, priority_: ?[]const u8, frame: *Frame) !void {
    // A resolved CSSStyleDeclaration is read-only. Check this before validating
    // arguments: Blink exposes the exception-ordering when both would fail.
    try self.denyComputedMethodMutation("setProperty", property_name, frame);

    // Validate priority
    const priority = priority_ orelse "";
    const important = if (priority.len > 0) blk: {
        if (!std.ascii.eqlIgnoreCase(priority, "important")) {
            return;
        }
        break :blk true;
    } else false;

    try self.setPropertyImpl(property_name, value, important, frame);

    try self.syncStyleAttribute(frame);
}

/// Apply one declaration parsed from a `style=` block. Unlike the imperative
/// setProperty path, within a single declaration block a normal declaration must
/// not override an earlier !important one (CSS cascade precedence).
fn applyParsedDeclaration(self: *CSSStyleDeclaration, declaration: CssParser.Declaration, frame: *Frame) !void {
    if (!declaration.important) {
        const normalized = normalizePropertyName(declaration.name, &frame.buf);
        if (self.findProperty(.wrap(normalized))) |existing| {
            if (existing._important) return;
        }
    }
    try self.setPropertyImpl(declaration.name, declaration.value, declaration.important, frame);
}

fn setPropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, important: bool, frame: *Frame) !void {
    if (value.len == 0) {
        _ = try self.removePropertyImpl(property_name, frame);
        return;
    }

    const normalized = normalizePropertyName(property_name, &frame.buf);

    // CSS declarations silently ignore unsupported property names. Custom
    // properties are the exception: their author-defined name is accepted and
    // remains case-sensitive. In particular, Chrome does not retain foreign
    // vendor prefixes such as -moz-/-ms-/-o- in cssText or
    // getPropertyValue(), while the supported -webkit- surface is present in
    // the pinned CSS property registry.
    const is_custom_property = normalized.len > 2 and std.mem.startsWith(u8, normalized, "--");
    if (!is_custom_property and !CSSPropertyRegistry.hasCssName(normalized)) {
        return;
    }

    // Normalize the value for canonical serialization
    const normalized_value = try normalizePropertyValue(frame.local_arena, normalized, value);

    // Find existing property
    if (self.findProperty(.wrap(normalized))) |existing| {
        existing._value = try String.init(frame.arena, normalized_value, .{});
        existing._important = important;
        return;
    }

    // Create new property
    const prop = try frame._factory.create(Property{
        ._node = .{},
        ._name = try String.init(frame.arena, normalized, .{}),
        ._value = try String.init(frame.arena, normalized_value, .{}),
        ._important = important,
    });
    self._properties.append(&prop._node);
}

pub fn removeProperty(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) ![]const u8 {
    try self.denyComputedMethodMutation("removeProperty", property_name, frame);

    const result = try self.removePropertyImpl(property_name, frame);
    try self.syncStyleAttribute(frame);
    return result;
}

fn removePropertyImpl(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) ![]const u8 {
    const normalized = normalizePropertyName(property_name, &frame.buf);
    const prop = self.findProperty(.wrap(normalized)) orelse return "";

    // the value might not be on the heap (it could be inlined in the small string
    // optimization), so we need to dupe it.
    const old_value = try frame.call_arena.dupe(u8, prop._value.str());
    self._properties.remove(&prop._node);
    frame._factory.destroy(prop);
    return old_value;
}

// Serialize current properties back to the element's style attribute so that
// DOM serialization (outerHTML, getAttribute) reflects JS-modified styles.
fn syncStyleAttribute(self: *CSSStyleDeclaration, frame: *Frame) !void {
    const element = self._element orelse return;
    const css_text = try self.getCssText(frame);
    try element.setAttributeSafe(comptime .wrap("style"), .wrap(css_text), frame);
}

pub fn getFloat(self: *const CSSStyleDeclaration, frame: *Frame) []const u8 {
    return self.getPropertyValue("float", frame);
}

pub fn setFloat(self: *CSSStyleDeclaration, value_: ?[]const u8, frame: *Frame) !void {
    try self.denyComputedAttributeMutation("cssFloat", "float", frame);

    try self.setPropertyImpl("float", value_ orelse "", false, frame);
    try self.syncStyleAttribute(frame);
}

pub fn getCssText(self: *const CSSStyleDeclaration, frame: *Frame) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    try self.format(&buf.writer);
    return buf.written();
}

pub fn setCssText(self: *CSSStyleDeclaration, text: []const u8, frame: *Frame) !void {
    try self.denyComputedAttributeMutation("cssText", null, frame);

    try self.setCssTextFromParser(text, frame);
}

/// Replace a mutable declaration block from CSS text supplied by an internal
/// parser/attribute path. Those callers construct inline or rule declarations,
/// never a read-only resolved declaration, so keep NoModificationAllowed out of
/// their error sets while sharing the actual parsing implementation.
pub fn setCssTextFromParser(self: *CSSStyleDeclaration, text: []const u8, frame: *Frame) !void {
    std.debug.assert(!self._is_computed);

    // Clear existing properties
    var node = self._properties.first;
    while (node) |n| {
        const next = n.next;
        const prop = Property.fromNodeLink(n);
        self._properties.remove(n);
        frame._factory.destroy(prop);
        node = next;
    }

    // Parse and set new properties
    var it = CssParser.parseDeclarationsList(text);
    while (it.next()) |declaration| {
        try self.applyParsedDeclaration(declaration, frame);
    }
    try self.syncStyleAttribute(frame);
}

pub fn format(self: *const CSSStyleDeclaration, writer: *std.Io.Writer) !void {
    const node = self._properties.first orelse return;
    try Property.fromNodeLink(node).format(writer);

    var next = node.next;
    while (next) |n| {
        try writer.writeByte(' ');
        try Property.fromNodeLink(n).format(writer);
        next = n.next;
    }
}

pub fn findProperty(self: *const CSSStyleDeclaration, name: String) ?*Property {
    var node = self._properties.first;
    while (node) |n| {
        const prop = Property.fromNodeLink(n);
        if (prop._name.eql(name)) {
            return prop;
        }
        node = n.next;
    }
    return null;
}

fn normalizePropertyName(name: []const u8, buf: []u8) []const u8 {
    // CSS custom property names are case-sensitive; ordinary property names
    // are ASCII case-insensitive and use a lowercase canonical spelling.
    if (std.mem.startsWith(u8, name, "--")) return name;
    if (name.len > buf.len) {
        log.info(.dom, "css.long.name", .{ .name = name });
        return name;
    }
    return std.ascii.lowerString(buf, name);
}

// Normalize CSS property values for canonical serialization
fn normalizePropertyValue(arena: Allocator, property_name: []const u8, raw_value: []const u8) ![]const u8 {
    const value = try normalizeLeadingZeros(arena, raw_value);

    // Per CSSOM spec, unitless zero in length properties should serialize as "0px"
    if (std.mem.eql(u8, value, "0") and isLengthProperty(property_name)) {
        return "0px";
    }

    // "first baseline" serializes canonically as "baseline" (first is the default)
    if (std.ascii.startsWithIgnoreCase(value, "first baseline")) {
        if (value.len == 14) {
            // Exact match "first baseline"
            return "baseline";
        }
        if (value.len > 14 and value[14] == ' ') {
            // "first baseline X" -> "baseline X"
            return try std.mem.concat(arena, u8, &.{ "baseline", value[14..] });
        }
    }

    // For 2-value shorthand properties, collapse "X X" to "X"
    if (isTwoValueShorthand(property_name)) {
        if (collapseDuplicateValue(value)) |single| {
            return single;
        }
    }

    // Canonicalize anchor-size() function: anchor name (dashed ident) comes before size keyword
    if (std.mem.indexOf(u8, value, "anchor-size(")) |idx| {
        return canonicalizeAnchorSize(arena, value, idx);
    }

    // Canonicalize anchor() function: anchor name (dashed ident) comes before position keyword
    // Note: indexOf finds first occurrence, so we check it's not part of "anchor-size("
    if (std.mem.indexOf(u8, value, "anchor(")) |idx| {
        if (idx == 0 or value[idx - 1] != '-') {
            return canonicalizeAnchor(arena, value, idx);
        }
    }

    return value;
}

// Insert a leading "0" before any bare ".<digit>". A value might have multiple
// such bare digits
fn normalizeLeadingZeros(arena: Allocator, value: []const u8) ![]const u8 {
    // A bare ".<digit>" needs at least 2 chars, and a trailing "." can never be
    // followed by a digit. So we only ever scan up to value.len - 1, which lets
    // us index value[i + 1] without a bounds check.
    if (value.len < 2) {
        return value;
    }

    var inserts: usize = 0;
    for (value[0 .. value.len - 1], 0..) |c, i| {
        if (c != '.') {
            continue;
        }
        if (!std.ascii.isDigit(value[i + 1])) {
            // next value isn't a digit
            continue;
        }
        if (i > 0 and std.ascii.isDigit(value[i - 1])) {
            // previous value is a digit
            continue;
        }
        inserts += 1;
    }
    if (inserts == 0) {
        return value;
    }

    const buf = try arena.alloc(u8, value.len + inserts);
    var w: usize = 0;
    for (value[0 .. value.len - 1], 0..) |c, i| {
        if (c == '.' and std.ascii.isDigit(value[i + 1]) and (i == 0 or !std.ascii.isDigit(value[i - 1]))) {
            buf[w] = '0';
            w += 1;
        }
        buf[w] = c;
        w += 1;
    }
    // The last char is copied unconditionally: it can't start a bare ".<digit>".
    buf[w] = value[value.len - 1];
    w += 1;
    return buf[0..w];
}

// Canonicalize anchor-size() so that the dashed ident (anchor name) comes before the size keyword.
// e.g. "anchor-size(width --foo)" -> "anchor-size(--foo width)"
fn canonicalizeAnchorSize(arena: Allocator, value: []const u8, start_index: usize) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);

    // Copy everything before the first anchor-size(
    try buf.writer.writeAll(value[0..start_index]);

    var i: usize = start_index;

    while (i < value.len) {
        // Look for "anchor-size("
        if (std.mem.startsWith(u8, value[i..], "anchor-size(")) {
            try buf.writer.writeAll("anchor-size(");
            i += "anchor-size(".len;

            // Parse and canonicalize the arguments
            i = try canonicalizeAnchorFnArgs(value, i, &buf.writer, .anchor_size);
        } else {
            try buf.writer.writeByte(value[i]);
            i += 1;
        }
    }

    return buf.written();
}

const AnchorFnKind = enum { anchor, anchor_size };

// Parse anchor/anchor-size arguments and write them in canonical order
fn canonicalizeAnchorFnArgs(value: []const u8, start: usize, writer: *std.Io.Writer, kind: AnchorFnKind) !usize {
    var i = start;
    var depth: usize = 1;

    // Skip leading whitespace
    while (i < value.len and value[i] == ' ') : (i += 1) {}

    var token_count: usize = 0;
    var comma_pos: ?usize = null;

    var first_token_end: usize = 0;
    var first_token_start: ?usize = null;

    var second_token_end: usize = 0;
    var second_token_start: ?usize = null;

    const args_start = i;
    var in_token = false;

    // First pass: find the structure of arguments before comma/closing paren at depth 1
    while (i < value.len and depth > 0) {
        const c = value[i];

        if (c == '(') {
            depth += 1;
            in_token = true;
            i += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                if (in_token) {
                    if (token_count == 0) {
                        first_token_end = i;
                    } else if (token_count == 1) {
                        second_token_end = i;
                    }
                }
                break;
            }
            i += 1;
        } else if (c == ',' and depth == 1) {
            if (in_token) {
                if (token_count == 0) {
                    first_token_end = i;
                } else if (token_count == 1) {
                    second_token_end = i;
                }
            }
            comma_pos = i;
            break;
        } else if (c == ' ') {
            if (in_token and depth == 1) {
                if (token_count == 0) {
                    first_token_end = i;
                    token_count = 1;
                } else if (token_count == 1 and second_token_start != null) {
                    second_token_end = i;
                    token_count = 2;
                }
                in_token = false;
            }
            i += 1;
        } else {
            if (!in_token and depth == 1) {
                if (token_count == 0) {
                    first_token_start = i;
                } else if (token_count == 1) {
                    second_token_start = i;
                }
                in_token = true;
            }
            i += 1;
        }
    }

    // Handle end of tokens
    if (in_token and token_count == 1 and second_token_start != null) {
        second_token_end = i;
        token_count = 2;
    } else if (in_token and token_count == 0) {
        first_token_end = i;
        token_count = 1;
    }

    // Check if we have exactly two tokens that need reordering
    if (token_count == 2) {
        const first_start = first_token_start orelse args_start;
        const second_start = second_token_start orelse first_token_end;

        const first_token = value[first_start..first_token_end];
        const second_token = value[second_start..second_token_end];

        // If second token is a dashed ident, it should come first
        // For anchor-size, also check that first token is a size keyword
        const should_swap = std.mem.startsWith(u8, second_token, "--") and
            (kind == .anchor or isAnchorSizeKeyword(first_token));

        if (should_swap) {
            try writer.writeAll(second_token);
            try writer.writeByte(' ');
            try writer.writeAll(first_token);
        } else {
            try writer.writeAll(first_token);
            try writer.writeByte(' ');
            try writer.writeAll(second_token);
        }
    } else if (first_token_start) |fts| {
        // Single token, just copy it
        try writer.writeAll(value[fts..first_token_end]);
    }

    // Handle comma and fallback value (may contain nested functions)
    if (comma_pos) |cp| {
        try writer.writeAll(", ");
        i = cp + 1;
        // Skip whitespace after comma
        while (i < value.len and value[i] == ' ') : (i += 1) {}

        // Copy the fallback, recursively handling nested anchor/anchor-size
        while (i < value.len and depth > 0) {
            if (std.mem.startsWith(u8, value[i..], "anchor-size(")) {
                try writer.writeAll("anchor-size(");
                i += "anchor-size(".len;
                depth += 1;
                i = try canonicalizeAnchorFnArgs(value, i, writer, .anchor_size);
                depth -= 1;
            } else if (std.mem.startsWith(u8, value[i..], "anchor(")) {
                try writer.writeAll("anchor(");
                i += "anchor(".len;
                depth += 1;
                i = try canonicalizeAnchorFnArgs(value, i, writer, .anchor);
                depth -= 1;
            } else if (value[i] == '(') {
                depth += 1;
                try writer.writeByte(value[i]);
                i += 1;
            } else if (value[i] == ')') {
                depth -= 1;
                if (depth == 0) break;
                try writer.writeByte(value[i]);
                i += 1;
            } else {
                try writer.writeByte(value[i]);
                i += 1;
            }
        }
    }

    // Write closing paren
    try writer.writeByte(')');

    return i + 1; // Skip past the closing paren
}

fn isAnchorSizeKeyword(token: []const u8) bool {
    const keywords = std.StaticStringMap(void).initComptime(.{
        .{ "width", {} },
        .{ "height", {} },
        .{ "block", {} },
        .{ "inline", {} },
        .{ "self-block", {} },
        .{ "self-inline", {} },
    });
    return keywords.has(token);
}

// Canonicalize anchor() so that the dashed ident (anchor name) comes before the position keyword.
// e.g. "anchor(left --foo)" -> "anchor(--foo left)"
fn canonicalizeAnchor(arena: Allocator, value: []const u8, start_index: usize) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);

    // Copy everything before the first anchor(
    try buf.writer.writeAll(value[0..start_index]);

    var i: usize = start_index;

    while (i < value.len) {
        // Look for "anchor(" but not "anchor-size("
        if (std.mem.startsWith(u8, value[i..], "anchor(") and (i == 0 or value[i - 1] != '-')) {
            try buf.writer.writeAll("anchor(");
            i += "anchor(".len;

            // Parse and canonicalize the arguments
            i = try canonicalizeAnchorFnArgs(value, i, &buf.writer, .anchor);
        } else {
            try buf.writer.writeByte(value[i]);
            i += 1;
        }
    }

    return buf.written();
}

// Check if a value is "X X" (duplicate) and return just "X"
fn collapseDuplicateValue(value: []const u8) ?[]const u8 {
    const space_idx = std.mem.indexOfScalar(u8, value, ' ') orelse return null;
    if (space_idx == 0 or space_idx >= value.len - 1) return null;

    const first = value[0..space_idx];
    const rest = std.mem.trimLeft(u8, value[space_idx + 1 ..], " ");

    // Check if there's only one more value (no additional spaces)
    if (std.mem.indexOfScalar(u8, rest, ' ') != null) return null;

    if (std.mem.eql(u8, first, rest)) {
        return first;
    }
    return null;
}

fn isTwoValueShorthand(name: []const u8) bool {
    const shorthands = std.StaticStringMap(void).initComptime(.{
        .{ "place-content", {} },
        .{ "place-items", {} },
        .{ "place-self", {} },
        .{ "margin-block", {} },
        .{ "margin-inline", {} },
        .{ "padding-block", {} },
        .{ "padding-inline", {} },
        .{ "inset-block", {} },
        .{ "inset-inline", {} },
        .{ "border-block-style", {} },
        .{ "border-inline-style", {} },
        .{ "border-block-width", {} },
        .{ "border-inline-width", {} },
        .{ "border-block-color", {} },
        .{ "border-inline-color", {} },
        .{ "overflow", {} },
        .{ "overscroll-behavior", {} },
        .{ "gap", {} },
        .{ "grid-gap", {} },
        // Scroll
        .{ "scroll-padding-block", {} },
        .{ "scroll-padding-inline", {} },
        .{ "scroll-snap-align", {} },
        // Background/Mask
        .{ "background-size", {} },
        .{ "border-image-repeat", {} },
        .{ "mask-repeat", {} },
        .{ "mask-size", {} },
    });
    return shorthands.has(name);
}

fn isLengthProperty(name: []const u8) bool {
    // Properties that accept <length> or <length-percentage> values
    const length_properties = std.StaticStringMap(void).initComptime(.{
        // Sizing
        .{ "width", {} },
        .{ "height", {} },
        .{ "min-width", {} },
        .{ "min-height", {} },
        .{ "max-width", {} },
        .{ "max-height", {} },
        // Margins
        .{ "margin", {} },
        .{ "margin-top", {} },
        .{ "margin-right", {} },
        .{ "margin-bottom", {} },
        .{ "margin-left", {} },
        .{ "margin-block", {} },
        .{ "margin-block-start", {} },
        .{ "margin-block-end", {} },
        .{ "margin-inline", {} },
        .{ "margin-inline-start", {} },
        .{ "margin-inline-end", {} },
        // Padding
        .{ "padding", {} },
        .{ "padding-top", {} },
        .{ "padding-right", {} },
        .{ "padding-bottom", {} },
        .{ "padding-left", {} },
        .{ "padding-block", {} },
        .{ "padding-block-start", {} },
        .{ "padding-block-end", {} },
        .{ "padding-inline", {} },
        .{ "padding-inline-start", {} },
        .{ "padding-inline-end", {} },
        // Positioning
        .{ "top", {} },
        .{ "right", {} },
        .{ "bottom", {} },
        .{ "left", {} },
        .{ "inset", {} },
        .{ "inset-block", {} },
        .{ "inset-block-start", {} },
        .{ "inset-block-end", {} },
        .{ "inset-inline", {} },
        .{ "inset-inline-start", {} },
        .{ "inset-inline-end", {} },
        // Border
        .{ "border-width", {} },
        .{ "border-top-width", {} },
        .{ "border-right-width", {} },
        .{ "border-bottom-width", {} },
        .{ "border-left-width", {} },
        .{ "border-block-width", {} },
        .{ "border-block-start-width", {} },
        .{ "border-block-end-width", {} },
        .{ "border-inline-width", {} },
        .{ "border-inline-start-width", {} },
        .{ "border-inline-end-width", {} },
        .{ "border-radius", {} },
        .{ "border-top-left-radius", {} },
        .{ "border-top-right-radius", {} },
        .{ "border-bottom-left-radius", {} },
        .{ "border-bottom-right-radius", {} },
        // Text
        .{ "font-size", {} },
        .{ "letter-spacing", {} },
        .{ "word-spacing", {} },
        .{ "text-indent", {} },
        // Flexbox/Grid
        .{ "gap", {} },
        .{ "row-gap", {} },
        .{ "column-gap", {} },
        .{ "flex-basis", {} },
        // Legacy grid aliases
        .{ "grid-column-gap", {} },
        .{ "grid-row-gap", {} },
        // Outline
        .{ "outline", {} },
        .{ "outline-width", {} },
        .{ "outline-offset", {} },
        // Multi-column
        .{ "column-rule-width", {} },
        .{ "column-width", {} },
        // Scroll
        .{ "scroll-margin", {} },
        .{ "scroll-margin-top", {} },
        .{ "scroll-margin-right", {} },
        .{ "scroll-margin-bottom", {} },
        .{ "scroll-margin-left", {} },
        .{ "scroll-padding", {} },
        .{ "scroll-padding-top", {} },
        .{ "scroll-padding-right", {} },
        .{ "scroll-padding-bottom", {} },
        .{ "scroll-padding-left", {} },
        // Shapes
        .{ "shape-margin", {} },
        // Motion path
        .{ "offset-distance", {} },
        // Transforms
        .{ "translate", {} },
        // Animations
        .{ "animation-range-end", {} },
        .{ "animation-range-start", {} },
        // Other
        .{ "border-spacing", {} },
        .{ "text-shadow", {} },
        .{ "box-shadow", {} },
        .{ "baseline-shift", {} },
        .{ "vertical-align", {} },
        .{ "text-decoration-inset", {} },
        .{ "block-step-size", {} },
        // Grid lanes
        .{ "flow-tolerance", {} },
        .{ "column-rule-edge-inset", {} },
        .{ "column-rule-interior-inset", {} },
        .{ "row-rule-edge-inset", {} },
        .{ "row-rule-interior-inset", {} },
        .{ "rule-edge-inset", {} },
        .{ "rule-interior-inset", {} },
    });

    return length_properties.has(name);
}

fn getDefaultPropertyValue(self: *const CSSStyleDeclaration, name: String) []const u8 {
    switch (name.len) {
        5 => {
            if (name.eql(comptime .wrap("color"))) {
                const element = self._element orelse return "";
                return getDefaultColor(element);
            }
        },
        7 => {
            if (name.eql(comptime .wrap("opacity"))) {
                return "1";
            }
            if (name.eql(comptime .wrap("display"))) {
                const element = self._element orelse return "";
                return getDefaultDisplay(element);
            }
        },
        10 => {
            if (name.eql(comptime .wrap("visibility"))) {
                return "visible";
            }
        },
        8 => {
            if (name.eql(comptime .wrap("position"))) {
                return "static";
            }
        },
        16 => {
            if (name.eqlSlice("background-color")) {
                // transparent
                return "rgba(0, 0, 0, 0)";
            }
        },
        18 => {
            if (name.eqlSlice("content-visibility")) {
                return "visible";
            }
        },
        else => {},
    }
    return "";
}

fn getDefaultDisplay(element: *const Element) []const u8 {
    switch (element._type) {
        .html => |html| {
            return switch (html._type) {
                .anchor, .br, .span, .label, .time, .font, .mod, .quote, .iframe => "inline",
                .body, .div, .dl, .p, .heading, .form, .button, .canvas, .details, .dialog, .embed, .head, .html, .hr, .img, .input, .li, .link, .meta, .ol, .option, .script, .select, .slot, .style, .template, .textarea, .title, .ul, .media, .area, .base, .datalist, .directory, .fieldset, .frameset, .legend, .map, .marquee, .meter, .object, .optgroup, .output, .param, .picture, .pre, .progress, .source, .table, .table_caption, .table_cell, .table_col, .table_row, .table_section, .track => "block",
                .generic, .custom, .unknown, .data => blk: {
                    const tag = element.getTagNameLower();
                    if (isInlineTag(tag)) break :blk "inline";
                    break :blk "block";
                },
            };
        },
        .svg => return "inline",
    }
}

fn isInlineTag(tag_name: []const u8) bool {
    const inline_tags = [_][]const u8{
        "abbr",  "b",    "bdi",    "bdo",  "cite", "code", "dfn",
        "em",    "i",    "kbd",    "mark", "q",    "s",    "samp",
        "small", "span", "strong", "sub",  "sup",  "time", "u",
        "var",   "wbr",
    };

    for (inline_tags) |inline_tag| {
        if (std.mem.eql(u8, tag_name, inline_tag)) {
            return true;
        }
    }
    return false;
}

fn getDefaultColor(element: *const Element) []const u8 {
    switch (element._type) {
        .html => |html| {
            return switch (html._type) {
                .anchor => "rgb(0, 0, 238)", // blue
                else => "rgb(0, 0, 0)",
            };
        },
        .svg => return "rgb(0, 0, 0)",
    }
}

pub const Property = struct {
    _name: String,
    _value: String,
    _important: bool = false,
    _node: std.DoublyLinkedList.Node,

    fn fromNodeLink(n: *std.DoublyLinkedList.Node) *Property {
        return @alignCast(@fieldParentPtr("_node", n));
    }

    pub fn format(self: *const Property, writer: *std.Io.Writer) !void {
        try self._name.format(writer);
        try writer.writeAll(": ");
        try self._value.format(writer);

        if (self._important) {
            try writer.writeAll(" !important");
        }
        try writer.writeByte(';');
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleDeclaration);

    pub const Meta = struct {
        pub const name = "CSSStyleDeclaration";
        pub const prototype_template_properties = [_]js.bridge.InstanceTemplateProperty{.{
            .key = .{ .well_known_symbol = .iterator },
            .value = .{ .intrinsic = .array_prototype_values },
            .writable = true,
            .enumerable = false,
            .configurable = true,
            .phase = .after_members,
        }};
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cssText = bridge.accessor(CSSStyleDeclaration.getCssText, CSSStyleDeclaration.setCssText, .{});
    pub const length = bridge.accessor(CSSStyleDeclaration.length, null, .{});
    pub const parentRule = bridge.accessor(CSSStyleDeclaration.getParentRule, null, .{});
    pub const cssFloat = bridge.accessor(CSSStyleDeclaration.getFloat, CSSStyleDeclaration.setFloat, .{});
    pub const getPropertyPriority = bridge.function(CSSStyleDeclaration.getPropertyPriority, .{});
    pub const getPropertyValue = bridge.function(CSSStyleDeclaration.getPropertyValue, .{});
    pub const item = bridge.function(_item, .{});
    pub const removeProperty = bridge.function(CSSStyleDeclaration.removeProperty, .{});
    pub const setProperty = bridge.function(CSSStyleDeclaration.setProperty, .{});

    fn _item(self: *const CSSStyleDeclaration, index: i32) []const u8 {
        if (index < 0) {
            return "";
        }
        return self.item(@intCast(index));
    }
};

const testing = @import("../../../testing.zig");
test "normalizePropertyValue: unitless zero to 0px" {
    const cases = .{
        .{ "width", "0", "0px" },
        .{ "height", "0", "0px" },
        .{ "scroll-margin-top", "0", "0px" },
        .{ "scroll-padding-bottom", "0", "0px" },
        .{ "column-width", "0", "0px" },
        .{ "column-rule-width", "0", "0px" },
        .{ "outline", "0", "0px" },
        .{ "shape-margin", "0", "0px" },
        .{ "offset-distance", "0", "0px" },
        .{ "translate", "0", "0px" },
        .{ "grid-column-gap", "0", "0px" },
        .{ "grid-row-gap", "0", "0px" },
        // Non-length properties should NOT normalize
        .{ "opacity", "0", "0" },
        .{ "z-index", "0", "0" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: first baseline to baseline" {
    const result = try normalizePropertyValue(testing.allocator, "align-items", "first baseline");
    try testing.expectEqual("baseline", result);

    const result2 = try normalizePropertyValue(testing.allocator, "align-self", "last baseline");
    try testing.expectEqual("last baseline", result2);
}

test "normalizePropertyValue: collapse duplicate two-value shorthands" {
    const cases = .{
        .{ "overflow", "hidden hidden", "hidden" },
        .{ "gap", "10px 10px", "10px" },
        .{ "scroll-snap-align", "start start", "start" },
        .{ "scroll-padding-block", "5px 5px", "5px" },
        .{ "background-size", "auto auto", "auto" },
        .{ "overscroll-behavior", "auto auto", "auto" },
        // Different values should NOT collapse
        .{ "overflow", "hidden scroll", "hidden scroll" },
        .{ "gap", "10px 20px", "10px 20px" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: anchor() canonical order" {
    defer testing.reset();
    const cases = .{
        // Dashed ident should come before keyword
        .{ "left", "anchor(left --foo)", "anchor(--foo left)" },
        .{ "left", "anchor(inside --foo)", "anchor(--foo inside)" },
        .{ "left", "anchor(50% --foo)", "anchor(--foo 50%)" },
        // Already canonical order - keep as-is
        .{ "left", "anchor(--foo left)", "anchor(--foo left)" },
        .{ "left", "anchor(left)", "anchor(left)" },
        // With fallback
        .{ "left", "anchor(left --foo, 1px)", "anchor(--foo left, 1px)" },
        // Nested anchor in fallback
        .{ "left", "anchor(left --foo, anchor(right --bar))", "anchor(--foo left, anchor(--bar right))" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.arena_allocator, case[0], case[1]);
        try testing.expectEqual(case[2], result);
    }
}
