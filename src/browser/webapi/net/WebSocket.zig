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

const http = @import("../../../network/http.zig");

const js = @import("../../js/js.zig");
const Blob = @import("../Blob.zig");
const URL = @import("../../URL.zig");

const Page = @import("../../Page.zig");
const HttpClient = @import("../../HttpClient.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const CloseEvent = @import("../event/CloseEvent.zig");
const DOMException = @import("../DOMException.zig");
const MessageEvent = @import("../event/MessageEvent.zig");

const log = lp.log;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const WebSocket = @This();

_rc: lp.RC(u8) = .{},
_exec: *const Execution,
_proto: *EventTarget,
_arena: Allocator,

// Connection state
_ready_state: ReadyState = .connecting,
_url: [:0]const u8 = "",
_binary_type: BinaryType = .blob,

_conn: ?*http.Connection,
_http_client: *HttpClient,
_req_headers: http.Headers,

_owner_node: std.DoublyLinkedList.Node = .{},

// close info for event dispatch
_close_code: u16 = 1000,
_close_reason: []const u8 = "",

// negotiated protocol
_protocol: []const u8 = "",

// Event handlers
_on_open: ?js.Function.Global = null,
_on_message: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_close: ?js.Function.Global = null,

pub const ReadyState = enum(u8) {
    connecting = 0,
    open = 1,
    closing = 2,
    closed = 3,
};

pub const BinaryType = enum {
    blob,
    arraybuffer,
};

// WebSocket's second Web IDL argument is `(DOMString or
// sequence<DOMString>)`, not a variadic parameter. Keep the raw value optional
// so omission and an explicitly supplied undefined can both select the empty
// default while null still undergoes normal DOMString conversion to "null".
const ProtocolsInit = union(enum) {
    single: js.DOMString,
    sequence: []js.DOMString,
};

fn convertProtocols(raw_: ?js.Value) ![]const []const u8 {
    const raw = raw_ orelse return &.{};
    if (raw.isUndefined()) {
        return &.{};
    }
    const converted = try raw.local.jsValueToZigWithContext(
        ProtocolsInit,
        raw,
        .{ .constructor = "WebSocket" },
    );
    return switch (converted) {
        .single => |protocol| blk: {
            const protocols = try raw.local.call_arena.alloc([]const u8, 1);
            protocols[0] = protocol.value;
            break :blk protocols;
        },
        .sequence => |input| blk: {
            const protocols = try raw.local.call_arena.alloc([]const u8, input.len);
            for (input, protocols) |protocol, *output| {
                output.* = protocol.value;
            }
            break :blk protocols;
        },
    };
}

pub fn init(url: []const u8, protocols_: ?js.Value, exec: *const Execution) !*WebSocket {
    const protocols = try convertProtocols(protocols_);
    const arena = try exec.getArena(.medium, "WebSocket");
    errdefer exec.releaseArena(arena);

    const parsed_url = URL.resolve(arena, exec.base(), url, .{ .encoding = exec.charset.* }) catch {
        const message = std.fmt.bufPrint(
            exec.buf,
            "Failed to construct 'WebSocket': The URL '{s}' is invalid.",
            .{url},
        ) catch return error.SyntaxError;
        return throwSyntaxError(exec, message);
    };

    var resolved_url = parsed_url;
    const scheme = URL.getProtocol(parsed_url);
    if (std.mem.eql(u8, scheme, "http:")) {
        resolved_url = try URL.setProtocol(parsed_url, "ws", arena);
    } else if (std.mem.eql(u8, scheme, "https:")) {
        resolved_url = try URL.setProtocol(parsed_url, "wss", arena);
    } else if (!std.mem.eql(u8, scheme, "ws:") and !std.mem.eql(u8, scheme, "wss:")) {
        const printable_scheme = if (scheme.len > 0) scheme[0 .. scheme.len - 1] else scheme;
        const message = std.fmt.bufPrint(
            exec.buf,
            "Failed to construct 'WebSocket': The URL's scheme must be either 'http', 'https', 'ws', or 'wss'. '{s}' is not allowed.",
            .{printable_scheme},
        ) catch return error.SyntaxError;
        return throwSyntaxError(exec, message);
    }

    const fragment = URL.getHash(resolved_url);
    if (fragment.len > 0) {
        const message = std.fmt.bufPrint(
            exec.buf,
            "Failed to construct 'WebSocket': The URL contains a fragment identifier ('{s}'). Fragment identifiers are not allowed in WebSocket URLs.",
            .{fragment},
        ) catch return error.SyntaxError;
        return throwSyntaxError(exec, message);
    }

    for (protocols, 0..) |protocol, index| {
        if (!isValidProtocol(protocol)) {
            const message = std.fmt.bufPrint(
                exec.buf,
                "Failed to construct 'WebSocket': The subprotocol '{s}' is invalid.",
                .{protocol},
            ) catch return error.SyntaxError;
            return throwSyntaxError(exec, message);
        }
        for (protocols[0..index]) |previous| {
            if (std.mem.eql(u8, previous, protocol)) {
                const message = std.fmt.bufPrint(
                    exec.buf,
                    "Failed to construct 'WebSocket': The subprotocol '{s}' is duplicated.",
                    .{protocol},
                ) catch return error.SyntaxError;
                return throwSyntaxError(exec, message);
            }
        }
    }

    // A Worker owns a separate HttpClient which is driven on its isolate
    // thread. Reaching through Session would register the connection on the
    // browser client's loop and later enter the worker's V8 objects from the
    // wrong thread.
    const http_client = exec.httpClient();

    // Blink still performs Web IDL, URL and subprotocol validation for a
    // cached constructor from a discarded realm. Only the actual connect step
    // is suppressed; the returned child-realm object remains CONNECTING and
    // inert. Because discard keeps the old V8 Context attached, `exec` is the
    // constructor's stable creator Execution rather than the incumbent caller.
    if (exec.isShuttingDown() or !exec.httpOwner().accepting_requests) {
        return exec._factory.eventTargetWithAllocator(arena, WebSocket{
            ._exec = exec,
            ._conn = null,
            ._arena = arena,
            ._proto = undefined,
            ._url = resolved_url,
            ._req_headers = .{ .headers = null },
            ._http_client = http_client,
        });
    }

    const conn = http_client.network.newConnection() orelse {
        return error.NoFreeConnection;
    };

    // trackConn is deliberately non-consuming on failure. Until it commits,
    // this constructor remains the connection's sole owner and returns it
    // exactly once through this errdefer.
    errdefer http_client.network.releaseConnection(conn);

    try conn.setURL(resolved_url);

    var headers = try http_client.newHeaders();
    errdefer headers.deinit();

    if (protocols.len > 0) {
        const header = try std.fmt.allocPrintSentinel(arena, "Sec-WebSocket-Protocol: {s}", .{try std.mem.join(arena, ", ", protocols)}, 0);
        try headers.add(header);
    }

    {
        // The upgrade is a browser-initiated HTTP request and must carry the
        // document's origin (RFC 6455 §4.1). Origin-checking endpoints (CSRF
        // protection on WS servers) reject upgrades that arrive without it.
        // Use the environment's committed SecurityOrigin, not its URL tuple.
        // A sandboxed HTTP(S) document keeps its URL but has an opaque origin,
        // for which Chromium sends the literal `Origin: null`.
        const origin = exec.origin() orelse "null";
        const header = try std.fmt.allocPrintSentinel(arena, "Origin: {s}", .{origin}, 0);
        try headers.add(header);
    }

    {
        var buf: std.Io.Writer.Allocating = .init(arena);
        try exec.session.cookie_jar.forRequest(resolved_url, &buf.writer, .{
            .is_http = true,
            .is_navigation = false,
            .origin_url = exec.url.*,
        });
        if (buf.written().len > 0) {
            try buf.writer.writeByte(0);
            const written = buf.written();
            try conn.setCookies(written.ptr[0 .. written.len - 1 :0]);
        }
    }

    try conn.setHeaders(&headers);

    const self = try exec._factory.eventTargetWithAllocator(arena, WebSocket{
        ._exec = exec,
        ._conn = conn,
        ._arena = arena,
        ._proto = undefined,
        ._url = resolved_url,
        ._req_headers = headers,
        ._http_client = http_client,
    });
    conn.transport = .{ .websocket = self };
    try http_client.trackConn(conn);
    exec.httpOwner().addWS(self);

    if (comptime IS_DEBUG) {
        log.info(.websocket, "connecting", .{ .url = url });
    }

    // Unlike an XHR object where we only selectively reference the instance
    // while the request is actually inflight, WS connection is "inflight" from
    // the moment it's created.
    self.acquireRef();

    return self;
}

fn throwSyntaxError(exec: *const Execution, message: []const u8) anyerror {
    const local = exec.js.local orelse return error.SyntaxError;
    const exception = local.zigValueToJs(DOMException.init(message, "SyntaxError"), .{}) catch return error.SyntaxError;
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

pub fn deinit(self: *WebSocket, page: *Page) void {
    self.teardownConn();

    if (self._on_open) |func| {
        func.release();
    }
    if (self._on_message) |func| {
        func.release();
    }
    if (self._on_error) |func| {
        func.release();
    }
    if (self._on_close) |func| {
        func.release();
    }

    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *WebSocket, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *WebSocket) void {
    self._rc.acquire();
}

fn asEventTarget(self: *WebSocket) *EventTarget {
    return self._proto;
}

// we're being aborted internally (e.g. frame shutting down)
pub fn kill(self: *WebSocket) void {
    self.cleanup();
}

pub fn disconnected(self: *WebSocket, err_: ?anyerror) void {
    if (self._ready_state == .closed) return;
    const was_clean = self._ready_state == .closing and err_ == null;
    self._ready_state = .closed;

    if (err_) |err| {
        log.warn(.websocket, "disconnected", .{ .err = err, .url = self._url });
    } else {
        log.info(.websocket, "disconnected", .{ .url = self._url, .reason = "closed" });
    }

    // Use 1006 (abnormal closure) if connection wasn't cleanly closed.
    const code = if (was_clean) self._close_code else 1006;
    const reason = if (was_clean) self._close_reason else "";

    // HttpClient completion runs at a host/network boundary, outside any
    // entered V8 Context. Queue the DOM events on this WebSocket's Context;
    // Env enters it with a HandleScope and performs the microtask checkpoint.
    // The task takes its own native reference before cleanup drops the
    // connection-held one.
    self.scheduleDeferred(.{ .terminal = .{
        .emit_error = !was_clean,
        .code = code,
        .reason = reason,
        .was_clean = was_clean,
    } }) catch |err| {
        log.err(.websocket, "terminal event scheduling failed", .{ .err = err });
    };
    self.cleanup();
}

fn cleanup(self: *WebSocket) void {
    if (self._conn == null) {
        return;
    }
    self.teardownConn();
    self.releaseRef(self._exec.page);
}

// Unlink the connection from the http client + owner and free the request headers.
fn teardownConn(self: *WebSocket) void {
    const conn = self._conn orelse return;
    self._exec.httpOwner().removeWS(self);
    self._http_client.removeConn(conn);
    self._req_headers.deinit();
    self._conn = null;
}

fn queueMessage(self: *WebSocket, msg: Message) !void {
    const conn = self._conn orelse return error.InvalidStateError;
    switch (msg) {
        .text => |content| {
            try self._http_client.sendWebSocket(conn, .text, content.data, 0);
            msg.deinit(self._exec.page);
        },
        .binary => |content| {
            try self._http_client.sendWebSocket(conn, .binary, content.data, 0);
            msg.deinit(self._exec.page);
        },
        .close => try self._http_client.sendWebSocket(
            conn,
            .close,
            self._close_reason,
            self._close_code,
        ),
    }
}

/// wreq reports OPEN only after validating the complete RFC 6455
/// response and taking ownership of the upgraded stream.
pub fn wreqConnected(self: *WebSocket, protocol: ?[]const u8) !void {
    if (self._ready_state != .connecting) return error.InvalidStateError;
    if (protocol) |value| self._protocol = try self._arena.dupe(u8, value);
    self._ready_state = .open;
    log.info(.websocket, "connected", .{ .url = self._url });
    try self.scheduleDeferred(.open);
}

/// wreq delivers one complete logical message per event, so the browser does
/// not need transport-specific fragment reassembly.
pub fn wreqMessage(self: *WebSocket, data: []const u8, frame_type: http.WsFrameType) !void {
    if (self._ready_state == .closed) return error.InvalidStateError;
    if (data.len > self._http_client.max_response_size) return error.MessageTooLarge;
    try self.scheduleMessage(data, frame_type);
}

/// Record a validated peer close. Event dispatch remains in the normal
/// HttpClient completion path so connection removal and JS callbacks retain
/// normal browser task ordering.
pub fn wreqClose(self: *WebSocket, code: u16, reason: []const u8) !void {
    if (self._ready_state == .closed) return error.InvalidStateError;
    self._close_code = code;
    self._close_reason = try self._arena.dupe(u8, reason);
    self._ready_state = .closing;
}

const DeferredEvent = union(enum) {
    open,
    message: struct {
        data: []const u8,
        frame_type: http.WsFrameType,
    },
    terminal: struct {
        emit_error: bool,
        code: u16,
        reason: []const u8,
        was_clean: bool,
    },
};

const DeferredEventTask = struct {
    ws: *WebSocket,
    event: DeferredEvent,

    fn finish(self: *DeferredEventTask) void {
        self.ws.releaseRef(self.ws._exec.page);
    }

    fn cancelled(raw: *anyopaque) void {
        const self: *DeferredEventTask = @ptrCast(@alignCast(raw));
        self.finish();
    }

    fn run(raw: *anyopaque) !?u32 {
        const self: *DeferredEventTask = @ptrCast(@alignCast(raw));
        defer self.finish();

        const ws = self.ws;
        if (ws._exec.isShuttingDown()) return null;
        switch (self.event) {
            .open => try ws.dispatchOpenEvent(),
            .message => |message| try ws.dispatchMessageEvent(message.data, message.frame_type),
            .terminal => |terminal| {
                // RFC 6455/HTML requires error before close for abnormal
                // termination. One failing listener must not suppress close.
                if (terminal.emit_error) {
                    ws.dispatchErrorEvent() catch |err| {
                        log.err(.websocket, "error event dispatch failed", .{ .err = err });
                    };
                }
                ws.dispatchCloseEvent(
                    terminal.code,
                    terminal.reason,
                    terminal.was_clean,
                ) catch |err| {
                    log.err(.websocket, "close event dispatch failed", .{ .err = err });
                };
            },
        }
        return null;
    }
};

fn scheduleDeferred(self: *WebSocket, event: DeferredEvent) !void {
    const task = try self._arena.create(DeferredEventTask);
    task.* = .{ .ws = self, .event = event };

    self.acquireRef();
    errdefer self.releaseRef(self._exec.page);
    try self._exec.js.scheduler.add(task, DeferredEventTask.run, 0, .{
        .name = "WebSocket.event",
        .low_priority = false,
        .finalizer = DeferredEventTask.cancelled,
    });
}

fn scheduleMessage(self: *WebSocket, data: []const u8, frame_type: http.WsFrameType) !void {
    const owned = try self._arena.dupe(u8, data);
    try self.scheduleDeferred(.{ .message = .{
        .data = owned,
        .frame_type = frame_type,
    } });
}

fn isValidProtocol(protocol: []const u8) bool {
    if (protocol.len == 0) return false;
    for (protocol) |c| {
        // Control characters and non-ASCII
        if (c <= 31 or c >= 127) return false;
        // Separators per RFC 2616
        switch (c) {
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}', ' ', '\t' => return false,
            else => {},
        }
    }
    return true;
}

/// WebSocket send() accepts string, Blob, ArrayBuffer, or TypedArray
const SendData = union(enum) {
    blob: *Blob,
    js_val: js.Value,
};

/// Union for extracting bytes from ArrayBuffer/TypedArray
const BinaryData = union(enum) {
    int8: []i8,
    uint8: []u8,
    int16: []i16,
    uint16: []u16,
    int32: []i32,
    uint32: []u32,
    int64: []i64,
    uint64: []u64,
    float32: []f32,
    float64: []f64,

    fn asBuffer(self: BinaryData) []u8 {
        return switch (self) {
            .int8 => |b| @as([*]u8, @ptrCast(b.ptr))[0..b.len],
            .uint8 => |b| b,
            inline .int16, .uint16 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 2],
            inline .int32, .uint32, .float32 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 4],
            inline .int64, .uint64, .float64 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 8],
        };
    }
};

