// Copyright (C) 2026  Lightpanda (Selecy SAS)
//
// Shared Web IDL conversion helpers.  Blink creates conversion TypeErrors with
// a concise reason in Error.stack, then exposes the operation-qualified text
// through Error.message.  Keeping that behavior here prevents every Web API
// wrapper from growing a subtly different exception implementation.

const std = @import("std");
const js = @import("js.zig");

pub const Operation = struct {
    interface: []const u8,
    name: []const u8,
};

pub const Attribute = struct {
    interface: []const u8,
    name: []const u8,
};

pub const DictionaryMemberParent = union(enum) {
    operation: Operation,
    constructor: []const u8,
};

pub const DictionaryMember = struct {
    parent: DictionaryMemberParent,
    dictionary: []const u8,
    member: []const u8,
};

/// Context attached to a Web IDL conversion. Constructors, operations, and
/// attribute getters/setters use different Chrome message prefixes while
/// sharing the same compact native conversion reason in Error.stack.
pub const ConversionContext = union(enum) {
    operation: Operation,
    constructor: []const u8,
    attribute_get: Attribute,
    attribute_set: Attribute,
    dictionary_member: DictionaryMember,
};

fn fullConstructorMessage(exec: *js.Execution, interface: []const u8, reason: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        exec.call_arena,
        "Failed to construct '{s}': {s}",
        .{ interface, reason },
    );
}

fn fullMessage(exec: *js.Execution, operation: Operation, reason: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute '{s}' on '{s}': {s}",
        .{ operation.name, operation.interface, reason },
    );
}

fn fullAttributeGetMessage(exec: *js.Execution, attribute: Attribute, reason: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        exec.call_arena,
        "Failed to read the '{s}' property from '{s}': {s}",
        .{ attribute.name, attribute.interface, reason },
    );
}

fn fullAttributeSetMessage(exec: *js.Execution, attribute: Attribute, reason: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        exec.call_arena,
        "Failed to set the '{s}' property on '{s}': {s}",
        .{ attribute.name, attribute.interface, reason },
    );
}

fn contextualMessage(exec: *js.Execution, context: ConversionContext, reason: []const u8) ![]const u8 {
    return switch (context) {
        .operation => |operation| fullMessage(exec, operation, reason),
        .constructor => |interface| fullConstructorMessage(exec, interface, reason),
        .attribute_get => |attribute| fullAttributeGetMessage(exec, attribute, reason),
        .attribute_set => |attribute| fullAttributeSetMessage(exec, attribute, reason),
        .dictionary_member => |member| {
            const member_reason = try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to read the '{s}' property from '{s}': {s}",
                .{ member.member, member.dictionary, reason },
            );
            return switch (member.parent) {
                .operation => |operation| fullMessage(exec, operation, member_reason),
                .constructor => |interface| fullConstructorMessage(exec, interface, member_reason),
            };
        },
    };
}

fn operationContext(operation: ?Operation) ?ConversionContext {
    return if (operation) |value| .{ .operation = value } else null;
}

fn replaceMessage(local: *const js.Local, exception: *const js.v8.Value, message: []const u8) void {
    if (!js.v8.v8__Value__IsObject(exception)) return;
    const key = local.isolate.initStringHandle("message");
    const value = local.isolate.initStringHandle(message);
    var maybe_result: js.v8.MaybeBool = undefined;
    // Blink uses CreateDataProperty, not ordinary [[Set]].  Re-defining the
    // existing Error.message property with `None` makes the contextual own
    // property writable/enumerable/configurable, exactly like Chrome.
    js.v8.v8__Object__DefineOwnProperty(
        @ptrCast(exception),
        local.handle,
        @ptrCast(key),
        @ptrCast(value),
        js.v8.None,
        &maybe_result,
    );
}

