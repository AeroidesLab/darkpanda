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
const lp = @import("darkpanda");

const js = @import("js.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const v8 = js.v8;
const bridge = js.bridge;

const IS_DEBUG = @import("builtin").mode == .Debug;

const Allocator = std.mem.Allocator;

const Value = @This();

local: *const js.Local,
handle: *const v8.Value,

pub fn isObject(self: Value) bool {
    return v8.v8__Value__IsObject(self.handle);
}

pub fn isString(self: Value) ?js.String {
    const handle = self.handle;
    if (!v8.v8__Value__IsString(handle)) {
        return null;
    }
    return .{ .local = self.local, .handle = @ptrCast(handle) };
}

pub fn isArray(self: Value) bool {
    return v8.v8__Value__IsArray(self.handle);
}

pub fn isSymbol(self: Value) bool {
    return v8.v8__Value__IsSymbol(self.handle);
}

pub fn isFunction(self: Value) bool {
    return v8.v8__Value__IsFunction(self.handle);
}

pub fn isNativeError(self: Value) bool {
    return v8.v8__Value__IsNativeError(self.handle);
}

pub fn isNull(self: Value) bool {
    return v8.v8__Value__IsNull(self.handle);
}

pub fn isUndefined(self: Value) bool {
    return v8.v8__Value__IsUndefined(self.handle);
}

pub fn isNullOrUndefined(self: Value) bool {
    return v8.v8__Value__IsNullOrUndefined(self.handle);
}

pub fn isNumber(self: Value) bool {
    return v8.v8__Value__IsNumber(self.handle);
}

pub fn isNumberObject(self: Value) bool {
    return v8.v8__Value__IsNumberObject(self.handle);
}

pub fn isInt32(self: Value) bool {
    return v8.v8__Value__IsInt32(self.handle);
}

pub fn isUint32(self: Value) bool {
    return v8.v8__Value__IsUint32(self.handle);
}

pub fn isBigInt(self: Value) bool {
    return v8.v8__Value__IsBigInt(self.handle);
}

pub fn isBigIntObject(self: Value) bool {
    return v8.v8__Value__IsBigIntObject(self.handle);
}

pub fn isBoolean(self: Value) bool {
    return v8.v8__Value__IsBoolean(self.handle);
}

pub fn isBooleanObject(self: Value) bool {
    return v8.v8__Value__IsBooleanObject(self.handle);
}

pub fn isTrue(self: Value) bool {
    return v8.v8__Value__IsTrue(self.handle);
}

pub fn isFalse(self: Value) bool {
    return v8.v8__Value__IsFalse(self.handle);
}

pub fn isTypedArray(self: Value) bool {
    return v8.v8__Value__IsTypedArray(self.handle);
}

pub fn isArrayBufferView(self: Value) bool {
    return v8.v8__Value__IsArrayBufferView(self.handle);
}

pub fn isArrayBuffer(self: Value) bool {
    return v8.v8__Value__IsArrayBuffer(self.handle);
}

pub fn isSharedArrayBuffer(self: Value) bool {
    return v8.v8__Value__IsSharedArrayBuffer(self.handle);
}

pub fn isDate(self: Value) bool {
    return v8.v8__Value__IsDate(self.handle);
}

pub fn isUint8Array(self: Value) bool {
    return v8.v8__Value__IsUint8Array(self.handle);
}

pub fn isUint8ClampedArray(self: Value) bool {
    return v8.v8__Value__IsUint8ClampedArray(self.handle);
}

pub fn isInt8Array(self: Value) bool {
    return v8.v8__Value__IsInt8Array(self.handle);
}

pub fn isUint16Array(self: Value) bool {
    return v8.v8__Value__IsUint16Array(self.handle);
}

pub fn isInt16Array(self: Value) bool {
    return v8.v8__Value__IsInt16Array(self.handle);
}

pub fn isUint32Array(self: Value) bool {
    return v8.v8__Value__IsUint32Array(self.handle);
}

pub fn isInt32Array(self: Value) bool {
    return v8.v8__Value__IsInt32Array(self.handle);
}

pub fn isBigUint64Array(self: Value) bool {
    return v8.v8__Value__IsBigUint64Array(self.handle);
}

pub fn isBigInt64Array(self: Value) bool {
    return v8.v8__Value__IsBigInt64Array(self.handle);
}

pub fn isFloat32Array(self: Value) bool {
    return v8.v8__Value__IsFloat32Array(self.handle);
}

pub fn isFloat64Array(self: Value) bool {
    return v8.v8__Value__IsFloat64Array(self.handle);
}

// A few places in the code take various types, but want a string. This is a
// type-aware version of toString(). If you do:
//    (new ArrayBuffer(100)).toString()
// You'll get "[object ArrayBuffer]". But this `toStringSmart()` knows about
// buffers, and Blobs, etc and will try to return the real underlying string
// value. It _does_ ultimately fallback to toString() - callers should check
// for types they _don't_ want before calling this. For example, `Response`
// checks for null or undefined before calling this to apply specific handling
// to those cases.
pub fn toStringSmart(self: Value) ![]const u8 {
    if (self.isString()) |js_str| {
        return try js_str.toSlice();
    }

    const Blob = @import("../webapi/Blob.zig");
    if (self.local.jsValueToZig(*Blob, self)) |blob_obj| {
        return blob_obj._slice;
    } else |_| {}

    var byte_offset: usize = 0;
    var byte_len: usize = undefined;
    var array_buffer: ?*const v8.ArrayBuffer = null;

    if (self.isTypedArray() or self.isArrayBufferView()) {
        const buffer_handle: *const v8.ArrayBufferView = @ptrCast(self.handle);
        byte_len = v8.v8__ArrayBufferView__ByteLength(buffer_handle);
        byte_offset = v8.v8__ArrayBufferView__ByteOffset(buffer_handle);
        array_buffer = v8.v8__ArrayBufferView__Buffer(buffer_handle);
    } else if (self.isArrayBuffer()) {
        array_buffer = @ptrCast(self.handle);
        byte_len = v8.v8__ArrayBuffer__ByteLength(array_buffer);
    } else {
        return self.toStringSlice();
    }

    const backing_store_ptr = v8.v8__ArrayBuffer__GetBackingStore(array_buffer orelse return "");
    if (byte_len == 0) {
        return &[_]u8{};
    }

    const backing_store_handle = v8.std__shared_ptr__v8__BackingStore__get(&backing_store_ptr) orelse return "";
    const data = v8.v8__BackingStore__Data(backing_store_handle) orelse return "";
    const base = @as([*]const u8, @ptrCast(data)) + byte_offset;

    return base[0..byte_len];
}

pub fn isPromise(self: Value) bool {
    return v8.v8__Value__IsPromise(self.handle);
}

pub fn toBool(self: Value) bool {
    return v8.v8__Value__BooleanValue(self.handle, self.local.isolate.handle);
}

pub fn typeOf(self: Value) js.String {
    const str_handle = v8.v8__Value__TypeOf(self.handle, self.local.isolate.handle).?;
    return js.String{ .local = self.local, .handle = str_handle };
}

pub fn toF32(self: Value) !f32 {
    return @floatCast(try self.toF64());
}

pub fn toF64(self: Value) !f64 {
    var maybe: v8.MaybeF64 = undefined;
    v8.v8__Value__NumberValue(self.handle, self.local.handle, &maybe);
    if (!maybe.has_value) {
        return error.JsException;
    }
    return maybe.value;
}

pub fn toI32(self: Value) !i32 {
    var maybe: v8.MaybeI32 = undefined;
    v8.v8__Value__Int32Value(self.handle, self.local.handle, &maybe);
    if (!maybe.has_value) {
        return error.JsException;
    }
    return maybe.value;
}

pub fn toU32(self: Value) !u32 {
    var maybe: v8.MaybeU32 = undefined;
    v8.v8__Value__Uint32Value(self.handle, self.local.handle, &maybe);
    if (!maybe.has_value) {
        return error.JsException;
    }
    return maybe.value;
}

pub fn toPromise(self: Value) js.Promise {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isPromise());
    }
    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toString(self: Value) !js.String {
    const l = self.local;
    const value_handle: *const v8.Value = blk: {
        if (self.isSymbol()) {
            break :blk @ptrCast(v8.v8__Symbol__Description(@ptrCast(self.handle), l.isolate.handle).?);
        }
        break :blk self.handle;
    };

    const str_handle = v8.v8__Value__ToString(value_handle, l.handle) orelse return error.JsException;
    return .{ .local = self.local, .handle = str_handle };
}

