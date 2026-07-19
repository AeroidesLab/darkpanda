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
const builtin = @import("builtin");

const App = @import("../App.zig");
const Config = @import("../Config.zig");

const CDP = @import("../cdp/CDP.zig");

const http = @import("http.zig");

const Cache = @import("cache/Cache.zig");

const log = lp.log;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;
const invalid_socket: posix.socket_t = if (builtin.os.tag == .windows)
    std.os.windows.ws2_32.INVALID_SOCKET
else
    -1;

const Network = @This();

pub const InitOptions = struct {
    /// Absolute path to the wreq transport dynamic library. The Network owns a
    /// copy so embedders may release their RuntimeOptions after initialization.
    wreq_transport_path: ?[]const u8 = null,
};

const Listener = struct {
    socket: posix.socket_t,
    ctx: *anyopaque,
    onAccept: *const fn (ctx: *anyopaque, socket: posix.socket_t) void,
};

// Read side of a CDP WebSocket, registered with the Network thread so
// bytes are read off the socket from here and dispatched into the CDP
// layer via direct method calls on `cdp`. Network never sends on the
// socket — the worker is the sole writer. After registerCdp returns,
// the worker must not call posix.read on this socket directly.
// unregisterCdp is synchronous: it blocks until Network confirms the
// link has been dropped from its poll set and won't touch it again.
pub const CdpLink = struct {
    cdp: *CDP,
    state: State,
    socket: posix.socket_t,
    // The worker's HttpClient.Handles (by value — it's one pointer
    // wide). Network calls handles.wakeup() whenever it pushes to the
    // worker's inbox.
    handles: http.Handles,
    node: DoublyLinkedList.Node = .{},

    pub const State = enum {
        live,
        // Worker called unregisterCdp; Network will drop the link on
        // its next loop iteration and signal cdp_unregister.
        unregistering,
        // Network has dropped the link from its poll set. The worker
        // can safely free anything the link's callbacks closed over.
        removed,
    };
};

// Number of fixed pollfds entries (wakeup endpoint + listener).
const PSEUDO_POLLFDS = 2;

allocator: Allocator,

/// Owned absolute path supplied by an embedder. null preserves the CLI lookup
/// order (DARKPANDA_WREQ_LIBRARY, then module-adjacent library).
wreq_transport_path: ?[]const u8,

app: *App,
cache: Cache,
config: *const Config,

connections: []http.Connection,
available: DoublyLinkedList = .{},
conn_mutex: std.Thread.Mutex = .{},

ws_pool: std.heap.MemoryPool(http.Connection),
ws_count: usize = 0,
ws_max: u8,
ws_mutex: std.Thread.Mutex = .{},

pollfds: []posix.pollfd,
listener: ?Listener = null,
accept: std.atomic.Value(bool) = .init(true),

// Wakeup endpoints: workers write to [1], main thread polls [0]. Windows
// uses connected UDP sockets because WSAPoll cannot wait on anonymous pipes.
wakeup_pipe: [2]posix.socket_t = .{ invalid_socket, invalid_socket },

shutdown: std.atomic.Value(bool) = .init(false),

// Registered CDP read endpoints. Producer-side (the worker doing
// register/unregister) and consumer-side (this thread's run loop) are
// serialized by cdp_mutex. cdp_unregister signals when a link
// transitions to .removed so unregisterCdp can return.
cdp_links: DoublyLinkedList = .{},
cdp_mutex: std.Thread.Mutex = .{},
cdp_unregister: std.Thread.Condition = .{},
// Per-iteration snapshot of CdpLinks whose sockets are in pollfds.
// Sized at maxConnections at init time so we never allocate inside
// run(). Parallel to pollfds[cdp_start..cdp_start + cdp_poll_count].
// Persists across iterations; only rebuilt when `cdp_dirty` is set.
cdp_poll_snapshot: []?*CdpLink,
cdp_poll_count: usize = 0,

// Set whenever the cdp_links list changes (register / unregister /
// natural drop). prepareCdpPollFds rebuilds the snapshot only when
// this is true; idle iterations skip the rebuild. Network run() ticks
// hundreds of times per second, and the link set is stable between
// connection lifecycle events, so the steady-state cost of the CDP
// poll prep is one mutex acquire + one bool read.
cdp_dirty: bool = false,

