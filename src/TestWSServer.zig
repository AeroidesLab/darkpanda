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
const builtin = @import("builtin");
const posix = std.posix;

const TestWSServer = @This();

state: std.atomic.Value(State),
port: u16,
wake_port: std.atomic.Value(u16),

const State = enum(u8) {
    starting,
    running,
    stopping,
    stopped,
};

const default_port = 9584;

pub fn init() TestWSServer {
    return initOnPort(default_port);
}

fn initOnPort(port: u16) TestWSServer {
    return .{
        .state = .init(.starting),
        .port = port,
        .wake_port = .init(0),
    };
}

pub fn stop(self: *TestWSServer) void {
    while (true) {
        const state = self.state.load(.acquire);
        switch (state) {
            .starting, .running => {
                if (self.state.cmpxchgStrong(state, .stopping, .acq_rel, .acquire) != null) {
                    continue;
                }

                // The accept thread owns and closes the listening socket. A
                // loopback connection wakes blocking accept() without the
                // cross-thread closesocket()/WSAEINTR race on Windows.
                if (state == .running) self.wakeListener();
                return;
            },
            .stopping, .stopped => return,
        }
    }
}

pub fn run(self: *TestWSServer, wg: *std.Thread.WaitGroup) void {
    self.runImpl(wg) catch |err| {
        std.debug.print("WebSocket echo server error: {}\n", .{err});
    };
}

fn runImpl(self: *TestWSServer, wg: *std.Thread.WaitGroup) !void {
    var readiness_reported = false;
    defer if (!readiness_reported) wg.finish();
    defer self.state.store(.stopped, .release);

    const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(socket);

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, self.port);

    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(socket, &addr.any, addr.getOsSockLen());
    try posix.listen(socket, 8);

    var bound_addr: std.net.Address = undefined;
    var bound_addr_len: posix.socklen_t = @sizeOf(std.net.Address);
    try posix.getsockname(socket, &bound_addr.any, &bound_addr_len);
    self.wake_port.store(bound_addr.getPort(), .release);

    if (self.state.cmpxchgStrong(.starting, .running, .release, .acquire)) |state| {
        if (state == .stopping) return;
        return error.InvalidServerState;
    }

    readiness_reported = true;
    wg.finish();

    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client = acceptSocket(socket, &client_addr, &addr_len) catch |err| {
            if (self.isStopping() and isShutdownSocketError(err)) return;

            std.debug.print("[WS Server] Accept error: {}\n", .{err});
            if (err == error.SocketNotListening or err == error.FileDescriptorNotASocket) return err;
            continue;
        };

        if (self.isStopping()) {
            posix.close(client);
            return;
        }

        const thread = std.Thread.spawn(.{}, handleClient, .{ self, client }) catch |err| {
            std.debug.print("[WS Server] Thread spawn error: {}\n", .{err});
            posix.close(client);
            continue;
        };
        thread.detach();
    }
}

fn wakeListener(self: *TestWSServer) void {
    const port = self.wake_port.load(.acquire);
    if (port == 0) return;

    const address = std.net.Address.parseIp("127.0.0.1", port) catch return;
    const stream = std.net.tcpConnectToAddress(address) catch return;
    stream.close();
}

