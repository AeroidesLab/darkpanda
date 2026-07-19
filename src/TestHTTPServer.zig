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
const builtin = @import("builtin");
const URL = @import("browser/URL.zig");

const TestHTTPServer = @This();

state: std.atomic.Value(State),
port: u16,
wake_port: std.atomic.Value(u16),
handler: Handler,

const Handler = *const fn (req: *std.http.Server.Request) anyerror!void;
const State = enum(u8) {
    starting,
    running,
    stopping,
    stopped,
};

const default_port = 9582;

pub fn init(handler: Handler) TestHTTPServer {
    return initOnPort(handler, default_port);
}

fn initOnPort(handler: Handler, port: u16) TestHTTPServer {
    return .{
        .state = .init(.starting),
        .port = port,
        .wake_port = .init(0),
        .handler = handler,
    };
}

pub fn deinit(self: *TestHTTPServer) void {
    _ = self;
}

pub fn stop(self: *TestHTTPServer) void {
    while (true) {
        const state = self.state.load(.acquire);
        switch (state) {
            .starting, .running => {
                if (self.state.cmpxchgStrong(state, .stopping, .acq_rel, .acquire) != null) {
                    continue;
                }

                // Never close a listening socket from another thread on Windows.
                // closesocket() interrupts accept() with WSAEINTR and can race a
                // recycled SOCKET value. A loopback connection wakes accept(); the
                // server thread remains the sole owner that closes the listener.
                if (state == .running) self.wakeListener();
                return;
            },
            .stopping, .stopped => return,
        }
    }
}

pub fn run(self: *TestHTTPServer, wg: *std.Thread.WaitGroup) !void {
    var readiness_reported = false;
    defer if (!readiness_reported) wg.finish();
    defer self.state.store(.stopped, .release);

    const address = try std.net.Address.parseIp("127.0.0.1", self.port);

    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    self.wake_port.store(listener.listen_address.getPort(), .release);
    if (self.state.cmpxchgStrong(.starting, .running, .release, .acquire)) |state| {
        if (state == .stopping) return;
        return error.InvalidServerState;
    }

    readiness_reported = true;
    wg.finish();

    while (true) {
        const conn = acceptConnection(&listener) catch |err| {
            if (self.isStopping() and isShutdownSocketError(err)) {
                return;
            }

            if (err == error.ConnectionAborted or err == error.ConnectionResetByPeer or err == error.Interrupted) {
                std.debug.print("Test HTTP Server accept error: {}\n", .{err});
                continue;
            }
            return err;
        };

        if (self.isStopping()) {
            conn.stream.close();
            return;
        }

        const thrd = try std.Thread.spawn(.{}, handleConnection, .{ self, conn });
        thrd.detach();
    }
}

fn wakeListener(self: *TestHTTPServer) void {
    const port = self.wake_port.load(.acquire);
    if (port == 0) return;

    const address = std.net.Address.parseIp("127.0.0.1", port) catch return;
    const stream = std.net.tcpConnectToAddress(address) catch return;
    stream.close();
}

fn isStopping(self: *const TestHTTPServer) bool {
    return self.state.load(.acquire) != .running;
}

fn isShutdownSocketError(err: anyerror) bool {
    return switch (err) {
        error.Interrupted,
        error.SocketNotListening,
        error.ConnectionAborted,
        error.ConnectionResetByPeer,
        error.SocketNotConnected,
        error.SocketShutdown,
        => true,
        else => false,
    };
}

fn acceptConnection(listener: *std.net.Server) !std.net.Server.Connection {
    if (builtin.os.tag != .windows) return listener.accept();

    const windows = std.os.windows;
    var accepted_addr: std.net.Address = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    const socket = windows.accept(listener.stream.handle, &accepted_addr.any, &addr_len);
    if (socket == windows.ws2_32.INVALID_SOCKET) {
        return switch (windows.ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => error.ConnectionAborted,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEINTR => error.Interrupted,
            .WSAEINVAL => error.SocketNotListening,
            .WSAENOTSOCK => error.FileDescriptorNotASocket,
            .WSAEMFILE => error.ProcessFdQuotaExceeded,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSAENOBUFS => error.SystemResources,
            .WSAEOPNOTSUPP => error.OperationNotSupported,
            .WSAEWOULDBLOCK => error.WouldBlock,
            else => |err| windows.unexpectedWSAError(err),
        };
    }

    return .{
        .stream = .{ .handle = socket },
        .address = accepted_addr,
    };
}