// Location in pollfds where cdp sockets start
cdp_start: usize,

fn closeSocket(socket: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        std.os.windows.closesocket(socket) catch {};
    } else {
        posix.close(socket);
    }
}

fn createWakeupPair() ![2]posix.socket_t {
    if (builtin.os.tag != .windows) {
        const pipe = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        return .{ pipe[0], pipe[1] };
    }

    const flags = posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
    const receiver = try posix.socket(posix.AF.INET, flags, posix.IPPROTO.UDP);
    errdefer closeSocket(receiver);

    const sender = try posix.socket(posix.AF.INET, flags, posix.IPPROTO.UDP);
    errdefer closeSocket(sender);

    var loopback = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try posix.bind(receiver, &loopback.any, loopback.getOsSockLen());

    var bound: posix.sockaddr.storage = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getsockname(receiver, @ptrCast(&bound), &bound_len);
    try posix.connect(sender, @ptrCast(&bound), bound_len);

    return .{ receiver, sender };
}

fn readWakeup(socket: posix.socket_t, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        return posix.recv(socket, buf, 0);
    }
    return posix.read(socket, buf);
}

fn writeWakeup(socket: posix.socket_t, buf: []const u8) !usize {
    if (builtin.os.tag == .windows) {
        return posix.send(socket, buf, 0);
    }
    return posix.write(socket, buf);
}

pub fn init(allocator: Allocator, app: *App, config: *const Config) !Network {
    return initWithOptions(allocator, app, config, .{});
}

pub fn initWithOptions(
    allocator: Allocator,
    app: *App,
    config: *const Config,
    options: InitOptions,
) !Network {
    const wreq_transport_path = if (options.wreq_transport_path) |path| blk: {
        if (!std.fs.path.isAbsolute(path)) return error.WreqTransportPathMustBeAbsolute;
        break :blk try allocator.dupe(u8, path);
    } else null;
    errdefer if (wreq_transport_path) |path| allocator.free(path);

    const pipe = try createWakeupPair();
    errdefer closeSocket(pipe[0]);
    errdefer closeSocket(pipe[1]);

    // pollfds layout:
    //   [0]                                  wakeup pipe
    //   [1]                                  listener
    //   [PSEUDO_POLLFDS .. + max_cdp]        CDP socket fds
    const max_cdp = config.maxConnections();
    const pollfds = try allocator.alloc(posix.pollfd, PSEUDO_POLLFDS + max_cdp);
    errdefer allocator.free(pollfds);

    const cdp_poll_snapshot = try allocator.alloc(?*CdpLink, max_cdp);
    errdefer allocator.free(cdp_poll_snapshot);
    @memset(cdp_poll_snapshot, null);

    @memset(pollfds, .{ .fd = invalid_socket, .events = 0, .revents = 0 });
    pollfds[0] = .{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 };

    const count: usize = config.httpMaxConcurrent();
    const connections = try allocator.alloc(http.Connection, count);
    errdefer allocator.free(connections);

    var available: DoublyLinkedList = .{};
    for (0..count) |i| {
        connections[i] = try http.Connection.init(config);
        available.append(&connections[i].node);
    }

    var cache = Cache.init(allocator);
    errdefer cache.deinit();

    return .{
        .allocator = allocator,
        .wreq_transport_path = wreq_transport_path,
        .config = config,

        .pollfds = pollfds,
        .wakeup_pipe = pipe,
        .cdp_poll_snapshot = cdp_poll_snapshot,
        .cdp_start = PSEUDO_POLLFDS,

        .available = available,
        .connections = connections,

        .app = app,

        .cache = cache,

        .ws_pool = .init(allocator),
        .ws_max = config.wsMaxConcurrent(),
    };
}

pub fn deinit(self: *Network) void {
    for (&self.wakeup_pipe) |*fd| {
        if (fd.* != invalid_socket) {
            closeSocket(fd.*);
            fd.* = invalid_socket;
        }
    }

    self.allocator.free(self.pollfds);
    self.allocator.free(self.cdp_poll_snapshot);

    for (self.connections) |*conn| {
        conn.deinit();
    }
    self.allocator.free(self.connections);

    self.ws_pool.deinit();

    self.cache.deinit();

    if (self.wreq_transport_path) |path| {
        self.allocator.free(path);
        self.wreq_transport_path = null;
    }
}

