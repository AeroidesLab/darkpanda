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
const Io = std.Io;

pub fn isHexColor(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }

    if (value[0] != '#') {
        return false;
    }

    const hex_part = value[1..];
    switch (hex_part.len) {
        3, 4, 6, 8 => for (hex_part) |c| if (!std.ascii.isHex(c)) return false,
        else => return false,
    }

    return true;
}

pub const RGBA = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    /// Opaque by default.
    a: u8 = std.math.maxInt(u8),

    pub const Named = struct {
        // Basic colors (CSS Level 1)
        pub const black: RGBA = .init(0, 0, 0, 1);
        pub const silver: RGBA = .init(192, 192, 192, 1);
        pub const gray: RGBA = .init(128, 128, 128, 1);
        pub const white: RGBA = .init(255, 255, 255, 1);
        pub const maroon: RGBA = .init(128, 0, 0, 1);
        pub const red: RGBA = .init(255, 0, 0, 1);
        pub const purple: RGBA = .init(128, 0, 128, 1);
        pub const fuchsia: RGBA = .init(255, 0, 255, 1);
        pub const green: RGBA = .init(0, 128, 0, 1);
        pub const lime: RGBA = .init(0, 255, 0, 1);
        pub const olive: RGBA = .init(128, 128, 0, 1);
        pub const yellow: RGBA = .init(255, 255, 0, 1);
        pub const navy: RGBA = .init(0, 0, 128, 1);
        pub const blue: RGBA = .init(0, 0, 255, 1);
        pub const teal: RGBA = .init(0, 128, 128, 1);
        pub const aqua: RGBA = .init(0, 255, 255, 1);

        // Extended colors (CSS Level 2+)
        pub const aliceblue: RGBA = .init(240, 248, 255, 1);
        pub const antiquewhite: RGBA = .init(250, 235, 215, 1);
        pub const aquamarine: RGBA = .init(127, 255, 212, 1);
        pub const azure: RGBA = .init(240, 255, 255, 1);
        pub const beige: RGBA = .init(245, 245, 220, 1);
        pub const bisque: RGBA = .init(255, 228, 196, 1);
        pub const blanchedalmond: RGBA = .init(255, 235, 205, 1);
        pub const blueviolet: RGBA = .init(138, 43, 226, 1);
        pub const brown: RGBA = .init(165, 42, 42, 1);
        pub const burlywood: RGBA = .init(222, 184, 135, 1);
        pub const cadetblue: RGBA = .init(95, 158, 160, 1);
        pub const chartreuse: RGBA = .init(127, 255, 0, 1);
        pub const chocolate: RGBA = .init(210, 105, 30, 1);
        pub const coral: RGBA = .init(255, 127, 80, 1);
        pub const cornflowerblue: RGBA = .init(100, 149, 237, 1);
        pub const cornsilk: RGBA = .init(255, 248, 220, 1);
        pub const crimson: RGBA = .init(220, 20, 60, 1);
        pub const cyan: RGBA = .init(0, 255, 255, 1); // Synonym of aqua
        pub const darkblue: RGBA = .init(0, 0, 139, 1);
        pub const darkcyan: RGBA = .init(0, 139, 139, 1);
        pub const darkgoldenrod: RGBA = .init(184, 134, 11, 1);
        pub const darkgray: RGBA = .init(169, 169, 169, 1);
        pub const darkgreen: RGBA = .init(0, 100, 0, 1);
        pub const darkgrey: RGBA = .init(169, 169, 169, 1); // Synonym of darkgray
        pub const darkkhaki: RGBA = .init(189, 183, 107, 1);
        pub const darkmagenta: RGBA = .init(139, 0, 139, 1);
        pub const darkolivegreen: RGBA = .init(85, 107, 47, 1);
        pub const darkorange: RGBA = .init(255, 140, 0, 1);
        pub const darkorchid: RGBA = .init(153, 50, 204, 1);
        pub const darkred: RGBA = .init(139, 0, 0, 1);
        pub const darksalmon: RGBA = .init(233, 150, 122, 1);
        pub const darkseagreen: RGBA = .init(143, 188, 143, 1);
        pub const darkslateblue: RGBA = .init(72, 61, 139, 1);
        pub const darkslategray: RGBA = .init(47, 79, 79, 1);
        pub const darkslategrey: RGBA = .init(47, 79, 79, 1); // Synonym of darkslategray
        pub const darkturquoise: RGBA = .init(0, 206, 209, 1);
        pub const darkviolet: RGBA = .init(148, 0, 211, 1);
        pub const deeppink: RGBA = .init(255, 20, 147, 1);
        pub const deepskyblue: RGBA = .init(0, 191, 255, 1);
        pub const dimgray: RGBA = .init(105, 105, 105, 1);
        pub const dimgrey: RGBA = .init(105, 105, 105, 1); // Synonym of dimgray
        pub const dodgerblue: RGBA = .init(30, 144, 255, 1);
        pub const firebrick: RGBA = .init(178, 34, 34, 1);
        pub const floralwhite: RGBA = .init(255, 250, 240, 1);
        pub const forestgreen: RGBA = .init(34, 139, 34, 1);
        pub const gainsboro: RGBA = .init(220, 220, 220, 1);
        pub const ghostwhite: RGBA = .init(248, 248, 255, 1);
        pub const gold: RGBA = .init(255, 215, 0, 1);
        pub const goldenrod: RGBA = .init(218, 165, 32, 1);
        pub const greenyellow: RGBA = .init(173, 255, 47, 1);
        pub const grey: RGBA = .init(128, 128, 128, 1); // Synonym of gray
        pub const honeydew: RGBA = .init(240, 255, 240, 1);
        pub const hotpink: RGBA = .init(255, 105, 180, 1);
        pub const indianred: RGBA = .init(205, 92, 92, 1);
        pub const indigo: RGBA = .init(75, 0, 130, 1);
        pub const ivory: RGBA = .init(255, 255, 240, 1);
        pub const khaki: RGBA = .init(240, 230, 140, 1);
        pub const lavender: RGBA = .init(230, 230, 250, 1);
        pub const lavenderblush: RGBA = .init(255, 240, 245, 1);
        pub const lawngreen: RGBA = .init(124, 252, 0, 1);
        pub const lemonchiffon: RGBA = .init(255, 250, 205, 1);
        pub const lightblue: RGBA = .init(173, 216, 230, 1);
        pub const lightcoral: RGBA = .init(240, 128, 128, 1);
        pub const lightcyan: RGBA = .init(224, 255, 255, 1);
        pub const lightgoldenrodyellow: RGBA = .init(250, 250, 210, 1);
        pub const lightgray: RGBA = .init(211, 211, 211, 1);
        pub const lightgreen: RGBA = .init(144, 238, 144, 1);
        pub const lightgrey: RGBA = .init(211, 211, 211, 1); // Synonym of lightgray
        pub const lightpink: RGBA = .init(255, 182, 193, 1);
        pub const lightsalmon: RGBA = .init(255, 160, 122, 1);
        pub const lightseagreen: RGBA = .init(32, 178, 170, 1);
        pub const lightskyblue: RGBA = .init(135, 206, 250, 1);
        pub const lightslategray: RGBA = .init(119, 136, 153, 1);
        pub const lightslategrey: RGBA = .init(119, 136, 153, 1); // Synonym of lightslategray
        pub const lightsteelblue: RGBA = .init(176, 196, 222, 1);
        pub const lightyellow: RGBA = .init(255, 255, 224, 1);
        pub const limegreen: RGBA = .init(50, 205, 50, 1);
        pub const linen: RGBA = .init(250, 240, 230, 1);
        pub const magenta: RGBA = .init(255, 0, 255, 1); // Synonym of fuchsia
        pub const mediumaquamarine: RGBA = .init(102, 205, 170, 1);
        pub const mediumblue: RGBA = .init(0, 0, 205, 1);
        pub const mediumorchid: RGBA = .init(186, 85, 211, 1);
        pub const mediumpurple: RGBA = .init(147, 112, 219, 1);
        pub const mediumseagreen: RGBA = .init(60, 179, 113, 1);
        pub const mediumslateblue: RGBA = .init(123, 104, 238, 1);
        pub const mediumspringgreen: RGBA = .init(0, 250, 154, 1);
        pub const mediumturquoise: RGBA = .init(72, 209, 204, 1);
        pub const mediumvioletred: RGBA = .init(199, 21, 133, 1);
        pub const midnightblue: RGBA = .init(25, 25, 112, 1);
        pub const mintcream: RGBA = .init(245, 255, 250, 1);
        pub const mistyrose: RGBA = .init(255, 228, 225, 1);
        pub const moccasin: RGBA = .init(255, 228, 181, 1);
        pub const navajowhite: RGBA = .init(255, 222, 173, 1);
        pub const oldlace: RGBA = .init(253, 245, 230, 1);
        pub const olivedrab: RGBA = .init(107, 142, 35, 1);
        pub const orange: RGBA = .init(255, 165, 0, 1);
        pub const orangered: RGBA = .init(255, 69, 0, 1);
        pub const orchid: RGBA = .init(218, 112, 214, 1);
        pub const palegoldenrod: RGBA = .init(238, 232, 170, 1);
        pub const palegreen: RGBA = .init(152, 251, 152, 1);
        pub const paleturquoise: RGBA = .init(175, 238, 238, 1);
        pub const palevioletred: RGBA = .init(219, 112, 147, 1);
        pub const papayawhip: RGBA = .init(255, 239, 213, 1);
        pub const peachpuff: RGBA = .init(255, 218, 185, 1);
        pub const peru: RGBA = .init(205, 133, 63, 1);
        pub const pink: RGBA = .init(255, 192, 203, 1);
        pub const plum: RGBA = .init(221, 160, 221, 1);
        pub const powderblue: RGBA = .init(176, 224, 230, 1);
        pub const rebeccapurple: RGBA = .init(102, 51, 153, 1);
        pub const rosybrown: RGBA = .init(188, 143, 143, 1);
        pub const royalblue: RGBA = .init(65, 105, 225, 1);
        pub const saddlebrown: RGBA = .init(139, 69, 19, 1);
        pub const salmon: RGBA = .init(250, 128, 114, 1);
        pub const sandybrown: RGBA = .init(244, 164, 96, 1);
        pub const seagreen: RGBA = .init(46, 139, 87, 1);
        pub const seashell: RGBA = .init(255, 245, 238, 1);
        pub const sienna: RGBA = .init(160, 82, 45, 1);
        pub const skyblue: RGBA = .init(135, 206, 235, 1);
        pub const slateblue: RGBA = .init(106, 90, 205, 1);
        pub const slategray: RGBA = .init(112, 128, 144, 1);
        pub const slategrey: RGBA = .init(112, 128, 144, 1); // Synonym of slategray
        pub const snow: RGBA = .init(255, 250, 250, 1);
        pub const springgreen: RGBA = .init(0, 255, 127, 1);
        pub const steelblue: RGBA = .init(70, 130, 180, 1);
        pub const tan: RGBA = .init(210, 180, 140, 1);
        pub const thistle: RGBA = .init(216, 191, 216, 1);
        pub const tomato: RGBA = .init(255, 99, 71, 1);
        pub const transparent: RGBA = .init(0, 0, 0, 0);
        pub const turquoise: RGBA = .init(64, 224, 208, 1);
        pub const violet: RGBA = .init(238, 130, 238, 1);
        pub const wheat: RGBA = .init(245, 222, 179, 1);
        pub const whitesmoke: RGBA = .init(245, 245, 245, 1);
        pub const yellowgreen: RGBA = .init(154, 205, 50, 1);
    };

    pub fn init(r: u8, g: u8, b: u8, a: f32) RGBA {
        const clamped = std.math.clamp(a, 0, 1);
        return .{ .r = r, .g = g, .b = b, .a = @intFromFloat(@round(clamped * 255)) };
    }

    /// Finds a color by its name.
    pub fn find(name: []const u8) ?RGBA {
        inline for (@typeInfo(Named).@"struct".decls) |decl| {
            if (std.ascii.eqlIgnoreCase(name, decl.name)) return @field(Named, decl.name);
        }
        return null;
    }

    fn parseRgbChannel(input: []const u8) !u8 {
        const token = std.mem.trim(u8, input, " \t\r\n\x0c");
        if (token.len == 0) return error.Invalid;
        const percent = token[token.len - 1] == '%';
        const number = std.fmt.parseFloat(f64, if (percent) token[0 .. token.len - 1] else token) catch return error.Invalid;
        if (!std.math.isFinite(number)) return error.Invalid;
        const scaled = if (percent) number * 2.55 else number;
        return @intFromFloat(@round(std.math.clamp(scaled, 0, 255)));
    }

    fn parseAlpha(input: []const u8) !u8 {
        const token = std.mem.trim(u8, input, " \t\r\n\x0c");
        if (token.len == 0) return error.Invalid;
        const percent = token[token.len - 1] == '%';
        const number = std.fmt.parseFloat(f64, if (percent) token[0 .. token.len - 1] else token) catch return error.Invalid;
        if (!std.math.isFinite(number)) return error.Invalid;
        const normalized = if (percent) number / 100 else number;
        return @intFromFloat(@round(std.math.clamp(normalized, 0, 1) * 255));
    }

    fn parseFunctionalRgb(input: []const u8) !RGBA {
        const opening = std.mem.indexOfScalar(u8, input, '(') orelse return error.Invalid;
        if (input.len < opening + 2 or input[input.len - 1] != ')') return error.Invalid;
        const function_name = std.mem.trim(u8, input[0..opening], " \t\r\n\x0c");
        if (!std.ascii.eqlIgnoreCase(function_name, "rgb") and !std.ascii.eqlIgnoreCase(function_name, "rgba")) {
            return error.Invalid;
        }

        const body = input[opening + 1 .. input.len - 1];
        var components: [4][]const u8 = undefined;
        var count: usize = 0;
        if (std.mem.indexOfScalar(u8, body, ',')) |_| {
            // Legacy comma syntax does not allow a slash separator.
            if (std.mem.indexOfScalar(u8, body, '/') != null) return error.Invalid;
            var iterator = std.mem.splitScalar(u8, body, ',');
            while (iterator.next()) |part| {
                if (count == components.len) return error.Invalid;
                const token = std.mem.trim(u8, part, " \t\r\n\x0c");
                if (token.len == 0) return error.Invalid;
                components[count] = token;
                count += 1;
            }
        } else {
            // CSS Color 4 space syntax: rgb(R G B / A).
            var iterator = std.mem.tokenizeAny(u8, body, " \t\r\n\x0c/");
            while (iterator.next()) |token| {
                if (count == components.len) return error.Invalid;
                components[count] = token;
                count += 1;
            }
        }

        if (count != 3 and count != 4) return error.Invalid;
        return .{
            .r = try parseRgbChannel(components[0]),
            .g = try parseRgbChannel(components[1]),
            .b = try parseRgbChannel(components[2]),
            .a = if (count == 4) try parseAlpha(components[3]) else 255,
        };
    }

    /// Color with float precision. hsl()/hwb() colors have sub-8-bit precision
    /// that Chrome carries end-to-end (e.g. hsl(45,80%,50%) = (0.9,0.7,0.1));
    /// the u8 RGBA is kept for CSS serialization, the float channels for the
    /// rendering pipeline.
    pub const ColorSpace = enum(i32) {
        srgb = 0,
        display_p3 = 1,
    };

    pub const Float = struct {
        rgba: RGBA,
        f: [4]f32,
        color_space: ColorSpace = .srgb,

        /// Canvas CSSOM keeps wide-gamut colors in `color(display-p3 ...)`
        /// form instead of collapsing them to an 8-bit sRGB serialization.
        pub fn format(self: *const Float, writer: *Io.Writer) Io.Writer.Error!void {
            if (self.color_space == .srgb) return self.rgba.format(writer);

            try writer.print(
                "color(display-p3 {d} {d} {d}",
                .{ self.f[0], self.f[1], self.f[2] },
            );
            if (self.f[3] != 1.0) try writer.print(" / {d}", .{self.f[3]});
            try writer.writeByte(')');
        }
    };

    fn u8Of(v: f32) u8 {
        return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
    }

    fn f32Of(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    /// Full-precision parse: hex/rgb()/named round-trip exactly; hsl()/hwb()
    /// follow the CSS Color 4 algorithm in f32 (gfx::HSLToSRGB/HWBToSRGB).
    pub fn parseFloat(input: []const u8) !Float {
        const trimmed = std.mem.trim(u8, input, " \t\r\n\x0c");
        if (parseFunctionalDisplayP3(trimmed)) |parsed| return parsed;
        if (!isHexColor(trimmed)) {
            if (find(trimmed)) |named| {
                return .{ .rgba = named, .f = .{ f32Of(named.r), f32Of(named.g), f32Of(named.b), f32Of(named.a) } };
            }
            if (parseFunctionalHslHwb(trimmed)) |parsed| return parsed;
        }
        const rgba = try parse(trimmed);
        return .{ .rgba = rgba, .f = .{ f32Of(rgba.r), f32Of(rgba.g), f32Of(rgba.b), f32Of(rgba.a) } };
    }

    fn parseColorComponent(token_raw: []const u8) !f32 {
        const token = std.mem.trim(u8, token_raw, " \t\r\n\x0c");
        if (token.len == 0) return error.Invalid;
        if (std.ascii.eqlIgnoreCase(token, "none")) return 0;
        const percent = token[token.len - 1] == '%';
        const value = std.fmt.parseFloat(
            f32,
            if (percent) token[0 .. token.len - 1] else token,
        ) catch return error.Invalid;
        if (!std.math.isFinite(value)) return error.Invalid;
        // CSS Color 4 preserves extended-range color() components. Percentages
        // are normalized but deliberately not clamped; the destination color
        // space conversion is responsible for gamut mapping.
        return if (percent) value / 100.0 else value;
    }

    fn parseFunctionalDisplayP3(input: []const u8) ?Float {
        const opening = std.mem.indexOfScalar(u8, input, '(') orelse return null;
        if (input.len < opening + 2 or input[input.len - 1] != ')') return null;
        if (!std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, input[0..opening], " \t\r\n\x0c"),
            "color",
        )) return null;

        const body = input[opening + 1 .. input.len - 1];
        var tokens: [5][]const u8 = undefined;
        var count: usize = 0;
        var iterator = std.mem.tokenizeAny(u8, body, " \t\r\n\x0c/");
        while (iterator.next()) |token| {
            if (count == tokens.len) return null;
            tokens[count] = token;
            count += 1;
        }
        if ((count != 4 and count != 5) or
            !std.ascii.eqlIgnoreCase(tokens[0], "display-p3"))
        {
            return null;
        }

        const r = parseColorComponent(tokens[1]) catch return null;
        const g = parseColorComponent(tokens[2]) catch return null;
        const b = parseColorComponent(tokens[3]) catch return null;
        const a = if (count == 5) parseAlphaF(tokens[4]) catch return null else 1.0;
        return .{
            .rgba = .{
                .r = u8Of(r),
                .g = u8Of(g),
                .b = u8Of(b),
                .a = u8Of(a),
            },
            .f = .{ r, g, b, a },
            .color_space = .display_p3,
        };
    }

    fn parseHue(token_raw: []const u8) !f32 {
        const token = std.mem.trim(u8, token_raw, " \t\r\n\x0c");
        if (token.len == 0) return error.Invalid;
        var value: f32 = undefined;
        if (std.mem.endsWith(u8, token, "deg")) {
            value = std.fmt.parseFloat(f32, token[0 .. token.len - 3]) catch return error.Invalid;
        } else if (std.mem.endsWith(u8, token, "grad")) {
            value = (std.fmt.parseFloat(f32, token[0 .. token.len - 4]) catch return error.Invalid) * 0.9;
        } else if (std.mem.endsWith(u8, token, "rad")) {
            value = (std.fmt.parseFloat(f32, token[0 .. token.len - 3]) catch return error.Invalid) * (180.0 / std.math.pi);
        } else if (std.mem.endsWith(u8, token, "turn")) {
            value = (std.fmt.parseFloat(f32, token[0 .. token.len - 4]) catch return error.Invalid) * 360.0;
        } else {
            value = std.fmt.parseFloat(f32, token) catch return error.Invalid;
        }
        if (!std.math.isFinite(value)) return error.Invalid;
        // CSS hue wraps (negative values wrap around the circle).
        const wrapped = @mod(value, 360.0);
        return wrapped;
    }

    fn parsePercent(token_raw: []const u8) !f32 {
        const token = std.mem.trim(u8, token_raw, " \t\r\n\x0c");
        if (token.len < 2 or token[token.len - 1] != '%') return error.Invalid;
        const number = std.fmt.parseFloat(f32, token[0 .. token.len - 1]) catch return error.Invalid;
        if (!std.math.isFinite(number)) return error.Invalid;
        return std.math.clamp(number / 100.0, 0, 1);
    }

    fn parseAlphaF(token_raw: []const u8) !f32 {
        const token = std.mem.trim(u8, token_raw, " \t\r\n\x0c");
        if (token.len == 0) return error.Invalid;
        if (token[token.len - 1] == '%') {
            const number = std.fmt.parseFloat(f32, token[0 .. token.len - 1]) catch return error.Invalid;
            if (!std.math.isFinite(number)) return error.Invalid;
            return std.math.clamp(number / 100.0, 0, 1);
        }
        const number = std.fmt.parseFloat(f32, token) catch return error.Invalid;
        if (!std.math.isFinite(number)) return error.Invalid;
        return std.math.clamp(number, 0, 1);
    }

    /// gfx::HSLToSRGB (ui/gfx/color_conversions.cc) — CSS Color 4 hsl-to-rgb,
    /// f32 arithmetic (fmod is evaluated in f64 there and here).
    fn hslToSrgb(h: f32, s: f32, l: f32) [3]f32 {
        if (s == 0) return .{ l, l, l };
        const a = s * @min(l, 1.0 - l);
        const F = struct {
            h: f32,
            l: f32,
            a: f32,
            fn f(self: @This(), n: f32) f32 {
                const k: f32 = @floatCast(@mod(@as(f64, n + self.h / 30.0), 12.0));
                const lo = @min(@min(k - 3.0, 9.0 - k), @as(f32, 1.0));
                return self.l - self.a * @max(-1.0, lo);
            }
        };
        const ctx: F = .{ .h = h, .l = l, .a = a };
        return .{ ctx.f(0), ctx.f(8), ctx.f(4) };
    }

    /// gfx::HWBToSRGB.
    fn hwbToSrgb(h: f32, w: f32, b: f32) [3]f32 {
        if (w + b >= 1.0) {
            const gray = w / (w + b);
            return .{ gray, gray, gray };
        }
        var rgb = hslToSrgb(h, 1.0, 0.5);
        for (&rgb) |*c| {
            c.* = c.* + w - (w + b) * c.*;
        }
        return rgb;
    }

    fn parseFunctionalHslHwb(input: []const u8) ?Float {
        const opening = std.mem.indexOfScalar(u8, input, '(') orelse return null;
        if (input.len < opening + 2 or input[input.len - 1] != ')') return null;
        const function_name = std.mem.trim(u8, input[0..opening], " \t\r\n\x0c");
        const is_hsl = std.ascii.eqlIgnoreCase(function_name, "hsl") or std.ascii.eqlIgnoreCase(function_name, "hsla");
        const is_hwb = std.ascii.eqlIgnoreCase(function_name, "hwb");
        if (!is_hsl and !is_hwb) return null;

        const body = input[opening + 1 .. input.len - 1];
        var components: [4][]const u8 = undefined;
        var count: usize = 0;
        if (std.mem.indexOfScalar(u8, body, ',')) |_| {
            if (std.mem.indexOfScalar(u8, body, '/') != null) return null;
            var iterator = std.mem.splitScalar(u8, body, ',');
            while (iterator.next()) |part| {
                if (count == components.len) return null;
                const token = std.mem.trim(u8, part, " \t\r\n\x0c");
                if (token.len == 0) return null;
                components[count] = token;
                count += 1;
            }
        } else {
            var iterator = std.mem.tokenizeAny(u8, body, " \t\r\n\x0c/");
            while (iterator.next()) |token| {
                if (count == components.len) return null;
                components[count] = token;
                count += 1;
            }
        }
        if (count != 3 and count != 4) return null;

        const hue = parseHue(components[0]) catch return null;
        const p1 = parsePercent(components[1]) catch return null;
        const p2 = parsePercent(components[2]) catch return null;
        const alpha = if (count == 4) parseAlphaF(components[3]) catch return null else 1.0;
        const rgb = if (is_hsl) hslToSrgb(hue, p1, p2) else hwbToSrgb(hue, p1, p2);
        return .{
            .rgba = .{ .r = u8Of(rgb[0]), .g = u8Of(rgb[1]), .b = u8Of(rgb[2]), .a = u8Of(alpha) },
            .f = .{ rgb[0], rgb[1], rgb[2], alpha },
        };
    }

    /// Parses the given color.
    /// Supports the basic CSS colors used by Canvas 2D: named colors, hex,
    /// rgb()/rgba() legacy comma syntax and CSS Color 4 space/slash syntax.
    pub fn parse(input: []const u8) !RGBA {
        const trimmed = std.mem.trim(u8, input, " \t\r\n\x0c");
        if (!isHexColor(trimmed)) {
            // Try named colors.
            if (find(trimmed)) |named| return named;
            if (parseFunctionalHslHwb(trimmed)) |parsed| return parsed.rgba;
            return parseFunctionalRgb(trimmed);
        }

        const slice = trimmed[1..];
        switch (slice.len) {
            // This means the digit for a color is repeated.
            // Given HEX is #f0c, its interpreted the same as #FF00CC.
            3 => {
                const r = try std.fmt.parseInt(u8, &.{ slice[0], slice[0] }, 16);
                const g = try std.fmt.parseInt(u8, &.{ slice[1], slice[1] }, 16);
                const b = try std.fmt.parseInt(u8, &.{ slice[2], slice[2] }, 16);
                return .{ .r = r, .g = g, .b = b, .a = 255 };
            },
            4 => {
                const r = try std.fmt.parseInt(u8, &.{ slice[0], slice[0] }, 16);
                const g = try std.fmt.parseInt(u8, &.{ slice[1], slice[1] }, 16);
                const b = try std.fmt.parseInt(u8, &.{ slice[2], slice[2] }, 16);
                const a = try std.fmt.parseInt(u8, &.{ slice[3], slice[3] }, 16);
                return .{ .r = r, .g = g, .b = b, .a = a };
            },
            // Regular HEX format.
            6 => {
                const r = try std.fmt.parseInt(u8, slice[0..2], 16);
                const g = try std.fmt.parseInt(u8, slice[2..4], 16);
                const b = try std.fmt.parseInt(u8, slice[4..6], 16);
                return .{ .r = r, .g = g, .b = b, .a = 255 };
            },
            8 => {
                const r = try std.fmt.parseInt(u8, slice[0..2], 16);
                const g = try std.fmt.parseInt(u8, slice[2..4], 16);
                const b = try std.fmt.parseInt(u8, slice[4..6], 16);
                const a = try std.fmt.parseInt(u8, slice[6..8], 16);
                return .{ .r = r, .g = g, .b = b, .a = a };
            },
            else => return error.Invalid,
        }
    }

    /// By default, browsers prefer lowercase formatting.
    const format_upper = false;

    /// Formats the `Color` according to web expectations.
    /// If color is opaque, HEX is preferred; RGBA otherwise.
    pub fn format(self: *const RGBA, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.isOpaque()) {
            // Convert RGB to HEX.
            // https://gristle.tripod.com/hexconv.html
            // Hexadecimal characters up to 15.
            const char: []const u8 = "0123456789" ++ if (format_upper) "ABCDEF" else "abcdef";
            // This variant always prefers 6 digit format, +1 is for hash char.
            const buffer = [7]u8{
                '#',
                char[self.r >> 4],
                char[self.r & 15],
                char[self.g >> 4],
                char[self.g & 15],
                char[self.b >> 4],
                char[self.b & 15],
            };

            return writer.writeAll(&buffer);
        }

        // CSSOM serializes an 8-bit alpha with the shortest decimal (up to
        // three fractional digits) that round-trips to the same byte.  This
        // is observably different from fixed precision: Chrome emits `0`,
        // `0.5`, `0.06`, and `0.004` for alpha bytes 0, 128, 15, and 1.
        try writer.print("rgba({d}, {d}, {d}, ", .{ self.r, self.g, self.b });
        switch (alphaSerializationPrecision(self.a)) {
            0 => try writer.writeByte('0'),
            1 => try writer.print("{d:.1}", .{self.normalizedAlpha()}),
            2 => try writer.print("{d:.2}", .{self.normalizedAlpha()}),
            3 => try writer.print("{d:.3}", .{self.normalizedAlpha()}),
        }
        return writer.writeByte(')');
    }

    /// Returns true if `Color` is opaque.
    pub inline fn isOpaque(self: *const RGBA) bool {
        return self.a == std.math.maxInt(u8);
    }

    /// Returns the normalized alpha value.
    pub inline fn normalizedAlpha(self: *const RGBA) f32 {
        return @as(f32, @floatFromInt(self.a)) / 255;
    }

    fn alphaSerializationPrecision(alpha_byte: u8) u2 {
        if (alpha_byte == 0) return 0;

        const alpha = @as(f64, @floatFromInt(alpha_byte)) / 255;
        inline for (.{ 10.0, 100.0, 1000.0 }, 1..) |scale, precision| {
            const candidate = @round(alpha * scale) / scale;
            const round_trip: u8 = @intFromFloat(@round(candidate * 255));
            if (round_trip == alpha_byte) return precision;
        }
        unreachable;
    }
};

