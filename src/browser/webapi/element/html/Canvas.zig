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
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");
const CanvasBackendProvider = @import("../../../canvas_backend/Provider.zig");
const CanvasSurface = @import("../../../canvas_backend/Surface.zig");

const Execution = js.Execution;

const Canvas = @This();
_proto: *HtmlElement,
_cached: ?DrawingContext = null,
// A surface remains owned by the Page's CanvasBackendProvider. Canvas keeps a
// non-owning handle so cached contexts survive dimension resets while the
// provider guarantees dynamic-library and thread-affinity lifetime ordering.
_surface_provider: ?*CanvasBackendProvider = null,
_surface: ?*CanvasSurface = null,
_bitmap_width: u32 = 300,
_bitmap_height: u32 = 150,

pub fn asElement(self: *Canvas) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn setWidth(self: *Canvas, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
    try self.resetBitmap();
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

pub fn setHeight(self: *Canvas, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
    try self.resetBitmap();
}

/// Invalidate the bitmap and reset the drawing state.  This must run even when
/// a dimension is assigned its current value: HTML canvas resize semantics are
/// reset semantics, not merely a size-change notification.
fn resetBitmap(self: *Canvas) !void {
    const width = self.getWidth();
    const height = self.getHeight();
    self._bitmap_width = width;
    self._bitmap_height = height;
    if (self._surface) |backing| try backing.resize(width, height);

    if (self._cached) |cached| switch (cached) {
        .@"2d" => |ctx| ctx.onCanvasResize(width, height),
        .webgl => {},
    };
}

/// Drop the current pixels without notifying the context.  The 2D context
/// uses this path to observe dimension changes made through setAttribute().
pub fn resetBitmapStorage(self: *Canvas, width: u32, height: u32) void {
    self._bitmap_width = width;
    self._bitmap_height = height;
    if (self._surface) |backing| {
        backing.resize(width, height) catch |err| backing.markFault(err);
    }
}

/// Lazily create the selected backend. Querying drawing state alone should
/// not allocate a 300x150 Skia surface for every canvas element on a page.
pub fn ensureSurface(self: *Canvas) !?*CanvasSurface {
    if (self._bitmap_width == 0 or self._bitmap_height == 0) return null;
    if (self._surface) |backing| {
        try backing.requireHealthy();
        return backing;
    }
    const provider = self._surface_provider orelse return error.InvalidStateError;
    const backing = try provider.createSurface(self._bitmap_width, self._bitmap_height);
    self._surface = backing;
    return backing;
}

pub fn surface(self: *Canvas) ?*CanvasSurface {
    return self._surface;
}

pub fn resetSurfaceStorage(self: *Canvas) !void {
    if (self._surface) |backing| {
        try backing.resize(self._bitmap_width, self._bitmap_height);
    }
}

pub fn bitmapWidth(self: *const Canvas) u32 {
    return self._bitmap_width;
}

pub fn bitmapHeight(self: *const Canvas) u32 {
    return self._bitmap_height;
}

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
};

pub fn getContext(self: *Canvas, context_type: []const u8, frame: *Frame) !?DrawingContext {
    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => std.mem.eql(u8, context_type, "2d"),
            .webgl => std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl"),
        };
        return if (matches) cached else null;
    }

    const drawing_context: DrawingContext = blk: {
        if (std.mem.eql(u8, context_type, "2d")) {
            self._surface_provider = &frame._page.canvas_backend;
            const ctx = try frame._factory.create(CanvasRenderingContext2D.init(self));
            break :blk .{ .@"2d" = ctx };
        }

        // We only stub a tiny slice of the WebGL API (getParameter,
        // getExtension, getSupportedExtensions). Real WebGL consumers like
        // Three.js immediately call createTexture/createBuffer/etc. and
        // throw `TypeError: e.createTexture is not a function`. Pretending
        // WebGL works until the first non-stubbed call is the worst of both
        // worlds: pages that have an error boundary above the WebGL widget
        // catch the throw, reset, re-render, and loop forever.
        // Spec-correct signal for "no WebGL" is null, so apps that check
        // (Three.js does) can degrade gracefully.
        if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
            return null;
        }
        return null;
    };
    self._cached = drawing_context;
    return drawing_context;
}

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, exec: *Execution) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    return OffscreenCanvas.constructor(width, height, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Canvas);

    pub const Meta = struct {
        pub const name = "HTMLCanvasElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(Canvas.getWidth, Canvas.setWidth, .{ .ce_reactions = true });
    pub const height = bridge.accessor(Canvas.getHeight, Canvas.setHeight, .{ .ce_reactions = true });
    pub const getContext = bridge.function(Canvas.getContext, .{});
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};