pub fn toSSO(self: Value, comptime global: bool) !(if (global) lp.String.Global else lp.String) {
    return (try self.toString()).toSSO(global);
}
pub fn toSSOWithAlloc(self: Value, allocator: Allocator) !lp.String {
    return (try self.toString()).toSSOWithAlloc(allocator);
}

pub fn toStringSlice(self: Value) ![]u8 {
    return (try self.toString()).toSlice();
}
pub fn toStringSliceZ(self: Value) ![:0]u8 {
    return (try self.toString()).toSliceZ();
}
pub fn toStringSliceWithAlloc(self: Value, allocator: Allocator) ![]u8 {
    return (try self.toString()).toSliceWithAlloc(allocator);
}

pub fn toJson(self: Value, allocator: Allocator) ![]u8 {
    const local = self.local;
    const str_handle = v8.v8__JSON__Stringify(local.handle, self.handle, null) orelse return error.JsException;
    return js.String.toSliceWithAlloc(.{ .local = local, .handle = str_handle }, allocator);
}

pub fn jsonStringify(self: Value, jws: anytype) !void {
    const local = self.local;
    const v = self.toJson(local.call_arena) catch return error.WriteFailed;
    // V8's JSON::Stringify finishes by calling Object::ToString on whatever
    // i::JsonStringify returns. For values that JSON.stringify treats as
    // non-serializable at the top level (undefined, functions, symbols),
    // i::JsonStringify yields the undefined sentinel, and ToString coerces
    // it to the JS string "undefined". Writing those 9 bytes raw embeds a
    // bare `undefined` token into the JSON stream — invalid per RFC 8259.
    // Map that case to `null`, matching what JSON.stringify emits when an
    // unserializable value sits in an array slot.
    if (std.mem.eql(u8, v, "undefined")) {
        return jws.write(null);
    }
    jws.beginWriteRaw() catch return error.WriteFailed;
    jws.writer.writeAll(v) catch return error.WriteFailed;
    jws.endWriteRaw();
}

const MessagePort = @import("../webapi/MessagePort.zig");

const ArrayBufferTransfer = struct {
    value: Value,
    transfer_index: usize,
    destination: ?*const v8.ArrayBuffer = null,
};

const MessagePortTransfer = struct {
    source: *MessagePort,
    transfer_index: usize,
    destination: ?*MessagePort = null,
    used_in_value: bool = false,
};