test "RGBA uses Chrome-compatible shortest alpha serialization" {
    const cases = .{
        .{ 0, "rgba(1, 2, 3, 0)" },
        .{ 1, "rgba(1, 2, 3, 0.004)" },
        .{ 2, "rgba(1, 2, 3, 0.008)" },
        .{ 15, "rgba(1, 2, 3, 0.06)" },
        .{ 16, "rgba(1, 2, 3, 0.063)" },
        .{ 127, "rgba(1, 2, 3, 0.498)" },
        .{ 128, "rgba(1, 2, 3, 0.5)" },
        .{ 129, "rgba(1, 2, 3, 0.506)" },
        .{ 254, "rgba(1, 2, 3, 0.996)" },
    };

    inline for (cases) |case| {
        var output = Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        const value: RGBA = .{ .r = 1, .g = 2, .b = 3, .a = case[0] };
        try value.format(&output.writer);
        try std.testing.expectEqualStrings(case[1], output.written());
    }
}

test "RGBA parses and serializes display-p3 float colors without quantizing" {
    const parsed = try RGBA.parseFloat("color(display-p3 1 0 25% / 50%)");
    try std.testing.expectEqual(RGBA.ColorSpace.display_p3, parsed.color_space);
    try std.testing.expectEqual(@as(f32, 1), parsed.f[0]);
    try std.testing.expectEqual(@as(f32, 0), parsed.f[1]);
    try std.testing.expectEqual(@as(f32, 0.25), parsed.f[2]);
    try std.testing.expectEqual(@as(f32, 0.5), parsed.f[3]);

    var output = Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try parsed.format(&output.writer);
    try std.testing.expectEqualStrings(
        "color(display-p3 1 0 0.25 / 0.5)",
        output.written(),
    );
}
