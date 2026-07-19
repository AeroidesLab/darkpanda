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
const js = @import("../../../js/js.zig");
const Evaluate = @import("../../../Evaluate.zig");

pub const Key = @import("Key.zig");
pub const Engine = @import("Engine.zig");
pub const Manager = @import("Manager.zig");

pub const IDBFactory = @import("IDBFactory.zig");
pub const IDBRecord = @import("IDBRecord.zig");
pub const IDBRequest = @import("IDBRequest.zig");
pub const IDBOpenDBRequest = @import("IDBOpenDBRequest.zig");
pub const IDBCursor = @import("IDBCursor.zig");
pub const IDBIndex = @import("IDBIndex.zig");
pub const IDBDatabase = @import("IDBDatabase.zig");
pub const IDBKeyRange = @import("IDBKeyRange.zig");
pub const IDBTransaction = @import("IDBTransaction.zig");
pub const IDBObjectStore = @import("IDBObjectStore.zig");
pub const IDBCursorWithValue = @import("IDBCursorWithValue.zig");
pub const IDBVersionChangeEvent = @import("IDBVersionChangeEvent.zig");

pub fn registerTypes() []const type {
    return &.{
        IDBFactory,
        IDBRecord,
        IDBRequest,
        IDBOpenDBRequest,
        IDBCursor,
        IDBIndex,
        IDBDatabase,
        IDBKeyRange,
        IDBTransaction,
        IDBObjectStore,
        IDBCursorWithValue,
        IDBVersionChangeEvent,
    };
}

// the keyPath attribute need identity equality. For a compound key (an array)
// we have to return the same v8::rray on every reach. So users of KeyPath will
// cache it locally, and store it in the Transaction's globals list for cleanup.
pub fn cachedKeyPathJs(cache: *?*js.GlobalSlot, txn: *IDBTransaction, kp: ?Key.KeyPath, exec: *js.Execution) !js.Value {
    const local = exec.js.local.?;
    if (kp) |path| {
        if (std.meta.activeTag(path) == .list) {
            if (cache.*) |slot| {
                return slot.local(local);
            }
            const value = try Key.keyPathToJs(local, path);
            cache.* = try txn.persist(value);
            return value;
        }
    }
    return Key.keyPathToJs(local, kp);
}

// An on* event-handler attribute setter. The bridge can hand the setter either
// a function (store it) or any other value (clears it).
pub const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

const testing = @import("../../../../testing.zig");
test "WebApi: IndexedDB" {
    try testing.htmlRunner("indexeddb.html", .{});
}

test "WebApi: IndexedDB immutable storage key" {
    try testing.htmlRunner("indexeddb_storage_key.html", .{ .timeout_ms = 8000 });
}