const TransferPlan = struct {
    array_buffers: std.ArrayListUnmanaged(ArrayBufferTransfer) = .empty,
    message_ports: std.ArrayListUnmanaged(MessagePortTransfer) = .empty,

    fn extract(
        self: *TransferPlan,
        values: []const Value,
        owner: Value,
        exec: *js.Execution,
        exception_prefix: []const u8,
    ) !void {
        for (values, 0..) |value, transfer_index| {
            if (value.isArrayBuffer()) {
                for (self.array_buffers.items) |earlier| {
                    if (v8.v8__Value__StrictEquals(value.handle, earlier.value.handle)) {
                        const reason = try std.fmt.allocPrint(
                            exec.call_arena,
                            "ArrayBuffer at index {d} is a duplicate of an earlier ArrayBuffer.",
                            .{transfer_index},
                        );
                        return owner.structuredCloneDataError(exception_prefix, reason);
                    }
                }
                try self.array_buffers.append(exec.call_arena, .{
                    .value = value,
                    .transfer_index = transfer_index,
                });
                continue;
            }

            // A SharedArrayBuffer is recognized as a transferable candidate by
            // Blink, then rejected by PrepareTransfer with this dedicated text.
            if (value.isSharedArrayBuffer()) {
                return owner.structuredCloneDataError(
                    exception_prefix,
                    "SharedArrayBuffer can not be in transfer list.",
                );
            }

            const maybe_port: ?*MessagePort = value.toZig(*MessagePort) catch null;
            if (maybe_port) |port| {
                for (self.message_ports.items) |earlier| {
                    if (earlier.source == port) {
                        const reason = try std.fmt.allocPrint(
                            exec.call_arena,
                            "Message port at index {d} is a duplicate of an earlier port.",
                            .{transfer_index},
                        );
                        return owner.structuredCloneDataError(exception_prefix, reason);
                    }
                }
                try self.message_ports.append(exec.call_arena, .{
                    .source = port,
                    .transfer_index = transfer_index,
                });
                continue;
            }

            const reason = try std.fmt.allocPrint(
                exec.call_arena,
                "Value at index {d} does not have a transferable type.",
                .{transfer_index},
            );
            return owner.structuredCloneDataError(exception_prefix, reason);
        }
    }

    fn finalizeArrayBuffers(
        self: *TransferPlan,
        owner: Value,
        exec: *js.Execution,
        exception_prefix: []const u8,
        operation: js.WebIDL.Operation,
    ) !void {
        // Blink first checks every entry for an already-detached buffer.  This
        // happens after WriteValue, so user getters still run before the error.
        for (self.array_buffers.items) |entry| {
            const source: *const v8.ArrayBuffer = @ptrCast(entry.value.handle);
            if (v8.v8__ArrayBuffer__WasDetached(source)) {
                const reason = try std.fmt.allocPrint(
                    exec.call_arena,
                    "ArrayBuffer at index {d} is already detached.",
                    .{entry.transfer_index},
                );
                return owner.structuredCloneDataError(exception_prefix, reason);
            }
        }

        for (self.array_buffers.items) |*entry| {
            const source: *const v8.ArrayBuffer = @ptrCast(entry.value.handle);
            if (!v8.v8__ArrayBuffer__IsDetachable(source)) {
                const reason = try std.fmt.allocPrint(
                    exec.call_arena,
                    "ArrayBuffer at index {d} is not detachable and could not be transferred.",
                    .{entry.transfer_index},
                );
                return js.WebIDL.typeError(exec, operation, reason);
            }

            var backing_store = v8.v8__ArrayBuffer__GetBackingStore(source);
            defer v8.std__shared_ptr__v8__BackingStore__reset(&backing_store);

            var detached: v8.MaybeBool = undefined;
            v8.v8__ArrayBuffer__Detach(source, &detached);
            if (!detached.has_value or !detached.value) {
                return error.TryCatchRethrow;
            }

            entry.destination = v8.v8__ArrayBuffer__New2(
                owner.local.isolate.handle,
                &backing_store,
            ) orelse return error.OutOfMemory;
        }
    }

    fn commitMessagePorts(
        self: *TransferPlan,
        owner: Value,
        exec: *js.Execution,
        exception_prefix: []const u8,
    ) !void {
        // DisentanglePorts validates the whole list before moving any channel.
        for (self.message_ports.items) |entry| {
            if (entry.source.isNeutered()) {
                const reason = try std.fmt.allocPrint(
                    exec.call_arena,
                    "Port at index {d} is already neutered.",
                    .{entry.transfer_index},
                );
                return owner.structuredCloneDataError(exception_prefix, reason);
            }
        }
        for (self.message_ports.items) |*entry| {
            entry.destination = try entry.source.transferTo(exec);
        }
    }

    fn closeDestinations(self: *TransferPlan, only_unused: bool) void {
        for (self.message_ports.items) |entry| {
            if (entry.destination) |port| {
                if (!only_unused or !entry.used_in_value) port.close();
            }
        }
    }
};

fn structuredCloneInterface(self: Value) []const u8 {
    return switch (self.local.ctx.global) {
        .frame => "Window",
        .worker => "WorkerGlobalScope",
    };
}

fn structuredClonePrefix(self: Value) []const u8 {
    return switch (self.local.ctx.global) {
        .frame => "Failed to execute 'structuredClone' on 'Window': ",
        .worker => "Failed to execute 'structuredClone' on 'WorkerGlobalScope': ",
    };
}

fn structuredCloneDataError(self: Value, prefix: []const u8, reason: []const u8) anyerror {
    CloneDelegate.throwDataCloneException(self.local, reason, prefix);
    return error.TryCatchRethrow;
}

fn structuredCloneSequenceTypeError(
    exec: *js.Execution,
    operation: js.WebIDL.Operation,
    reason: []const u8,
) anyerror {
    const local = exec.js.local orelse return error.TypeError;
    const exception = local.isolate.createTypeError(reason);

    // Blink's generated nested converter materializes Error.stack with only
    // the innermost reason, then replaces Error.message with both the operation
    // and dictionary-member contexts.
    const stack_key = local.isolate.initStringHandle("stack");
    _ = v8.v8__Object__Get(@ptrCast(exception), local.handle, stack_key);

    const message = try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '{s}' on '{s}': Failed to read the 'transfer' property from 'StructuredSerializeOptions': {s}",
        .{ operation.name, operation.interface, reason },
    );
    const message_key = local.isolate.initStringHandle("message");
    const message_value = local.isolate.initStringHandle(message);
    var defined: v8.MaybeBool = undefined;
    v8.v8__Object__DefineOwnProperty(
        @ptrCast(exception),
        local.handle,
        @ptrCast(message_key),
        @ptrCast(message_value),
        v8.None,
        &defined,
    );
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

fn structuredCloneTransferSequence(
    raw: Value,
    exec: *js.Execution,
    operation: js.WebIDL.Operation,
) ![]const Value {
    if (raw.isUndefined()) return &.{};
    if (!raw.isObject()) {
        return structuredCloneSequenceTypeError(
            exec,
            operation,
            "The provided value cannot be converted to a sequence.",
        );
    }

    const iterable = raw.toObject();
    const local = raw.local;
    const iterator_symbol = v8.v8__Symbol__GetIterator(local.isolate.handle);
    const method_handle = v8.v8__Object__Get(
        iterable.handle,
        local.handle,
        @ptrCast(iterator_symbol),
    ) orelse return error.TryCatchRethrow;
    const method = Value{ .local = local, .handle = method_handle };
    if (!method.isFunction()) {
        return structuredCloneSequenceTypeError(
            exec,
            operation,
            "The object must have a callable @@iterator property.",
        );
    }

    const iterator_fn = js.Function{ .local = local, .handle = @ptrCast(method.handle) };
    const bound_iterator_fn = try iterator_fn.withThis(iterable);
    const iterator_value = try bound_iterator_fn.callRethrow(Value, .{});
    if (!iterator_value.isObject()) {
        return structuredCloneSequenceTypeError(
            exec,
            operation,
            "Iterator object must be an object.",
        );
    }
    const iterator = iterator_value.toObject();

    const next_value = iterator.get("next") catch return error.TryCatchRethrow;
    if (!next_value.isFunction()) {
        return structuredCloneSequenceTypeError(
            exec,
            operation,
            "Expected next() function on iterator.",
        );
    }
    const next = js.Function{ .local = local, .handle = @ptrCast(next_value.handle) };
    const bound_next = try next.withThis(iterator);

    var items: std.ArrayListUnmanaged(Value) = .empty;
    while (true) {
        const result_value = try bound_next.callRethrow(Value, .{});
        if (!result_value.isObject()) {
            return structuredCloneSequenceTypeError(
                exec,
                operation,
                "Expected iterator.next() to return an Object.",
            );
        }
        const result = result_value.toObject();
        const done = result.get("done") catch return error.TryCatchRethrow;
        if (done.toBool()) break;
        const item = result.get("value") catch return error.TryCatchRethrow;
        if (!item.isObject()) {
            return structuredCloneSequenceTypeError(
                exec,
                operation,
                "Failed to convert value to 'object'.",
            );
        }
        try items.append(exec.call_arena, item);
    }
    return items.items;
}

