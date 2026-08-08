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
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const CanvasException = @import("../../canvas/CanvasException.zig");
const ContextOptions = @import("../../canvas/ContextOptions.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");
const Blob = @import("../../Blob.zig");
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
_surface_flags: u32 = 0,
_bitmap_width: u32 = 300,
_bitmap_height: u32 = 150,
_transferred: bool = false,

pub fn asElement(self: *Canvas) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

fn isHtmlSpace(byte: u8) bool {
    return switch (byte) {
        '\t', '\n', '\x0C', '\r', ' ' => true,
        else => false,
    };
}

/// Canvas dimensions are HTML non-negative integer content attributes, not
/// strict decimal strings. Blink accepts leading HTML whitespace, one sign,
/// and the maximal decimal prefix while leaving the source attribute intact.
fn parseDimensionAttribute(attr: []const u8, default_value: u32) u32 {
    var index: usize = 0;
    while (index < attr.len and isHtmlSpace(attr[index])) : (index += 1) {}

    var negative = false;
    if (index < attr.len) {
        switch (attr[index]) {
            '+' => index += 1,
            '-' => {
                negative = true;
                index += 1;
            },
            else => {},
        }
    }

    const first_digit = index;
    const limit: u32 = @intCast(std.math.maxInt(i32));
    var value: u32 = 0;
    while (index < attr.len and std.ascii.isDigit(attr[index])) : (index += 1) {
        const digit: u32 = attr[index] - '0';
        if (value > (limit - digit) / 10) return default_value;
        value = value * 10 + digit;
    }
    if (index == first_digit) return default_value;
    if (negative and value != 0) return default_value;
    return value;
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 300;
    return parseDimensionAttribute(attr, 300);
}

fn dimensionValue(
    raw_value: js.Value,
    attribute: []const u8,
    default_value: u32,
    frame: *Frame,
) !u32 {
    const number = try js.WebIDL.toNumberWithContext(
        raw_value,
        &frame.js.execution,
        .{ .attribute_set = .{
            .interface = "HTMLCanvasElement",
            .name = attribute,
        } },
    );
    if (!std.math.isFinite(number) or number == 0) return 0;

    // Web IDL unsigned long conversion truncates then wraps modulo 2^32.
    var modulo = @mod(@trunc(number), 4_294_967_296.0);
    if (modulo < 0) modulo += 4_294_967_296.0;
    const value: u32 = @intFromFloat(modulo);
    // Blink stores HTML canvas dimensions in a signed integer. Values outside
    // that range select the element's per-axis default rather than saturating.
    return if (value <= std.math.maxInt(i32)) value else default_value;
}

pub fn setWidth(self: *Canvas, raw_value: js.Value, frame: *Frame) !void {
    const value = try dimensionValue(raw_value, "width", 300, frame);
    const str = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 150;
    return parseDimensionAttribute(attr, 150);
}