fn isStopping(self: *const TestWSServer) bool {
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

fn acceptSocket(socket: posix.socket_t, address: *posix.sockaddr, address_len: *posix.socklen_t) !posix.socket_t {
    if (builtin.os.tag != .windows) return posix.accept(socket, address, address_len, 0);

    const windows = std.os.windows;
    const client = windows.accept(socket, address, address_len);
    if (client != windows.ws2_32.INVALID_SOCKET) return client;

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

fn handleClient(self: *TestWSServer, client: posix.socket_t) void {
    defer posix.close(client);

    self.handleClientImpl(client) catch |err| {
        if (err == error.ForceClose) return;
        if (self.isStopping() and isShutdownSocketError(err)) return;
        std.debug.print("[WS Server] Connection error: {}\n", .{err});
    };
}

fn handleClientImpl(self: *TestWSServer, client: posix.socket_t) !void {

    // Header field-names are case-insensitive and TCP may split an HTTP/1
    // header block at any byte. The old one-read/case-sensitive fixture hid
    // genuine client behavior differences (wreq commonly serializes generated
    // handshake fields with a different case than the client transport).
    var handshake_buf: [64 * 1024]u8 = undefined;
    const request = (try readHeaderBlock(client, &handshake_buf)) orelse return;

    const key = headerValue(request, "sec-websocket-key") orelse return;
    const selected_protocol = if (headerValue(request, "sec-websocket-protocol")) |value|
        firstHeaderToken(value)
    else
        null;

    // Capture the request's Cookie header value (if any) so the test fixture
    // can ask for it back via the `get-cookie` command. Copy out of the
    // handshake buffer because the value must remain available throughout
    // the frame loop.
    var cookie_buf: [4096]u8 = undefined;
    var cookie_len: usize = 0;
    if (headerValue(request, "cookie")) |value| {
        cookie_len = @min(value.len, cookie_buf.len);
        @memcpy(cookie_buf[0..cookie_len], value[0..cookie_len]);
    }

    // Same for the Origin header, exposed via the `get-origin` command. Exact
    // field-name matching prevents obsolete Sec-WebSocket-Origin from aliasing
    // it while retaining HTTP's case-insensitive semantics.
    var origin_buf: [1024]u8 = undefined;
    var origin_len: usize = 0;
    if (headerValue(request, "origin")) |value| {
        origin_len = @min(value.len, origin_buf.len);
        @memcpy(origin_buf[0..origin_len], value[0..origin_len]);
    }

    // Compute accept key
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var hash: [20]u8 = undefined;
    hasher.final(&hash);

    var accept_key: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

    // Select the first offered subprotocol, as a deterministic RFC 6455 test
    // endpoint. Emit it only when the client sent a non-empty offer.
    try writeAll(client, "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n");
    if (selected_protocol) |protocol| {
        try writeAll(client, "Sec-WebSocket-Protocol: ");
        try writeAll(client, protocol);
        try writeAll(client, "\r\n");
    }
    var accept_line_buf: [64]u8 = undefined;
    const accept_line = try std.fmt.bufPrint(
        &accept_line_buf,
        "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept_key},
    );
    try writeAll(client, accept_line);

    // Message loop with larger buffer for big messages
    var msg_buf: [128 * 1024]u8 = undefined;
    var recv_buf = RecvBuffer{ .buf = &msg_buf };

    while (true) {
        const frame = (try recv_buf.readFrame(client)) orelse break;

        // Close frame - echo it back before closing
        if (frame.opcode == 8) {
            try sendFrame(client, 8, "", frame.payload);
            break;
        }

        // Handle commands or echo
        if (frame.opcode == 1) { // Text
            try handleTextMessage(client, frame.payload, cookie_buf[0..cookie_len], origin_buf[0..origin_len]);
        } else if (frame.opcode == 2) { // Binary
            try handleBinaryMessage(client, frame.payload);
        }
    }

    _ = self;
}

fn readHeaderBlock(client: posix.socket_t, buf: []u8) !?[]const u8 {
    var end: usize = 0;
    while (end < buf.len) {
        const n = try socketRecv(client, buf[end..]);
        if (n == 0) return null;
        end += n;
        if (std.mem.indexOf(u8, buf[0..end], "\r\n\r\n")) |terminator| {
            return buf[0 .. terminator + 4];
        }
    }
    return null;
}

fn headerValue(request: []const u8, wanted_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, wanted_name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn firstHeaderToken(value: []const u8) ?[]const u8 {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

test "HTTP upgrade header parser is case-insensitive and exact" {
    const request = "GET /socket HTTP/1.1\r\n" ++
        "sEc-WeBsOcKeT-kEy:\t nonce-value \t\r\n" ++
        "Sec-WebSocket-Origin: must-not-alias\r\n" ++
        "oRiGiN: null\r\n\r\n";

    try std.testing.expectEqualStrings("nonce-value", headerValue(request, "sec-websocket-key").?);
    try std.testing.expectEqualStrings("null", headerValue(request, "origin").?);
    try std.testing.expect(headerValue(request, "cookie") == null);
}

test "subprotocol selection uses the first non-empty offered token" {
    try std.testing.expectEqualStrings("chat", firstHeaderToken("  , chat , superchat ").?);
    try std.testing.expect(firstHeaderToken(" , \t , ") == null);
}

fn writeAll(client: posix.socket_t, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const n = try socketSend(client, data[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn socketRecv(socket: posix.socket_t, buf: []u8) !usize {
    if (builtin.os.tag != .windows) return posix.recv(socket, buf, 0);

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

fn socketSend(socket: posix.socket_t, buf: []const u8) !usize {
    if (builtin.os.tag != .windows) return posix.send(socket, buf, 0);

    const windows = std.os.windows;
    const len = @min(buf.len, std.math.maxInt(i32));
    const result = windows.ws2_32.send(socket, buf.ptr, @intCast(len), 0);
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
        .WSAENOBUFS => error.SystemResources,
        else => |err| windows.unexpectedWSAError(err),
    };
}

fn runLifecycleTestServer(server: *TestWSServer, wg: *std.Thread.WaitGroup, result: *?anyerror) void {
    server.runImpl(wg) catch |err| {
        result.* = err;
    };
}

test "stop wakes a blocking WebSocket accept without cross-thread close" {
    var timer = try std.time.Timer.start();

    for (0..3) |_| {
        var server = initOnPort(0);
        var result: ?anyerror = null;
        var wg: std.Thread.WaitGroup = .{};
        wg.startMany(1);

        const thread = try std.Thread.spawn(.{}, runLifecycleTestServer, .{ &server, &wg, &result });
        wg.wait();
        server.stop();
        server.stop();
        thread.join();
        server.stop();

        try std.testing.expect(result == null);
        try std.testing.expectEqual(State.stopped, server.state.load(.acquire));
    }

    // A regression to closesocket(listener) commonly stalls one of these joins
    // for about 30 seconds on Windows. Keep enough margin for debug/CI hosts.
    try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
}

const Frame = struct {
    opcode: u8,
    payload: []u8,
};

const RecvBuffer = struct {
    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    fn available(self: *RecvBuffer) []u8 {
        return self.buf[self.start..self.end];
    }

    fn consume(self: *RecvBuffer, n: usize) void {
        self.start += n;
        if (self.start >= self.end) {
            self.start = 0;
            self.end = 0;
        }
    }

    fn ensureBytes(self: *RecvBuffer, client: posix.socket_t, needed: usize) !bool {
        while (self.end - self.start < needed) {
            // Compact buffer if needed
            if (self.end >= self.buf.len - 1024) {
                const avail = self.end - self.start;
                std.mem.copyForwards(u8, self.buf[0..avail], self.buf[self.start..self.end]);
                self.start = 0;
                self.end = avail;
            }

            const n = try socketRecv(client, self.buf[self.end..]);
            if (n == 0) return false;
            self.end += n;
        }
        return true;
    }

    fn readFrame(self: *RecvBuffer, client: posix.socket_t) !?Frame {
        // Need at least 2 bytes for basic header
        if (!try self.ensureBytes(client, 2)) return null;

        const data = self.available();
        const opcode = data[0] & 0x0F;
        const masked = (data[1] & 0x80) != 0;
        var payload_len: usize = data[1] & 0x7F;
        var header_size: usize = 2;

        // Extended payload length
        if (payload_len == 126) {
            if (!try self.ensureBytes(client, 4)) return null;
            const d = self.available();
            payload_len = @as(usize, d[2]) << 8 | d[3];
            header_size = 4;
        } else if (payload_len == 127) {
            if (!try self.ensureBytes(client, 10)) return null;
            const d = self.available();
            payload_len = @as(usize, d[2]) << 56 |
                @as(usize, d[3]) << 48 |
                @as(usize, d[4]) << 40 |
                @as(usize, d[5]) << 32 |
                @as(usize, d[6]) << 24 |
                @as(usize, d[7]) << 16 |
                @as(usize, d[8]) << 8 |
                d[9];
            header_size = 10;
        }

        const mask_size: usize = if (masked) 4 else 0;
        const total_frame_size = header_size + mask_size + payload_len;

        if (!try self.ensureBytes(client, total_frame_size)) return null;

        const frame_data = self.available();

        // Get mask key if present
        var mask_key: [4]u8 = undefined;
        if (masked) {
            @memcpy(&mask_key, frame_data[header_size..][0..4]);
        }

        // Get payload and unmask
        const payload_start = header_size + mask_size;
        const payload = frame_data[payload_start..][0..payload_len];

        if (masked) {
            for (payload, 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
        }

        self.consume(total_frame_size);

        return .{ .opcode = opcode, .payload = payload };
    }
};

fn handleTextMessage(client: posix.socket_t, payload: []const u8, cookie_header: []const u8, origin_header: []const u8) !void {
    // Command: force-close - close socket immediately without close frame
    if (std.mem.eql(u8, payload, "force-close")) {
        return error.ForceClose;
    }

    // Command: get-cookie - send the Cookie header value the upgrade
    // request carried (empty string if none). Used by the cookie-on-
    // upgrade regression test.
    if (std.mem.eql(u8, payload, "get-cookie")) {
        try sendFrame(client, 1, "cookie:", cookie_header);
        return;
    }

    // Command: get-origin - send the Origin header value the upgrade
    // request carried (empty string if none). Used by the origin-on-
    // upgrade regression test.
    if (std.mem.eql(u8, payload, "get-origin")) {
        try sendFrame(client, 1, "origin:", origin_header);
        return;
    }

    // Command: send-large:N - send a message of N bytes
    if (std.mem.startsWith(u8, payload, "send-large:")) {
        const size_str = payload["send-large:".len..];
        const size = std.fmt.parseInt(usize, size_str, 10) catch return error.InvalidCommand;
        try sendLargeMessage(client, size);
        return;
    }

    // Command: close:CODE:REASON - send close frame with specific code/reason
    if (std.mem.startsWith(u8, payload, "close:")) {
        const rest = payload["close:".len..];
        if (std.mem.indexOf(u8, rest, ":")) |sep| {
            const code = std.fmt.parseInt(u16, rest[0..sep], 10) catch 1000;
            const reason = rest[sep + 1 ..];
            try sendCloseFrame(client, code, reason);
        }
        return;
    }

    // Default: echo with "echo-" prefix
    const prefix = "echo-";
    try sendFrame(client, 1, prefix, payload);
}

fn handleBinaryMessage(client: posix.socket_t, payload: []const u8) !void {
    // Echo binary data back with byte 0xEE prepended as marker
    const marker = [_]u8{0xEE};
    try sendFrame(client, 2, &marker, payload);
}

fn sendFrame(client: posix.socket_t, opcode: u8, prefix: []const u8, payload: []const u8) !void {
    const total_len = prefix.len + payload.len;

    // Build header
    var header: [10]u8 = undefined;
    var header_len: usize = 2;

    header[0] = 0x80 | opcode; // FIN + opcode

    if (total_len <= 125) {
        header[1] = @intCast(total_len);
    } else if (total_len <= 65535) {
        header[1] = 126;
        header[2] = @intCast((total_len >> 8) & 0xFF);
        header[3] = @intCast(total_len & 0xFF);
        header_len = 4;
    } else {
        header[1] = 127;
        header[2] = @intCast((total_len >> 56) & 0xFF);
        header[3] = @intCast((total_len >> 48) & 0xFF);
        header[4] = @intCast((total_len >> 40) & 0xFF);
        header[5] = @intCast((total_len >> 32) & 0xFF);
        header[6] = @intCast((total_len >> 24) & 0xFF);
        header[7] = @intCast((total_len >> 16) & 0xFF);
        header[8] = @intCast((total_len >> 8) & 0xFF);
        header[9] = @intCast(total_len & 0xFF);
        header_len = 10;
    }

    try writeAll(client, header[0..header_len]);
    if (prefix.len > 0) {
        try writeAll(client, prefix);
    }
    if (payload.len > 0) {
        try writeAll(client, payload);
    }
}

fn sendLargeMessage(client: posix.socket_t, size: usize) !void {
    // Build header
    var header: [10]u8 = undefined;
    var header_len: usize = 2;

    header[0] = 0x81; // FIN + text

    if (size <= 125) {
        header[1] = @intCast(size);
    } else if (size <= 65535) {
        header[1] = 126;
        header[2] = @intCast((size >> 8) & 0xFF);
        header[3] = @intCast(size & 0xFF);
        header_len = 4;
    } else {
        header[1] = 127;
        header[2] = @intCast((size >> 56) & 0xFF);
        header[3] = @intCast((size >> 48) & 0xFF);
        header[4] = @intCast((size >> 40) & 0xFF);
        header[5] = @intCast((size >> 32) & 0xFF);
        header[6] = @intCast((size >> 24) & 0xFF);
        header[7] = @intCast((size >> 16) & 0xFF);
        header[8] = @intCast((size >> 8) & 0xFF);
        header[9] = @intCast(size & 0xFF);
        header_len = 10;
    }

    try writeAll(client, header[0..header_len]);

    // Send payload in chunks - pattern of 'A'-'Z' repeating
    var sent: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (sent < size) {
        const to_send = @min(chunk.len, size - sent);
        for (chunk[0..to_send], 0..) |*b, i| {
            b.* = @intCast('A' + ((sent + i) % 26));
        }
        try writeAll(client, chunk[0..to_send]);
        sent += to_send;
    }
}

fn sendCloseFrame(client: posix.socket_t, code: u16, reason: []const u8) !void {
    const reason_len = @min(reason.len, 123); // Max 123 bytes for reason
    const payload_len = 2 + reason_len;

    var frame: [129]u8 = undefined; // 2 header + 2 code + 123 reason + 2 padding
    frame[0] = 0x88; // FIN + close
    frame[1] = @intCast(payload_len);
    frame[2] = @intCast((code >> 8) & 0xFF);
    frame[3] = @intCast(code & 0xFF);
    if (reason_len > 0) {
        @memcpy(frame[4..][0..reason_len], reason[0..reason_len]);
    }

    try writeAll(client, frame[0 .. 4 + reason_len]);
}
