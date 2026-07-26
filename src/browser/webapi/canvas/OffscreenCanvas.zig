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
const js = @import("../../js/js.zig");

const Blob = @import("../Blob.zig");
const EventTarget = @import("../EventTarget.zig");
const CanvasException = @import("CanvasException.zig");
const ContextOptions = @import("ContextOptions.zig");
const OffscreenCanvasRenderingContext2D = @import("OffscreenCanvasRenderingContext2D.zig");
const CanvasSurface = @import("../../canvas_backend/Surface.zig");
const CanvasBackendProvider = @import("../../canvas_backend/Provider.zig");

const Execution = js.Execution;

/// https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas
const OffscreenCanvas = @This();

/// Chrome: OffscreenCanvas -> EventTarget -> Object (it is an event target for
/// contextlost/contextrestored). The _proto field wires the prototype chain.
_proto: *EventTarget,

_width: u32,
_height: u32,
/// Backing surface, owned by the Page's CanvasBackendProvider like HTML canvas.
_surface_provider: ?*CanvasBackendProvider = null,
_surface: ?*CanvasSurface = null,
_surface_flags: u32 = 0,
_cached: ?*OffscreenCanvasRenderingContext2D = null,

/// Since there's no base class rendering contexts inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *OffscreenCanvasRenderingContext2D,
};

const DimensionTarget = enum {
    constructor,
    width,
    height,

    fn conversionContext(self: DimensionTarget) js.WebIDL.ConversionContext {
        return switch (self) {
            .constructor => .{ .constructor = "OffscreenCanvas" },
            .width => .{ .attribute_set = .{
                .interface = "OffscreenCanvas",
                .name = "width",
            } },
            .height => .{ .attribute_set = .{
                .interface = "OffscreenCanvas",
                .name = "height",
            } },
        };
    }
};

/// OffscreenCanvas dimensions are `[EnforceRange] unsigned long` in Web IDL.
/// Blink performs that conversion before touching the bitmap, then clamps the
/// accepted unsigned value to the signed dimension type used by its canvas
/// implementation.
fn canvasDimension(value: js.Value, target: DimensionTarget, exec: *Execution) !u32 {
    const context = target.conversionContext();
    const number = try js.WebIDL.toNumberWithContext(value, exec, context);

    const reason = if (std.math.isNan(number))
        "Value is not of type 'unsigned long'."
    else if (std.math.isInf(number))
        "Value is infinite and not of type 'unsigned long'."
    else blk: {
        const integer = @trunc(number);
        if (integer < 0 or integer > @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
            break :blk "Value is outside the 'unsigned long' value range.";
        }

        const maximum_canvas_dimension: f64 = @floatFromInt(std.math.maxInt(i32));
        return @intFromFloat(@min(integer, maximum_canvas_dimension));
    };

    return js.WebIDL.contextualTypeError(exec, context, reason);
}

fn construct(width_value: js.Value, height_value: js.Value, exec: *Execution) !*OffscreenCanvas {
    // Convert in argument order and allocate only after both conversions have
    // succeeded. A failure therefore cannot create or fault a backing surface.
    const width = try canvasDimension(width_value, .constructor, exec);
    const height = try canvasDimension(height_value, .constructor, exec);
    return constructor(width, height, exec);
}

/// Native construction path used when HTMLCanvasElement transfers its already
/// validated dimensions to an OffscreenCanvas.
pub fn constructor(width: u32, height: u32, exec: *Execution) !*OffscreenCanvas {
    return exec._factory.eventTarget(OffscreenCanvas{
        ._proto = undefined,
        ._width = width,
        ._height = height,
    });
}

pub fn asEventTarget(self: *OffscreenCanvas) *EventTarget {
    return self._proto;
}

/// Lazily create the backend surface (same provider as HTML canvas).
pub fn ensureSurface(self: *OffscreenCanvas) !?*CanvasSurface {
    if (self._width == 0 or self._height == 0) return null;
    if (self._surface) |backing| {
        try backing.requireHealthy();
        return backing;
    }
    const provider = self._surface_provider orelse return error.InvalidStateError;
    const backing = try provider.createSurface(self._width, self._height, self._surface_flags);
    self._surface = backing;
    return backing;
}

pub fn surface(self: *OffscreenCanvas) ?*CanvasSurface {
    return self._surface;
}

/// Drop the current pixels (mirrors HTMLCanvasElement.resetSurfaceStorage).
pub fn resetSurfaceStorage(self: *OffscreenCanvas) !void {
    if (self._surface) |backing| {
        try backing.resize(self._width, self._height);
    }
}

