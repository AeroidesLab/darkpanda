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

const js = @import("../../../js/js.zig");

const Key = @import("Key.zig");
const Engine = @import("Engine.zig");
const IDBRequest = @import("IDBRequest.zig");
const IDBOpenDBRequest = @import("IDBOpenDBRequest.zig");
const IDBDatabase = @import("IDBDatabase.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const DOMException = @import("../../DOMException.zig");

const log = lp.log;
const Execution = js.Execution;
const WebIDL = js.WebIDL;

const IDBFactory = @This();

// IDBFactory is stateful: its owner determines both the backing store and the
// detached-context lifetime gate. It must therefore always be carried by the
// wrapper's TaggedOpaque instead of being synthesized as an empty value.
_exec: *Execution,
// Immutable storage partition selected by the factory owner's environment
// settings object. `null` records an opaque owner: the factory (and cmp()) is
// still exposed, but operations which reach the database backend are denied.
// Every asynchronous operation copies this slice into its own Context so a
// later URL/origin mutation can never redirect an in-flight request.
_storage_origin_key: ?[]const u8,

pub fn init(exec: *Execution, storage_origin_key: ?[]const u8) !IDBFactory {
    return .{
        ._exec = exec,
        ._storage_origin_key = if (storage_origin_key) |key|
            try exec.dupeString(key)
        else
            null,
    };
}

const max_safe_integer: f64 = 9_007_199_254_740_991.0;

fn throwWebIDLTypeError(exec: *Execution, operation: []const u8, reason: []const u8) anyerror {
    return WebIDL.typeError(exec, .{ .interface = "IDBFactory", .name = operation }, reason);
}

fn throwDatabaseAccessDenied(exec: *Execution, comptime operation: []const u8) anyerror {
    const local = exec.js.local.?;
    const message = "Failed to execute '" ++ operation ++ "' on 'IDBFactory': access to the Indexed Database API is denied in this context.";
    const exception = try local.zigValueToJs(DOMException.init(message, "SecurityError"), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

fn throwCmpDataError(exec: *Execution) anyerror {
    const local = exec.js.local.?;
    const message = "Failed to execute 'cmp' on 'IDBFactory': The parameter is not a valid key.";
    const exception = try local.zigValueToJs(DOMException.init(message, "DataError"), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

fn convertName(raw: ?js.Value, exec: *Execution, operation: []const u8) ![]const u8 {
    const value = raw orelse return throwWebIDLTypeError(
        exec,
        operation,
        "1 argument required, but only 0 present.",
    );
    return WebIDL.toDOMString(
        value,
        exec,
        .{ .interface = "IDBFactory", .name = operation },
    );
}

fn convertVersion(raw: ?js.Value, exec: *Execution) !?u64 {
    const value = raw orelse return null;
    // Web IDL treats explicit undefined like an omitted optional argument.
    if (value.isUndefined()) return null;
    const number = try WebIDL.toNumber(
        value,
        exec,
        .{ .interface = "IDBFactory", .name = "open" },
    );
    if (!std.math.isFinite(number)) {
        return throwWebIDLTypeError(
            exec,
            "open",
            if (std.math.isInf(number))
                "Value is infinite and not of type 'unsigned long long'."
            else
                "Value is not of type 'unsigned long long'.",
        );
    }

    const truncated = @trunc(number);
    if (truncated < 0 or truncated > max_safe_integer) {
        return throwWebIDLTypeError(
            exec,
            "open",
            "Value is outside the 'unsigned long long' value range.",
        );
    }

    const version: u64 = @intFromFloat(truncated);
    if (version == 0) {
        return throwWebIDLTypeError(
            exec,
            "open",
            "The version provided must not be 0.",
        );
    }
    return version;
}

pub fn open(self: *IDBFactory, name_value: ?js.Value, version_value: ?js.Value, caller_exec: *Execution) !?*IDBOpenDBRequest {
    // Web IDL conversions run before Blink enters IDBFactory::OpenInternal and
    // discovers that the ExecutionContext was destroyed.
    const name = try convertName(name_value, caller_exec, "open");
    const version = try convertVersion(version_value, caller_exec);

    const exec = self._exec;
    if (exec.isShuttingDown()) return null;

    const storage_origin_key = self._storage_origin_key orelse {
        return throwDatabaseAccessDenied(caller_exec, "open");
    };

    const public_request = try IDBOpenDBRequest.init(exec);
    const request = public_request.asRequest();

    const ctx = try exec._factory.create(OpenContext{
        .open_request = public_request,
        .request = request,
        .name = try exec.dupeString(name),
        .version = version,
        .exec = exec,
        .storage_origin_key = storage_origin_key,
        ._gate_waiter = .{ .ctx = exec.js, .wake = OpenContext.wakeUp, .cancel = OpenContext.cancelParked },
        ._connection_change_waiter = .{
            .ctx = exec.js,
            .wake = OpenContext.wakeConnectionChange,
            .cancel = OpenContext.cancelConnectionChange,
            .force_close = OpenContext.forceCloseConnectionChange,
        },
    });

    try exec.js.scheduler.add(ctx, OpenContext.run, 0, .{
        .name = "IDBFactory.open",
        .finalizer = OpenContext.cancelled,
    });
    return public_request;
}

const OpenContext = struct {
    open_request: *IDBOpenDBRequest,
    request: *IDBRequest,
    name: []const u8,
    version: ?u64,
    exec: *Execution,
    // Exact factory partition snapshot. Never recompute this from `exec` at a
    // scheduler wake: the owner can mutate its effective scripting origin in
    // between the Web IDL call and backend dispatch.
    storage_origin_key: []const u8,
    // Our node in the engine's connection gate wait-list. See Engine.acquireGate.
    _gate_waiter: Engine.GateWaiter,
    // Per-database FIFO ownership for open/delete schema operations. This is
    // retained while waiting for old connections, but does not block their
    // normal transactions from acquiring `_gate_waiter`'s sqlite gate.
    _connection_change_waiter: Engine.ConnectionChangeWaiter,
    // Whether a scheduler task currently points at us; its finalizer owns our
    // destruction then. When parked on the gate instead, cancelParked owns it.
    _scheduled: bool = true,
    _connection_change_sent: bool = false,
    _version_change_ignored: bool = false,
    _blocked_fired: bool = false,
    _backend_force_closed: bool = false,

    // If an callback queued more requests, we need to process those requests
    // on the next tick, and thus need to hold onto the transaction (which pins
    // that transaction (_rc++) so that it does't get cleaned up from under us).
    _upgrade: ?*IDBTransaction = null,

    fn cancelled(ctx: *anyopaque) void {
        // What if we're gated? Well, A scheduled task is only canceled on
        // teardown, which would have already called Engine.detach(js_ctx).
        const self: *OpenContext = @ptrCast(@alignCast(ctx));
        var engine: ?*Engine = null;
        if (self._upgrade) |txn| {
            engine = txn._engine;
            txn.cancelForContextDetach();
            self.request._txn = .none;
            txn._db._txn = null;
            _ = txn._engine.releaseGate(&self._gate_waiter);
            txn.releaseRef(self.exec.page);
        } else if (self._gate_waiter.state == .owner) {
            // Backstop for a scheduler stop which was not preceded by the
            // normal Engine.detach context unlink.
            if (self.resolveEngine()) |resolved| {
                engine = resolved;
                _ = resolved.releaseGate(&self._gate_waiter);
            } else |_| {}
        }
        if (engine == null and self._connection_change_waiter.state == .owner) {
            engine = self.resolveEngine() catch null;
        }
        if (engine) |resolved| {
            _ = resolved.releaseConnectionChange(&self._connection_change_waiter);
        }
        self.exec._factory.destroy(self);
    }

    // Engine.detach cancel: our context is going away while we sit on the
    // gate. When parked there's no scheduler task, so we own our destruction;
    // in the wake->run window the task finalizer does.
    fn cancelParked(waiter: *Engine.GateWaiter) void {
        const self: *OpenContext = @fieldParentPtr("_gate_waiter", waiter);
        self.cancelUpgradeForDetach();
        self.destroyDetachedIfIdle();
    }

    fn cancelConnectionChange(waiter: *Engine.ConnectionChangeWaiter) void {
        const self: *OpenContext = @fieldParentPtr("_connection_change_waiter", waiter);
        self.cancelUpgradeForDetach();
        self.destroyDetachedIfIdle();
    }

    fn forceCloseConnectionChange(waiter: *Engine.ConnectionChangeWaiter, reason: []const u8) void {
        const self: *OpenContext = @fieldParentPtr("_connection_change_waiter", waiter);
        if (self._backend_force_closed) return;
        self._backend_force_closed = true;

        // During the async drain phase this database is already public to the
        // upgradeneeded handler but is intentionally not yet an Engine.Connection.
        // Abort the versionchange transaction and make the handle close-pending;
        // unlike a successful connection, Chrome does not dispatch `close` for
        // this pre-success database object.
        if (self._upgrade) |txn| {
            txn._db.close();
            txn.forceAbortFromBackend(reason);
        }
    }

    fn cancelUpgradeForDetach(self: *OpenContext) void {
        if (self._upgrade) |txn| {
            txn.cancelForContextDetach();
        } else switch (self.request._txn) {
            // During the synchronous upgradeneeded dispatch, OpenContext has
            // not yet moved the transaction into `_upgrade`.
            .borrowed => |txn| txn.cancelForContextDetach(),
            .none, .owned => {},
        }
    }

    fn destroyDetachedIfIdle(self: *OpenContext) void {
        // A context may be parked on the sqlite gate while it owns the separate
        // connection-change coordinator. Engine.detach removes both nodes and
        // calls both callbacks; only the callback which observes both idle is
        // allowed to destroy the shared context.
        if (!self._scheduled and
            !self._gate_waiter.running and
            !self._connection_change_waiter.running and
            self._gate_waiter.state == .idle and
            self._connection_change_waiter.state == .idle)
        {
            self.exec._factory.destroy(self);
        }
    }

    fn stopRunning(self: *OpenContext) void {
        self._gate_waiter.running = false;
        self._connection_change_waiter.running = false;
    }

    fn isDetached(self: *const OpenContext) bool {
        return self._gate_waiter.detached or self._connection_change_waiter.detached;
    }

    fn releaseAndDestroy(self: *OpenContext, engine: *Engine) void {
        self.stopRunning();
        _ = engine.releaseGate(&self._gate_waiter);
        _ = engine.releaseConnectionChange(&self._connection_change_waiter);
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *OpenContext = @ptrCast(@alignCast(ctx));
        self._scheduled = false;
        self._gate_waiter.running = true;
        self._connection_change_waiter.running = true;

        if (self._upgrade != null) {
            return self.drainUpgrade();
        }

        const engine = self.resolveEngine() catch |err| {
            if (!self.exec.isShuttingDown()) {
                self.request.setError(err);
                self.request.deliver(self.exec) catch {};
            }
            self.stopRunning();
            self.exec._factory.destroy(self);
            return null;
        };

        if (self._backend_force_closed) {
            if (!self.exec.isShuttingDown()) {
                self.request.setConnectionClosedError();
                self.request.deliver(self.exec) catch {};
            }
            self.releaseAndDestroy(engine);
            return null;
        }

        if (!engine.acquireConnectionChange(&self._connection_change_waiter, self.name)) {
            self.stopRunning();
            return null;
        }

        // Connection notifications precede lock/gate acquisition in Chromium.
        // Always yield once after the first versionchange dispatch: the event
        // listener's microtask checkpoint may close every connection, in which
        // case the request must proceed without a spurious blocked event.
        const yield_for_connection_microtasks = self.prepareConnectionChange(engine) catch |err| {
            log.warn(.storage, "idb open connection coordination", .{ .err = err, .name = self.name });
            if (!self.exec.isShuttingDown()) {
                self.request.setError(err);
                self.request.deliver(self.exec) catch {};
            }
            self.releaseAndDestroy(engine);
            return null;
        };
        if (yield_for_connection_microtasks) {
            if (self.isDetached()) {
                self.releaseAndDestroy(engine);
                return null;
            }
            self._scheduled = true;
            self.stopRunning();
            return 1;
        }

        // An open that upgrades runs a versionchange transaction on the shared
        // connection, so it must serialize with other transactions/opens. Park
        // on the gate if it's held; wakeUp re-runs us when it's handed over.
        if (!engine.acquireGate(&self._gate_waiter)) {
            self.stopRunning();
            return null; // parked; not destroyed
        }

        const step = self.runOpen(engine) catch |err| blk: {
            log.warn(.storage, "idb open", .{ .err = err, .name = self.name, .sqlite = engine.lastError() });
            if (!self.exec.isShuttingDown()) {
                self.request.setError(err);
                self.request.deliver(self.exec) catch {};
            }
            break :blk OpenStep.complete;
        };
        switch (step) {
            .upgrade_draining => {
                if (self.isDetached()) {
                    self.releaseAndDestroy(engine);
                    return null;
                }
                self._scheduled = true;
                self.stopRunning();
                // Keep both the sqlite-operation gate and this context until
                // the versionchange transaction drains or every old
                // connection closes. Polling is a scheduler task boundary, so
                // author timers that call close() can make progress.
                return 1;
            },
            .waiting_connections => {
                // This is only a defensive race backstop: connection waiting
                // normally happens in prepareConnectionChange(), before gate
                // acquisition. Never retain the sqlite gate while waiting for
                // an old connection's active transaction to finish.
                self.stopRunning();
                _ = engine.releaseGate(&self._gate_waiter);
                if (self.isDetached()) {
                    _ = engine.releaseConnectionChange(&self._connection_change_waiter);
                    self.exec._factory.destroy(self);
                    return null;
                }
                self._scheduled = true;
                return 1;
            },
            .complete => {},
        }

        self.releaseAndDestroy(engine);
        return null;
    }

    // One turn of the versionchange drain: deliver a batch of request events;
    // handlers may enqueue more. Once the transaction settles — the queue
    // stayed empty (committed, `complete` fired) or a handler aborted —
    // deliver the open request's outcome and clean up.
    fn drainUpgrade(self: *OpenContext) !?u32 {
        const txn = self._upgrade.?;
        if (txn.settleStep(self.exec)) {
            self._scheduled = true;
            self.stopRunning();
            return 1;
        }

        self._upgrade = null;
        const engine = txn._engine;
        defer self.exec._factory.destroy(self);
        defer _ = engine.releaseConnectionChange(&self._connection_change_waiter);
        defer _ = engine.releaseGate(&self._gate_waiter);
        if (self.isDetached()) {
            self.disconnectUpgrade(txn);
            self.stopRunning();
            return null;
        }
        try self.finishUpgrade(txn);
        self.stopRunning();
        return null;
    }

    // Sever the public request/database view and release OpenContext's pin
    // without dispatching success/error into a retired realm.
    fn disconnectUpgrade(self: *OpenContext, txn: *IDBTransaction) void {
        self.request._txn = .none;
        txn._db._txn = null;
        txn.releaseRef(self.exec.page);
    }

    // The versionchange transaction settled (committed or aborted): sever the
    // upgrade wiring, drop our pin (may free the transaction), and deliver the
    // open request's outcome.
    fn finishUpgrade(self: *OpenContext, txn: *IDBTransaction) !void {
        const exec = self.exec;
        const aborted = txn.aborted();
        const db = txn._db;
        self.request._txn = .none;
        db._txn = null;
        txn.releaseRef(exec.page);

        if (aborted) {
            if (self._backend_force_closed) {
                self.request.setConnectionClosedError();
            } else {
                self.request.setError(error.AbortError);
            }
            return self.request.deliver(exec);
        }
        if (!db.activateConnection()) {
            // close() during upgradeneeded makes the eventual open success an
            // AbortError (Blink checks close-pending before dispatching it).
            self.request.setError(error.AbortError);
            return self.request.deliver(exec);
        }
        return self.request.fireSuccess(exec);
    }

    // Scheduler wake-up: the connection gate was handed to us, so re-run.
    fn wakeUp(waiter: *Engine.GateWaiter) void {
        const self: *OpenContext = @fieldParentPtr("_gate_waiter", waiter);
        // Scheduler.add() finalizes synchronously when the owning context has
        // already stopped. Publish task ownership before calling it so the
        // finalizer cannot free `self` and leave the write below as a UAF.
        self._scheduled = true;
        self.exec.js.scheduler.add(self, run, 0, .{
            .name = "IDBFactory.open",
            .finalizer = cancelled,
        }) catch |err| {
            // We were handed the gate; if we can't reschedule, hand it off so the
            // waiters behind us aren't stranded.
            log.warn(.storage, "idb resume open", .{ .err = err });
            if (self.resolveEngine()) |engine| {
                _ = engine.releaseGate(&self._gate_waiter);
                _ = engine.releaseConnectionChange(&self._connection_change_waiter);
            } else |_| {}
            self.exec._factory.destroy(self);
        };
    }

    fn wakeConnectionChange(waiter: *Engine.ConnectionChangeWaiter) void {
        const self: *OpenContext = @fieldParentPtr("_connection_change_waiter", waiter);
        self._scheduled = true;
        self.exec.js.scheduler.add(self, run, 0, .{
            .name = "IDBFactory.open.connectionChange",
            .finalizer = cancelled,
        }) catch |err| {
            log.warn(.storage, "idb resume coordinated open", .{ .err = err });
            if (self.resolveEngine()) |engine| {
                _ = engine.releaseConnectionChange(&self._connection_change_waiter);
            } else |_| {}
            self.exec._factory.destroy(self);
        };
    }

    fn resolveEngine(self: *OpenContext) !*Engine {
        return self.exec.session.idb.engineForOrigin(self.storage_origin_key);
    }

    const OpenStep = enum { complete, waiting_connections, upgrade_draining };

    fn prepareConnectionChange(
        self: *OpenContext,
        engine: *Engine,
    ) !bool {
        const existing = (try engine.databaseVersion(self.name)) orelse return false;
        const requested: i64 = if (self.version) |version| @intCast(version) else existing;
        if (requested <= existing) return false;

        const database_id = (try engine.databaseId(self.name)).?;
        if (!self._connection_change_sent) {
            self._connection_change_sent = true;
            if (!engine.hasConnections(database_id)) return false;
            self._version_change_ignored = engine.notifyVersionChange(
                database_id,
                @intCast(existing),
                @intCast(requested),
            );
            return true;
        }

        const still_connected = engine.hasConnections(database_id);
        if (still_connected or self._version_change_ignored) {
            if (!self._blocked_fired and !self.exec.isShuttingDown()) {
                self._blocked_fired = true;
                try self.open_request.fireBlocked(
                    self.exec,
                    @intCast(existing),
                    @intCast(requested),
                );
            }
            // The blocked handler may synchronously close the final
            // connection. Otherwise stay entirely outside the sqlite gate so
            // close-pending connections can drain their transactions.
            return engine.hasConnections(database_id);
        }
        return false;
    }

    // Returns the next coordination stage. A version upgrade does not touch
    // sqlite metadata until all existing IDBDatabase connections have had
    // their versionchange opportunity and closed.
    fn runOpen(self: *OpenContext, engine: *Engine) !OpenStep {
        const exec = self.exec;
        const existing = try engine.databaseVersion(self.name);

        // No explicit version means "open at the current version" (or 1 for a
        // brand-new database).
        const requested: i64 = if (self.version) |v| @intCast(v) else existing orelse 1;

        if (existing) |current| {
            if (requested < current) {
                self.request.setError(error.VersionError);
                self.request.deliver(exec) catch {};
                return .complete;
            }

            if (requested == current) {
                const database_id = (try engine.databaseId(self.name)).?;
                const db = try IDBDatabase.init(exec, engine, database_id, self.name, current);
                _ = db.activateConnection();
                self.request.setDatabaseResult(db);
                try self.request.fireSuccess(exec);
                return .complete;
            }

            const database_id = (try engine.databaseId(self.name)).?;
            if (engine.hasConnections(database_id)) return .waiting_connections;
        }

        // New database or an upgrade to a higher version. Run a versionchange
        // transaction so user JS can evolve the schema during `upgradeneeded`;
        // it's exposed as `request.transaction` and committed once its request
        // queue stays empty.
        try engine.begin();

        var closed = false;
        errdefer if (closed == false) {
            engine.rollback();
        };

        const database_id = try engine.upsertDatabase(self.name, requested);
        const db = try IDBDatabase.init(exec, engine, database_id, self.name, requested);
        self.request.setDatabaseResult(db);

        const txn = try IDBTransaction.initVersionChange(db, exec);
        txn.acquireRef();

        {
            // The wiring below outlives this call on the drain path; on an
            // error it must be severed here, with our pin.
            errdefer {
                self.request._txn = .none;
                db._txn = null;
                txn.releaseRef(exec.page);
            }
            self.request._txn = .{ .borrowed = txn };
            db._txn = txn;
            const old_version: u64 = @intCast(existing orelse 0);
            try self.request.fireUpgradeNeeded(exec, old_version, @intCast(requested));
        }

        if (self._gate_waiter.detached) {
            txn.cancelForContextDetach();
            closed = true;
            self.disconnectUpgrade(txn);
            return .complete;
        }

        if (!txn.aborted() and txn._queue.items.len > 0) {
            // The handler left requests pending (e.g. a keep-alive loop).
            // Deliver their events one batch per scheduler turn — never
            // synchronously — so timer tasks can interleave and observe the
            // transaction as inactive. The drain owns the sqlite txn's fate now.
            closed = true;
            self._upgrade = txn;
            return .upgrade_draining;
        }

        if (!txn.aborted()) {
            // Nothing queued: settle synchronously (commit + fire `complete`).
            txn.settle(exec);
        }
        if (self._gate_waiter.detached) {
            closed = true;
            self.disconnectUpgrade(txn);
            return .complete;
        }
        // An aborted transaction — the upgradeneeded handler called abort()
        // (what a jerk!) — already rolled back; finishUpgrade delivers its
        // AbortError.
        closed = true;
        try self.finishUpgrade(txn);
        return .complete;
    }
};

pub fn deleteDatabase(self: *IDBFactory, name_value: ?js.Value, caller_exec: *Execution) !?*IDBOpenDBRequest {
    const name = try convertName(name_value, caller_exec, "deleteDatabase");

    const exec = self._exec;
    if (exec.isShuttingDown()) return null;

    const storage_origin_key = self._storage_origin_key orelse {
        return throwDatabaseAccessDenied(caller_exec, "deleteDatabase");
    };

    const public_request = try IDBOpenDBRequest.init(exec);
    const request = public_request.asRequest();

    const ctx = try exec._factory.create(DeleteContext{
        .open_request = public_request,
        .request = request,
        .name = try exec.dupeString(name),
        .exec = exec,
        .storage_origin_key = storage_origin_key,
        ._gate_waiter = .{ .ctx = exec.js, .wake = DeleteContext.wakeUp, .cancel = DeleteContext.cancelParked },
        ._connection_change_waiter = .{
            .ctx = exec.js,
            .wake = DeleteContext.wakeConnectionChange,
            .cancel = DeleteContext.cancelConnectionChange,
            .force_close = DeleteContext.forceCloseConnectionChange,
        },
    });

    try exec.js.scheduler.add(ctx, DeleteContext.run, 0, .{
        .name = "IDBFactory.deleteDatabase",
        .finalizer = DeleteContext.cancelled,
    });
    return public_request;
}

const DeleteContext = struct {
    open_request: *IDBOpenDBRequest,
    request: *IDBRequest,
    name: []const u8,
    exec: *Execution,
    storage_origin_key: []const u8,
    _gate_waiter: Engine.GateWaiter,
    _connection_change_waiter: Engine.ConnectionChangeWaiter,
    // See OpenContext._scheduled.
    _scheduled: bool = true,
    _connection_change_sent: bool = false,
    _version_change_ignored: bool = false,
    _blocked_fired: bool = false,
    _backend_force_closed: bool = false,

    fn cancelled(ctx: *anyopaque) void {
        // What if we're gated? Well, A scheduled task is only canceled on
        // teardown, which would have already called Engine.detach(js_ctx).
        const self: *DeleteContext = @ptrCast(@alignCast(ctx));
        var engine: ?*Engine = null;
        if (self._gate_waiter.state == .owner) {
            if (self.resolveEngine()) |resolved| {
                engine = resolved;
                _ = resolved.releaseGate(&self._gate_waiter);
            } else |_| {}
        }
        if (engine == null and self._connection_change_waiter.state == .owner) {
            engine = self.resolveEngine() catch null;
        }
        if (engine) |resolved| {
            _ = resolved.releaseConnectionChange(&self._connection_change_waiter);
        }
        self.exec._factory.destroy(self);
    }

    // See OpenContext.cancelParked.
    fn cancelParked(waiter: *Engine.GateWaiter) void {
        const self: *DeleteContext = @fieldParentPtr("_gate_waiter", waiter);
        self.destroyDetachedIfIdle();
    }

    fn cancelConnectionChange(waiter: *Engine.ConnectionChangeWaiter) void {
        const self: *DeleteContext = @fieldParentPtr("_connection_change_waiter", waiter);
        self.destroyDetachedIfIdle();
    }

    fn forceCloseConnectionChange(waiter: *Engine.ConnectionChangeWaiter, _: []const u8) void {
        const self: *DeleteContext = @fieldParentPtr("_connection_change_waiter", waiter);
        self._backend_force_closed = true;
    }

    fn destroyDetachedIfIdle(self: *DeleteContext) void {
        if (!self._scheduled and
            !self._gate_waiter.running and
            !self._connection_change_waiter.running and
            self._gate_waiter.state == .idle and
            self._connection_change_waiter.state == .idle)
        {
            self.exec._factory.destroy(self);
        }
    }

    fn stopRunning(self: *DeleteContext) void {
        self._gate_waiter.running = false;
        self._connection_change_waiter.running = false;
    }

    fn isDetached(self: *const DeleteContext) bool {
        return self._gate_waiter.detached or self._connection_change_waiter.detached;
    }

    fn releaseAndDestroy(self: *DeleteContext, engine: *Engine) void {
        self.stopRunning();
        _ = engine.releaseGate(&self._gate_waiter);
        _ = engine.releaseConnectionChange(&self._connection_change_waiter);
        self.exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DeleteContext = @ptrCast(@alignCast(ctx));
        self._scheduled = false;
        self._gate_waiter.running = true;
        self._connection_change_waiter.running = true;

        const engine = self.resolveEngine() catch |err| {
            if (!self.exec.isShuttingDown()) {
                self.request.setError(err);
                self.request.deliver(self.exec) catch {};
            }
            self.stopRunning();
            self.exec._factory.destroy(self);
            return null;
        };

        if (self._backend_force_closed) {
            if (!self.exec.isShuttingDown()) {
                self.request.setConnectionClosedError();
                self.request.deliver(self.exec) catch {};
            }
            self.releaseAndDestroy(engine);
            return null;
        }

        if (!engine.acquireConnectionChange(&self._connection_change_waiter, self.name)) {
            self.stopRunning();
            return null;
        }

        // As with open(), Chromium sends versionchange before attempting the
        // exclusive backend operation. Give the listener's microtask
        // checkpoint one scheduler turn to close its connection before we
        // decide whether a blocked event is warranted.
        const yield_for_connection_microtasks = self.prepareConnectionChange(engine) catch |err| {
            log.warn(.storage, "idb delete connection coordination", .{ .err = err, .name = self.name });
            if (!self.exec.isShuttingDown()) {
                self.request.setError(err);
                self.request.deliver(self.exec) catch {};
            }
            self.releaseAndDestroy(engine);
            return null;
        };
        if (yield_for_connection_microtasks) {
            if (self.isDetached()) {
                self.releaseAndDestroy(engine);
                return null;
            }
            self._scheduled = true;
            self.stopRunning();
            return 1;
        }

        if (!engine.acquireGate(&self._gate_waiter)) {
            self.stopRunning();
            return null; // parked; not destroyed
        }
        const waiting = self.runDelete(engine) catch |err| blk: {
            log.warn(.storage, "idb deleteDatabase", .{ .err = err, .name = self.name, .sqlite = engine.lastError() });
            if (!self.exec.isShuttingDown()) {
                self.request.setError(err);
                self.request.deliver(self.exec) catch {};
            }
            break :blk false;
        };
        if (waiting) {
            // See OpenContext's defensive waiting_connections branch: do not
            // strand a close-pending transaction behind the delete request.
            self.stopRunning();
            _ = engine.releaseGate(&self._gate_waiter);
            if (self.isDetached()) {
                _ = engine.releaseConnectionChange(&self._connection_change_waiter);
                self.exec._factory.destroy(self);
                return null;
            }
            self._scheduled = true;
            return 1;
        }

        self.releaseAndDestroy(engine);
        return null;
    }

    // Scheduler wake-up: the connection gate was handed to us, so re-run.
    fn wakeUp(waiter: *Engine.GateWaiter) void {
        const self: *DeleteContext = @fieldParentPtr("_gate_waiter", waiter);
        // See OpenContext.wakeUp: a stopped scheduler invokes the finalizer
        // synchronously from add().
        self._scheduled = true;
        self.exec.js.scheduler.add(self, run, 0, .{
            .name = "IDBFactory.deleteDatabase",
            .finalizer = cancelled,
        }) catch |err| {
            // We were handed the gate; if we can't reschedule, hand it off so the
            // waiters behind us aren't stranded.
            log.warn(.storage, "idb resume delete", .{ .err = err });
            if (self.resolveEngine()) |engine| {
                _ = engine.releaseGate(&self._gate_waiter);
                _ = engine.releaseConnectionChange(&self._connection_change_waiter);
            } else |_| {}
            self.exec._factory.destroy(self);
        };
    }

    fn wakeConnectionChange(waiter: *Engine.ConnectionChangeWaiter) void {
        const self: *DeleteContext = @fieldParentPtr("_connection_change_waiter", waiter);
        self._scheduled = true;
        self.exec.js.scheduler.add(self, run, 0, .{
            .name = "IDBFactory.deleteDatabase.connectionChange",
            .finalizer = cancelled,
        }) catch |err| {
            log.warn(.storage, "idb resume coordinated delete", .{ .err = err });
            if (self.resolveEngine()) |engine| {
                _ = engine.releaseConnectionChange(&self._connection_change_waiter);
            } else |_| {}
            self.exec._factory.destroy(self);
        };
    }

    fn resolveEngine(self: *DeleteContext) !*Engine {
        return self.exec.session.idb.engineForOrigin(self.storage_origin_key);
    }

    fn prepareConnectionChange(self: *DeleteContext, engine: *Engine) !bool {
        const existing = (try engine.databaseVersion(self.name)) orelse return false;
        const database_id = (try engine.databaseId(self.name)).?;

        if (!self._connection_change_sent) {
            self._connection_change_sent = true;
            if (!engine.hasConnections(database_id)) return false;
            self._version_change_ignored = engine.notifyVersionChange(database_id, @intCast(existing), null);
            return true;
        }

        const still_connected = engine.hasConnections(database_id);
        if (still_connected or self._version_change_ignored) {
            if (!self._blocked_fired and !self.exec.isShuttingDown()) {
                self._blocked_fired = true;
                try self.open_request.fireBlocked(self.exec, @intCast(existing), null);
            }
            return engine.hasConnections(database_id);
        }
        return false;
    }

    // Returns true while existing connections still block deletion.
    fn runDelete(self: *DeleteContext, engine: *Engine) !bool {
        const existing = try engine.databaseVersion(self.name);
        if (existing != null) {
            const database_id = (try engine.databaseId(self.name)).?;
            if (engine.hasConnections(database_id)) return true;
        }

        try engine.deleteDatabase(self.name);
        try self.request.fireSuccess(self.exec);
        return false;
    }
};

pub fn databases(self: *IDBFactory, caller_exec: *Execution) !js.Promise {
    // A promise-returning Web IDL operation creates its promise before the
    // backend/context validity checks. This also preserves the relevant realm
    // when a retained factory is invoked across a same-origin realm boundary.
    const local = caller_exec.js.local.?;
    const resolver = local.createPromiseResolver();
    const promise = resolver.promise();

    const exec = self._exec;
    if (exec.isShuttingDown()) {
        // Chrome 149 returns a promise from the factory's realm but leaves it
        // pending when a retained factory belongs to a discarded iframe. The
        // backend callback is intentionally lost with that execution context.
        return promise;
    }

    const storage_origin_key = self._storage_origin_key orelse {
        resolver.reject(
            "IDBFactory.databases security",
            DOMException.init(
                "Failed to execute 'databases' on 'IDBFactory': Access to the IndexedDB API is denied in this context.",
                "SecurityError",
            ),
        );
        return promise;
    };

    const global_resolver = try resolver.persist();
    errdefer global_resolver.deinit();

    const ctx = try exec._factory.create(DatabaseContext{
        .resolver = global_resolver,
        .exec = exec,
        .storage_origin_key = storage_origin_key,
        ._gate_waiter = .{
            .ctx = exec.js,
            .wake = DatabaseContext.wakeUp,
            .cancel = DatabaseContext.cancelParked,
        },
    });
    errdefer exec._factory.destroy(ctx);

    try exec.js.scheduler.add(ctx, DatabaseContext.run, 0, .{
        .name = "IDBFactory.databases",
        .finalizer = DatabaseContext.cancelled,
    });
    return promise;
}

const DatabaseContext = struct {
    resolver: js.PromiseResolver.Global,
    exec: *Execution,
    storage_origin_key: []const u8,
    _gate_waiter: Engine.GateWaiter,
    // Chromium crosses the renderer/backend boundary before the metadata
    // response task is queued. Keep that extra task hop observable: a timer
    // queued after databases() runs before its promise settles.
    _backend_dispatched: bool = false,
    // See OpenContext._scheduled.
    _scheduled: bool = true,

    fn destroy(self: *DatabaseContext) void {
        self.resolver.deinit();
        self.exec._factory.destroy(self);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *DatabaseContext = @ptrCast(@alignCast(ctx));
        if (self._gate_waiter.state == .owner) {
            if (self.resolveEngine()) |engine| _ = engine.releaseGate(&self._gate_waiter) else |_| {}
        }
        self.destroy();
    }

    fn cancelParked(waiter: *Engine.GateWaiter) void {
        const self: *DatabaseContext = @fieldParentPtr("_gate_waiter", waiter);
        if (waiter.running) return;
        if (!self._scheduled) {
            self.destroy();
        }
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *DatabaseContext = @ptrCast(@alignCast(ctx));
        self._scheduled = false;
        self._gate_waiter.running = true;

        if (!self._backend_dispatched) {
            self._backend_dispatched = true;
            self._scheduled = true;
            self._gate_waiter.running = false;
            self.exec.js.scheduler.add(self, run, 0, .{
                .name = "IDBFactory.databases.backend",
                .finalizer = cancelled,
            }) catch |err| {
                self._scheduled = false;
                self.rejectBackend(err);
                self.destroy();
            };
            return null;
        }

        const engine = self.resolveEngine() catch |err| {
            self.rejectBackend(err);
            self.destroy();
            return null;
        };

        // Metadata reads share the sqlite connection with versionchange and
        // normal transactions, so they must observe the same serialization
        // gate as open/deleteDatabase.
        if (!engine.acquireGate(&self._gate_waiter)) {
            self._gate_waiter.running = false;
            return null; // parked; not destroyed
        }
        defer self.destroy();
        defer _ = engine.releaseGate(&self._gate_waiter);
        defer self._gate_waiter.running = false;

        const arena = self.exec.getArena(.tiny, "IDBFactory.databases") catch |err| {
            self.rejectBackend(err);
            return null;
        };
        defer self.exec.releaseArena(arena);

        const infos = engine.databaseInfos(arena) catch |err| {
            log.warn(.storage, "idb databases", .{ .err = err, .sqlite = engine.lastError() });
            self.rejectBackend(err);
            return null;
        };

        // Scheduler callbacks are a native task boundary, not a V8 -> Zig
        // call, so Context.local is normally null here. Enter the resolver's
        // owner realm explicitly before materializing DatabaseInfo records and
        // settling its persistent V8 resolver.
        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();
        self.resolver.local(&ls.local).resolve("IDBFactory.databases", infos);
        return null;
    }

    fn rejectBackend(self: *DatabaseContext, err: anyerror) void {
        log.warn(.storage, "idb databases backend", .{ .err = err });
        // Error completion runs from the same scheduler boundary as success;
        // never depend on Caller having populated Context.local.
        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();
        self.resolver.local(&ls.local).reject(
            "IDBFactory.databases backend",
            DOMException.init(null, "UnknownError"),
        );
    }

    fn wakeUp(waiter: *Engine.GateWaiter) void {
        const self: *DatabaseContext = @fieldParentPtr("_gate_waiter", waiter);
        self._scheduled = true;
        self.exec.js.scheduler.add(self, run, 0, .{
            .name = "IDBFactory.databases",
            .finalizer = cancelled,
        }) catch |err| {
            log.warn(.storage, "idb resume databases", .{ .err = err });
            if (self.resolveEngine()) |engine| _ = engine.releaseGate(&self._gate_waiter) else |_| {}
            self.destroy();
        };
    }

    fn resolveEngine(self: *DatabaseContext) !*Engine {
        return self.exec.session.idb.engineForOrigin(self.storage_origin_key);
    }
};

pub fn cmp(_: *IDBFactory, first_value: ?js.Value, second_value: ?js.Value, exec: *Execution) !i32 {
    const operation: WebIDL.Operation = .{ .interface = "IDBFactory", .name = "cmp" };
    const first = first_value orelse return WebIDL.requiredArgument(exec, operation, 2, 0);
    const second = second_value orelse return WebIDL.requiredArgument(exec, operation, 2, 1);
    const a = Key.encodeValue(exec.call_arena, first) catch |err| switch (err) {
        error.DataError => return throwCmpDataError(exec),
        else => return err,
    };
    const b = Key.encodeValue(exec.call_arena, second) catch |err| switch (err) {
        error.DataError => return throwCmpDataError(exec),
        else => return err,
    };
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBFactory);

    pub const Meta = struct {
        pub const name = "IDBFactory";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Declaration order is observable through Reflect.ownKeys and follows the
    // Chrome 149 generated binding.
    pub const cmp = bridge.function(IDBFactory.cmp, .{ .arity = 2, .required_args = 2 });
    pub const databases = bridge.function(IDBFactory.databases, .{ .arity = 0, .required_args = 0 });
    pub const deleteDatabase = bridge.function(IDBFactory.deleteDatabase, .{ .arity = 1, .required_args = 1 });
    pub const open = bridge.function(IDBFactory.open, .{ .arity = 1, .required_args = 1 });
};
