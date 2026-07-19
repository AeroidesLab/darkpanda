// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");

const Allocator = std.mem.Allocator;

const FontFace = @This();

_rc: lp.RC(u8) = .{},
_arena: Allocator,
_family: []const u8,
_style: []const u8,
_weight: []const u8,
_stretch: []const u8,
_unicode_range: []const u8,
_variant: []const u8,
_feature_settings: []const u8,
_variation_settings: []const u8,
_display: []const u8,
_ascent_override: []const u8,
_descent_override: []const u8,
_line_gap_override: []const u8,
_size_adjust: []const u8,

const Descriptors = struct {
    ascentOverride: []const u8 = "normal",
    descentOverride: []const u8 = "normal",
    display: []const u8 = "auto",
    featureSettings: []const u8 = "normal",
    lineGapOverride: []const u8 = "normal",
    sizeAdjust: []const u8 = "100%",
    stretch: []const u8 = "normal",
    style: []const u8 = "normal",
    unicodeRange: []const u8 = "U+0-10FFFF",
    variant: []const u8 = "normal",
    variationSettings: []const u8 = "normal",
    weight: []const u8 = "normal",
};

pub fn init(family: []const u8, source: []const u8, descriptors_: ?Descriptors, frame: *Frame) !*FontFace {
    _ = source;
    const descriptors = descriptors_ orelse Descriptors{};

    const arena = try frame.getArena(.tiny, "FontFace");
    errdefer frame.releaseArena(arena);

    const self = try arena.create(FontFace);
    self.* = .{
        ._arena = arena,
        ._family = try arena.dupe(u8, family),
        ._style = try arena.dupe(u8, descriptors.style),
        ._weight = try arena.dupe(u8, descriptors.weight),
        ._stretch = try arena.dupe(u8, descriptors.stretch),
        ._unicode_range = try arena.dupe(u8, descriptors.unicodeRange),
        ._variant = try arena.dupe(u8, descriptors.variant),
        ._feature_settings = try arena.dupe(u8, descriptors.featureSettings),
        ._variation_settings = try arena.dupe(u8, descriptors.variationSettings),
        ._display = try arena.dupe(u8, descriptors.display),
        ._ascent_override = try arena.dupe(u8, descriptors.ascentOverride),
        ._descent_override = try arena.dupe(u8, descriptors.descentOverride),
        ._line_gap_override = try arena.dupe(u8, descriptors.lineGapOverride),
        ._size_adjust = try arena.dupe(u8, descriptors.sizeAdjust),
    };
    return self;
}

pub fn deinit(self: *FontFace, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *FontFace, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FontFace) void {
    self._rc.acquire();
}

pub fn getFamily(self: *const FontFace) []const u8 {
    return self._family;
}

pub fn setFamily(self: *FontFace, value: []const u8) !void {
    self._family = try self._arena.dupe(u8, value);
}

pub fn getStyle(self: *const FontFace) []const u8 {
    return self._style;
}

pub fn setStyle(self: *FontFace, value: []const u8) !void {
    self._style = try self._arena.dupe(u8, value);
}

pub fn getWeight(self: *const FontFace) []const u8 {
    return self._weight;
}

pub fn setWeight(self: *FontFace, value: []const u8) !void {
    self._weight = try self._arena.dupe(u8, value);
}

pub fn getStretch(self: *const FontFace) []const u8 {
    return self._stretch;
}

pub fn setStretch(self: *FontFace, value: []const u8) !void {
    self._stretch = try self._arena.dupe(u8, value);
}

pub fn getUnicodeRange(self: *const FontFace) []const u8 {
    return self._unicode_range;
}

pub fn setUnicodeRange(self: *FontFace, value: []const u8) !void {
    self._unicode_range = try self._arena.dupe(u8, value);
}

pub fn getVariant(self: *const FontFace) []const u8 {
    return self._variant;
}

pub fn setVariant(self: *FontFace, value: []const u8) !void {
    self._variant = try self._arena.dupe(u8, value);
}