pub fn bind(
    self: *Network,
    address: *net.Address,
    ctx: *anyopaque,
    on_accept: *const fn (ctx: *anyopaque, socket: posix.socket_t) void,
) !void {
    if (self.listener != null) return error.TooManyListeners;

    self.accept.store(true, .release);

    const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const listener = try posix.socket(address.any.family, flags, posix.IPPROTO.TCP);
    errdefer closeSocket(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(posix.TCP, "NODELAY")) {
        try posix.setsockopt(listener, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    }

    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, self.config.maxPendingConnections());

    // When the caller requests port 0, the OS assigns an ephemeral port; read
    // the actual bound address back so callers (e.g. logging) see the real port.
    var bound: posix.sockaddr.storage = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getsockname(listener, @ptrCast(&bound), &bound_len);
    address.* = net.Address.initPosix(@ptrCast(@alignCast(&bound)));

    self.listener = .{
        .socket = listener,
        .ctx = ctx,
        .onAccept = on_accept,
    };
    self.pollfds[1] = .{
        .fd = listener,
        .events = posix.POLL.IN,
        .revents = 0,
    };
}

pub fn unbind(self: *Network) void {
    self.accept.store(false, .release);
    self.wakeupPoll();
}

// Hand a CDP WebSocket's read side over to the main network thread. The caller
// owns the link and must keep it alive until unregisterCdp is called.
// The caller must not read from the socket.
pub fn registerCdp(self: *Network, link: *CdpLink) void {
    self.cdp_mutex.lock();
    self.cdp_links.append(&link.node);
    self.cdp_dirty = true;
    self.cdp_mutex.unlock();
    self.wakeupPoll();
}

// Synchronous teardown. Blocks the caller until this thread has
// dropped the link from its poll set and won't invoke any of the
// link's callbacks. Safe to call after Network has already dropped
// the link unsolicited (state == .removed) — returns immediately in
// that case.
pub fn unregisterCdp(self: *Network, link: *CdpLink) void {
    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();
    if (link.state == .live) {
        link.state = .unregistering;
        self.cdp_dirty = true;
        self.wakeupPoll();
    }

    while (link.state != .removed) {
        // condition variable, waiting for a signal
        self.cdp_unregister.wait(&self.cdp_mutex);
    }
}

// Drop a link from the poll set. Caller must hold cdp_mutex.
//   - on_disconnect is fired iff `notify` is true. Set notify=false
//     when the consumer already knows the link is dead (e.g. close
//     frame just went through on_bytes; the .close message in the
//     inbox is enough to wake the worker).
//   - The worker transport is woken either way.
fn dropCdp(self: *Network, link: *CdpLink, err: ?anyerror, notify: bool) void {
    self.cdp_links.remove(&link.node);
    link.state = .removed;
    self.cdp_dirty = true;
    if (notify) {
        link.cdp.terminateFromNetwork();

        // notify=true means the worker hasn't been told yet — push the
        // disconnect into the inbox and break it out of the transport poll.
        // notify=false paths have already woken the worker (close frame
        // case) or are about to be unblocked via cdp_unregister.broadcast
        // (unregister case); no extra wakeup needed.
        link.cdp.onLinkDisconnect(err);
        link.handles.wakeup() catch |e| {
            lp.log.warn(.cdp, "CDP link wakeup", .{ .err = e });
        };
    }
}