// Clones host objects listed in cloneable_types and implements Blink's
// StructuredSerializeWithTransfer path for ArrayBuffer and MessagePort.
pub fn structuredClone(self: Value) !Value {
    const context_prefix = self.structuredClonePrefix();
    const serialized = try self.serializeWithContext(context_prefix);
    defer serialized.deinit();
    return deserialize(self.local, serialized.bytes());
}

pub fn structuredCloneWithOptions(
    self: Value,
    raw_options: ?Value,
    exec: *js.Execution,
) !Value {
    const interface = self.structuredCloneInterface();
    const operation: js.WebIDL.Operation = .{ .interface = interface, .name = "structuredClone" };
    const exception_prefix = self.structuredClonePrefix();

    const transfer_values: []const Value = blk: {
        const options = raw_options orelse break :blk &.{};
        if (options.isNullOrUndefined()) break :blk &.{};
        if (!options.isObject()) {
            return js.WebIDL.typeError(
                exec,
                operation,
                "The provided value is not of type 'StructuredSerializeOptions'.",
            );
        }
        const raw_transfer = options.toObject().get("transfer") catch
            return error.TryCatchRethrow;
        break :blk try structuredCloneTransferSequence(raw_transfer, exec, operation);
    };

    var plan: TransferPlan = .{};
    try plan.extract(transfer_values, self, exec, exception_prefix);

    const serialized = try self.serializeWithContextAndTransfers(
        exception_prefix,
        &plan,
        exec,
        operation,
    );
    defer serialized.deinit();

    try plan.commitMessagePorts(self, exec, exception_prefix);
    const cloned = deserializeWithTransfers(self.local, serialized.bytes(), &plan) catch |err| {
        plan.closeDestinations(false);
        return err;
    };
    plan.closeDestinations(true);
    return cloned;
}

// Clone a value to a different context (within the same isolate).
// Used for cross-context messaging (e.g., Worker <-> Page).
pub fn structuredCloneTo(self: Value, target: *const js.Local) !Value {
    const serialized = try self.serialize();
    defer serialized.deinit();
    return deserialize(target, serialized.bytes());
}

// A structured-serialized value: a V8-owned byte buffer. Caller must free it
// and must dupe the bytes if they want it to outlive the current local scope.
pub const Serialized = struct {
    data: [*c]u8,
    size: usize,

    pub fn bytes(self: Serialized) []const u8 {
        return self.data[0..self.size];
    }

    pub fn deinit(self: Serialized) void {
        v8.v8__ValueSerializer__FreeBuffer(self.data);
    }
};

// Thread-transferable structured-clone envelope. `bytes` is owned by V8's
// serializer allocator and each SharedPtr owns one reference to a shared SAB
// BackingStore. The envelope itself contains no isolate-local handles, so it
// may move through a synchronized DedicatedWorker mailbox.
pub const SerializedMessage = struct {
    data: [*c]u8,
    size: usize,
    shared_backing_stores: []v8.SharedPtr,
    allocator: std.mem.Allocator,

    pub fn bytes(self: *const SerializedMessage) []const u8 {
        return self.data[0..self.size];
    }

    pub fn deinit(self: *SerializedMessage) void {
        v8.v8__ValueSerializer__FreeBuffer(self.data);
        for (self.shared_backing_stores) |*store| {
            v8.std__shared_ptr__v8__BackingStore__reset(store);
        }
        self.allocator.free(self.shared_backing_stores);
        self.* = undefined;
    }
};

// Ref-counted, isolate-free BroadcastChannel payload. One immutable envelope
// may be queued to several agent mailboxes at once; each destination performs
// ValueDeserializer work only after entering its own isolate on its owner
// thread. SharedArrayBuffer backing stores remain shared through the retained
// std::shared_ptr entries in `serialized`.
pub const BroadcastMessage = struct {
    refs: std.atomic.Value(usize) = .init(1),
    serialized: SerializedMessage,
    name: []u8,
    origin: ?[]u8,
    post_sequence: u64,
    allocator: Allocator,

    // `serialized` is transferred to the result only on success. The caller
    // remains responsible for deinit if construction fails.
    pub fn create(
        allocator: Allocator,
        serialized: SerializedMessage,
        name: []const u8,
        origin: ?[]const u8,
        post_sequence: u64,
    ) !*BroadcastMessage {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const owned_origin = if (origin) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_origin) |value| allocator.free(value);

        const self = try allocator.create(BroadcastMessage);
        self.* = .{
            .serialized = serialized,
            .name = owned_name,
            .origin = owned_origin,
            .post_sequence = post_sequence,
            .allocator = allocator,
        };
        return self;
    }

    pub fn retain(self: *BroadcastMessage) void {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0);
    }

    pub fn release(self: *BroadcastMessage) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;

        self.serialized.deinit();
        self.allocator.free(self.name);
        if (self.origin) |origin| self.allocator.free(origin);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

// Serialize `self` into a V8-owned buffer. The caller must call deinit on the
// result. Raises a JS exception (DataCloneError) for unserializable values.
pub fn serialize(self: Value) !Serialized {
    return self.serializeWithContext(null);
}

// Web APIs such as IndexedDB perform structured serialization as part of a
// named operation. Blink prefixes the serializer's DataCloneError reason with
// that Web IDL operation, while the underlying clone format stays identical.
pub fn serializeWithPrefix(self: Value, exception_prefix: []const u8) !Serialized {
    return self.serializeWithContext(exception_prefix);
}

fn serializeWithContext(self: Value, exception_prefix: ?[]const u8) !Serialized {
    return self.serializeWithContextAndTransfers(
        exception_prefix,
        null,
        null,
        null,
    );
}

