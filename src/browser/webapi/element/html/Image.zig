const std = @import("std");
const lp = @import("darkpanda");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const HttpClient = @import("../../../HttpClient.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Image = @This();
_proto: *HtmlElement,
_complete: bool = true,
_current_src: ?[]const u8 = null,
_natural_width: u32 = 0,
_natural_height: u32 = 0,
_generation: u64 = 0,
_active: ?*LoadContext = null,

const log = lp.log;

pub fn constructor(w_: ?u32, h_: ?u32, frame: *Frame) !*Image {
    const node = try Frame.node_factory.createElementNS(frame, .html, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&frame.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("width"), .wrap(w_string), frame);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&frame.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("height"), .wrap(h_string), frame);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Image) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    const request_src = std.mem.trim(u8, src, " \t\n\x0c\r");
    if (request_src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(request_src, frame, .{});
}

pub fn setSrc(self: *Image, value: []const u8, frame: *Frame) !void {
    // Attribute mutation is the single image-update entry point.  The
    // Build.attributeChange hook below handles property setters,
    // setAttribute(), Attr.value and other DOM mutation paths uniformly.
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub fn getCurrentSrc(self: *const Image) []const u8 {
    return self._current_src orelse "";
}

pub fn getAlt(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("alt")) orelse "";
}

pub fn setAlt(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("alt"), .wrap(value), frame);
}

pub fn getWidth(self: *const Image) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setWidth(self: *Image, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
}

pub fn getHeight(self: *const Image) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setHeight(self: *Image, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
}

pub fn getCrossOrigin(self: *const Image) ?[]const u8 {
    const values = [_][]const u8{ "anonymous", "use-credentials" };
    return HtmlElement.reflectEnumerated(
        self.asConstElement().getAttributeSafe(comptime .wrap("crossorigin")),
        &values,
        null,
        "anonymous",
    );
}

pub fn setCrossOrigin(self: *Image, value: ?[]const u8, frame: *Frame) !void {
    if (value) |v| {
        return self.asElement().setAttributeSafe(comptime .wrap("crossorigin"), .wrap(v), frame);
    }
    return self.asElement().removeAttribute(comptime .wrap("crossorigin"), frame);
}

pub fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("loading")) orelse "eager";
}

pub fn setLoading(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), frame);
}

pub fn getReferrerPolicy(self: *const Image) []const u8 {
    const values = [_][]const u8{
        "",
        "no-referrer",
        "no-referrer-when-downgrade",
        "same-origin",
        "origin",
        "strict-origin",
        "origin-when-cross-origin",
        "strict-origin-when-cross-origin",
        "unsafe-url",
    };
    return HtmlElement.reflectEnumerated(
        self.asConstElement().getAttributeSafe(.wrap("referrerpolicy")),
        &values,
        "",
        "",
    ).?;
}

pub fn setReferrerPolicy(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("referrerpolicy"), .wrap(value), frame);
}

pub fn getNaturalWidth(self: *const Image) u32 {
    return self._natural_width;
}

pub fn getNaturalHeight(self: *const Image) u32 {
    return self._natural_height;
}

pub fn getComplete(self: *const Image) bool {
    return self._complete;
}

