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

const EventTarget = @import("../../EventTarget.zig");
const Event = @import("../../Event.zig");

const idb = @import("idb.zig");
const Key = @import("Key.zig");
const Engine = @import("Engine.zig");
const IDBTransaction = @import("IDBTransaction.zig");
const IDBObjectStore = @import("IDBObjectStore.zig");
const IDBVersionChangeEvent = @import("IDBVersionChangeEvent.zig");
const DOMStringList = @import("../../collections.zig").DOMStringList;
const DOMException = @import("../../DOMException.zig");

const FunctionSetter = idb.FunctionSetter;

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const IDBDatabase = @This();

fn throwTransactionInvalidState(exec: *Execution, reason: []const u8) anyerror {
    return throwTransactionDOMException(exec, "InvalidStateError", reason);
}

fn throwTransactionDOMException(exec: *Execution, name: []const u8, reason: []const u8) anyerror {
    const local = exec.js.local.?;
    const message = try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute 'transaction' on 'IDBDatabase': {s}",
        .{reason},
    );
    const exception = try local.zigValueToJs(
        DOMException.init(message, name),
        .{},
    );
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

_proto: *EventTarget,
_exec: *Execution,
_engine: *Engine,
_database_id: i64,
_name: []const u8,
_version: i64,
_txn: ?*IDBTransaction = null, // only set during upgradeneeded
_connection: Engine.Connection = undefined,
_connection_state: enum { unregistered, open, close_pending, detached } = .unregistered,
_active_transactions: usize = 0,
// Intrusive because both the database and transactions are page-owned. It
// lets a backend force-close abort every live transaction without introducing
// a second allocator/lifetime into this connection object.
_transactions: std.DoublyLinkedList = .{},
_on_abort: ?js.Function.Global = null,
_on_close: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_version_change: ?js.Function.Global = null,

pub fn init(exec: *Execution, engine: *Engine, database_id: i64, name: []const u8, version: i64) !*IDBDatabase {
    const self = try exec._factory.eventTarget(IDBDatabase{
        ._proto = undefined,
        ._exec = exec,
        ._engine = engine,
        ._database_id = database_id,
        ._name = name,
        ._version = version,
    });
    self._connection = .{
        .database_id = database_id,
        .ctx = exec.js,
        .version_change = versionChange,
        .force_close = forcedClose,
        .context_detached = contextDetached,
    };
    return self;
}

pub fn asEventTarget(self: *IDBDatabase) *EventTarget {
    return self._proto;
}

const CreateObjectStoreOptions = struct {
    keyPath: ?Key.KeyPath = null,
    autoIncrement: bool = false,
};

// Only callable while the upgrade transaction is live and active, hence the checks
pub fn createObjectStore(
    self: *IDBDatabase,
    name: []const u8,
    options: ?CreateObjectStoreOptions,
) !*IDBObjectStore {
    const txn = self._txn orelse return error.InvalidStateError;
    if (txn._settled) {
        return error.InvalidStateError;
    }
    try txn.assertActive();

    const opts = options orelse CreateObjectStoreOptions{};

    // Validate + copy the key path onto the transaction arena so it outlives the
    // call. autoIncrement is incompatible with an empty or compound key path.
    const key_path: ?Key.KeyPath = if (opts.keyPath) |kp| blk: {
        if (Key.isValidKeyPathSpec(kp) == false) {
            return error.SyntaxError;
        }
        if (opts.autoIncrement and keyPathBlocksAutoIncrement(kp)) {
            return error.InvalidAccessError;
        }
        break :blk try Key.dupeKeyPath(txn._arena, kp);
    } else null;

    const store_id = self._engine.createObjectStore(
        txn._arena,
        self._database_id,
        name,
        key_path,
        opts.autoIncrement,
    ) catch |err| switch (err) {
        error.Constraint => return error.ConstraintError,
        else => return err,
    };

    const owned_name = try txn.dupe(name);
    const store = try IDBObjectStore.init(txn, store_id, owned_name, key_path, opts.autoIncrement);
    store._created = true;
    try txn.cacheStore(store);
    return store;
}

// autoIncrement requires an out-of-line or single-property in-line key; an empty
// or compound key path can't carry a generated key.
fn keyPathBlocksAutoIncrement(kp: Key.KeyPath) bool {
    return switch (kp) {
        .string => |s| s.len == 0,
        .list => true,
    };
}

// Only callable while the upgrade transaction is live and active, hence the checks
pub fn deleteObjectStore(self: *IDBDatabase, name: []const u8, _: *Execution) !void {
    const txn = self._txn orelse return error.InvalidStateError;
    if (txn._settled) {
        return error.InvalidStateError;
    }
    try txn.assertActive();
    try self._engine.deleteObjectStore(self._database_id, name);
    txn.uncacheStore(name);
}

const TransactionMode = enum {
    readonly,
    readwrite,
    pub const js_enum_from_string = true;
};

const StoreNames = union(enum) {
    name: []const u8,
    names: []const []const u8,
};