/// Resize semantics mirror HTML canvas: the bitmap resets and the context's
/// drawing state resets even when assigning the current value.
pub fn getWidth(self: *const OffscreenCanvas) u32 {
    return self._width;
}

pub fn setWidth(self: *OffscreenCanvas, raw_value: js.Value, exec: *Execution) !void {
    const value = try canvasDimension(raw_value, .width, exec);
    self._width = value;
    if (self._surface) |backing| backing.resize(value, self._height) catch |err| backing.markFault(err);
    if (self._cached) |ctx| ctx.onCanvasResize(value, self._height);
}

pub fn getHeight(self: *const OffscreenCanvas) u32 {
    return self._height;
}

pub fn setHeight(self: *OffscreenCanvas, raw_value: js.Value, exec: *Execution) !void {
    const value = try canvasDimension(raw_value, .height, exec);
    self._height = value;
    if (self._surface) |backing| backing.resize(self._width, value) catch |err| backing.markFault(err);
    if (self._cached) |ctx| ctx.onCanvasResize(self._width, value);
}

/// Resize the bitmap without notifying the context (mirrors
/// HTMLCanvasElement.resetBitmapStorage for the context's dimension sync).
pub fn resizeBitmapStorage(self: *OffscreenCanvas, width: u32, height: u32) void {
    self._width = width;
    self._height = height;
    if (self._surface) |backing| {
        backing.resize(width, height) catch |err| backing.markFault(err);
    }
}

pub fn getContext(
    self: *OffscreenCanvas,
    context_type: []const u8,
    raw_options: ?js.Value,
    exec: *Execution,
) !?DrawingContext {
    if (std.mem.eql(u8, context_type, "2d")) {
        const attributes = try ContextOptions.parse(raw_options, exec, .offscreen_canvas);
        self._surface_provider = &exec.page.canvas_backend;
        if (self._cached) |ctx| return .{ .@"2d" = ctx };
        self._surface_flags = attributes.surfaceFlags();
        // Blink materializes OffscreenCanvas storage with its first context.
        // This differs from HTMLCanvasElement's lazy backing and makes an
        // untouched alpha:false OffscreenCanvas read as opaque black.
        _ = try self.ensureSurface();
        const ctx = try exec._factory.create(OffscreenCanvasRenderingContext2D.init(self, attributes));
        self._cached = ctx;
        return .{ .@"2d" = ctx };
    }

    return null;
}

fn convertOptionsContext(member: []const u8) js.WebIDL.ConversionContext {
    return .{ .dictionary_member = .{
        .parent = .{ .operation = .{
            .interface = "OffscreenCanvas",
            .name = "convertToBlob",
        } },
        .dictionary = "ImageEncodeOptions",
        .member = member,
    } };
}

fn parseConvertToBlobOptions(raw_options: ?js.Value, exec: *Execution) !ConvertToBlobOptions {
    const raw = raw_options orelse return .{};
    if (raw.isNullOrUndefined()) return .{};
    if (!raw.isObject()) {
        const reason = "The provided value is not of type 'ImageEncodeOptions'.";
        return CanvasException.typeErrorWithStackReason(
            exec,
            "OffscreenCanvas",
            "convertToBlob",
            reason,
            reason,
        );
    }

    const object = raw.toObject();
    var result: ConvertToBlobOptions = .{};

    const raw_quality = object.get("quality") catch return error.TryCatchRethrow;
    if (!raw_quality.isUndefined()) {
        result.quality = try js.WebIDL.toNumberWithContext(
            raw_quality,
            exec,
            convertOptionsContext("quality"),
        );
    }

    const raw_type = object.get("type") catch return error.TryCatchRethrow;
    if (!raw_type.isUndefined()) {
        result.type = try js.WebIDL.toDOMStringWithContext(
            raw_type,
            exec,
            convertOptionsContext("type"),
        );
    }
    return result;
}

const ConvertToBlobTask = struct {
    exec: *Execution,
    resolver: js.PromiseResolver.Global,
    blob: *Blob,

    fn finish(self: *ConvertToBlobTask) void {
        self.resolver.release();
        self.blob.releaseRef(self.exec.page);
        self.exec._factory.destroy(self);
    }

    fn cancelled(raw: *anyopaque) void {
        const self: *ConvertToBlobTask = @ptrCast(@alignCast(raw));
        self.finish();
    }

    fn run(raw: *anyopaque) !?u32 {
        const self: *ConvertToBlobTask = @ptrCast(@alignCast(raw));
        defer self.finish();

        if (self.exec.isShuttingDown()) return null;

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        self.resolver.local(&ls.local).resolve(
            "OffscreenCanvas.convertToBlob",
            self.blob,
        );
        return null;
    }
};

