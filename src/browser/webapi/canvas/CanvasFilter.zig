// Copyright (C) 2023-2026 Lightpanda
//
// Canvas 2D's `filter` attribute uses the CSS filter-function grammar, but the
// getter preserves the exact string assigned by script. This module only owns
// the parsed, renderer-facing operation chain; the contexts retain the source
// string separately.

const std = @import("std");

const color = @import("../../color.zig");
const Tokenizer = @import("../../css/Tokenizer.zig");
const adapter = @import("../../../canvas_backend/adapter.zig");

pub const Operation = adapter.FilterOperation;
pub const Kind = adapter.FilterKind;

const ParseError = error{Invalid};

/// Parse a complete CSS filter-function list. `null` means invalid syntax;
/// an empty slice is the valid keyword `none`.
///
/// CSS Syntax implicitly closes an open function at EOF. In particular,
/// Chrome accepts `ctx.filter = "blur("` as `blur()` while preserving the
/// original `blur(` string in the getter.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !?[]const Operation {
    return parseInternal(allocator, input) catch |err| switch (err) {
        error.Invalid => null,
        else => |other| return other,
    };
}

fn parseInternal(allocator: std.mem.Allocator, input: []const u8) ![]const Operation {
    var stream = Tokenizer{ .input = input };
    var operations: std.ArrayList(Operation) = .empty;
    errdefer operations.deinit(allocator);

    var saw_value = false;
    while (stream.next()) |token| {
        if (isTrivia(token)) continue;
        saw_value = true;

        switch (token) {
            .ident => |name| {
                if (!std.ascii.eqlIgnoreCase(name, "none") or operations.items.len != 0) {
                    return error.Invalid;
                }
                while (stream.next()) |tail| {
                    if (!isTrivia(tail)) return error.Invalid;
                }
                return &.{};
            },
            .function => |name| {
                const body = consumeFunctionBody(input, &stream);
                try operations.append(allocator, try parseFunction(allocator, name, body));
            },
            else => return error.Invalid,
        }
    }

    if (!saw_value or operations.items.len == 0) return error.Invalid;
    return operations.toOwnedSlice(allocator);
}

/// The tokenizer is positioned immediately after the opening `(`. The slice
/// excludes the matching `)`, or extends to EOF when CSS implicit closing is
/// used.
fn consumeFunctionBody(input: []const u8, stream: *Tokenizer) []const u8 {
    const body_start = stream.position;
    var depth: usize = 1;
    while (true) {
        const token_start = stream.position;
        const token = stream.next() orelse return input[body_start..stream.position];
        switch (token) {
            .function, .parenthesis_block => depth += 1,
            .close_parenthesis => {
                depth -= 1;
                if (depth == 0) return input[body_start..token_start];
            },
            else => {},
        }
    }
}

fn parseFunction(allocator: std.mem.Allocator, name: []const u8, body: []const u8) !Operation {
    if (std.ascii.eqlIgnoreCase(name, "blur")) {
        return .{ .kind = .blur, .amount = try parseLengthArgument(body, 0, false) };
    }
    if (std.ascii.eqlIgnoreCase(name, "drop-shadow")) {
        return parseDropShadow(allocator, body);
    }
    if (std.ascii.eqlIgnoreCase(name, "grayscale")) {
        return amountOperation(.grayscale, body, 1, true);
    }
    if (std.ascii.eqlIgnoreCase(name, "sepia")) {
        return amountOperation(.sepia, body, 1, true);
    }
    if (std.ascii.eqlIgnoreCase(name, "saturate")) {
        return amountOperation(.saturate, body, 1, false);
    }
    if (std.ascii.eqlIgnoreCase(name, "hue-rotate")) {
        return .{ .kind = .hue_rotate, .amount = try parseAngle(body) };
    }
    if (std.ascii.eqlIgnoreCase(name, "invert")) {
        return amountOperation(.invert, body, 1, true);
    }
    if (std.ascii.eqlIgnoreCase(name, "opacity")) {
        return amountOperation(.opacity, body, 1, true);
    }
    if (std.ascii.eqlIgnoreCase(name, "brightness")) {
        return amountOperation(.brightness, body, 1, false);
    }
    if (std.ascii.eqlIgnoreCase(name, "contrast")) {
        return amountOperation(.contrast, body, 1, false);
    }
    return error.Invalid;
}

fn amountOperation(kind: Kind, body: []const u8, default: f64, clamp_to_one: bool) !Operation {
    const token = try singleArgument(body);
    var amount = if (token) |arg| switch (arg) {
        .number => |number| @as(f64, number.value),
        .percentage => |percentage| @as(f64, percentage.unit_value),
        else => return error.Invalid,
    } else default;

    if (!std.math.isFinite(amount) or amount < 0) return error.Invalid;
    if (clamp_to_one) amount = @min(amount, 1);
    return .{ .kind = kind, .amount = amount };
}