fn serializeWithContextAndTransfers(
    self: Value,
    exception_prefix: ?[]const u8,
    transfer_plan: ?*TransferPlan,
    exec: ?*js.Execution,
    operation: ?js.WebIDL.Operation,
) !Serialized {
    var delegate_ctx = CloneDelegate.SerializeContext{
        .local = self.local,
        .serializer = undefined,
        .shared_backing_stores = null,
        .shared_allocator = undefined,
        .exception_prefix = exception_prefix,
        .transfer_ports = if (transfer_plan) |plan| plan.message_ports.items else null,
    };
    const serializer = v8.v8__ValueSerializer__New(self.local.isolate.handle, &.{
        .data = &delegate_ctx,
        .get_shared_array_buffer_id = CloneDelegate.getSharedArrayBufferId,
        .write_host_object = CloneDelegate.writeHostObject,
        .throw_data_clone_error = CloneDelegate.throwDataCloneError,
    }) orelse return error.JsException;
    defer v8.v8__ValueSerializer__DELETE(serializer);

    // the delegate callbacks only fire during WriteValue, after this is set
    delegate_ctx.serializer = serializer;

    v8.v8__ValueSerializer__WriteHeader(serializer);
    if (transfer_plan) |plan| {
        for (plan.array_buffers.items, 0..) |entry, transfer_id| {
            v8.v8__ValueSerializer__TransferArrayBuffer(
                serializer,
                @intCast(transfer_id),
                @ptrCast(entry.value.handle),
            );
        }
    }

    var write_result: v8.MaybeBool = undefined;
    v8.v8__ValueSerializer__WriteValue(serializer, self.local.handle, self.handle, &write_result);
    if (!write_result.has_value or !write_result.value) {
        return error.JsException;
    }

    if (transfer_plan) |plan| {
        try plan.finalizeArrayBuffers(
            self,
            exec.?,
            exception_prefix.?,
            operation.?,
        );
    }

    var size: usize = undefined;
    const data = v8.v8__ValueSerializer__Release(serializer, &size) orelse return error.JsException;
    return .{ .data = data, .size = size };
}

// Serialize for a cross-isolate postMessage. SharedArrayBuffer objects are
// represented by stable clone IDs and retained std::shared_ptr<BackingStore>
// references in the envelope; ordinary ArrayBuffers remain byte-cloned by V8.
pub fn serializeForMessage(self: Value, allocator: std.mem.Allocator) !SerializedMessage {
    return self.serializeForMessageWithContext(allocator, null);
}