pub fn send(self: *WebSocket, data: SendData) !void {
    if (self._ready_state != .open) {
        return error.InvalidStateError;
    }

    switch (data) {
        .blob => |blob| {
            const arena = try self._exec.getArena(blob._slice.len, "WebSocket.message");
            errdefer self._exec.releaseArena(arena);
            try self.queueMessage(.{ .binary = .{
                .arena = arena,
                .data = try arena.dupe(u8, blob._slice),
            } });
        },
        .js_val => |js_val| {
            if (js_val.isString()) |str| {
                const arena = try self._exec.getArena(str.len(), "WebSocket.message");
                errdefer self._exec.releaseArena(arena);
                try self.queueMessage(.{ .text = .{
                    .arena = arena,
                    .data = try str.toSliceWithAlloc(arena),
                } });
            } else {
                const binary = try js_val.toZig(BinaryData);
                const buffer = binary.asBuffer();

                const arena = try self._exec.getArena(buffer.len, "WebSocket.message");
                errdefer self._exec.releaseArena(arena);
                try self.queueMessage(.{ .binary = .{
                    .arena = arena,
                    .data = try arena.dupe(u8, buffer),
                } });
            }
        },
    }
}

pub fn close(self: *WebSocket, code_: ?u16, reason_: ?[]const u8) !void {
    if (self._ready_state == .closing or self._ready_state == .closed) {
        return;
    }

    // Validate close code per spec: must be 1000 or in range 3000-4999
    if (code_) |code| {
        if (code != 1000 and (code < 3000 or code > 4999)) {
            return error.InvalidAccessError;
        }
    }

    const code = code_ orelse 1000;
    const reason = reason_ orelse "";

    if (self._ready_state == .connecting) {
        // Connection not yet established - fail it
        self._ready_state = .closed;
        // Keep the connection-held reference alive through event dispatch.
        // cleanup() releases that final native reference and may destroy this
        // wrapper, so doing it first is a use-after-free when a close listener
        // is installed on an otherwise unreferenced CONNECTING socket.
        defer self.cleanup();
        try self.dispatchCloseEvent(code, reason, false);
        return;
    }

    self._ready_state = .closing;
    self._close_code = code;
    self._close_reason = try self._arena.dupe(u8, reason);
    try self.queueMessage(.close);
}

