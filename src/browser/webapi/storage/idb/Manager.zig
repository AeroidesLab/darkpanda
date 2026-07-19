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

const Engine = @import("Engine.zig");

const Allocator = std.mem.Allocator;

const Manager = @This();

allocator: Allocator,
// Engines are never removed while a Session is live. The mutex therefore only
// protects publication/lookup and the head snapshot; Engine callbacks are
// always made after it is released so author script can re-enter IDB without
// deadlocking the origin map. Existing `Engine._manager_next` links are
// immutable after publication, so a captured head can be traversed lock-free.
engines_mutex: std.Thread.Mutex = .{},
engines: std.StringHashMapUnmanaged(*Engine) = .empty,
engines_head: ?*Engine = null,

pub fn init(allocator: Allocator) Manager {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Manager) void {
    var it = self.engines.iterator();
    while (it.next()) |kv| {
        kv.value_ptr.*.close();
        self.allocator.destroy(kv.value_ptr.*);
        self.allocator.free(kv.key_ptr.*);
    }
    self.engines.deinit(self.allocator);
    self.engines_head = null;
}

// A js Context is being torn down (navigation, popup close, worker close):
// every engine must drop any gate participant whose callbacks would run in it.
// Must be called before that context's scheduler is reset or deinit'd.
pub fn detachContext(self: *Manager, ctx: *anyopaque) void {
    self.engines_mutex.lock();
    var engine = self.engines_head;
    self.engines_mutex.unlock();

    while (engine) |current| {
        // Capture before detach: callbacks may re-enter Manager and publish a
        // new head, but links which were already published never change.
        const next = current._manager_next;
        current.detach(ctx);
        engine = next;
    }
}

// Backend/bucket teardown for an origin whose JavaScript contexts remain
// alive (for example Storage.clearDataForOrigin or a backing-store failure).
// This deliberately only closes renderer connections; data deletion/reopen is
// owned by the backend operation which calls this seam.
pub fn forceCloseOrigin(self: *Manager, origin: []const u8) usize {
    return self.forceCloseOriginWithReason(origin, "Force close delete origin");
}

// Chromium threads the backend's diagnostic reason through Connection and the
// active transaction's UnknownError. Keep the generic seam available for a
// backing-store failure while forceCloseOrigin models storage data deletion.
pub fn forceCloseOriginWithReason(self: *Manager, origin: []const u8, reason: []const u8) usize {
    self.engines_mutex.lock();
    const engine = self.engines.get(origin);
    self.engines_mutex.unlock();
    const found = engine orelse return 0;

    var delivered: usize = 0;
    // Match Database::ForceCloseConnectionsAndCancelRequests: first close
    // established frontend connections (which may synchronously abort their
    // transactions), then cancel every in-flight open/delete operation in the
    // per-database connection coordinators. The latter includes an upgrade
    // request whose IDBDatabase has not been registered as a live connection.
    delivered += found.forceCloseAllConnections(reason);
    delivered += found.forceCloseAllConnectionChanges(reason);
    return delivered;
}

// Gets or creates the engine for the given origin.
pub fn engineForOrigin(self: *Manager, origin: []const u8) !*Engine {
    self.engines_mutex.lock();
    defer self.engines_mutex.unlock();

    const gop = try self.engines.getOrPut(self.allocator, origin);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }
    errdefer _ = self.engines.remove(origin);

    const engine = try self.allocator.create(Engine);
    errdefer self.allocator.destroy(engine);

    engine.* = try Engine.open(":memory:");
    errdefer engine.close();

    gop.key_ptr.* = try self.allocator.dupe(u8, origin);
    gop.value_ptr.* = engine;
    engine._manager_next = self.engines_head;
    self.engines_head = engine;
    return engine;
}

const testing = @import("../../../../testing.zig");
test "IDB - Manager: same origin returns same engine, distinct origins differ" {
    var mgr = Manager.init(testing.allocator);
    defer mgr.deinit();

    const a1 = try mgr.engineForOrigin("https://a.com");
    const a2 = try mgr.engineForOrigin("https://a.com");
    const b1 = try mgr.engineForOrigin("https://b.com");

    try testing.expect(a1 == a2);
    try testing.expect(a1 != b1);
}

test "IDB - Manager: context detach visits every published engine without a snapshot allocation" {
    var mgr = Manager.init(testing.allocator);
    defer mgr.deinit();

    const TestConnection = struct {
        connection: Engine.Connection,
        detached_count: *usize,

        fn init(ctx: *anyopaque, detached_count: *usize) @This() {
            return .{
                .connection = .{
                    .database_id = 1,
                    .ctx = ctx,
                    .version_change = versionChange,
                    .context_detached = contextDetached,
                },
                .detached_count = detached_count,
            };
        }

        fn versionChange(_: *Engine.Connection, _: u64, _: ?u64) bool {
            return false;
        }

        fn contextDetached(connection: *Engine.Connection) void {
            const self: *@This() = @fieldParentPtr("connection", connection);
            self.detached_count.* += 1;
            _ = connection.engine.?.unregisterConnection(connection);
        }
    };

    const a = try mgr.engineForOrigin("https://a.com");
    const b = try mgr.engineForOrigin("https://b.com");
    var context_marker: u8 = 0;
    var detached_count: usize = 0;
    var a_connection = TestConnection.init(&context_marker, &detached_count);
    var b_connection = TestConnection.init(&context_marker, &detached_count);
    a.registerConnection(&a_connection.connection);
    b.registerConnection(&b_connection.connection);

    mgr.detachContext(&context_marker);

    try testing.expectEqual(2, detached_count);
    try testing.expect(!a.hasConnections(1));
    try testing.expect(!b.hasConnections(1));
}

test "IDB - Manager: in-memory engines are origin-isolated" {
    var mgr = Manager.init(testing.allocator);
    defer mgr.deinit();

    const a = try mgr.engineForOrigin("https://a.com");
    const b = try mgr.engineForOrigin("https://b.com");

    _ = try a.upsertDatabase("db", 1);
    try testing.expectEqual(null, try b.databaseVersion("db"));
}

test "IDB - Manager: on-disk engines hash to per-origin files, isolated" {
    var mgr = Manager.init(testing.allocator);
    defer mgr.deinit();

    // A long origin (hostname near the 253-byte limit) must still open: the
    // hashed file name stays well under NAME_MAX where a transcribed one would
    // not.
    const long_host = "https://" ++ ("a" ** 250) ++ ".com";
    const a = try mgr.engineForOrigin(long_host);
    _ = try a.upsertDatabase("db", 7);

    const b = try mgr.engineForOrigin("https://b.com");
    try testing.expectEqual(null, try b.databaseVersion("db"));
    try testing.expectEqual(7, (try a.databaseVersion("db")).?);
}