pub fn serializeForMessageWithContext(
    self: Value,
    allocator: std.mem.Allocator,
    exception_prefix: ?[]const u8,
) !SerializedMessage {
    var stores: std.ArrayList(v8.SharedPtr) = .empty;
    errdefer {
        for (stores.items) |*store| {
            v8.std__shared_ptr__v8__BackingStore__reset(store);
        }
        stores.deinit(allocator);
    }

    var delegate_ctx = CloneDelegate.SerializeContext{
        .local = self.local,
        .serializer = undefined,
        .shared_backing_stores = &stores,
        .shared_allocator = allocator,
        .exception_prefix = exception_prefix,
        .transfer_ports = null,
    };
    const serializer = v8.v8__ValueSerializer__New(self.local.isolate.handle, &.{
        .data = &delegate_ctx,
        .get_shared_array_buffer_id = CloneDelegate.getSharedArrayBufferId,
        .write_host_object = CloneDelegate.writeHostObject,
        .throw_data_clone_error = CloneDelegate.throwDataCloneError,
    }) orelse return error.JsException;
    defer v8.v8__ValueSerializer__DELETE(serializer);
    delegate_ctx.serializer = serializer;

    var write_result: v8.MaybeBool = undefined;
    v8.v8__ValueSerializer__WriteHeader(serializer);
    v8.v8__ValueSerializer__WriteValue(serializer, self.local.handle, self.handle, &write_result);
    if (!write_result.has_value or !write_result.value) return error.JsException;

    var size: usize = undefined;
    const data = v8.v8__ValueSerializer__Release(serializer, &size) orelse return error.JsException;
    return .{
        .data = data,
        .size = size,
        .shared_backing_stores = try stores.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// Deserialize a structured-serialized buffer (from `serialize`) into a value in
// `local`'s context. A malformed buffer surfaces as error.JsException.
pub fn deserialize(local: *const js.Local, bytes: []const u8) !Value {
    return deserializeWithTransfers(local, bytes, null);
}

fn deserializeWithTransfers(
    local: *const js.Local,
    bytes: []const u8,
    transfer_plan: ?*TransferPlan,
) !Value {
    var delegate_ctx = CloneDelegate.DeserializeContext{
        .local = local,
        .deserializer = undefined,
        .shared_backing_stores = &.{},
        .transfer_ports = if (transfer_plan) |plan| plan.message_ports.items else null,
    };
    const deserializer = v8.v8__ValueDeserializer__New(local.isolate.handle, bytes.ptr, bytes.len, &.{
        .data = &delegate_ctx,
        .read_host_object = CloneDelegate.readHostObject,
    }) orelse return error.JsException;
    defer v8.v8__ValueDeserializer__DELETE(deserializer);
    delegate_ctx.deserializer = deserializer;

    var read_header_result: v8.MaybeBool = undefined;
    v8.v8__ValueDeserializer__ReadHeader(deserializer, local.handle, &read_header_result);
    if (!read_header_result.has_value or !read_header_result.value) {
        return error.JsException;
    }

    if (transfer_plan) |plan| {
        for (plan.array_buffers.items, 0..) |entry, transfer_id| {
            v8.v8__ValueDeserializer__TransferArrayBuffer(
                deserializer,
                @intCast(transfer_id),
                entry.destination orelse return error.DataClone,
            );
        }
    }

    const handle = v8.v8__ValueDeserializer__ReadValue(deserializer, local.handle) orelse return error.JsException;
    return .{ .local = local, .handle = handle };
}

pub fn deserializeMessage(local: *const js.Local, message: *const SerializedMessage) !Value {
    var delegate_ctx = CloneDelegate.DeserializeContext{
        .local = local,
        .deserializer = undefined,
        .shared_backing_stores = message.shared_backing_stores,
        .transfer_ports = null,
    };
    const deserializer = v8.v8__ValueDeserializer__New(
        local.isolate.handle,
        message.data,
        message.size,
        &.{
            .data = &delegate_ctx,
            .read_host_object = CloneDelegate.readHostObject,
            .get_shared_array_buffer_from_id = CloneDelegate.getSharedArrayBufferFromId,
        },
    ) orelse return error.JsException;
    defer v8.v8__ValueDeserializer__DELETE(deserializer);
    delegate_ctx.deserializer = deserializer;

    var read_header_result: v8.MaybeBool = undefined;
    v8.v8__ValueDeserializer__ReadHeader(deserializer, local.handle, &read_header_result);
    if (!read_header_result.has_value or !read_header_result.value) return error.JsException;

    const handle = v8.v8__ValueDeserializer__ReadValue(deserializer, local.handle) orelse
        return error.JsException;
    return .{ .local = local, .handle = handle };
}

// Host object types that support structured cloning via structuredSerialize /
// structuredDeserialize hooks. The serialized payload tags each host object
// with its position in this list; buffers never outlive the process, so the
// order only has to be consistent within a build.
const cloneable_types = .{
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/FileList.zig"),
    @import("../webapi/ImageData.zig"),
    @import("../webapi/DOMPointReadOnly.zig"),
    @import("../webapi/DOMPoint.zig"),
};

// Passed to a type's structuredSerialize hook to write its payload into the
// V8 serialization buffer.
pub const StructuredWriter = struct {
    local: *const js.Local,
    serializer: *v8.ValueSerializer,

    pub fn writeUint32(self: *const StructuredWriter, value: u32) void {
        v8.v8__ValueSerializer__WriteUint32(self.serializer, value);
    }

    pub fn writeUint64(self: *const StructuredWriter, value: u64) void {
        v8.v8__ValueSerializer__WriteUint64(self.serializer, value);
    }

    pub fn writeBytes(self: *const StructuredWriter, bytes: []const u8) void {
        v8.v8__ValueSerializer__WriteUint32(self.serializer, @intCast(bytes.len));
        if (bytes.len > 0) {
            v8.v8__ValueSerializer__WriteRawBytes(self.serializer, bytes.ptr, bytes.len);
        }
    }
};

// Passed to a type's structuredDeserialize hook to read back the payload its
// structuredSerialize hook wrote.
pub const StructuredReader = struct {
    local: *const js.Local,
    deserializer: *v8.ValueDeserializer,

    pub fn readUint32(self: *const StructuredReader) !u32 {
        var out: u32 = undefined;
        if (!v8.v8__ValueDeserializer__ReadUint32(self.deserializer, &out)) {
            return error.DataClone;
        }
        return out;
    }

    pub fn readUint64(self: *const StructuredReader) !u64 {
        var out: u64 = undefined;
        if (!v8.v8__ValueDeserializer__ReadUint64(self.deserializer, &out)) {
            return error.DataClone;
        }
        return out;
    }

    // The returned slice points into the serialization buffer; dupe anything
    // that must outlive deserialization.
    pub fn readBytes(self: *const StructuredReader) ![]const u8 {
        const len = try self.readUint32();
        if (len == 0) {
            return "";
        }
        var ptr: ?*const anyopaque = null;
        if (!v8.v8__ValueDeserializer__ReadRawBytes(self.deserializer, len, &ptr)) {
            return error.DataClone;
        }
        return @as([*]const u8, @ptrCast(ptr.?))[0..len];
    }
};

const CloneDelegate = struct {
    const transferred_message_port_tag: u32 = std.math.maxInt(u32);

    const SerializeContext = struct {
        local: *const js.Local,
        serializer: *v8.ValueSerializer,
        shared_backing_stores: ?*std.ArrayList(v8.SharedPtr),
        shared_allocator: std.mem.Allocator,
        exception_prefix: ?[]const u8,
        transfer_ports: ?[]MessagePortTransfer,
    };

    const DeserializeContext = struct {
        local: *const js.Local,
        deserializer: *v8.ValueDeserializer,
        shared_backing_stores: []const v8.SharedPtr,
        transfer_ports: ?[]MessagePortTransfer,
    };

    // Called when V8 encounters an object with embedder fields, i.e. one of
    // our wrapped Zig instances. Serialize it if its type (or a prototype)
    // is in cloneable_types, otherwise throw a DataCloneError. V8 asserts
    // has_exception() after a false return, so we must throw here.
    fn writeHostObject(data: ?*anyopaque, _: ?*v8.Isolate, object: ?*const v8.Object) callconv(.c) v8.MaybeBool {
        const ctx: *SerializeContext = @ptrCast(@alignCast(data.?));

        blk: {
            const obj = object orelse break :blk;
            if (v8.v8__Object__InternalFieldCount(obj) == 0) {
                break :blk;
            }
            const tao_ptr = v8.v8__Object__GetAlignedPointerFromInternalField(obj, 0) orelse break :blk;
            const tao: *TaggedOpaque = @ptrCast(@alignCast(tao_ptr));

            const prototype_chain = tao.prototype_chain[0..tao.prototype_len];

            if (prototype_chain[0].index == bridge.JsApiLookup.getId(MessagePort.JsApi)) {
                const port: *MessagePort = @ptrCast(@alignCast(tao.value));
                if (ctx.transfer_ports) |ports| {
                    for (ports, 0..) |*entry, transfer_id| {
                        if (entry.source == port) {
                            entry.used_in_value = true;
                            v8.v8__ValueSerializer__WriteUint32(
                                ctx.serializer,
                                transferred_message_port_tag,
                            );
                            v8.v8__ValueSerializer__WriteUint32(
                                ctx.serializer,
                                @intCast(transfer_id),
                            );
                            return .{ .has_value = true, .value = true };
                        }
                    }
                }
                throwDataCloneException(
                    ctx.local,
                    "A MessagePort could not be cloned because it was not transferred.",
                    ctx.exception_prefix,
                );
                return .{ .has_value = true, .value = false };
            }

            if (writeCloneable(ctx, prototype_chain[0].index, tao.value)) |result| {
                return result;
            }

            // Walk up the prototype chain so a subtype serializes as its
            // closest cloneable supertype (mirrors TaggedOpaque.fromJS).
            var ptr = @intFromPtr(tao.value);
            for (prototype_chain[1..]) |proto| {
                ptr += proto.offset;
                const proto_ptr: **anyopaque = @ptrFromInt(ptr);
                if (writeCloneable(ctx, proto.index, proto_ptr.*)) |result| {
                    return result;
                }
                ptr = @intFromPtr(proto_ptr.*);
            }
        }

        throwDataCloneException(
            ctx.local,
            uncloneableHostObjectMessage(ctx.local, object),
            ctx.exception_prefix,
        );
        return .{ .has_value = true, .value = false };
    }

    fn uncloneableHostObjectMessage(local: *const js.Local, object: ?*const v8.Object) ?[]const u8 {
        const handle = object orelse return null;
        if (v8.v8__Object__InternalFieldCount(handle) == 0) return null;
        const tao_ptr = v8.v8__Object__GetAlignedPointerFromInternalField(handle, 0) orelse return null;
        const tao: *const TaggedOpaque = @ptrCast(@alignCast(tao_ptr));
        if (tao.prototype_len == 0) return null;
        const type_index = tao.prototype_chain[0].index;

        inline for (bridge.JsApis, 0..) |Api, i| {
            if (type_index == i) {
                if (comptime @hasDecl(Api.Meta, "name")) {
                    const name = Api.Meta.name;
                    // A WindowProxy is reported by Blink/V8 as the Window global,
                    // including when DarkPanda represents cross-origin access with
                    // its host-side wrapper.
                    if (comptime std.mem.eql(u8, name, "Window") or
                        std.mem.eql(u8, name, "CrossOriginWindow"))
                    {
                        return "#<Window> could not be cloned.";
                    }
                    if (comptime @hasDecl(Api.Meta, "global_scope") and Api.Meta.global_scope) {
                        return std.fmt.allocPrint(
                            local.ctx.arena,
                            "#<{s}> could not be cloned.",
                            .{name},
                        ) catch null;
                    }
                    return std.fmt.allocPrint(
                        local.ctx.arena,
                        "{s} object could not be cloned.",
                        .{name},
                    ) catch null;
                }
                return null;
            }
        }
        return null;
    }

    fn writeCloneable(
        ctx: *SerializeContext,
        type_index: bridge.JsApiLookup.BackingInt,
        value_ptr: *anyopaque,
    ) ?v8.MaybeBool {
        inline for (cloneable_types, 0..) |T, tag| {
            if (type_index == bridge.JsApiLookup.getId(T.JsApi)) {
                v8.v8__ValueSerializer__WriteUint32(ctx.serializer, tag);
                var writer = StructuredWriter{ .local = ctx.local, .serializer = ctx.serializer };
                const instance: *const T = @ptrCast(@alignCast(value_ptr));
                instance.structuredSerialize(&writer) catch {
                    throwDataCloneException(ctx.local, null, ctx.exception_prefix);
                    return .{ .has_value = true, .value = false };
                };
                return .{ .has_value = true, .value = true };
            }
        }
        return null;
    }

    // Called by V8 to read back what writeHostObject wrote. Returning null
    // aborts deserialization, so we throw first to surface a proper error.
    fn readHostObject(data: ?*anyopaque, _: ?*v8.Isolate) callconv(.c) ?*const v8.Object {
        const ctx: *DeserializeContext = @ptrCast(@alignCast(data.?));
        const local = ctx.local;

        var tag: u32 = undefined;
        if (v8.v8__ValueDeserializer__ReadUint32(ctx.deserializer, &tag)) {
            if (tag == transferred_message_port_tag) {
                var transfer_id: u32 = undefined;
                if (!v8.v8__ValueDeserializer__ReadUint32(ctx.deserializer, &transfer_id)) {
                    throwDataCloneException(local, null, null);
                    return null;
                }
                const ports = ctx.transfer_ports orelse {
                    throwDataCloneException(local, null, null);
                    return null;
                };
                if (transfer_id >= ports.len) {
                    throwDataCloneException(local, null, null);
                    return null;
                }
                const destination = ports[transfer_id].destination orelse {
                    throwDataCloneException(local, null, null);
                    return null;
                };
                const js_obj = local.mapZigInstanceToJs(null, destination) catch {
                    throwDataCloneException(local, null, null);
                    return null;
                };
                return js_obj.handle;
            }

            var reader = StructuredReader{ .local = local, .deserializer = ctx.deserializer };
            inline for (cloneable_types, 0..) |T, i| {
                if (tag == i) {
                    return readCloneable(T, &reader) orelse {
                        throwDataCloneException(local, null, null);
                        return null;
                    };
                }
            }
        }

        throwDataCloneException(local, null, null);
        return null;
    }

    fn readCloneable(comptime T: type, reader: *StructuredReader) ?*const v8.Object {
        const local = reader.local;
        const instance = T.structuredDeserialize(reader, local.ctx.page) catch return null;
        const js_obj = local.mapZigInstanceToJs(null, instance) catch return null;
        return js_obj.handle;
    }

    // Called by V8 when a built-in can't be serialized (e.g. an out-of-bounds
    // TypedArray). The delegate is responsible for actually throwing.
    fn throwDataCloneError(data: ?*anyopaque, message: ?*const v8.String) callconv(.c) void {
        const ctx: *SerializeContext = @ptrCast(@alignCast(data.?));
        const local = ctx.local;
        const msg: ?[]const u8 = blk: {
            const handle = message orelse break :blk null;
            const str = js.String{ .local = local, .handle = handle };
            // the exception can outlive this call; dupe onto the context arena
            break :blk str.toSliceWithAlloc(local.ctx.arena) catch null;
        };
        throwDataCloneException(local, msg, ctx.exception_prefix);
    }

    // Cross-isolate postMessage retains the exact BackingStore. Plain
    // structuredClone keeps its historical DataCloneError behavior because it
    // has no cross-agent envelope in which to own the shared_ptr reference.
    fn getSharedArrayBufferId(data: ?*anyopaque, _: ?*v8.Isolate, sab_: ?*const v8.SharedArrayBuffer, id_out: ?*u32) callconv(.c) bool {
        const ctx: *SerializeContext = @ptrCast(@alignCast(data.?));
        const stores = ctx.shared_backing_stores orelse {
            throwDataCloneException(
                ctx.local,
                "SharedArrayBuffer transfer requires self.crossOriginIsolated.",
                ctx.exception_prefix,
            );
            return false;
        };
        const sab = sab_ orelse return false;
        const output = id_out orelse return false;
        var store = v8.v8__SharedArrayBuffer__GetBackingStore(sab);
        stores.append(ctx.shared_allocator, store) catch {
            v8.std__shared_ptr__v8__BackingStore__reset(&store);
            throwDataCloneException(ctx.local, "SharedArrayBuffer clone allocation failed", ctx.exception_prefix);
            return false;
        };
        output.* = @intCast(stores.items.len - 1);
        return true;
    }

    fn getSharedArrayBufferFromId(data: ?*anyopaque, isolate_: ?*v8.Isolate, id: u32) callconv(.c) ?*const v8.SharedArrayBuffer {
        const ctx: *DeserializeContext = @ptrCast(@alignCast(data.?));
        const isolate = isolate_ orelse return null;
        if (id >= ctx.shared_backing_stores.len) return null;
        return v8.v8__SharedArrayBuffer__New2(isolate, &ctx.shared_backing_stores[id]);
    }

    fn throwDataCloneException(
        local: *const js.Local,
        message: ?[]const u8,
        exception_prefix: ?[]const u8,
    ) void {
        const DOMException = @import("../webapi/DOMException.zig");
        const isolate = local.isolate;
        const final_message = if (exception_prefix) |prefix|
            std.fmt.allocPrint(
                local.ctx.arena,
                "{s}{s}",
                .{ prefix, message orelse "The object can not be cloned" },
            ) catch message
        else
            message;
        const js_value = local.zigValueToJs(DOMException.init(final_message, "DataCloneError"), .{}) catch {
            const str = v8.v8__String__NewFromUtf8(isolate.handle, "The object can not be cloned", v8.kNormal, -1);
            const error_value = v8.v8__Exception__Error(str) orelse return;
            _ = v8.v8__Isolate__ThrowException(isolate.handle, error_value);
            return;
        };
        _ = v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(js_value.handle));
        _ = isolate.throwException(js_value.handle);
    }
};

pub fn persist(self: Value) !Global {
    return .{ .slot = try js.newTrackedSlot(self.local.ctx, self.handle) };
}

// like persist, but not tracked by the page. Caller takes responsibility for
// resetting and freeing the allocation.
pub fn persistBare(self: Value, arena: std.mem.Allocator) !*js.GlobalSlot {
    const slot = try arena.create(js.GlobalSlot);
    var global: v8.Global = undefined;
    v8.v8__Global__New(self.local.ctx.isolate.handle, self.handle, &global);
    slot.* = .{ .handle = global, .tracker = null, .gindex = undefined };
    return slot;
}

pub fn toZig(self: Value, comptime T: type) !T {
    return self.local.jsValueToZig(T, self);
}

pub fn toObject(self: Value) js.Object {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isObject());
    }

    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toArray(self: Value) js.Array {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isArray());
    }

    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toBigInt(self: Value) js.BigInt {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isBigInt());
    }

    return .{
        .handle = @ptrCast(self.handle),
    };
}