// Build the CDP portion of pollfds and snapshot the matching *CdpLink
// pointers so we can correlate revents after poll() returns. Called
// before poll, under cdp_mutex.
fn prepareCdpPollFds(self: *Network) void {
    const cdp_start = self.cdp_start;

    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();

    // Idle fast-path: link set unchanged since last rebuild, so the
    // snapshot + pollfds entries from the previous iteration are still
    // correct. Kernel will overwrite `revents` in the next poll() call.
    if (!self.cdp_dirty) {
        return;
    }
    self.cdp_dirty = false;

    @memset(self.pollfds[cdp_start..], .{ .fd = invalid_socket, .events = 0, .revents = 0 });

    var i: usize = 0;
    var it = self.cdp_links.first;
    while (it) |node| : (it = node.next) {
        lp.assert(i < self.cdp_poll_snapshot.len, "CDP poll snapshot overflow", .{ .i = i, .len = self.cdp_poll_snapshot.len });
        const link: *CdpLink = @fieldParentPtr("node", node);
        if (link.state != .live) {
            // Will be handled in processCdpEvents; don't poll its fd.
            continue;
        }

        self.pollfds[cdp_start + i] = .{
            .fd = link.socket,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        self.cdp_poll_snapshot[i] = link;
        i += 1;
    }
    self.cdp_poll_count = i;
}

// Per-iteration CDP handling: process pending unregistrations, then
// process revents on each polled link. Called after poll().
fn processCdpEvents(self: *Network) void {
    var any_removed = false;
    const cdp_start = self.cdp_start;

    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();

    // First pass: pending unregister requests.
    var it = self.cdp_links.first;
    while (it) |node| {
        const next = node.next;
        const link: *CdpLink = @fieldParentPtr("node", node);
        if (link.state == .unregistering) {
            self.dropCdp(link, null, false);
            any_removed = true;
        }
        it = next;
    }

    // Second pass: revents on the snapshot. Skip links the first pass
    // (or a prior natural drop) has already removed.
    for (self.cdp_poll_snapshot[0..self.cdp_poll_count], 0..) |link_opt, i| {
        const link = link_opt orelse continue;
        if (link.state != .live) {
            continue;
        }
        const pfd = self.pollfds[cdp_start + i];
        if (pfd.revents == 0) {
            continue;
        }

        const fatal_events: i16 = comptime @intCast(posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL);
        if (pfd.revents & fatal_events != 0) {
            self.dropCdp(link, null, true);
            any_removed = true;
            continue;
        }

        if (pfd.revents & posix.POLL.IN == 0) {
            continue;
        }

        var buf: [16 * 1024]u8 = undefined;
        const n = posix.recv(link.socket, &buf, 0) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => {
                lp.log.warn(.cdp, "CDP read", .{ .err = err });
                self.dropCdp(link, err, true);
                any_removed = true;
                continue;
            },
        };

        if (n == 0) {
            // peer EOF
            self.dropCdp(link, null, true);
            any_removed = true;
            continue;
        }

        const keep = link.cdp.onData(buf[0..n]) catch |err| {
            // Fatal frame/feed error. Whatever messages on_bytes
            // managed to push are still in the inbox; the failing
            // frame was NOT pushed, and the worker has no way to
            // know it should exit. Drop with notify=true so
            // on_disconnect surfaces a .disconnect into the inbox.
            // dropCdp wakes the worker.
            lp.log.info(.cdp, "CDP onData", .{ .err = err });
            self.dropCdp(link, err, true);
            any_removed = true;
            continue;
        };

        // on_bytes succeeded — wake the worker so it observes anything
        // new in the inbox (data / ping / close).
        link.handles.wakeup() catch |err| {
            lp.log.warn(.cdp, "CDP link wakeup", .{ .err = err });
        };

        if (!keep) {
            // Close frame: the handler already pushed .close. Worker's
            // drainInbox will call on_disconnect itself after replying,
            // so we drop without re-notifying.
            self.dropCdp(link, null, false);
            any_removed = true;
        }
    }

    if (any_removed) {
        self.cdp_unregister.broadcast();
    }
}

// On shutdown, force-disconnect every still-live CDP link. Each link's
// worker thread blocks in a transport poll and is woken ONLY by this
// (Network) thread via dropCdp -> handles.wakeup(). If the run loop
// exits with links still live, those workers never wake and
// Server.deinit() spins on active_threads forever (issue #2510).
// Mirrors the peer-EOF path in processCdpEvents: dropCdp(notify=true)
// pushes a .disconnect into the worker's inbox and wakes it, so
// cdp.tick() returns false and the worker exits.
fn shutdownCdpLinks(self: *Network) void {
    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();

    var it = self.cdp_links.first;
    while (it) |node| {
        it = node.next;
        const link: *CdpLink = @fieldParentPtr("node", node);
        if (link.state == .live) {
            self.dropCdp(link, null, true);
        }
    }

    self.cdp_unregister.broadcast();
}