pub fn setHeight(self: *Canvas, raw_value: js.Value, frame: *Frame) !void {
    const value = try dimensionValue(raw_value, "height", 150, frame);
    const str = try std.fmt.allocPrint(frame.local_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
}

/// Invalidate the bitmap and reset the drawing state.  This must run even when
/// a dimension is assigned its current value: HTML canvas resize semantics are
/// reset semantics, not merely a size-change notification.
fn resetBitmap(self: *Canvas) !void {
    const width = self.getWidth();
    const height = self.getHeight();
    self._bitmap_width = width;
    self._bitmap_height = height;

    if (self._cached) |cached| switch (cached) {
        .@"2d" => |ctx| ctx.onCanvasResize(width, height),
        .webgl => {},
    };

    // Context state reset is unconditional even if allocating the replacement
    // storage fails. Keep the existing surface faulted rather than allowing
    // later drawing to reuse stale pixels under the new logical dimensions.
    if (self._surface) |backing| {
        backing.resize(width, height) catch |err| {
            backing.markFault(err);
            return err;
        };
    }
}

/// Reconcile parser-created or otherwise unobserved content attributes with
/// the backing bitmap. Runtime mutations reset eagerly through `Build`; this
/// size comparison is deliberately only a fallback because same-size writes
/// must also reset an HTML canvas.
pub fn syncBitmapDimensions(self: *Canvas) !void {
    const width = self.getWidth();
    const height = self.getHeight();
    if (width == self._bitmap_width and height == self._bitmap_height) return;
    try self.resetBitmap();
}

/// Drop the current pixels without notifying the context. The 2D context uses
/// this only as a fallback for parser-created or otherwise unobserved
/// dimension changes; ordinary DOM mutations are handled by `Build`.
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
    try self.syncBitmapDimensions();
    if (self._bitmap_width == 0 or self._bitmap_height == 0) return null;
    if (self._surface) |backing| {
        try backing.requireHealthy();
        return backing;
    }
    const provider = self._surface_provider orelse return error.InvalidStateError;
    const backing = try provider.createSurface(
        self._bitmap_width,
        self._bitmap_height,
        self._surface_flags,
    );
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

fn webglCanvasToJs(raw: *anyopaque, local: *const js.Local) !js.Value {
    const canvas: *Canvas = @ptrCast(@alignCast(raw));
    return local.zigValueToJs(canvas, .{});
}

fn webglCanvasWidth(raw: *anyopaque) u32 {
    const canvas: *Canvas = @ptrCast(@alignCast(raw));
    return canvas.getWidth();
}

fn webglCanvasHeight(raw: *anyopaque) u32 {
    const canvas: *Canvas = @ptrCast(@alignCast(raw));
    return canvas.getHeight();
}

fn webglCanvasHooks(self: *Canvas) WebGLRenderingContext.CanvasHooks {
    return .{
        .ptr = self,
        .toJs = webglCanvasToJs,
        .width = webglCanvasWidth,
        .height = webglCanvasHeight,
    };
}

pub fn getContext(
    self: *Canvas,
    context_type: []const u8,
    raw_options: ?js.Value,
    frame: *Frame,
) !?DrawingContext {
    if (self._transferred) {
        return CanvasException.operationDOMException(
            &frame.js.execution,
            "HTMLCanvasElement",
            "getContext",
            "InvalidStateError",
            "Cannot get context from a canvas that has transferred its control to offscreen.",
        );
    }
    const is_2d = std.mem.eql(u8, context_type, "2d");
    const is_webgl = std.mem.eql(u8, context_type, "webgl") or
        std.mem.eql(u8, context_type, "experimental-webgl");
    const is_webgl2 = std.mem.eql(u8, context_type, "webgl2") or
        std.mem.eql(u8, context_type, "experimental-webgl2");
    const attributes = if (is_2d)
        try ContextOptions.parse(raw_options, &frame.js.execution, .html_canvas)
    else
        ContextOptions.Attributes{};

    if (self._cached) |cached| {
        const matches = switch (cached) {
            .@"2d" => is_2d,
            .webgl => is_webgl or is_webgl2,
        };
        return if (matches) cached else null;
    }

    const drawing_context: DrawingContext = blk: {
        if (is_2d) {
            self._surface_provider = &frame._page.canvas_backend;
            self._surface_flags = attributes.surfaceFlags();
            const ctx = try frame._factory.create(CanvasRenderingContext2D.init(self, attributes));
            break :blk .{ .@"2d" = ctx };
        }

        if (is_webgl or is_webgl2) {
            const ctx = try frame._factory.create(WebGLRenderingContext.init(
                webglCanvasHooks(self),
                is_webgl2,
            ));
            break :blk .{ .webgl = ctx };
        }
        return null;
    };
    self._cached = drawing_context;
    return drawing_context;
}

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, exec: *Execution) !*OffscreenCanvas {
    if (self._cached != null) {
        return CanvasException.operationDOMException(
            exec,
            "HTMLCanvasElement",
            "transferControlToOffscreen",
            "InvalidStateError",
            "Cannot transfer control from a canvas that has a rendering context.",
        );
    }
    if (self._transferred) {
        return CanvasException.operationDOMException(
            exec,
            "HTMLCanvasElement",
            "transferControlToOffscreen",
            "InvalidStateError",
            "Cannot transfer control from a canvas for more than one time.",
        );
    }
    const width = self.getWidth();
    const height = self.getHeight();
    const offscreen = try OffscreenCanvas.constructor(width, height, exec);
    self._transferred = true;
    return offscreen;
}