pub fn format(self: Value, writer: *std.Io.Writer) !void {
    if (comptime IS_DEBUG) {
        return self.local.debugValue(self, writer);
    }
    const js_str = self.toString() catch return error.WriteFailed;
    return js_str.format(writer);
}

// Copyable handle to our v8::Global wrapper so that releasing a copy resets
// the underlying v8::Global
pub const Global = struct {
    slot: *js.GlobalSlot,

    pub fn deinit(self: Global) void {
        self.slot.release();
    }
    pub const release = deinit;

    pub fn local(self: Global, l: *const js.Local) Value {
        return .{
            .local = l,
            .handle = @ptrCast(v8.v8__Global__Get(&self.slot.handle, l.isolate.handle)),
        };
    }

    pub fn isEqual(self: Global, other: Value) bool {
        return v8.v8__Global__IsEqual(&self.slot.handle, other.handle);
    }
};

const testing = @import("../../testing.zig");
test "Value: persisted handle early-release swap-removes and fixes up indices" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const tracker = &frame.js.page.globals;
    const base = tracker.list.items.len;

    var a = try (try ls.local.exec("({a:1})", null)).persist();
    var b = try (try ls.local.exec("({b:2})", null)).persist();
    var c = try (try ls.local.exec("({c:3})", null)).persist();

    try testing.expectEqual(base + 3, tracker.list.items.len);
    try testing.expectEqual(base + 0, a.slot.gindex);
    try testing.expectEqual(base + 1, b.slot.gindex);
    try testing.expectEqual(base + 2, c.slot.gindex);

    // Release the middle one: the last live slot (c) must move into b's spot and
    // have its stored index rewritten to match, or a later release corrupts.
    b.deinit();
    try testing.expectEqual(base + 2, tracker.list.items.len);
    try testing.expectEqual(base + 1, c.slot.gindex);
    try testing.expectEqual(c.slot, tracker.list.items[base + 1]);
    try testing.expectEqual(a.slot, tracker.list.items[base + 0]);

    // a and c are still usable (right handle, not b's).
    try testing.expect(a.local(&ls.local).isObject());
    try testing.expect(c.local(&ls.local).isObject());

    // Release the remaining two via the moved indices — must not corrupt.
    a.deinit();
    try testing.expectEqual(base + 1, tracker.list.items.len);
    try testing.expectEqual(base + 0, c.slot.gindex);
    try testing.expectEqual(c.slot, tracker.list.items[base + 0]);

    c.deinit();
    try testing.expectEqual(base, tracker.list.items.len);
}