test "WebApi: IndexedDB backend forced close" {
    defer testing.reset();

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    try frame.navigate(
        "http://127.0.0.1:9582/src/browser/tests/idb_backend_force_close_fixture.html",
        .{},
    );
    try testing.waitForFrame();

    const open_source: [:0]const u8 =
        \\(async () => {
        \\  window.__fc_events = [];
        \\  window.__fc_db = await new Promise((resolve, reject) => {
        \\    const request = indexedDB.open('backend-force-close-db', 1);
        \\    request.onupgradeneeded = () => request.result.createObjectStore('records');
        \\    request.onsuccess = () => resolve(request.result);
        \\    request.onerror = () => reject(request.error);
        \\  });
        \\  __fc_db.addEventListener('close', event => {
        \\    let transactionError = null;
        \\    try { __fc_db.transaction('records'); }
        \\    catch (error) { transactionError = {name: error.name, message: error.message}; }
        \\    __fc_events.push({
        \\      owner: 'database', type: event.type, isTrusted: event.isTrusted,
        \\      bubbles: event.bubbles, cancelable: event.cancelable, composed: event.composed,
        \\      eventPhase: event.eventPhase, targetSame: event.target === __fc_db,
        \\      currentTargetSame: event.currentTarget === __fc_db,
        \\      pathOnlyDatabase: event.composedPath().length === 1 && event.composedPath()[0] === __fc_db,
        \\      transactionError,
        \\    });
        \\  });
        \\  return 'ready';
        \\})()
    ;
    const opened = try Evaluate.run(testing.arena_allocator, frame, open_source, .{});
    try testing.expect(!opened.is_error);
    try testing.expectString("ready", opened.text);

    // Arm an ordinary transaction in a separate synchronous JS task. Its
    // native drain is queued but cannot run before the backend seam below.
    const arm_source: [:0]const u8 =
        \\window.__fc_tx = __fc_db.transaction('records', 'readwrite');
        \\window.__fc_request = __fc_tx.objectStore('records').put('value', 'key');
        \\__fc_request.addEventListener('error', event => __fc_events.push({
        \\  owner: 'request', type: event.type, isTrusted: event.isTrusted,
        \\  bubbles: event.bubbles, cancelable: event.cancelable, composed: event.composed,
        \\}));
        \\__fc_tx.addEventListener('abort', event => __fc_events.push({
        \\  owner: 'transaction', type: event.type, isTrusted: event.isTrusted,
        \\  bubbles: event.bubbles, cancelable: event.cancelable, composed: event.composed,
        \\}));
        \\'armed'
    ;
    const armed = try Evaluate.run(testing.arena_allocator, frame, arm_source, .{});
    try testing.expect(!armed.is_error);
    try testing.expectString("armed", armed.text);

    const origin = frame.js.execution.origin().?;
    try testing.expectEqual(1, testing.test_session.idb.forceCloseOrigin(origin));

    const observe_source: [:0]const u8 =
        \\(() => {
        \\  let post = null;
        \\  try { __fc_db.transaction('records'); }
        \\  catch (error) { post = {name: error.name, message: error.message}; }
        \\  return {events: __fc_events, post};
        \\})()
    ;
    const observed = try Evaluate.run(testing.arena_allocator, frame, observe_source, .{});
    try testing.expect(!observed.is_error);
    try testing.expectString(
        "{\"events\":[{\"owner\":\"request\",\"type\":\"error\",\"isTrusted\":true," ++
            "\"bubbles\":true,\"cancelable\":true,\"composed\":false}," ++
            "{\"owner\":\"transaction\",\"type\":\"abort\",\"isTrusted\":true," ++
            "\"bubbles\":true,\"cancelable\":false,\"composed\":false}," ++
            "{\"owner\":\"database\",\"type\":\"close\",\"isTrusted\":true," ++
            "\"bubbles\":false,\"cancelable\":false,\"composed\":false,\"eventPhase\":2," ++
            "\"targetSame\":true,\"currentTargetSame\":true,\"pathOnlyDatabase\":true," ++
            "\"transactionError\":{\"name\":\"InvalidStateError\",\"message\":" ++
            "\"Failed to execute 'transaction' on 'IDBDatabase': The database connection is closing.\"}}]," ++
            "\"post\":{\"name\":\"InvalidStateError\",\"message\":" ++
            "\"Failed to execute 'transaction' on 'IDBDatabase': The database connection is closing.\"}}",
        observed.text,
    );
}