/// Used in `Page.nodeIsReady`.
pub fn imageAddedCallback(self: *Image, frame: *Frame) !void {
    const generation = self.beginUpdate();
    // A detached Image still loads, but a retired Frame must never start new
    // I/O.  beginUpdate above also invalidates any already-queued old event.
    if (frame.isGoingAway()) return;

    const element = self.asElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return;
    // The image request algorithm strips HTML whitespace from the URL input;
    // reflection continues to expose the author's unmodified attribute.
    const request_src = std.mem.trim(u8, src, " \t\n\x0c\r");
    if (request_src.len == 0) return;

    const arena = try frame.getArena(.medium, "HTMLImageElement.load");
    var context_owns_arena = false;
    defer if (!context_owns_arena) frame.releaseArena(arena);

    const resolved = element.asNode().resolveURL(request_src, frame, .{ .allocator = arena }) catch |err| switch (err) {
        error.TypeError => {
            self._current_src = try frame.arena.dupe(u8, request_src);
            self.queueTerminalEvent(frame, generation, .@"error");
            return;
        },
        else => return err,
    };
    // currentSrc stays empty while the request is pending.  Keep the selected
    // URL separately in the Frame arena so terminal state and queued-event
    // generation checks remain valid after the per-request arena is released.
    const selected_url = try frame.arena.dupeZ(u8, resolved);

    const cross_origin = self.getCrossOrigin();
    const use_credentials = if (cross_origin) |value|
        std.ascii.eqlIgnoreCase(value, "use-credentials")
    else
        false;
    const same_origin = frame.isSameOrigin(selected_url);
    const credentials: HttpClient.RequestContext.Credentials = if (cross_origin == null or use_credentials)
        .include
    else
        .same_origin;
    const cookie_jar = switch (credentials) {
        .include => &frame._session.cookie_jar,
        .same_origin => if (same_origin) &frame._session.cookie_jar else null,
        .omit => null,
    };

    var headers = try frame._session.browser.http_client.newRequestHeaders(selected_url, .{
        .destination = .image,
        .mode = if (cross_origin == null) .no_cors else .cors,
        .initiator_url = frame.url,
        .top_level_url = frame.url,
        .referrer_url = frame.url,
        .referrer_policy = self.effectiveReferrerPolicy(),
        .credentials = credentials,
        .priority = .image,
    });
    var request_owns_headers = false;
    defer if (!request_owns_headers) headers.deinit();

    const context = try arena.create(LoadContext);
    context.* = .{
        .arena = arena,
        .frame = frame,
        .image = self,
        .generation = generation,
        .selected_url = selected_url,
    };

    self._complete = false;
    self._active = context;
    context_owns_arena = true;

    // Frame.makeRequest owns the header list from entry onward.  Every
    // terminal path releases LoadContext's arena exactly once: normal done,
    // transport/error callback, owner shutdown, or the explicit pre-transfer
    // unstarted callback.
    request_owns_headers = true;
    frame.makeRequest(.{
        .ctx = context,
        .url = selected_url,
        .method = .GET,
        .frame_id = frame._frame_id,
        .loader_id = frame._loader_id,
        .headers = headers,
        .cookie_jar = cookie_jar,
        .cookie_origin = frame.url,
        .resource_type = .image,
        .notification = frame._session.notification,
        .start_callback = LoadContext.startCallback,
        .header_callback = LoadContext.headerCallback,
        .data_callback = LoadContext.dataCallback,
        .done_callback = LoadContext.doneCallback,
        .error_callback = LoadContext.errorCallback,
        .shutdown_callback = LoadContext.shutdownCallback,
        .unstarted_callback = LoadContext.unstartedCallback,
    }) catch {};
}

fn beginUpdate(self: *Image) u64 {
    self._generation +%= 1;
    const generation = self._generation;

    // Invalidate state and queued events before aborting.  abort() can invoke
    // the old error callback synchronously, and that callback must observe the
    // new generation and remain a cleanup-only stale completion.
    const active = self._active;
    self._active = null;
    self._complete = true;
    self._current_src = null;
    self._natural_width = 0;
    self._natural_height = 0;

    if (active) |context| {
        if (context.response) |response| {
            context.response = null;
            response.abort(error.Abort);
        }
    }
    return generation;
}

pub fn isCurrentGeneration(self: *const Image, generation: u64) bool {
    return self._generation == generation;
}

fn queueTerminalEvent(
    self: *Image,
    frame: *Frame,
    generation: u64,
    kind: Frame.QueuedEvent.Kind,
) void {
    if (frame.isGoingAway()) return;
    frame.queueImageEvent(self, generation, kind) catch |err| {
        log.err(.frame, "queue image event", .{ .err = err, .url = self._current_src orelse "" });
    };
}

