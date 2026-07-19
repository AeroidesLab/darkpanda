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
const Sqlite = @import("Sqlite.zig");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const Pool = @This();

available: usize,
mutex: Thread.Mutex,
cond: Thread.Condition,
conns: []Sqlite.Conn,

pub fn init(allocator: Allocator, path: [:0]const u8) !Pool {
    // can't have a pool of connections to in-memory database, so, to keep the
    // API simple, we create a pool of 1.
    const count: usize = if (std.mem.eql(u8, path, ":memory:")) 1 else 5;

    var conns = try allocator.alloc(Sqlite.Conn, count);
    errdefer allocator.free(conns);

    var initialized: usize = 0;
    errdefer {
        for (0..initialized) |i| {
            conns[i].close();
        }
    }

    for (0..count) |i| {
        conns[i] = try Sqlite.Conn.open(path);
        initialized += 1;
        try conns[i].busyTimeout(1000);
    }

    return .{
        .cond = .{},
        .mutex = .{},
        .conns = conns,
        .available = count,
    };
}

pub fn deinit(self: *Pool, allocator: Allocator) void {
    for (self.conns) |conn| {
        conn.close();
    }
    allocator.free(self.conns);
}

pub fn acquire(self: *Pool) !Sqlite.Conn {
    const conns = self.conns;

    self.mutex.lock();
    defer self.mutex.unlock();
    while (true) {
        const available = self.available;
        if (available == 0) {
            try self.cond.timedWait(&self.mutex, 5 * std.time.ns_per_s);
            continue;
        }
        const index = available - 1;
        const conn = conns[index];
        self.available = index;
        return conn;
    }
}

pub fn release(self: *Pool, conn: Sqlite.Conn) void {
    var conns = self.conns;

    self.mutex.lock();
    const available = self.available;
    conns[available] = conn;
    self.available = available + 1;
    self.mutex.unlock();
    self.cond.signal();
}

const testing = @import("../../testing.zig");
test "Sqlite: Pool" {
    // :memory: _has_ to run with a single connection in the pool, which isn't
    // that useful for testing. So we create a temp file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const db_path = try std.fs.path.joinZ(
        testing.allocator,
        &.{ root, "darkpanda_test.sqlite" },
    );
    defer testing.allocator.free(db_path);

    var pool = try Pool.init(testing.allocator, db_path);
    defer pool.deinit(testing.allocator);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec("create table pool_test (cnt int not null)", .{});
        try conn.exec("insert into pool_test (cnt) values (0)", .{});
    }

    for (pool.conns) |conn| {
        // This is not safe and can result in corruption. This is only set
        // because the tests might be run on really slow hardware and we
        // want to avoid having a busy timeout.
        try conn.exec("pragma synchronous=off", .{});

        // Also not safe, but we're trying to avoid busy timeouts without using
        // WAL mode, which can trigger false positives in thread-sanitizer
        try conn.exec("pragma journal_mode=memory", .{});
    }

    var workers = [_]PoolTestWorker{.{}} ** 6;
    var threads: [workers.len]Thread = undefined;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();
    for (&threads, &workers) |*thread, *worker| {
        thread.* = try Thread.spawn(.{}, testPool, .{ &pool, worker });
        spawned += 1;
    }
    for (threads) |thread| thread.join();
    spawned = 0;

    for (workers) |worker| {
        if (worker.err) |err| return err;
        try testing.expectEqual(100, worker.completed);
        try testing.expect(worker.retries <= PoolTestWorker.busy_retry_budget);
    }
    try testing.expectEqual(pool.conns.len, pool.available);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        const cnt = blk: {
            const row = (try conn.row("select cnt from pool_test", .{})).?;
            defer row.deinit();
            break :blk row.get(i64, 0);
        };
        try testing.expectEqual(600, cnt);
        try conn.exec("drop table pool_test", .{});
    }
    try testing.expectEqual(pool.conns.len, pool.available);
}

const PoolTestWorker = struct {
    const busy_retry_budget = 16;

    completed: usize = 0,
    retries: usize = 0,
    err: ?anyerror = null,
};

fn testPool(p: *Pool, worker: *PoolTestWorker) void {
    for (0..100) |_| {
        while (true) {
            incrementPoolCounter(p) catch |err| switch (err) {
                // A pool permits concurrent connections; it does not remove
                // SQLite's single-writer lock. Retrying the whole transaction
                // is the correct caller behavior after a bounded busy wait.
                error.Busy,
                error.BusyRecovery,
                error.BusySnapshot,
                error.BusyTimeout,
                => {
                    if (worker.retries >= PoolTestWorker.busy_retry_budget) {
                        worker.err = error.BusyRetryBudgetExhausted;
                        return;
                    }
                    worker.retries += 1;
                    std.Thread.sleep(2 * std.time.ns_per_ms);
                    continue;
                },
                else => {
                    worker.err = err;
                    return;
                },
            };
            worker.completed += 1;
            break;
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
}

fn incrementPoolCounter(p: *Pool) !void {
    const conn = try p.acquire();
    defer p.release(conn);

    try conn.exec("begin immediate", .{});
    conn.exec("update pool_test set cnt = cnt + 1", .{}) catch |err| {
        conn.exec("rollback", .{}) catch |rollback_err| return rollback_err;
        return err;
    };
    conn.exec("commit", .{}) catch |err| {
        conn.exec("rollback", .{}) catch |rollback_err| return rollback_err;
        return err;
    };
}