// V8 formats Error.stack lazily from the current `message`. Blink exposes an
// operation-qualified Error.message while retaining the concise conversion
// reason in the first stack line. Materialize the native error stack before
// replacing `message` so subsequent reads observe that same split behavior.
fn materializeStack(local: *const js.Local, exception: *const js.v8.Value) void {
    if (!js.v8.v8__Value__IsObject(exception)) return;
    const key = local.isolate.initStringHandle("stack");
    _ = js.v8.v8__Object__Get(@ptrCast(exception), local.handle, key);
}

fn v8StringToOwned(
    allocator: std.mem.Allocator,
    isolate: *js.v8.Isolate,
    value: *const js.v8.String,
) ?[]u8 {
    const len = js.v8.v8__String__Utf8Length(value, isolate);
    if (len < 0) return null;
    const buffer = allocator.alloc(u8, @intCast(len)) catch return null;
    const written = js.v8.v8__String__WriteUtf8(
        value,
        isolate,
        buffer.ptr,
        buffer.len,
        js.v8.NO_NULL_TERMINATION | js.v8.REPLACE_INVALID_UTF8,
    );
    if (written > buffer.len) {
        allocator.free(buffer);
        return null;
    }
    return buffer[0..written];
}

/// V8 invokes this callback only for exceptions created while a native API
/// callback is active. Exceptions thrown by author code across a nested
/// C++ -> JavaScript boundary are deliberately excluded, which is the crucial
/// distinction that message-text heuristics cannot make.
pub fn exceptionPropagationCallback(
    isolate_or_null: ?*js.v8.Isolate,
    exception_or_null: ?*const js.v8.Object,
    interface_name_or_null: ?*const js.v8.String,
    property_name_or_null: ?*const js.v8.String,
    context_kind: js.v8.ExceptionContext,
) callconv(.c) void {
    const isolate = isolate_or_null orelse return;
    const exception = exception_or_null orelse return;
    const interface_name_value = interface_name_or_null orelse return;
    const property_name_value = property_name_or_null orelse return;
    const context = js.v8.v8__Isolate__GetCurrentContext(isolate) orelse return;
    const allocator = std.heap.page_allocator;

    const interface_name = v8StringToOwned(allocator, isolate, interface_name_value) orelse return;
    defer allocator.free(interface_name);
    const property_name_owned = v8StringToOwned(allocator, isolate, property_name_value) orelse return;
    defer allocator.free(property_name_owned);
    var property_name: []const u8 = property_name_owned;

    if (context_kind == js.v8.kExceptionContext_AttributeGet and std.mem.startsWith(u8, property_name, "get ")) {
        property_name = property_name[4..];
    } else if (context_kind == js.v8.kExceptionContext_AttributeSet and std.mem.startsWith(u8, property_name, "set ")) {
        property_name = property_name[4..];
    }

    const message_key = js.v8.v8__String__NewFromUtf8(isolate, "message", js.v8.kNormal, 7) orelse return;
    const reason_value = js.v8.v8__Object__Get(exception, context, message_key) orelse return;
    const reason_string = js.v8.v8__Value__ToString(reason_value, context) orelse return;
    const reason = v8StringToOwned(allocator, isolate, reason_string) orelse return;
    defer allocator.free(reason);

    // Materialize Error.stack before replacing the message so its first line
    // remains the compact native conversion reason, matching Blink.
    const stack_key = js.v8.v8__String__NewFromUtf8(isolate, "stack", js.v8.kNormal, 5) orelse return;
    _ = js.v8.v8__Object__Get(exception, context, stack_key);

    const full = switch (context_kind) {
        js.v8.kExceptionContext_Constructor => std.fmt.allocPrint(
            allocator,
            "Failed to construct '{s}': {s}",
            .{ property_name, reason },
        ),
        js.v8.kExceptionContext_Operation => std.fmt.allocPrint(
            allocator,
            "Failed to execute '{s}' on '{s}': {s}",
            .{ property_name, interface_name, reason },
        ),
        js.v8.kExceptionContext_AttributeGet => std.fmt.allocPrint(
            allocator,
            "Failed to read the '{s}' property from '{s}': {s}",
            .{ property_name, interface_name, reason },
        ),
        js.v8.kExceptionContext_AttributeSet => std.fmt.allocPrint(
            allocator,
            "Failed to set the '{s}' property on '{s}': {s}",
            .{ property_name, interface_name, reason },
        ),
        else => return,
    } catch return;
    defer allocator.free(full);

    const message_value = js.v8.v8__String__NewFromUtf8(
        isolate,
        full.ptr,
        js.v8.kNormal,
        @intCast(full.len),
    ) orelse return;
    var maybe_result: js.v8.MaybeBool = undefined;
    js.v8.v8__Object__DefineOwnProperty(
        exception,
        context,
        @ptrCast(message_key),
        @ptrCast(message_value),
        js.v8.None,
        &maybe_result,
    );
}