pub fn getUrl(self: *const WebSocket) []const u8 {
    return self._url;
}

pub fn getReadyState(self: *const WebSocket) u16 {
    return @intFromEnum(self._ready_state);
}

pub fn getBufferedAmount(self: *const WebSocket) u32 {
    _ = self;
    return 0;
}

pub fn getBinaryType(self: *const WebSocket) []const u8 {
    return @tagName(self._binary_type);
}

pub fn getProtocol(self: *const WebSocket) []const u8 {
    return self._protocol;
}

pub fn setBinaryType(self: *WebSocket, value: []const u8) void {
    if (std.meta.stringToEnum(BinaryType, value)) |bt| {
        self._binary_type = bt;
    }
}

pub fn getOnOpen(self: *const WebSocket) ?js.Function.Global {
    return self._on_open;
}

pub fn setOnOpen(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_open) |old| old.release();
    if (cb_) |cb| {
        self._on_open = try cb.persistWithThis(self);
    } else {
        self._on_open = null;
    }
}

pub fn getOnMessage(self: *const WebSocket) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_message) |old| old.release();
    if (cb_) |cb| {
        self._on_message = try cb.persistWithThis(self);
    } else {
        self._on_message = null;
    }
}

pub fn getOnError(self: *const WebSocket) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_error) |old| old.release();
    if (cb_) |cb| {
        self._on_error = try cb.persistWithThis(self);
    } else {
        self._on_error = null;
    }
}