test "Value: jsonStringify maps unserializable JS values to null" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // V8::JSON::Stringify finishes with Object::ToString on whatever
    // i::JsonStringify returns. For values JSON.stringify treats as
    // non-serializable at the top level (undefined, functions, symbols),
    // i::JsonStringify yields the undefined sentinel, and ToString coerces
    // it to the JS string "undefined". Without the jsonStringify fix, those
    // 9 bytes get written raw and the produced JSON is invalid.
    const Wrapper = struct { v: Value };
    const cases = .{
        .{ .name = "undefined", .expr = "undefined" },
        .{ .name = "function", .expr = "(function(){})" },
        .{ .name = "symbol", .expr = "Symbol('s')" },
    };
    inline for (cases) |case| {
        const value = try ls.local.exec(case.expr, null);
        const out = try std.json.Stringify.valueAlloc(
            testing.allocator,
            Wrapper{ .v = value },
            .{},
        );
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, "{\"v\":null}", out);
    }

    // Values that DO serialize must pass through unchanged.
    const ok_cases = .{
        .{ .expr = "null", .expected = "{\"v\":null}" },
        .{ .expr = "42", .expected = "{\"v\":42}" },
        .{ .expr = "'hi'", .expected = "{\"v\":\"hi\"}" },
        .{ .expr = "true", .expected = "{\"v\":true}" },
        .{ .expr = "({a:1})", .expected = "{\"v\":{\"a\":1}}" },
        .{ .expr = "[undefined]", .expected = "{\"v\":[null]}" },
        .{ .expr = "({x:undefined})", .expected = "{\"v\":{}}" },
        // A string literally equal to "undefined" must keep its quotes.
        .{ .expr = "'undefined'", .expected = "{\"v\":\"undefined\"}" },
    };
    inline for (ok_cases) |case| {
        const value = try ls.local.exec(case.expr, null);
        const out = try std.json.Stringify.valueAlloc(
            testing.allocator,
            Wrapper{ .v = value },
            .{},
        );
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, case.expected, out);
    }
}