/// Throw a Blink-shaped Web IDL TypeError.  Supplying null intentionally
/// leaves Error.message unqualified (HTMLAllCollection's callable path is one
/// of the legacy bindings that does this).
pub fn typeError(exec: *js.Execution, operation: ?Operation, reason: []const u8) anyerror {
    _ = operation;
    const local = exec.js.local orelse return error.TypeError;
    const exception = local.isolate.createTypeError(reason);
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

pub fn requiredArgument(exec: *js.Execution, operation: Operation, required: usize, present: usize) anyerror {
    const reason = try std.fmt.allocPrint(
        exec.call_arena,
        "{d} argument{s} required, but only {d} present.",
        .{ required, if (required == 1) "" else "s", present },
    );
    return typeError(exec, operation, reason);
}

/// Blink's generated bindings pass the zero-based Web IDL argument index to
/// NativeValueTraits<T>::ArgumentValue.  Interface conversions that fail use
/// ExceptionMessages::ArgumentNotOfType before ExceptionState adds the
/// operation/constructor context.  Keep that formatting in the shared
/// conversion layer so every interface-typed parameter gets the same error.
pub fn argumentNotOfType(
    exec: *js.Execution,
    context: ?ConversionContext,
    argument_index: usize,
    expected_type: []const u8,
) anyerror {
    const reason = try std.fmt.allocPrint(
        exec.call_arena,
        "parameter {d} is not of type '{s}'.",
        .{ argument_index + 1, expected_type },
    );
    return conversionTypeError(exec, context, reason);
}

/// Promise-returning Web IDL operations reject with the same contextual
/// TypeError object that a synchronous binding would throw.  Materialize the
/// concise native stack before installing Blink's operation-qualified
/// `message`, matching `typeError` without leaving a pending exception.
pub fn rejectedTypeError(exec: *js.Execution, operation: Operation, reason: []const u8) !js.Promise {
    const local = exec.js.local orelse return error.TypeError;
    const exception = local.isolate.createTypeError(reason);
    materializeStack(local, exception);
    replaceMessage(local, exception, try fullMessage(exec, operation, reason));

    const resolver = local.createPromiseResolver();
    resolver.reject("WebIDL.rejectedTypeError", js.Value{
        .local = local,
        .handle = exception,
    });
    return resolver.promise();
}

/// Throw a constructor-qualified TypeError while retaining Blink's compact
/// reason in Error.stack.  Constructor bindings use this for diagnostics that
/// happen before argument conversion, such as invoking an interface object
/// without `new`.
pub fn constructorTypeError(exec: *js.Execution, interface: []const u8, reason: []const u8) anyerror {
    _ = interface;
    const local = exec.js.local orelse return error.TypeError;
    const exception = local.isolate.createTypeError(reason);
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

pub fn contextualTypeError(exec: *js.Execution, context: ConversionContext, reason: []const u8) anyerror {
    const local = exec.js.local orelse return error.TypeError;
    const native_reason = switch (context) {
        .dictionary_member => |member| try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to read the '{s}' property from '{s}': {s}",
            .{ member.member, member.dictionary, reason },
        ),
        else => reason,
    };
    const exception = local.isolate.createTypeError(native_reason);
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

/// V8's propagation callback decorates native conversion failures before they
/// reach this TryCatch. Authored exceptions bypass that callback and must be
/// rethrown byte-for-byte unchanged.
fn rethrowConversion(
    exec: *js.Execution,
    try_catch: *js.TryCatch,
    context: ?ConversionContext,
) anyerror {
    _ = exec;
    _ = context;
    try_catch.rethrow();
    return error.TryCatchRethrow;
}

fn conversionTypeError(exec: *js.Execution, context: ?ConversionContext, reason: []const u8) anyerror {
    if (context) |conversion_context| {
        return switch (conversion_context) {
            .operation => |operation| typeError(exec, operation, reason),
            .constructor => |interface| constructorTypeError(exec, interface, reason),
            .attribute_get, .attribute_set, .dictionary_member => contextualTypeError(exec, conversion_context, reason),
        };
    }
    return typeError(exec, null, reason);
}

/// Convert to the actual V8 string value. Callers that need UTF-16 code-unit
/// fidelity (for example TextEncoderStream's dangling-surrogate algorithm)
/// must not round-trip through UTF-8 first.
pub fn toDOMStringValue(value: js.Value, exec: *js.Execution, operation: ?Operation) !js.String {
    return toDOMStringValueWithContext(value, exec, operationContext(operation));
}

pub fn toDOMStringValueWithContext(value: js.Value, exec: *js.Execution, context: ?ConversionContext) !js.String {
    if (value.isSymbol()) {
        return conversionTypeError(exec, context, "Cannot convert a Symbol value to a string");
    }

    var try_catch: js.TryCatch = undefined;
    try_catch.init(value.local);
    defer try_catch.deinit();

    return value.toString() catch |err| {
        if (err == error.JsException and try_catch.hasCaught()) {
            return rethrowConversion(exec, &try_catch, context);
        }
        return err;
    };
}

pub fn toDOMString(value: js.Value, exec: *js.Execution, operation: ?Operation) ![]const u8 {
    return (try toDOMStringValue(value, exec, operation)).toSlice();
}

pub fn toDOMStringWithContext(value: js.Value, exec: *js.Execution, context: ?ConversionContext) ![]const u8 {
    return (try toDOMStringValueWithContext(value, exec, context)).toSlice();
}

pub fn toNumber(value: js.Value, exec: *js.Execution, operation: ?Operation) !f64 {
    return toNumberWithContext(value, exec, operationContext(operation));
}

/// Numeric Web IDL conversion used by the generic bridge. Preserve operation,
/// constructor and attribute context so native Symbol/BigInt conversion
/// failures expose Blink's qualified `message` while keeping V8's concise
/// first stack line.
pub fn toNumberWithContext(
    value: js.Value,
    exec: *js.Execution,
    context: ?ConversionContext,
) !f64 {
    if (value.isSymbol()) {
        return conversionTypeError(exec, context, "Cannot convert a Symbol value to a number");
    }
    if (value.isBigInt()) {
        return conversionTypeError(exec, context, "Cannot convert a BigInt value to a number");
    }

    var try_catch: js.TryCatch = undefined;
    try_catch.init(value.local);
    defer try_catch.deinit();

    return value.toF64() catch |err| {
        if (err == error.JsException and try_catch.hasCaught()) {
            return rethrowConversion(exec, &try_catch, context);
        }
        return err;
    };
}

/// Web IDL `long`: ToNumber, truncate, modulo 2^32, then interpret the result
/// as a signed 32-bit integer. NaN and infinities become zero.
pub fn toLong(value: js.Value, exec: *js.Execution, operation: ?Operation) !i32 {
    const number = try toNumber(value, exec, operation);
    if (!std.math.isFinite(number) or number == 0) return 0;

    const truncated = @trunc(number);
    var modulo = @mod(truncated, 4_294_967_296.0);
    if (modulo < 0) modulo += 4_294_967_296.0;
    if (modulo >= 2_147_483_648.0) modulo -= 4_294_967_296.0;
    return @intFromFloat(modulo);
}
