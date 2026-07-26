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

const CanvasSurface = @import("../../canvas_backend/Surface.zig");
const Page = @import("../../Page.zig");
const adapter = @import("../../../canvas_backend/adapter.zig");
const CanvasMatrix2DInit = @import("CanvasMatrix2DInit.zig");

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasPattern
/// Opaque pattern object created by createPattern. Canvas and OffscreenCanvas
/// source pixels are captured at creation, matching Chrome's snapshot
/// semantics.
const CanvasPattern = @This();

pub const Repetition = adapter.PatternRepetition;

_pixels: []u8,
_width: u32,
_height: u32,
_row_bytes: usize,
_repetition: Repetition,
_transform: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
_handle: ?*CanvasSurface.StyleHandle = null,
_api: ?*const adapter.Api = null,
_rc: lp.RC(u8) = .{},

pub fn init(pixels: []u8, width: u32, height: u32, repetition: Repetition) CanvasPattern {
    return .{
        ._pixels = pixels,
        ._width = width,
        ._height = height,
        ._row_bytes = @as(usize, width) * 4,
        ._repetition = repetition,
    };
}

pub fn deinit(self: *CanvasPattern, _: *Page) void {
    self.releaseHandle();
}

pub fn acquireRef(self: *CanvasPattern) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *CanvasPattern, page: *Page) void {
    self._rc.release(self, page);
}

/// Replace the pattern's local transform. The backend style object is shared by
/// every drawing state using this pattern, so changes remain live after the
/// pattern has already been assigned to fillStyle or strokeStyle.
pub fn setTransform(self: *CanvasPattern, matrix: ?js.Value, exec: *Execution) !void {
    const next = try CanvasMatrix2DInit.parseForInterface(
        matrix,
        "CanvasPattern",
        "setTransform",
        exec,
    );
    for (next) |component| {
        // CanvasTransform.setTransform silently ignores a non-invertible
        // non-finite dictionary rather than poisoning a live pattern object.
        if (!std.math.isFinite(component)) return;
    }
    self._transform = next;
    if (self._handle) |handle| {
        if (self._api) |api| try api.setPatternTransform(handle, self._transform);
    }
}

/// Lazily realize the backend style object.
pub fn realize(self: *CanvasPattern, surface: *CanvasSurface) !?*CanvasSurface.StyleHandle {
    if (self._handle) |handle| return handle;
    const owned = surface.backend() orelse return null;
    const handle = try owned.createPattern(
        self._pixels,
        self._width,
        self._height,
        self._row_bytes,
        self._repetition,
    );
    errdefer owned.freeStyleObject(handle) catch {};
    try owned.setPatternTransform(handle, self._transform);
    self._handle = handle;
    self._api = owned.api;
    return handle;
}

fn releaseHandle(self: *CanvasPattern) void {
    const handle = self._handle orelse return;
    const api = self._api orelse {
        self._handle = null;
        return;
    };
    self._handle = null;
    self._api = null;
    api.freeStyleObject(handle) catch |err| {
        std.log.err("CanvasPattern style teardown failed: {s}", .{@errorName(err)});
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasPattern);

    pub const Meta = struct {
        pub const name = "CanvasPattern";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const setTransform = bridge.function(CanvasPattern.setTransform, .{});
};