/// Returns a Promise that resolves to a Blob with the encoded bitmap (PNG by
/// default; JPEG with Chrome's quality mapping when asked). Successful
/// serialization settles from a low-priority canvas task, after already queued
/// microtasks and zero-delay timers. Validation and dictionary failures keep
/// their immediate rejected-Promise behavior.
pub fn convertToBlob(self: *OffscreenCanvas, raw_options: ?js.Value, exec: *Execution) !js.Promise {
    const opts = try parseConvertToBlobOptions(raw_options, exec);
    if (self._width == 0 or self._height == 0) {
        return CanvasException.rejectedDOMException(
            exec,
            "OffscreenCanvas",
            "convertToBlob",
            "IndexSizeError",
            "The size of \"OffscreenCanvas\" is zero.",
        );
    }
    if (self._cached == null) {
        return CanvasException.rejectedDOMException(
            exec,
            "OffscreenCanvas",
            "convertToBlob",
            "InvalidStateError",
            "\"OffscreenCanvas\" has no rendering context.",
        );
    }
    const is_jpeg = if (opts.type) |t| std.ascii.eqlIgnoreCase(t, "image/jpeg") else false;
    const blob = blk: {
        const backing = (try self.ensureSurface()) orelse unreachable;
        const owned = backing.backend() orelse break :blk try Blob.init(null, null, exec.page);
        const buf = if (is_jpeg)
            owned.encodeJpeg(jpegQuality(opts.quality)) catch break :blk try Blob.init(null, null, exec.page)
        else
            owned.encodePng() catch break :blk try Blob.init(null, null, exec.page);
        defer owned.freeEncodedBuffer(buf) catch {};
        break :blk try Blob.initFromBytes(buf, if (is_jpeg) "image/jpeg" else "image/png", exec.page);
    };

    const resolver = exec.js.local.?.createPromiseResolver();
    const promise = resolver.promise();
    const persisted_resolver = try resolver.persist();
    var resolver_needs_release = true;
    errdefer if (resolver_needs_release) persisted_resolver.release();

    blob.acquireRef();
    var blob_needs_release = true;
    errdefer if (blob_needs_release) blob.releaseRef(exec.page);

    const task = try exec._factory.create(ConvertToBlobTask{
        .exec = exec,
        .resolver = persisted_resolver,
        .blob = blob,
    });
    resolver_needs_release = false;
    blob_needs_release = false;
    errdefer task.finish();

    try exec.js.scheduler.add(task, ConvertToBlobTask.run, 0, .{
        .name = "OffscreenCanvas.convertToBlob",
        .low_priority = true,
        .finalizer = ConvertToBlobTask.cancelled,
    });
    return promise;
}

pub const ConvertToBlobOptions = struct {
    type: ?[]const u8 = null,
    quality: ?f64 = null,
};

fn jpegQuality(quality: ?f64) i32 {
    const q = quality orelse return 92;
    if (!std.math.isFinite(q) or q <= 0 or q > 1) return 92;
    return @intFromFloat(@round(q * 100));
}

/// Returns an ImageBitmap with the rendered content (stub).
pub fn transferToImageBitmap(self: *OffscreenCanvas, exec: *Execution) !?void {
    if (self._cached == null) {
        return CanvasException.operationDOMException(
            exec,
            "OffscreenCanvas",
            "transferToImageBitmap",
            "InvalidStateError",
            "Cannot transfer an ImageBitmap from an OffscreenCanvas with no context",
        );
    }
    // ImageBitmap not implemented yet, return null
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OffscreenCanvas);

    pub const Meta = struct {
        pub const name = "OffscreenCanvas";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(OffscreenCanvas.construct, .{});
    pub const width = bridge.accessor(OffscreenCanvas.getWidth, OffscreenCanvas.setWidth, .{});
    pub const height = bridge.accessor(OffscreenCanvas.getHeight, OffscreenCanvas.setHeight, .{});
    pub const getContext = bridge.function(OffscreenCanvas.getContext, .{});
    pub const convertToBlob = bridge.function(OffscreenCanvas.convertToBlob, .{
        .receiver_mode = .reject_promise,
    });
    pub const transferToImageBitmap = bridge.function(OffscreenCanvas.transferToImageBitmap, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: OffscreenCanvas" {
    try testing.htmlRunner("canvas/offscreen_canvas.html", .{});
}