pub fn getOnClose(self: *const WebSocket) ?js.Function.Global {
    return self._on_close;
}

pub fn setOnClose(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_close) |old| old.release();
    if (cb_) |cb| {
        self._on_close = try cb.persistWithThis(self);
    } else {
        self._on_close = null;
    }
}

fn dispatchOpenEvent(self: *WebSocket) !void {
    const exec = self._exec;
    const target = self.asEventTarget();

    if (exec.hasDirectListeners(target, "open", self._on_open)) {
        const event = try Event.initTrusted(comptime .wrap("open"), .{}, exec.page);
        try exec.dispatch(target, event, self._on_open, .{ .context = "WebSocket open" });
    }
}

fn dispatchMessageEvent(self: *WebSocket, data: []const u8, frame_type: http.WsFrameType) !void {
    const exec = self._exec;
    const target = self.asEventTarget();

    if (exec.hasDirectListeners(target, "message", self._on_message)) {
        const msg_data: MessageEvent.Data = if (frame_type == .binary)
            switch (self._binary_type) {
                .arraybuffer => .{ .arraybuffer = .{ .values = data } },
                .blob => blk: {
                    const blob = try Blob.initFromBytes(data, "", exec.page);
                    blob.acquireRef();
                    break :blk .{ .blob = blob };
                },
            }
        else
            .{ .string = data };

        const event = try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = msg_data,
            .origin = "",
        }, exec.page);
        try exec.dispatch(target, event.asEvent(), self._on_message, .{ .context = "WebSocket message" });
    }
}