/// Encode the bitmap as a data: URL (PNG by default; JPEG when asked, with
/// Chrome's quality mapping: outside (0,1] => 92). Unsupported types fall back
/// to PNG per spec.
pub fn toDataURL(self: *Canvas, mime: ?[]const u8, quality: ?js.Value, exec: *Execution) ![]const u8 {
    try self.syncBitmapDimensions();
    if (self._bitmap_width == 0 or self._bitmap_height == 0) return "data:,";
    // Serialization is permitted before getContext().  Such a canvas still
    // has its default transparent bitmap, so connect the lazy surface to the
    // page backend on first encode just as getContext("2d") would.
    if (self._surface_provider == null) {
        self._surface_provider = &exec.page.canvas_backend;
    }
    const backing = (try self.ensureSurface()) orelse return "data:,";
    const owned = backing.backend() orelse return error.NotSupportedError;

    const is_jpeg = mime != null and std.ascii.eqlIgnoreCase(mime.?, "image/jpeg");
    const buf = if (is_jpeg)
        try owned.encodeJpeg(jpegQualityValue(quality))
    else
        try owned.encodePng();
    defer owned.freeEncodedBuffer(buf) catch {};

    const b64 = try exec.call_arena.alloc(u8, std.base64.standard.Encoder.calcSize(buf.len));
    const encoded = std.base64.standard.Encoder.encode(b64, buf);
    return std.fmt.allocPrint(exec.call_arena, "data:{s};base64,{s}", .{
        if (is_jpeg) "image/jpeg" else "image/png",
        encoded,
    });
}

fn jpegQuality(quality: ?f64) i32 {
    const q = quality orelse return 92;
    if (!std.math.isFinite(q) or q <= 0 or q > 1) return 92;
    return @intFromFloat(@round(q * 100));
}

fn jpegQualityValue(quality: ?js.Value) i32 {
    const raw = quality orelse return 92;
    // HTMLCanvasElement's quality argument is Web IDL `any`. Blink consults it
    // only when the supplied JS value is already a Number; Symbols, strings,
    // null and objects are ignored without conversion.
    if (!raw.isNumber()) return 92;
    return jpegQuality(raw.toF64() catch return 92);
}

const ToBlobTask = struct {
    exec: *Execution,
    callback: js.Function.Global,
    blob: ?*Blob,

    fn finish(self: *ToBlobTask) void {
        self.callback.release();
        if (self.blob) |blob| blob.releaseRef(self.exec.page);
        self.exec._factory.destroy(self);
    }

    fn cancelled(raw: *anyopaque) void {
        const self: *ToBlobTask = @ptrCast(@alignCast(raw));
        self.finish();
    }

    fn run(raw: *anyopaque) !?u32 {
        const self: *ToBlobTask = @ptrCast(@alignCast(raw));
        defer self.finish();

        // A stopped scheduler normally runs cancelled(), but keep the task
        // harmless if retirement races with an already-selected callback.
        if (self.exec.isShuttingDown()) return null;

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        // Let callback failures reach Scheduler.runOne's normal error path.
        // That path reports the failure and continues pumping later tasks.
        const callback = ls.toLocal(self.callback);
        try callback.callWithThis(void, js.Undefined{}, .{self.blob});
        return null;
    }
};