const TransactionOptions = struct {
    durability: IDBTransaction.Durability = .default,
};

pub fn transaction(
    self: *IDBDatabase,
    store_names: StoreNames,
    mode: ?TransactionMode,
    options: ?TransactionOptions,
    exec: *Execution,
) !*IDBTransaction {
    if (self._txn != null) {
        return throwTransactionInvalidState(exec, "A version change transaction is running.");
    }

    // ContextDestroyed closes Blink's backing connection. A retained wrapper
    // can still be called from its surviving V8 realm, but it must fail before
    // allocating or scheduling a transaction. Scheduling on a stopped owner
    // runs the task finalizer synchronously and would return a freed wrapper.
    if (self._exec.isShuttingDown() or self._connection_state == .detached) {
        return throwTransactionInvalidState(exec, "The database connection is closed.");
    }
    if (self._connection_state == .close_pending) {
        return throwTransactionInvalidState(exec, "The database connection is closing.");
    }
    if (self._connection_state != .open) {
        return throwTransactionInvalidState(exec, "The database connection is closed.");
    }

    switch (store_names) {
        .names => |names| if (names.len == 0) {
            return throwTransactionDOMException(
                exec,
                "InvalidAccessError",
                "The storeNames parameter was empty.",
            );
        },
        .name => {},
    }
    const existing_names = try self._engine.objectStoreNames(exec.call_arena, self._database_id);
    const Validate = struct {
        fn contains(names: []const []const u8, requested: []const u8) bool {
            for (names) |existing| {
                if (std.mem.eql(u8, requested, existing)) return true;
            }
            return false;
        }
    };
    const missing = switch (store_names) {
        .name => |requested| !Validate.contains(existing_names, requested),
        .names => |requested_names| blk: {
            for (requested_names) |requested| {
                if (!Validate.contains(existing_names, requested)) break :blk true;
            }
            break :blk false;
        },
    };
    if (missing) {
        return throwTransactionDOMException(
            exec,
            "NotFoundError",
            "One of the specified object stores was not found.",
        );
    }

    const opts = options orelse TransactionOptions{};
    const txn = try IDBTransaction.init(self, switch (mode orelse .readonly) {
        .readonly => .readonly,
        .readwrite => .readwrite,
    }, opts.durability, exec);
    txn._scope = try normalizeStoreNames(txn._arena, store_names);
    return txn;
}

// The transaction's scope: the requested store names, sorted with duplicates
// removed (per the IndexedDB spec's "transaction scope" steps).
fn normalizeStoreNames(arena: Allocator, store_names: StoreNames) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    switch (store_names) {
        .name => |name| try list.append(arena, try arena.dupe(u8, name)),
        .names => |names| {
            try list.ensureUnusedCapacity(arena, names.len);
            for (names) |name| {
                list.appendAssumeCapacity(try arena.dupe(u8, name));
            }
        },
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Drop duplicates now that equal names are adjacent. The first name always
    // survives, so only the rest need comparing.
    if (list.items.len <= 1) {
        return list.items;
    }

    var write: usize = 1;
    for (list.items[1..]) |name| {
        if (!std.mem.eql(u8, name, list.items[write - 1])) {
            list.items[write] = name;
            write += 1;
        }
    }
    return list.items[0..write];
}

// Called exactly once before an open request's success event. The upgrade path
// creates the public object before `upgradeneeded`, so close() may already have
// moved it to close_pending; in that case success must become AbortError.
pub fn activateConnection(self: *IDBDatabase) bool {
    if (self._connection_state != .unregistered) return false;
    self._connection_state = .open;
    self._engine.registerConnection(&self._connection);
    return true;
}

pub fn transactionCreated(self: *IDBDatabase, txn: *IDBTransaction) void {
    std.debug.assert(self._connection_state == .open);
    std.debug.assert(txn._database_transaction_active == false);
    self._transactions.append(&txn._database_node);
    self._active_transactions += 1;
}

pub fn transactionFinished(self: *IDBDatabase, txn: *IDBTransaction) void {
    std.debug.assert(self._active_transactions > 0);
    self._transactions.remove(&txn._database_node);
    txn._database_node = .{};
    self._active_transactions -= 1;
    if (self._active_transactions == 0 and self._connection_state == .close_pending) {
        _ = self._engine.unregisterConnection(&self._connection);
    }
}

pub fn close(self: *IDBDatabase) void {
    switch (self._connection_state) {
        .unregistered, .open => self._connection_state = .close_pending,
        .close_pending, .detached => return,
    }
    if (self._active_transactions == 0) {
        _ = self._engine.unregisterConnection(&self._connection);
    }
}