fn parseAngle(body: []const u8) !f64 {
    const token = (try singleArgument(body)) orelse return 0;
    const degrees: f64 = switch (token) {
        .number => |number| if (number.value == 0) 0 else return error.Invalid,
        .dimension => |dimension| blk: {
            const value: f64 = dimension.value;
            if (std.ascii.eqlIgnoreCase(dimension.unit, "deg")) break :blk value;
            if (std.ascii.eqlIgnoreCase(dimension.unit, "grad")) break :blk value * 0.9;
            if (std.ascii.eqlIgnoreCase(dimension.unit, "rad")) break :blk value * (180.0 / std.math.pi);
            if (std.ascii.eqlIgnoreCase(dimension.unit, "turn")) break :blk value * 360.0;
            return error.Invalid;
        },
        else => return error.Invalid,
    };
    if (!std.math.isFinite(degrees)) return error.Invalid;
    return degrees;
}

fn parseLengthArgument(body: []const u8, default: f64, allow_negative: bool) !f64 {
    const token = (try singleArgument(body)) orelse return default;
    return lengthFromToken(token, allow_negative);
}

fn lengthFromToken(token: Tokenizer.Token, allow_negative: bool) !f64 {
    const pixels: f64 = switch (token) {
        .number => |number| if (number.value == 0) 0 else return error.Invalid,
        .dimension => |dimension| blk: {
            const factor: f64 = if (std.ascii.eqlIgnoreCase(dimension.unit, "px"))
                1
            else if (std.ascii.eqlIgnoreCase(dimension.unit, "in"))
                96
            else if (std.ascii.eqlIgnoreCase(dimension.unit, "cm"))
                96.0 / 2.54
            else if (std.ascii.eqlIgnoreCase(dimension.unit, "mm"))
                96.0 / 25.4
            else if (std.ascii.eqlIgnoreCase(dimension.unit, "q"))
                96.0 / 101.6
            else if (std.ascii.eqlIgnoreCase(dimension.unit, "pt"))
                96.0 / 72.0
            else if (std.ascii.eqlIgnoreCase(dimension.unit, "pc"))
                16
            else
                return error.Invalid;
            break :blk @as(f64, dimension.value) * factor;
        },
        else => return error.Invalid,
    };
    if (!std.math.isFinite(pixels) or (!allow_negative and pixels < 0)) return error.Invalid;
    return pixels;
}

fn singleArgument(input: []const u8) !?Tokenizer.Token {
    var stream = Tokenizer{ .input = input };
    var result: ?Tokenizer.Token = null;
    while (stream.next()) |token| {
        if (isTrivia(token)) continue;
        if (result != null) return error.Invalid;
        result = token;
    }
    return result;
}

const Item = struct {
    text: []const u8,
    token: Tokenizer.Token,
};

fn parseDropShadow(allocator: std.mem.Allocator, body: []const u8) !Operation {
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(allocator);
    try splitTopLevelItems(allocator, body, &items);

    var lengths: [3]f64 = undefined;
    var length_count: usize = 0;
    var shadow_color: [4]f32 = .{ 0, 0, 0, 1 };
    var saw_color = false;

    for (items.items) |item| {
        if (lengthFromToken(item.token, true)) |length| {
            if (length_count == lengths.len) return error.Invalid; // spread is forbidden
            lengths[length_count] = length;
            length_count += 1;
            continue;
        } else |err| switch (err) {
            error.Invalid => {},
        }

        if (saw_color) return error.Invalid;
        const parsed_color = (try parseShadowColor(allocator, item.text)) orelse return error.Invalid;
        shadow_color = parsed_color.f;
        saw_color = true;
    }

    if (length_count != 2 and length_count != 3) return error.Invalid;
    const sigma = if (length_count == 3) lengths[2] else 0;
    if (sigma < 0) return error.Invalid;
    return .{
        .kind = .drop_shadow,
        .amount = sigma,
        .offset_x = lengths[0],
        .offset_y = lengths[1],
        .color = shadow_color,
    };
}

fn splitTopLevelItems(
    allocator: std.mem.Allocator,
    input: []const u8,
    items: *std.ArrayList(Item),
) !void {
    var stream = Tokenizer{ .input = input };
    while (true) {
        const start = stream.position;
        const token = stream.next() orelse return;
        if (isTrivia(token)) continue;

        switch (token) {
            .function => {
                _ = consumeFunctionBody(input, &stream);
                try items.append(allocator, .{
                    .text = input[start..stream.position],
                    .token = token,
                });
            },
            else => try items.append(allocator, .{
                .text = input[start..stream.position],
                .token = token,
            }),
        }
    }
}