pub fn run(self: *Network) void {
    var drain_buf: [64]u8 = undefined;

    const poll_fd = &self.pollfds[0];
    const listen_fd = &self.pollfds[1];

    // Receiving a shutdown command does not terminate existing connections: we
    // stop accepting new ones but leave in-flight requests to external code to
    // terminate. This loop only services the listener and the CDP read sockets;
    // page fetches run on per-worker HttpClient multis
    // thread, so nothing here drives page HTTP requests.
    while (true) {
        if (self.listener != null and !self.accept.load(.acquire)) {
            closeSocket(self.listener.?.socket);
            self.listener = null;
            self.pollfds[1] = .{ .fd = invalid_socket, .events = 0, .revents = 0 };
        }

        self.prepareCdpPollFds();

        // wait until we get a CDP message or a signal on the wakeup pipe
        _ = posix.poll(self.pollfds, -1) catch |err| {
            lp.log.err(.app, "poll", .{ .err = err });
            continue;
        };

        // check wakeup pipe
        if (poll_fd.revents != 0) {
            poll_fd.revents = 0;
            while (true)
                _ = readWakeup(self.wakeup_pipe[0], &drain_buf) catch break;
        }

        // accept new connections
        if (listen_fd.revents != 0) {
            listen_fd.revents = 0;
            self.acceptConnections();
        }

        self.processCdpEvents();

        if (self.shutdown.load(.acquire)) {
            // Drain any live CDP links so their workers can exit (issue #2510),
            // then stop. Page fetches don't run on this loop, so
            // there is nothing else to flush here.
            self.shutdownCdpLinks();
            break;
        }
    }

    if (self.listener) |listener| {
        posix.shutdown(listener.socket, .both) catch |err| blk: {
            if (err == error.SocketNotConnected and builtin.os.tag != .linux) {
                // This error is normal/expected on BSD/MacOS. We probably
                // shouldn't bother calling shutdown at all, but I guess this
                // is safer.
                break :blk;
            }
            lp.log.warn(.app, "listener shutdown", .{ .err = err });
        };
        closeSocket(listener.socket);
    }
}

fn wakeupPoll(self: *Network) void {
    _ = writeWakeup(self.wakeup_pipe[1], &.{1}) catch {};
}

pub fn stop(self: *Network) void {
    self.shutdown.store(true, .release);
    self.wakeupPoll();
}

fn acceptConnections(self: *Network) void {
    if (self.shutdown.load(.acquire)) {
        return;
    }
    const listener = self.listener orelse return;

    while (true) {
        const socket = posix.accept(listener.socket, null, null, posix.SOCK.NONBLOCK) catch |err| {
            switch (err) {
                error.WouldBlock => break,
                error.SocketNotListening => {
                    self.pollfds[1] = .{ .fd = invalid_socket, .events = 0, .revents = 0 };
                    self.listener = null;
                    return;
                },
                error.ConnectionAborted => {
                    lp.log.warn(.app, "accept connection aborted", .{});
                    continue;
                },
                else => {
                    lp.log.err(.app, "accept error", .{ .err = err });
                    continue;
                },
            }
        };

        listener.onAccept(listener.ctx, socket);
    }
}

pub fn getConnection(self: *Network) ?*http.Connection {
    self.conn_mutex.lock();
    defer self.conn_mutex.unlock();

    const node = self.available.popFirst() orelse return null;
    return @fieldParentPtr("node", node);
}

pub fn releaseConnection(self: *Network, conn: *http.Connection) void {
    switch (conn.transport) {
        .websocket => {
            conn.deinit();
            self.ws_mutex.lock();
            defer self.ws_mutex.unlock();
            self.ws_pool.destroy(conn);
            self.ws_count -= 1;
        },
        else => {
            conn.reset(self.config) catch |err| {
                lp.assert(false, "couldn't reset HTTP connection", .{ .err = err });
            };
            self.conn_mutex.lock();
            defer self.conn_mutex.unlock();
            self.available.append(&conn.node);
        },
    }
}

pub fn newConnection(self: *Network) ?*http.Connection {
    const conn = blk: {
        self.ws_mutex.lock();
        defer self.ws_mutex.unlock();

        if (self.ws_count >= self.ws_max) {
            return null;
        }

        const c = self.ws_pool.create() catch return null;
        self.ws_count += 1;
        break :blk c;
    };

    // don't do this under lock
    conn.* = http.Connection.init(self.config) catch {
        self.ws_mutex.lock();
        defer self.ws_mutex.unlock();
        self.ws_pool.destroy(conn);
        self.ws_count -= 1;

        return null;
    };

    return conn;
}