fn versionChange(connection: *Engine.Connection, old_version: u64, new_version: ?u64) bool {
    const self: *IDBDatabase = @fieldParentPtr("_connection", connection);
    // Blink acknowledges VersionChangeIgnored for close-pending connections:
    // they still block the request until their transactions finish, but do not
    // receive an author-facing versionchange event.
    if (self._connection_state != .open or self._exec.isShuttingDown()) return false;

    var ls: js.Local.Scope = undefined;
    self._exec.js.localScope(&ls);
    defer ls.deinit();

    const event = IDBVersionChangeEvent.initTrusted(
        .wrap("versionchange"),
        old_version,
        new_version,
        self._exec,
    ) catch return false;
    self._exec.dispatch(
        self.asEventTarget(),
        event.asEvent(),
        self._on_version_change,
        .{ .context = "IDBDatabase.versionchange" },
    ) catch {};
    return true;
}

fn forcedClose(connection: *Engine.Connection, reason: []const u8) void {
    const self: *IDBDatabase = @fieldParentPtr("_connection", connection);
    if (self._connection_state == .detached or self._exec.isShuttingDown()) {
        return;
    }

    // Chrome leaves the handle close-pending after a backend force-close.
    // Mark it before abort events run so no re-entrant callback can create a
    // fresh transaction on a connection which the backend has already torn
    // down. Each abort unlinks itself from this list, hence repeatedly consume
    // the current head rather than retaining an invalidated `next` pointer.
    self.close();
    while (self._transactions.first) |node| {
        const txn: *IDBTransaction = @fieldParentPtr("_database_node", node);
        txn.forceAbortFromBackend(reason);
    }

    var ls: js.Local.Scope = undefined;
    self._exec.js.localScope(&ls);
    defer ls.deinit();

    const event = Event.initTrusted(comptime .wrap("close"), null, self._exec.page) catch return;
    self._exec.dispatch(
        self.asEventTarget(),
        event,
        self._on_close,
        .{ .context = "IDBDatabase.close" },
    ) catch {};
}

fn contextDetached(connection: *Engine.Connection) void {
    const self: *IDBDatabase = @fieldParentPtr("_connection", connection);
    self._connection_state = .detached;
    _ = self._engine.unregisterConnection(connection);
}

pub fn getName(self: *const IDBDatabase) []const u8 {
    return self._name;
}

pub fn getVersion(self: *const IDBDatabase) i64 {
    return self._version;
}

pub fn getObjectStoreNames(self: *IDBDatabase, exec: *Execution) !*DOMStringList {
    const arena = try exec.getArena(.small, "IDB.getObjectStoreNames");
    errdefer exec.releaseArena(arena);

    const names = try self._engine.objectStoreNames(arena, self._database_id);
    const list = try arena.create(DOMStringList);
    list.* = .{ ._items = names, ._arena = arena };
    return list;
}

pub fn getOnError(self: *const IDBDatabase) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *IDBDatabase, setter: ?FunctionSetter) void {
    self._on_error = functionFromSetter(setter);
}

pub fn getOnAbort(self: *const IDBDatabase) ?js.Function.Global {
    return self._on_abort;
}

pub fn setOnAbort(self: *IDBDatabase, setter: ?FunctionSetter) void {
    self._on_abort = functionFromSetter(setter);
}

pub fn getOnClose(self: *const IDBDatabase) ?js.Function.Global {
    return self._on_close;
}

pub fn setOnClose(self: *IDBDatabase, setter: ?FunctionSetter) void {
    self._on_close = functionFromSetter(setter);
}

pub fn getOnVersionChange(self: *const IDBDatabase) ?js.Function.Global {
    return self._on_version_change;
}

pub fn setOnVersionChange(self: *IDBDatabase, setter: ?FunctionSetter) void {
    self._on_version_change = functionFromSetter(setter);
}

fn functionFromSetter(setter: ?FunctionSetter) ?js.Function.Global {
    return if (setter) |s| switch (s) {
        .func => |f| f,
        .anything => null,
    } else null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBDatabase);

    pub const Meta = struct {
        pub const name = "IDBDatabase";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome 149 generated binding declaration order (observable through
    // Reflect.ownKeys).
    pub const name = bridge.accessor(IDBDatabase.getName, null, .{});
    pub const version = bridge.accessor(IDBDatabase.getVersion, null, .{});
    pub const objectStoreNames = bridge.accessor(IDBDatabase.getObjectStoreNames, null, .{});
    pub const onabort = bridge.accessor(IDBDatabase.getOnAbort, IDBDatabase.setOnAbort, .{});
    pub const onclose = bridge.accessor(IDBDatabase.getOnClose, IDBDatabase.setOnClose, .{});
    pub const onerror = bridge.accessor(IDBDatabase.getOnError, IDBDatabase.setOnError, .{});
    pub const onversionchange = bridge.accessor(IDBDatabase.getOnVersionChange, IDBDatabase.setOnVersionChange, .{});
    pub const close = bridge.function(IDBDatabase.close, .{});
    pub const createObjectStore = bridge.function(IDBDatabase.createObjectStore, .{});
    pub const deleteObjectStore = bridge.function(IDBDatabase.deleteObjectStore, .{});
    pub const transaction = bridge.function(IDBDatabase.transaction, .{});
};