fn effectiveReferrerPolicy(self: *const Image) HttpClient.ReferrerPolicy {
    const value = self.getReferrerPolicy();
    if (std.ascii.eqlIgnoreCase(value, "no-referrer")) return .no_referrer;
    if (std.ascii.eqlIgnoreCase(value, "no-referrer-when-downgrade")) return .no_referrer_when_downgrade;
    if (std.ascii.eqlIgnoreCase(value, "origin")) return .origin;
    if (std.ascii.eqlIgnoreCase(value, "origin-when-cross-origin")) return .origin_when_cross_origin;
    if (std.ascii.eqlIgnoreCase(value, "same-origin")) return .same_origin;
    if (std.ascii.eqlIgnoreCase(value, "strict-origin")) return .strict_origin;
    if (std.ascii.eqlIgnoreCase(value, "unsafe-url")) return .unsafe_url;
    return HttpClient.default_referrer_policy;
}

const Dimensions = struct {
    width: u32,
    height: u32,
};

const LoadContext = struct {
    const max_body_bytes: usize = 8 * 1024 * 1024;

    arena: std.mem.Allocator,
    frame: *Frame,
    image: *Image,
    generation: u64,
    selected_url: [:0]const u8,
    body: std.ArrayList(u8) = .empty,
    response: ?HttpClient.Response = null,
    failed: bool = false,

    fn startCallback(response: HttpClient.Response) !void {
        const self: *LoadContext = @ptrCast(@alignCast(response.ctx));
        // Never fail from start_callback: HttpClient is inside the commit
        // window here, and a synchronous abort followed by the outer request
        // catch would otherwise inspect a freed Transfer. A stale response is
        // dropped safely by the later callbacks without retaining its body.
        self.response = response;
    }

    fn headerCallback(response: HttpClient.Response) !HttpClient.HeaderResult {
        const self: *LoadContext = @ptrCast(@alignCast(response.ctx));
        if (!self.isCurrent()) {
            self.failed = true;
            return .proceed;
        }
        const status = response.status() orelse {
            self.failed = true;
            return .proceed;
        };
        if (status < 200 or status >= 300) self.failed = true;
        if (response.contentLength()) |length| {
            if (length > max_body_bytes) {
                self.failed = true;
            } else if (!self.failed) {
                self.body.ensureTotalCapacity(self.arena, length) catch {
                    self.failed = true;
                };
            }
        }
        return .proceed;
    }

    fn dataCallback(response: HttpClient.Response, data: []const u8) !void {
        const self: *LoadContext = @ptrCast(@alignCast(response.ctx));
        if (!self.isCurrent() or self.failed) return;
        if (data.len > max_body_bytes - self.body.items.len) {
            self.failed = true;
            return;
        }
        self.body.appendSlice(self.arena, data) catch {
            self.failed = true;
        };
    }

    fn doneCallback(raw: *anyopaque) !void {
        const self: *LoadContext = @ptrCast(@alignCast(raw));
        defer self.release();
        self.response = null;

        if (self.failed) {
            self.finish(.@"error", null);
            return;
        }
        const dimensions = parsePngDimensions(self.body.items) orelse {
            self.finish(.@"error", null);
            return;
        };
        self.finish(.load, dimensions);
    }

    fn errorCallback(raw: *anyopaque, _: anyerror) void {
        const self: *LoadContext = @ptrCast(@alignCast(raw));
        defer self.release();
        self.response = null;
        self.finish(.@"error", null);
    }

    fn unstartedCallback(raw: *anyopaque) void {
        const self: *LoadContext = @ptrCast(@alignCast(raw));
        defer self.release();
        self.finish(.@"error", null);
    }

    // Owner retirement is not an image failure observable by the dying realm.
    // Clear the native link and release storage without scheduling or running
    // any JavaScript.
    fn shutdownCallback(raw: *anyopaque) void {
        const self: *LoadContext = @ptrCast(@alignCast(raw));
        if (self.image._active == self) self.image._active = null;
        self.response = null;
        self.release();
    }

    fn finish(self: *LoadContext, kind: Frame.QueuedEvent.Kind, dimensions: ?Dimensions) void {
        if (self.image._active == self) self.image._active = null;
        if (!self.image.isCurrentGeneration(self.generation)) return;

        self.image._complete = true;
        self.image._current_src = self.selected_url;
        if (dimensions) |size| {
            self.image._natural_width = size.width;
            self.image._natural_height = size.height;
        } else {
            self.image._natural_width = 0;
            self.image._natural_height = 0;
        }
        self.image.queueTerminalEvent(self.frame, self.generation, kind);
    }

    fn isCurrent(self: *const LoadContext) bool {
        return self.image.isCurrentGeneration(self.generation) and self.image._active == self;
    }

    fn release(self: *LoadContext) void {
        const frame = self.frame;
        const arena = self.arena;
        frame.releaseArena(arena);
    }
};