fn dispatchErrorEvent(self: *WebSocket) !void {
    const exec = self._exec;
    const target = self.asEventTarget();

    if (exec.hasDirectListeners(target, "error", self._on_error)) {
        const event = try Event.initTrusted(comptime .wrap("error"), .{}, exec.page);
        try exec.dispatch(target, event, self._on_error, .{ .context = "WebSocket error" });
    }
}

fn dispatchCloseEvent(self: *WebSocket, code: u16, reason: []const u8, was_clean: bool) !void {
    const exec = self._exec;
    const target = self.asEventTarget();

    if (exec.hasDirectListeners(target, "close", self._on_close)) {
        const event = try CloseEvent.initTrusted(comptime .wrap("close"), .{
            .code = code,
            .reason = reason,
            .wasClean = was_clean,
        }, exec.page);
        try exec.dispatch(target, event.asEvent(), self._on_close, .{ .context = "WebSocket close" });
    }
}

const Message = union(enum) {
    close,
    text: Content,
    binary: Content,

    const Content = struct {
        arena: Allocator,
        data: []const u8,
    };
    fn deinit(self: Message, page: *Page) void {
        switch (self) {
            .text, .binary => |msg| page.releaseArena(msg.arena),
            .close => {},
        }
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebSocket);

    pub const Meta = struct {
        pub const name = "WebSocket";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(WebSocket.init, .{ .arity = 1, .required_args = 1 });

    pub const CONNECTING = bridge.property(@intFromEnum(ReadyState.connecting), .{ .template = true });
    pub const OPEN = bridge.property(@intFromEnum(ReadyState.open), .{ .template = true });
    pub const CLOSING = bridge.property(@intFromEnum(ReadyState.closing), .{ .template = true });
    pub const CLOSED = bridge.property(@intFromEnum(ReadyState.closed), .{ .template = true });

    pub const url = bridge.accessor(WebSocket.getUrl, null, .{});
    pub const readyState = bridge.accessor(WebSocket.getReadyState, null, .{});
    pub const bufferedAmount = bridge.accessor(WebSocket.getBufferedAmount, null, .{});
    pub const binaryType = bridge.accessor(WebSocket.getBinaryType, WebSocket.setBinaryType, .{});

    pub const protocol = bridge.accessor(WebSocket.getProtocol, null, .{});
    pub const extensions = bridge.constantAccessor("");

    pub const onopen = bridge.accessor(WebSocket.getOnOpen, WebSocket.setOnOpen, .{});
    pub const onmessage = bridge.accessor(WebSocket.getOnMessage, WebSocket.setOnMessage, .{});
    pub const onerror = bridge.accessor(WebSocket.getOnError, WebSocket.setOnError, .{});
    pub const onclose = bridge.accessor(WebSocket.getOnClose, WebSocket.setOnClose, .{});

    pub const send = bridge.function(WebSocket.send, .{});
    pub const close = bridge.function(WebSocket.close, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: WebSocket" {
    try testing.htmlRunner("net/websocket.html", .{});
}

test "WebApi: WebSocket in worker" {
    try testing.htmlRunner("net/websocket_worker.html", .{});
}