fn parseShadowColor(allocator: std.mem.Allocator, input: []const u8) !?color.RGBA.Float {
    const trimmed = std.mem.trim(u8, input, " \t\r\n\x0c");
    if (std.ascii.eqlIgnoreCase(trimmed, "currentcolor")) {
        return .{ .rgba = color.RGBA.Named.black, .f = .{ 0, 0, 0, 1 } };
    }

    // The shared color parser operates on source text rather than CSS tokens.
    // Normalize comments and append CSS's implicit EOF-closing parentheses.
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);
    var i: usize = 0;
    var open_parens: usize = 0;
    while (i < trimmed.len) {
        if (i + 1 < trimmed.len and trimmed[i] == '/' and trimmed[i + 1] == '*') {
            i += 2;
            while (i + 1 < trimmed.len and !(trimmed[i] == '*' and trimmed[i + 1] == '/')) : (i += 1) {}
            if (i + 1 >= trimmed.len) return null;
            i += 2;
            try normalized.append(allocator, ' ');
            continue;
        }
        const byte = trimmed[i];
        if (byte == '(') open_parens += 1;
        if (byte == ')') {
            if (open_parens == 0) return null;
            open_parens -= 1;
        }
        try normalized.append(allocator, byte);
        i += 1;
    }
    try normalized.appendNTimes(allocator, ')', open_parens);
    return color.RGBA.parseFloat(normalized.items) catch null;
}

fn isTrivia(token: Tokenizer.Token) bool {
    return switch (token) {
        .white_space, .comment => true,
        else => false,
    };
}

const testing = std.testing;

fn expectValid(input: []const u8, expected: []const Operation) !void {
    const parsed = (try parse(testing.allocator, input)) orelse return error.TestUnexpectedResult;
    defer if (parsed.len != 0) testing.allocator.free(parsed);
    try testing.expectEqualDeep(expected, parsed);
}

fn expectInvalid(input: []const u8) !void {
    try testing.expect((try parse(testing.allocator, input)) == null);
}

test "CanvasFilter: none, complete chains, and EOF implicit close" {
    try expectValid(" none ", &.{});
    try expectValid("blur(", &.{.{ .kind = .blur, .amount = 0 }});
    try expectValid(
        "blur(2px) contrast(150%) grayscale(.25)",
        &.{
            .{ .kind = .blur, .amount = 2 },
            .{ .kind = .contrast, .amount = 1.5 },
            .{ .kind = .grayscale, .amount = 0.25 },
        },
    );
}

test "CanvasFilter: defaults, percentages, clamping, and angles" {
    try expectValid(
        "grayscale() sepia(250%) saturate() hue-rotate(.5turn) invert(2) opacity(20%) brightness(3) contrast()",
        &.{
            .{ .kind = .grayscale, .amount = 1 },
            .{ .kind = .sepia, .amount = 1 },
            .{ .kind = .saturate, .amount = 1 },
            .{ .kind = .hue_rotate, .amount = 180 },
            .{ .kind = .invert, .amount = 1 },
            .{ .kind = .opacity, .amount = @as(f64, @floatCast(@as(f32, 0.2))) },
            .{ .kind = .brightness, .amount = 3 },
            .{ .kind = .contrast, .amount = 1 },
        },
    );
    try expectValid("hue-rotate(3.1415927rad)", &.{.{
        .kind = .hue_rotate,
        .amount = @as(f64, @floatCast(@as(f32, 3.1415927))) * (180.0 / std.math.pi),
    }});
}

test "CanvasFilter: drop-shadow color order, defaults, and lengths" {
    try expectValid("drop-shadow(red 1px -2px 3px)", &.{.{
        .kind = .drop_shadow,
        .amount = 3,
        .offset_x = 1,
        .offset_y = -2,
        .color = .{ 1, 0, 0, 1 },
    }});
    try expectValid("drop-shadow(0 2px rgba(0, 128, 255, 50%))", &.{.{
        .kind = .drop_shadow,
        .offset_x = 0,
        .offset_y = 2,
        .color = .{ 0, 128.0 / 255.0, 1, 128.0 / 255.0 },
    }});
}

test "CanvasFilter: invalid values reject the whole assignment" {
    const invalid = [_][]const u8{
        "",
        "initial",
        "inherit",
        "unset",
        "revert",
        "url(#x)",
        "unknown(1)",
        "blur(-1px)",
        "blur(1)",
        "blur(1px) nope(2)",
        "grayscale(-1)",
        "opacity(-1%)",
        "hue-rotate(1)",
        "drop-shadow()",
        "drop-shadow(1px)",
        "drop-shadow(1px 2px -3px)",
        "drop-shadow(1px 2px 3px 4px)",
    };
    for (invalid) |value| try expectInvalid(value);
}