// A rendering engine is unnecessary for intrinsic PNG dimensions.  Validate
// the signature/chunk envelope and required IHDR/IDAT/IEND structure, then
// read the big-endian IHDR dimensions.  Full pixel decompression remains out
// of scope, while truncated or structurally invalid responses correctly enter
// the broken-image state.
fn parsePngDimensions(data: []const u8) ?Dimensions {
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (data.len < signature.len or !std.mem.eql(u8, data[0..signature.len], &signature)) return null;

    var offset: usize = signature.len;
    var dimensions: ?Dimensions = null;
    var saw_idat = false;
    var first_chunk = true;
    while (offset <= data.len and data.len - offset >= 12) {
        const length: usize = std.mem.readInt(u32, data[offset..][0..4], .big);
        const chunk_type = data[offset + 4 .. offset + 8];
        const data_start = offset + 8;
        if (length > data.len - data_start or data.len - data_start - length < 4) return null;
        const data_end = data_start + length;

        if (first_chunk) {
            if (!std.mem.eql(u8, chunk_type, "IHDR") or length != 13) return null;
            first_chunk = false;

            const width = std.mem.readInt(u32, data[data_start..][0..4], .big);
            const height = std.mem.readInt(u32, data[data_start + 4 ..][0..4], .big);
            const bit_depth = data[data_start + 8];
            const color_type = data[data_start + 9];
            const compression = data[data_start + 10];
            const filter = data[data_start + 11];
            const interlace = data[data_start + 12];
            if (width == 0 or height == 0 or
                !validPngBitDepth(color_type, bit_depth) or
                compression != 0 or filter != 0 or interlace > 1)
            {
                return null;
            }
            dimensions = .{ .width = width, .height = height };
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            saw_idat = true;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            if (length != 0 or !saw_idat) return null;
            return dimensions;
        }

        offset = data_end + 4; // skip the chunk CRC
    }
    return null;
}

fn validPngBitDepth(color_type: u8, bit_depth: u8) bool {
    return switch (color_type) {
        0 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        2, 4, 6 => bit_depth == 8 or bit_depth == 16,
        3 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        else => false,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "HTMLImageElement";
        pub const constructor_alias = "Image";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Image.constructor, .{});
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{ .ce_reactions = true });
    pub const currentSrc = bridge.accessor(Image.getCurrentSrc, null, .{});
    pub const alt = bridge.accessor(Image.getAlt, Image.setAlt, .{ .ce_reactions = true });
    pub const width = bridge.accessor(Image.getWidth, Image.setWidth, .{ .ce_reactions = true });
    pub const height = bridge.accessor(Image.getHeight, Image.setHeight, .{ .ce_reactions = true });
    pub const crossOrigin = bridge.accessor(Image.getCrossOrigin, Image.setCrossOrigin, .{ .ce_reactions = true });
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{ .ce_reactions = true });
    pub const referrerPolicy = bridge.accessor(Image.getReferrerPolicy, Image.setReferrerPolicy, .{ .ce_reactions = true });
    pub const naturalWidth = bridge.accessor(Image.getNaturalWidth, null, .{});
    pub const naturalHeight = bridge.accessor(Image.getNaturalHeight, null, .{});
    pub const complete = bridge.accessor(Image.getComplete, null, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Image);
        return self.imageAddedCallback(frame);
    }

    pub fn attributeChange(element: *Element, name: lp.String, _: lp.String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) return;
        return element.as(Image).imageAddedCallback(frame);
    }

    pub fn attributeRemove(element: *Element, name: lp.String, _: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) return;
        _ = element.as(Image).beginUpdate();
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}
