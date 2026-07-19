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

/// Context attached to a Web IDL conversion. Constructors, operations, and
/// attribute getters/setters use different Chrome message prefixes while
/// sharing the same compact native conversion reason in Error.stack.
pub const ConversionContext = union(enum) {
    operation: Operation,
    constructor: []const u8,
    attribute_get: Attribute,
    attribute_set: Attribute,
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

/// Throw a Blink-shaped Web IDL TypeError.  Supplying null intentionally
/// leaves Error.message unqualified (HTMLAllCollection's callable path is one
/// of the legacy bindings that does this).
pub fn typeError(exec: *js.Execution, operation: ?Operation, reason: []const u8) anyerror {
    const local = exec.js.local orelse return error.TypeError;
    const exception = local.isolate.createTypeError(reason);
    if (operation) |context| {
        materializeStack(local, exception);
        replaceMessage(local, exception, try fullMessage(exec, context, reason));
    }
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
    const local = exec.js.local orelse return error.TypeError;
    const exception = local.isolate.createTypeError(reason);
    materializeStack(local, exception);
    replaceMessage(local, exception, try fullConstructorMessage(exec, interface, reason));
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

pub fn contextualTypeError(exec: *js.Execution, context: ConversionContext, reason: []const u8) anyerror {
    const local = exec.js.local orelse return error.TypeError;
    const exception = local.isolate.createTypeError(reason);
    materializeStack(local, exception);
    replaceMessage(local, exception, try contextualMessage(exec, context, reason));
    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

fn isNativeConversionReason(reason: []const u8) bool {
    return std.mem.eql(u8, reason, "Cannot convert a Symbol value to a string") or
        std.mem.eql(u8, reason, "Cannot convert a Symbol value to a number") or
        std.mem.eql(u8, reason, "Cannot convert a BigInt value to a number") or
        std.mem.eql(u8, reason, "Cannot convert object to primitive value") or
        (std.mem.indexOf(
            u8,
            reason,
            " returned for property 'Symbol(Symbol.toPrimitive)' ",
        ) != null and std.mem.endsWith(u8, reason, " is not a function"));
}

fn messageConversionReason(message: []const u8) ?[]const u8 {
    const uncaught_type_error = "Uncaught TypeError: ";
    const reason = if (std.mem.startsWith(u8, message, uncaught_type_error))
        message[uncaught_type_error.len..]
    else
        message;
    return if (isNativeConversionReason(reason)) reason else null;
}

/// A V8 conversion can invoke user code before producing a Symbol/BigInt.  A
/// nested TryCatch lets us decorate only V8's standard conversion failures and
/// rethrow the original Error object, preserving its compact stack string.
fn rethrowConversion(
    exec: *js.Execution,
    try_catch: *js.TryCatch,
    context: ?ConversionContext,
) anyerror {
    if (context) |conversion_context| {
        if (try_catch.exceptionValue()) |exception| {
            if (try_catch.messageText(exec.call_arena)) |message| {
                if (messageConversionReason(message)) |reason| {
                    // TryCatch.caught obtains the stack before `message` is
                    // replaced, preserving Blink's concise first stack line.
                    _ = try_catch.caught(exec.call_arena);
                    replaceMessage(
                        exec.js.local.?,
                        exception.handle,
                        try contextualMessage(exec, conversion_context, reason),
                    );
                }
            }
        }
    }
    try_catch.rethrow();
    return error.TryCatchRethrow;
}

fn conversionTypeError(exec: *js.Execution, context: ?ConversionContext, reason: []const u8) anyerror {
    if (context) |conversion_context| {
        return switch (conversion_context) {
            .operation => |operation| typeError(exec, operation, reason),
            .constructor => |interface| constructorTypeError(exec, interface, reason),
            .attribute_get, .attribute_set => contextualTypeError(exec, conversion_context, reason),
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
    if (value.isSymbol()) {
        return typeError(exec, operation, "Cannot convert a Symbol value to a number");
    }
    if (value.isBigInt()) {
        return typeError(exec, operation, "Cannot convert a BigInt value to a number");
    }

    var try_catch: js.TryCatch = undefined;
    try_catch.init(value.local);
    defer try_catch.deinit();

    return value.toF64() catch |err| {
        if (err == error.JsException and try_catch.hasCaught()) {
            return rethrowConversion(exec, &try_catch, operationContext(operation));
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