test "WebApi: IndexedDB backend forced close during upgrade" {
    defer testing.reset();

    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    try frame.navigate(
        "http://127.0.0.1:9582/src/browser/tests/idb_backend_force_close_fixture.html",
        .{},
    );
    try testing.waitForFrame();

    // Keep the versionchange transaction alive across scheduler turns. This is
    // the exact window in which Blink has exposed the IDBDatabase from
    // upgradeneeded, while Lightpanda intentionally has not registered it as an
    // Engine.Connection because the open request has not succeeded yet.
    const arm_source: [:0]const u8 =
        \\(async () => {
        \\  window.__fcu_events = [];
        \\  window.__fcu_close_count = 0;
        \\  let finish;
        \\  window.__fcu_done = new Promise(resolve => { finish = resolve; });
        \\  return new Promise((resolve, reject) => {
        \\    const request = indexedDB.open('backend-force-close-upgrade-db', 1);
        \\    window.__fcu_request = request;
        \\    request.onupgradeneeded = () => {
        \\      const db = request.result;
        \\      const transaction = request.transaction;
        \\      const store = db.createObjectStore('records');
        \\      window.__fcu_db = db;
        \\      window.__fcu_transaction = transaction;
        \\      db.addEventListener('close', () => { __fcu_close_count += 1; });
        \\      transaction.addEventListener('error', event => {
        \\        let databaseTransactionError = null;
        \\        try { db.transaction('records'); }
        \\        catch (error) { databaseTransactionError = {name: error.name, message: error.message}; }
        \\        __fcu_events.push({
        \\          owner: 'transaction', type: event.type, isTrusted: event.isTrusted,
        \\          bubbles: event.bubbles, cancelable: event.cancelable,
        \\          transactionError: {name: transaction.error.name, message: transaction.error.message},
        \\          databaseTransactionError,
        \\        });
        \\      });
        \\      transaction.addEventListener('abort', event => {
        \\        let databaseTransactionError = null;
        \\        try { db.transaction('records'); }
        \\        catch (error) { databaseTransactionError = {name: error.name, message: error.message}; }
        \\        __fcu_events.push({
        \\          owner: 'transaction', type: event.type, isTrusted: event.isTrusted,
        \\          bubbles: event.bubbles, cancelable: event.cancelable, databaseTransactionError,
        \\        });
        \\      });
        \\      const keepAlive = () => {
        \\        const pending = store.get('key');
        \\        pending.onsuccess = keepAlive;
        \\      };
        \\      keepAlive();
        \\      resolve('upgrade-ready');
        \\    };
        \\    request.onerror = event => {
        \\      __fcu_events.push({
        \\        owner: 'request', type: event.type, isTrusted: event.isTrusted,
        \\        bubbles: event.bubbles, cancelable: event.cancelable,
        \\        error: {name: request.error.name, message: request.error.message},
        \\        resultUndefined: request.result === undefined,
        \\      });
        \\      finish();
        \\    };
        \\    request.onsuccess = () => reject(new Error('forced upgrade unexpectedly succeeded'));
        \\  });
        \\})()
    ;
    const armed = try Evaluate.run(testing.arena_allocator, frame, arm_source, .{});
    try testing.expect(!armed.is_error);
    try testing.expectString("upgrade-ready", armed.text);

    const origin = frame.js.execution.origin().?;
    try testing.expectEqual(1, testing.test_session.idb.forceCloseOrigin(origin));

    const observe_source: [:0]const u8 =
        \\(async () => {
        \\  await __fcu_done;
        \\  let transactionError = null;
        \\  try { __fcu_db.transaction('records'); }
        \\  catch (error) { transactionError = {name: error.name, message: error.message}; }
        \\  return {events: __fcu_events, closeCount: __fcu_close_count, transactionError};
        \\})()
    ;
    const observed = try Evaluate.run(testing.arena_allocator, frame, observe_source, .{});
    try testing.expect(!observed.is_error);
    try testing.expectString(
        "{\"events\":[{\"owner\":\"transaction\",\"type\":\"error\",\"isTrusted\":true," ++
            "\"bubbles\":true,\"cancelable\":true,\"transactionError\":{\"name\":\"UnknownError\"," ++
            "\"message\":\"Connection is closing because of: Force close delete origin\"}," ++
            "\"databaseTransactionError\":{\"name\":\"InvalidStateError\",\"message\":" ++
            "\"Failed to execute 'transaction' on 'IDBDatabase': A version change transaction is running.\"}}," ++
            "{\"owner\":\"transaction\",\"type\":\"abort\"," ++
            "\"isTrusted\":true,\"bubbles\":true,\"cancelable\":false,\"databaseTransactionError\":" ++
            "{\"name\":\"InvalidStateError\",\"message\":\"Failed to execute 'transaction' on 'IDBDatabase': " ++
            "The database connection is closing.\"}},{\"owner\":\"request\"," ++
            "\"type\":\"error\",\"isTrusted\":true,\"bubbles\":true,\"cancelable\":true," ++
            "\"error\":{\"name\":\"AbortError\",\"message\":\"The connection was closed.\"}," ++
            "\"resultUndefined\":true}],\"closeCount\":0,\"transactionError\":{\"name\":\"InvalidStateError\"," ++
            "\"message\":\"Failed to execute 'transaction' on 'IDBDatabase': The database connection is closing.\"}}",
        observed.text,
    );

    // The version row and object store were part of the aborted sqlite
    // transaction, so a subsequent open must recreate the database from v0.
    const engine = try testing.test_session.idb.engineForOrigin(origin);
    try testing.expectEqual(null, try engine.databaseVersion("backend-force-close-upgrade-db"));
}