const SocketReader = struct {
    interface: std.Io.Reader,
    socket: std.posix.socket_t,
    err: ?anyerror = null,

    fn init(socket: std.posix.socket_t, buffer: []u8) SocketReader {
        return .{
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .socket = socket,
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SocketReader = @alignCast(@fieldParentPtr("interface", reader));
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        const read_len = socketRecv(self.socket, dest) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (read_len == 0) return error.EndOfStream;
        writer.advance(read_len);
        return read_len;
    }
};

fn socketRecv(socket: std.posix.socket_t, buf: []u8) !usize {
    if (builtin.os.tag != .windows) return std.posix.recv(socket, buf, 0);

    const windows = std.os.windows;
    const len = @min(buf.len, std.math.maxInt(i32));
    const result = windows.ws2_32.recv(socket, buf.ptr, @intCast(len), 0);
    if (result != windows.ws2_32.SOCKET_ERROR) return @intCast(result);

    return switch (windows.ws2_32.WSAGetLastError()) {
        .WSAECONNABORTED => error.ConnectionAborted,
        .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
        .WSAEINTR => error.Interrupted,
        .WSAENOTCONN => error.SocketNotConnected,
        .WSAESHUTDOWN => error.SocketShutdown,
        .WSAETIMEDOUT => error.ConnectionTimedOut,
        .WSAEWOULDBLOCK => error.WouldBlock,
        .WSAENETDOWN => error.NetworkSubsystemFailed,
        else => |err| windows.unexpectedWSAError(err),
    };
}

fn lifecycleTestHandler(req: *std.http.Server.Request) !void {
    try req.respond("", .{});
}

fn runLifecycleTestServer(server: *TestHTTPServer, wg: *std.Thread.WaitGroup, result: *?anyerror) void {
    server.run(wg) catch |err| {
        result.* = err;
    };
}

test "stop wakes a blocking HTTP accept without cross-thread close" {
    var timer = try std.time.Timer.start();

    for (0..3) |_| {
        var server = initOnPort(lifecycleTestHandler, 0);
        var result: ?anyerror = null;
        var wg: std.Thread.WaitGroup = .{};
        wg.startMany(1);

        const thread = try std.Thread.spawn(.{}, runLifecycleTestServer, .{ &server, &wg, &result });
        wg.wait();
        server.stop();
        server.stop();
        thread.join();
        server.stop();

        try std.testing.expectEqual(@as(?anyerror, null), result);
        try std.testing.expectEqual(State.stopped, server.state.load(.acquire));
        server.deinit();
    }

    // A regression to closesocket(listener) commonly stalls one of these joins
    // for about 30 seconds on Windows. Keep enough margin for debug/CI hosts.
    try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
}

fn handleConnection(self: *TestHTTPServer, conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    var req_buf: [2048]u8 = undefined;
    var conn_reader = SocketReader.init(conn.stream.handle, &req_buf);
    var conn_writer = conn.stream.writer(&req_buf);

    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var req = http_server.receiveHead() catch |err| switch (err) {
            error.ReadFailed => {
                if (conn_reader.err) |socket_err| {
                    if (!(self.isStopping() and isShutdownSocketError(socket_err))) {
                        std.debug.print("Test HTTP Server connection error: {}\n", .{socket_err});
                    }
                }
                return;
            },
            error.HttpConnectionClosing => return,
            else => {
                std.debug.print("Test HTTP Server error: {}\n", .{err});
                return err;
            },
        };

        self.handler(&req) catch |err| {
            switch (err) {
                error.BrokenPipe => {},
                else => {
                    std.debug.print("test http error '{s}': {}\n", .{ req.head.target, err });
                    req.respond("server error", .{ .status = .internal_server_error }) catch {};
                },
            }
            return;
        };
    }
}

pub fn sendFile(req: *std.http.Server.Request, file_path: []const u8) !void {
    var url_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&url_buf);
    var unescaped_file_path = try URL.unescape(fba.allocator(), file_path);
    if (std.mem.indexOfScalarPos(u8, unescaped_file_path, 0, '?')) |pos| {
        unescaped_file_path = unescaped_file_path[0..pos];
    }
    var file = std.fs.cwd().openFile(unescaped_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return req.respond("server error", .{ .status = .not_found }),
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    var send_buffer: [4096]u8 = undefined;

    var res = try req.respondStreaming(&send_buffer, .{
        .content_length = stat.size,
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = getContentType(unescaped_file_path) },
            },
        },
    });

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&read_buffer);
    _ = try res.writer.sendFileAll(&reader, .unlimited);
    try res.writer.flush();
    try res.end();
}

fn getContentType(file_path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, file_path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, file_path, ".jpg") or std.mem.endsWith(u8, file_path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, file_path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, file_path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, file_path, ".avif")) return "image/avif";
    if (std.mem.endsWith(u8, file_path, ".svg")) return "image/svg+xml";

    if (std.mem.endsWith(u8, file_path, ".js")) {
        return "application/json";
    }

    if (std.mem.endsWith(u8, file_path, ".GB2312.html")) {
        return "text/html; charset=GB2312";
    }

    if (std.mem.endsWith(u8, file_path, ".html")) {
        return "text/html";
    }

    if (std.mem.endsWith(u8, file_path, ".htm")) {
        return "text/html";
    }

    if (std.mem.endsWith(u8, file_path, ".xml")) {
        // some wpt tests do this
        return "text/xml";
    }

    if (std.mem.endsWith(u8, file_path, ".mjs")) {
        // mjs are ECMAScript modules
        return "application/json";
    }

    std.debug.print("TestHTTPServer asked to serve an unknown file type: {s}\n", .{file_path});
    return "text/html";
}