/// toBlob(callback, type, quality): snapshot the encoded bitmap now, then
/// deliver the resulting Blob from an HTML task. The persisted callback and a
/// native Blob reference keep both values alive until delivery or cancellation.
pub fn toBlob(self: *Canvas, callback_value: js.Value, mime_value: ?js.Value, quality: ?js.Value, exec: *Execution) !void {
    const operation: js.WebIDL.Operation = .{
        .interface = "HTMLCanvasElement",
        .name = "toBlob",
    };
    if (!callback_value.isFunction()) {
        return js.WebIDL.argumentNotOfType(
            exec,
            .{ .operation = operation },
            0,
            "Function",
        );
    }
    // Web IDL converts arguments in declaration order. Keep the type value raw
    // at the bridge boundary so an invalid callback wins over a throwing MIME
    // conversion, while a valid callback still gets the qualified DOMString
    // conversion error.
    const mime: ?[]const u8 = if (mime_value) |raw|
        if (raw.isUndefined()) null else try js.WebIDL.toDOMString(raw, exec, operation)
    else
        null;

    const callback_local = js.Function{
        .local = callback_value.local,
        .handle = @ptrCast(callback_value.handle),
    };
    const callback = try callback_local.persist();
    var callback_needs_release = true;
    errdefer if (callback_needs_release) callback.release();

    try self.syncBitmapDimensions();
    const blob: ?*Blob = if (self._bitmap_width == 0 or self._bitmap_height == 0)
        null
    else blk: {
        // Match toDataURL(): the untouched default bitmap is serializable even
        // when the page never requested a rendering context.
        if (self._surface_provider == null) {
            self._surface_provider = &exec.page.canvas_backend;
        }
        const backing = (try self.ensureSurface()) orelse break :blk null;
        const owned = backing.backend() orelse return error.NotSupportedError;

        const is_jpeg = mime != null and std.ascii.eqlIgnoreCase(mime.?, "image/jpeg");
        const buf = if (is_jpeg)
            try owned.encodeJpeg(jpegQualityValue(quality))
        else
            try owned.encodePng();
        defer owned.freeEncodedBuffer(buf) catch {};

        break :blk try Blob.initFromBytes(
            buf,
            if (is_jpeg) "image/jpeg" else "image/png",
            exec.page,
        );
    };

    // The Blob has no JS wrapper yet, so pin its arena while the task is
    // pending. Mapping it as the callback argument acquires the wrapper's own
    // reference before finish() releases this task-owned pin.
    var blob_needs_release = false;
    if (blob) |value| {
        value.acquireRef();
        blob_needs_release = true;
    }
    errdefer if (blob_needs_release) blob.?.releaseRef(exec.page);

    const task = try exec._factory.create(ToBlobTask{
        .exec = exec,
        .callback = callback,
        .blob = blob,
    });
    callback_needs_release = false;
    blob_needs_release = false;
    errdefer task.finish();

    try exec.js.scheduler.add(task, ToBlobTask.run, 0, .{
        .name = "HTMLCanvasElement.toBlob",
        .low_priority = false,
        .finalizer = ToBlobTask.cancelled,
    });
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
    pub const toDataURL = bridge.function(Canvas.toDataURL, .{});
    pub const toBlob = bridge.function(Canvas.toBlob, .{ .required_args = 1 });
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};

pub const Build = struct {
    pub fn attributeChange(element: *Element, name: lp.String, _: lp.String, _: *Frame) !void {
        if (!isBitmapDimension(name)) return;
        try element.as(Canvas).resetBitmap();
    }

    pub fn attributeRemove(element: *Element, name: lp.String, _: *Frame) !void {
        if (!isBitmapDimension(name)) return;
        try element.as(Canvas).resetBitmap();
    }

    fn isBitmapDimension(name: lp.String) bool {
        return name.eql(comptime .wrap("width")) or name.eql(comptime .wrap("height"));
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTMLCanvasElement binding semantics" {
    try testing.htmlRunner("canvas/html_canvas_element.html", .{});
}

test "WebApi: HTMLCanvasElement toBlob task semantics" {
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

    try testing.htmlRunner("canvas/html_canvas_element_to_blob.html", .{});
}
