// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const color = @import("../../color.zig");
const Page = @import("../../Page.zig");
const CanvasException = @import("CanvasException.zig");

const CanvasSurface = @import("../../canvas_backend/Surface.zig");
const adapter = @import("../../../canvas_backend/adapter.zig");

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasGradient
/// Opaque gradient object created by createLinearGradient /
/// createRadialGradient / createConicGradient. Holds the stop list JS-side
/// (float colors — hsl stops have sub-8-bit precision in Chrome) and the
/// backend style handle once realized against a dynamic surface.
const CanvasGradient = @This();

pub const Kind = adapter.GradientKind;

/// Geometry parameters, backend layout:
///   linear: x0,y0,x1,y1 ; radial: x0,y0,r0,x1,y1,r1 ; conic: startRad,cx,cy.
_points: [6]f32,
_kind: Kind,
/// (r,g,b,a) extended-sRGB float stops + positions, stably sorted by offset.
_colors: std.ArrayList([4]f32) = .empty,
_positions: std.ArrayList(f32) = .empty,
_handle: ?*CanvasSurface.StyleHandle = null,
_api: ?*const adapter.Api = null,
_rc: lp.RC(u8) = .{},

pub fn init(kind: Kind, points: [6]f32) CanvasGradient {
    return .{ ._kind = kind, ._points = points };
}

pub fn deinit(self: *CanvasGradient, _: *Page) void {
    self.releaseHandle();
}

pub fn acquireRef(self: *CanvasGradient) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *CanvasGradient, page: *Page) void {
    self._rc.release(self, page);
}

/// Chrome: offset outside [0,1] throws IndexSizeError; an unparsable color
/// throws SyntaxError.
pub fn addColorStop(self: *CanvasGradient, offset_value: js.Value, color_value: js.Value, exec: *Execution) !void {
    const operation: js.WebIDL.Operation = .{
        .interface = "CanvasGradient",
        .name = "addColorStop",
    };
    const offset = try js.WebIDL.toNumber(offset_value, exec, .{
        .interface = "CanvasGradient",
        .name = "addColorStop",
    });
    if (!std.math.isFinite(offset)) {
        return CanvasException.gradientTypeError(
            exec,
            "addColorStop",
            "The provided double value is non-finite.",
        );
    }
    // Web IDL converts the DOMString argument before native range validation.
    // A throwing color conversion therefore wins over an out-of-range offset,
    // while a non-finite restricted double still fails immediately above.
    const color_text = try js.WebIDL.toDOMString(color_value, exec, operation);
    if (offset < 0 or offset > 1) {
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The provided value ({d}) is outside the range (0.0, 1.0).",
            .{offset},
        );
        return CanvasException.gradientDOMException(
            exec,
            "addColorStop",
            "IndexSizeError",
            reason,
        );
    }
    const parsed = color.RGBA.parseFloat(color_text) catch {
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "The value provided ('{s}') could not be parsed as a color.",
            .{color_text},
        );
        return CanvasException.gradientDOMException(
            exec,
            "addColorStop",
            "SyntaxError",
            reason,
        );
    };

    // CanvasGradient keeps equal-offset stops in author order, while stops
    // supplied out of order are rendered in ascending offset order.
    const position: f32 = @floatCast(offset);
    var insertion_index = self._positions.items.len;
    while (insertion_index > 0 and self._positions.items[insertion_index - 1] > position) {
        insertion_index -= 1;
    }
    try self._colors.insert(exec.arena, insertion_index, gradientStopColor(parsed));
    errdefer _ = self._colors.orderedRemove(insertion_index);
    try self._positions.insert(exec.arena, insertion_index, position);
    // The realized handle is stale once the stop list changes. Release it
    // before clearing the cache so repeated rebuilds cannot leak or double-free.
    self.releaseHandle();
}

fn srgbToLinear(component: f32) f32 {
    const sign: f32 = if (component < 0) -1 else 1;
    const magnitude = @abs(component);
    if (magnitude <= 0.04045) return component / 12.92;
    return sign * std.math.pow(f32, (magnitude + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(component: f32) f32 {
    const sign: f32 = if (component < 0) -1 else 1;
    const magnitude = @abs(component);
    if (magnitude <= 0.0031308) return component * 12.92;
    return sign * (1.055 * std.math.pow(f32, magnitude, 1.0 / 2.4) - 0.055);
}

/// The current gradient ABI consumes untagged extended-sRGB stops. Convert
/// display-p3 CSS colors before crossing it; do not clamp out-of-gamut values,
/// because the destination SkColorSpace performs the final gamut mapping.
fn gradientStopColor(parsed: color.RGBA.Float) [4]f32 {
    if (parsed.color_space == .srgb) return parsed.f;

    const p3_r = srgbToLinear(parsed.f[0]);
    const p3_g = srgbToLinear(parsed.f[1]);
    const p3_b = srgbToLinear(parsed.f[2]);
    const srgb_r = 1.2247453 * p3_r - 0.2249044 * p3_g - 0.0000001 * p3_b;
    const srgb_g = -0.0420581 * p3_r + 1.0420810 * p3_g - 0.0000001 * p3_b;
    const srgb_b = -0.0196423 * p3_r - 0.0786549 * p3_g + 1.0985372 * p3_b;
    return .{
        linearToSrgb(srgb_r),
        linearToSrgb(srgb_g),
        linearToSrgb(srgb_b),
        parsed.f[3],
    };
}

/// Lazily realize the backend style object. The backend gradient is surface
/// -agnostic once created but creation requires a live dynamic surface.
pub fn realize(self: *CanvasGradient, surface: *CanvasSurface) !?*CanvasSurface.StyleHandle {
    if (self._handle) |handle| return handle;
    const owned = surface.backend() orelse return null;
    if (self._colors.items.len == 0) return null;
    const flat: []const f32 = @as([*]const f32, @ptrCast(self._colors.items.ptr))[0 .. self._colors.items.len * 4];
    const handle = try owned.createGradientF(
        self._kind,
        self._points[0..pointCount(self._kind)],
        flat,
        self._positions.items,
        0,
    );
    self._handle = handle;
    self._api = owned.api;
    return handle;
}

fn releaseHandle(self: *CanvasGradient) void {
    const handle = self._handle orelse return;
    const api = self._api orelse {
        self._handle = null;
        return;
    };
    // Clear ownership before entering the backend, making teardown idempotent
    // even when a later caller observes or retries after an error.
    self._handle = null;
    self._api = null;
    api.freeStyleObject(handle) catch |err| {
        std.log.err("CanvasGradient style teardown failed: {s}", .{@errorName(err)});
    };
}

fn pointCount(kind: Kind) usize {
    return switch (kind) {
        .linear => 4,
        .radial => 6,
        .conic => 3,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasGradient);

    pub const Meta = struct {
        pub const name = "CanvasGradient";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const addColorStop = bridge.function(CanvasGradient.addColorStop, .{ .required_args = 2 });
};