pub fn getFeatureSettings(self: *const FontFace) []const u8 {
    return self._feature_settings;
}

pub fn setFeatureSettings(self: *FontFace, value: []const u8) !void {
    self._feature_settings = try self._arena.dupe(u8, value);
}

pub fn getVariationSettings(self: *const FontFace) []const u8 {
    return self._variation_settings;
}

pub fn setVariationSettings(self: *FontFace, value: []const u8) !void {
    self._variation_settings = try self._arena.dupe(u8, value);
}

pub fn getDisplay(self: *const FontFace) []const u8 {
    return self._display;
}

pub fn setDisplay(self: *FontFace, value: []const u8) !void {
    self._display = try self._arena.dupe(u8, value);
}

pub fn getAscentOverride(self: *const FontFace) []const u8 {
    return self._ascent_override;
}

pub fn setAscentOverride(self: *FontFace, value: []const u8) !void {
    self._ascent_override = try self._arena.dupe(u8, value);
}

pub fn getDescentOverride(self: *const FontFace) []const u8 {
    return self._descent_override;
}

pub fn setDescentOverride(self: *FontFace, value: []const u8) !void {
    self._descent_override = try self._arena.dupe(u8, value);
}

pub fn getLineGapOverride(self: *const FontFace) []const u8 {
    return self._line_gap_override;
}

pub fn setLineGapOverride(self: *FontFace, value: []const u8) !void {
    self._line_gap_override = try self._arena.dupe(u8, value);
}

pub fn getSizeAdjust(self: *const FontFace) []const u8 {
    return self._size_adjust;
}

pub fn setSizeAdjust(self: *FontFace, value: []const u8) !void {
    self._size_adjust = try self._arena.dupe(u8, value);
}

pub fn getStatus(_: *const FontFace) []const u8 {
    return "unloaded";
}

// load() - resolves immediately; headless browser has no real font loading.
pub fn load(_: *FontFace, frame: *Frame) !js.Promise {
    return frame.js.local.?.resolvePromise({});
}

// loaded - returns an already-resolved Promise.
pub fn getLoaded(_: *FontFace, frame: *Frame) !js.Promise {
    return frame.js.local.?.resolvePromise({});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FontFace);

    pub const Meta = struct {
        pub const name = "FontFace";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FontFace.init, .{});
    pub const family = bridge.accessor(FontFace.getFamily, FontFace.setFamily, .{});
    pub const style = bridge.accessor(FontFace.getStyle, FontFace.setStyle, .{});
    pub const weight = bridge.accessor(FontFace.getWeight, FontFace.setWeight, .{});
    pub const stretch = bridge.accessor(FontFace.getStretch, FontFace.setStretch, .{});
    pub const unicodeRange = bridge.accessor(FontFace.getUnicodeRange, FontFace.setUnicodeRange, .{});
    pub const variant = bridge.accessor(FontFace.getVariant, FontFace.setVariant, .{});
    pub const featureSettings = bridge.accessor(FontFace.getFeatureSettings, FontFace.setFeatureSettings, .{});
    pub const variationSettings = bridge.accessor(FontFace.getVariationSettings, FontFace.setVariationSettings, .{});
    pub const display = bridge.accessor(FontFace.getDisplay, FontFace.setDisplay, .{});
    pub const ascentOverride = bridge.accessor(FontFace.getAscentOverride, FontFace.setAscentOverride, .{});
    pub const descentOverride = bridge.accessor(FontFace.getDescentOverride, FontFace.setDescentOverride, .{});
    pub const lineGapOverride = bridge.accessor(FontFace.getLineGapOverride, FontFace.setLineGapOverride, .{});
    pub const sizeAdjust = bridge.accessor(FontFace.getSizeAdjust, FontFace.setSizeAdjust, .{});
    pub const status = bridge.accessor(FontFace.getStatus, null, .{});
    pub const loaded = bridge.accessor(FontFace.getLoaded, null, .{});
    pub const load = bridge.function(FontFace.load, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FontFace" {
    try testing.htmlRunner("css/font_face.html", .{});
}
