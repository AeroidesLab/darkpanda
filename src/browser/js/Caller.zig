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
const string = @import("../../string.zig");

const Frame = @import("../Frame.zig");
const Page = @import("../Page.zig");
const Session = @import("../Session.zig");

const js = @import("js.zig");
const Local = @import("Local.zig");
const Context = @import("Context.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const v8 = js.v8;
const log = lp.log;
const ArenaAllocator = std.heap.ArenaAllocator;
const CALL_ARENA_RETAIN = 1024 * 16;
const LOCAL_ARENA_RETAIN = 1024 * 16;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Caller = @This();

pub const WebIDLCallbackKind = enum {
    operation,
    attribute_get,
    attribute_set,
};

// Named access-check handlers need both Blink's diagnostic spelling and the
// identity of well-known symbols.  A custom Symbol("Symbol.toStringTag") has
// the same description but must remain blocked.
pub const PropertyName = struct {
    text: []const u8,
    kind: Kind,

    pub const Kind = enum {
        string,
        symbol,
        to_string_tag,
        has_instance,
        is_concat_spreadable,
    };
};

local: Local,
prev_local: ?*const js.Local,
prev_context: *Context,

// Takes the raw v8 isolate and extracts the context from it.
// Returns false if the context has been destroyed (e.g., navigated-away iframe),
// in which case a JS exception has been thrown and the caller should return immediately.
pub fn init(self: *Caller, v8_isolate: *v8.Isolate) bool {
    const ctx, const v8_context = Context.fromIsolate(.{ .handle = v8_isolate }) orelse {
        throwDetachedError(v8_isolate);
        return false;
    };
    initWithContext(self, ctx, v8_context);
    return true;
}

fn throwDetachedError(isolate: *v8.Isolate) void {
    const message = "Cannot execute in detached context (e.g., navigated-away iframe)";
    const v8_message = v8.v8__String__NewFromUtf8(isolate, message.ptr, v8.kNormal, @intCast(message.len));
    const js_exception = v8.v8__Exception__Error(v8_message);
    _ = v8.v8__Isolate__ThrowException(isolate, js_exception);
}

pub fn initWithContext(self: *Caller, ctx: *Context, v8_context: *const v8.Context) void {
    ctx.call_depth += 1;
    self.* = Caller{
        .local = .{
            .ctx = ctx,
            .handle = v8_context,
            .call_arena = ctx.call_arena,
            .isolate = ctx.isolate,
        },
        .prev_local = ctx.local,
        .prev_context = ctx.global.getJs(),
    };
    ctx.global.setJs(ctx);
    ctx.local = &self.local;
}

pub fn initFromHandle(self: *Caller, handle: ?*const v8.FunctionCallbackInfo) bool {
    const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
    return self.init(isolate);
}

pub fn deinit(self: *Caller) void {
    const ctx = self.local.ctx;
    const call_depth = ctx.call_depth - 1;

    // Because of callbacks, calls can be nested. Because of this, we
    // can't clear the call_arena after _every_ call. Imagine we have
    //    arr.forEach((i) => { console.log(i); }
    //
    // First we call forEach. Inside of our forEach call,
    // we call console.log. If we reset the call_arena after this call,
    // it'll reset it for the `forEach` call after, which might still
    // need the data.
    //
    // Therefore, we keep a call_depth, and only reset the call_arena
    // when a top-level (call_depth == 0) function ends.
    if (call_depth == 0) {
        const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx.call_arena.ptr));
        _ = arena.reset(.{ .retain_with_limit = CALL_ARENA_RETAIN });
    }

    // Unlike call_arena, local_arena is reset on _every_ return, since its
    // users promise not to hold data across a nested call. In debug, free
    // back to the backing allocator so a stale pointer trips the
    // DebugAllocator's use-after-free detection; in release, retain a buffer
    // to avoid realloc churn.
    {
        const local_arena: *ArenaAllocator = @ptrCast(@alignCast(ctx.local_arena.ptr));
        _ = local_arena.reset(if (comptime IS_DEBUG) .free_all else .{ .retain_with_limit = LOCAL_ARENA_RETAIN });
    }

    ctx.call_depth = call_depth;
    ctx.local = self.prev_local;
    ctx.global.setJs(self.prev_context);
}

pub const CallOpts = struct {
    null_as_undefined: bool = false,
    as_typed_array: bool = false,
    // Constructor-only. When true, `new.target` is pulled from the
    // FunctionCallbackInfo and passed as the first argument to the Zig
    // function (as a js.Function). See bridge.Constructor.Opts.
    new_target: bool = false,
    // Number of required Web IDL arguments, excluding an injected new.target.
    // The bridge derives this independently from Function.length because a
    // variadic operation has no required arguments even when its Zig adapter
    // uses a non-optional slice.
    required_args: usize = 0,
    // Whether the final JavaScript-visible parameter is a Web IDL rest
    // parameter. Zig slices are also used for ordinary sequences,
    // BufferSource and DOMString, so this must never be inferred from either
    // the adapter type or the runtime value.
    variadic: bool = false,
};

pub fn constructor(self: *Caller, comptime T: type, func: anytype, handle: *const v8.FunctionCallbackInfo, comptime opts: CallOpts) void {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = FunctionCallbackInfo{ .handle = handle };

    if (!info.isConstructCall()) {
        const reason = "Please use the 'new' operator, this DOM object constructor cannot be called as a function.";
        const err = js.WebIDL.constructorTypeError(&local.ctx.execution, interfaceName(T), reason);
        handleError(T, @TypeOf(func), local, err, info);
        return;
    }

    self._constructor(T, func, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
    };
}

fn _constructor(self: *Caller, comptime T: type, func: anytype, info: FunctionCallbackInfo, comptime opts: CallOpts) !void {
    const F = @TypeOf(func);
    const local = &self.local;
    const offset: comptime_int = if (opts.new_target) 1 else 0;
    if (info.length() < opts.required_args) {
        const reason = try std.fmt.allocPrint(
            local.call_arena,
            "{d} argument{s} required, but only {d} present.",
            .{ opts.required_args, if (opts.required_args == 1) "" else "s", info.length() },
        );
        return js.WebIDL.constructorTypeError(&local.ctx.execution, interfaceName(T), reason);
    }
    var args = try getArgs(
        F,
        offset,
        local,
        info,
        opts.variadic,
        .{ .constructor = interfaceName(T) },
    );
    if (comptime opts.new_target) {
        const new_target_handle = v8.v8__FunctionCallbackInfo__NewTarget(info.handle).?;
        @field(args, "0") = js.Function{ .local = local, .handle = @ptrCast(new_target_handle) };
    }
    const res = @call(.auto, func, args);

    const ReturnType = @typeInfo(F).@"fn".return_type orelse {
        @compileError(@typeName(F) ++ " has a constructor without a return type");
    };

    const new_this_handle = info.getThis();
    var this = js.Object{ .local = local, .handle = new_this_handle };
    if (@typeInfo(ReturnType) == .error_union) {
        const non_error_res = try res;
        this = try local.mapZigInstanceToJs(new_this_handle, non_error_res);
    } else {
        this = try local.mapZigInstanceToJs(new_this_handle, res);
    }

    // If we got back a different object (existing wrapper), copy the prototype
    // from new object. (this happens when we're upgrading an CustomElement)
    if (this.handle != new_this_handle) {
        const prototype_handle = v8.v8__Object__GetPrototype(new_this_handle).?;
        var out: v8.MaybeBool = undefined;
        v8.v8__Object__SetPrototype(this.handle, self.local.handle, prototype_handle, &out);
        if (comptime IS_DEBUG) {
            std.debug.assert(out.has_value and out.value);
        }
    }

    info.getReturnValue().set(this.handle);
}

pub fn getIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getIndex(T, local, func, idx, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

fn _getIndex(comptime T: type, local: *const Local, func: anytype, idx: u32, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, true, local, ret, info, opts);
}

pub fn setIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, js_value: *const v8.Value, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _setIndex(T, local, func, idx, .{ .local = &self.local, .handle = js_value }, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

fn _setIndex(comptime T: type, local: *const Local, func: anytype, idx: u32, js_value: js.Value, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    @field(args, "2") = try local.jsValueToZig(@TypeOf(@field(args, "2")), js_value);
    if (@typeInfo(F).@"fn".params.len == 4) {
        @field(args, "3") = getGlobalArg(@TypeOf(args.@"3"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, false, local, ret, info, opts);
}

pub fn deleteIndex(self: *Caller, comptime T: type, func: anytype, idx: u32, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _deleteIndex(T, local, func, idx, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

fn _deleteIndex(comptime T: type, local: *const Local, func: anytype, idx: u32, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, false, local, ret, info, opts);
}

pub fn getNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getNamedIndex(T, local, func, name, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

fn _getNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, true, local, ret, info, opts);
}

pub fn setNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, js_value: *const v8.Value, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _setNamedIndex(T, local, func, name, .{ .local = &self.local, .handle = js_value }, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

fn _setNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, js_value: js.Value, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    @field(args, "2") = try local.jsValueToZig(@TypeOf(@field(args, "2")), js_value);
    if (@typeInfo(F).@"fn".params.len == 4) {
        @field(args, "3") = getGlobalArg(@TypeOf(args.@"3"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, false, local, ret, info, opts);
}

pub fn deleteNamedIndex(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _deleteNamedIndex(T, local, func, name, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

fn _deleteNamedIndex(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, false, local, ret, info, opts);
}

pub fn getEnumerator(self: *Caller, comptime T: type, func: anytype, handle: *const v8.PropertyCallbackInfo, comptime opts: CallOpts) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getEnumerator(T, local, func, info, opts) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

fn _getEnumerator(comptime T: type, local: *const Local, func: anytype, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    if (@typeInfo(F).@"fn".params.len == 2) {
        @field(args, "1") = getGlobalArg(@TypeOf(args.@"1"), local.ctx);
    }
    const ret = @call(.auto, func, args);
    return handleIndexedReturn(T, F, true, local, ret, info, opts);
}

pub fn getIndexQuery(self: *Caller, comptime T: type, func: anytype, idx: u32, handle: *const v8.PropertyCallbackInfo) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getIndexQuery(T, local, func, idx, info) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

fn _getIndexQuery(comptime T: type, local: *const Local, func: anytype, idx: u32, info: PropertyCallbackInfo) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = idx;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const result = @call(.auto, func, args);
    const non_error_result = switch (@typeInfo(@TypeOf(result))) {
        .error_union => try result,
        else => result,
    };
    const attributes = queryAttributes(non_error_result) orelse return js.Intercepted.no;
    info.getReturnValue().set(try local.zigValueToJs(attributes, .{}));
    return js.Intercepted.yes;
}

pub fn getNamedQuery(self: *Caller, comptime T: type, func: anytype, name: *const v8.Name, handle: *const v8.PropertyCallbackInfo) u32 {
    const local = &self.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    return _getNamedQuery(T, local, func, name, info) catch |err| {
        handleError(T, @TypeOf(func), local, err, info);
        return js.Intercepted.yes;
    };
}

/// Blink installs setter/deleter/definer callbacks even when a legacy
/// platform object only declares indexed/named getters.  V8 tells those
/// callbacks whether the caller requested throwing semantics (strict
/// assignment/Object.defineProperty) or silent failure
/// (sloppy assignment/Reflect).  Keeping this in Caller means every Web IDL
/// collection can share the same receiver decoding and error boundary.
pub fn legacyReadOnlyIndexedSetter(
    self: *Caller,
    index: u32,
    handle: *const v8.PropertyCallbackInfo,
    comptime interface_name: []const u8,
) u32 {
    const local = &self.local;
    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    if (info.shouldThrowOnError()) {
        throwPropertyTypeError(
            local,
            "Failed to set an indexed property [{d}] on '{s}': Indexed property setter is not supported.",
            .{ index, interface_name },
        );
    }
    return js.Intercepted.yes;
}

pub fn legacyReadOnlyIndexedDeleter(
    self: *Caller,
    comptime T: type,
    query: anytype,
    index: u32,
    handle: *const v8.PropertyCallbackInfo,
    comptime interface_name: []const u8,
) u32 {
    const local = &self.local;
    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    const supported = legacyIndexedSupported(T, local, query, index, info) catch |err| {
        handleError(T, @TypeOf(query), local, err, info);
        return js.Intercepted.yes;
    };
    info.getReturnValue().setValueHandle(if (supported) local.isolate.initFalse() else local.isolate.initTrue());
    if (supported and info.shouldThrowOnError()) {
        throwPropertyTypeError(
            local,
            "Failed to delete an indexed property [{d}] from '{s}': Index property deleter is not supported.",
            .{ index, interface_name },
        );
    }
    return js.Intercepted.yes;
}

pub fn legacyReadOnlyIndexedDefiner(
    self: *Caller,
    index: u32,
    descriptor: *const v8.PropertyDescriptor,
    handle: *const v8.PropertyCallbackInfo,
    comptime interface_name: []const u8,
) u32 {
    const local = &self.local;
    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    if (info.shouldThrowOnError()) {
        const reason = if (v8.v8__PropertyDescriptor__HasGetter(descriptor) or v8.v8__PropertyDescriptor__HasSetter(descriptor))
            "Accessor properties are not allowed."
        else
            "Index property setter is not supported.";
        throwPropertyTypeError(
            local,
            "Failed to set an indexed property [{d}] on '{s}': {s}",
            .{ index, interface_name, reason },
        );
    }
    return js.Intercepted.yes;
}

pub fn legacyReadOnlyNamedSetter(
    self: *Caller,
    comptime T: type,
    query: anytype,
    name: *const v8.Name,
    handle: *const v8.PropertyCallbackInfo,
    comptime interface_name: []const u8,
) u32 {
    return self.legacyReadOnlyNamedOperation(T, query, name, handle, interface_name, .setter);
}

pub fn legacyReadOnlyNamedDeleter(
    self: *Caller,
    comptime T: type,
    query: anytype,
    name: *const v8.Name,
    handle: *const v8.PropertyCallbackInfo,
    comptime interface_name: []const u8,
) u32 {
    return self.legacyReadOnlyNamedOperation(T, query, name, handle, interface_name, .deleter);
}

pub fn legacyReadOnlyNamedDefiner(
    self: *Caller,
    comptime T: type,
    query: anytype,
    name: *const v8.Name,
    handle: *const v8.PropertyCallbackInfo,
    comptime interface_name: []const u8,
) u32 {
    return self.legacyReadOnlyNamedOperation(T, query, name, handle, interface_name, .definer);
}

const LegacyNamedOperation = enum { setter, deleter, definer };

fn legacyReadOnlyNamedOperation(
    self: *Caller,
    comptime T: type,
    query: anytype,
    name: *const v8.Name,
    handle: *const v8.PropertyCallbackInfo,
    comptime interface_name: []const u8,
    comptime operation: LegacyNamedOperation,
) u32 {
    const local = &self.local;
    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const info = PropertyCallbackInfo{ .handle = handle };
    const property_name = nameToString(local, []const u8, name) catch |err| {
        handleError(T, @TypeOf(query), local, err, info);
        return js.Intercepted.yes;
    };
    const supported = legacyNamedSupported(T, local, query, name, info) catch |err| {
        handleError(T, @TypeOf(query), local, err, info);
        return js.Intercepted.yes;
    };
    if (!supported) return js.Intercepted.no;

    if (comptime operation == .deleter) {
        info.getReturnValue().setValueHandle(local.isolate.initFalse());
    }
    if (info.shouldThrowOnError()) {
        switch (operation) {
            .setter, .definer => throwPropertyTypeError(
                local,
                "Failed to set a named property '{s}' on '{s}': Named property setter is not supported.",
                .{ property_name, interface_name },
            ),
            .deleter => throwPropertyTypeError(
                local,
                "Failed to delete a named property '{s}' from '{s}': Named property deleter is not supported.",
                .{ property_name, interface_name },
            ),
        }
    }
    return js.Intercepted.yes;
}

fn legacyIndexedSupported(
    comptime T: type,
    local: *const Local,
    query: anytype,
    index: u32,
    info: PropertyCallbackInfo,
) !bool {
    const F = @TypeOf(query);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = index;
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const result = @call(.auto, query, args);
    const value = switch (@typeInfo(@TypeOf(result))) {
        .error_union => try result,
        else => result,
    };
    return queryAttributes(value) != null;
}

fn legacyNamedSupported(
    comptime T: type,
    local: *const Local,
    query: anytype,
    name: *const v8.Name,
    info: PropertyCallbackInfo,
) !bool {
    const F = @TypeOf(query);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const result = @call(.auto, query, args);
    const value = switch (@typeInfo(@TypeOf(result))) {
        .error_union => try result,
        else => result,
    };
    return queryAttributes(value) != null;
}

fn throwPropertyTypeError(local: *const Local, comptime format: []const u8, args: anytype) void {
    const message = std.fmt.allocPrint(local.call_arena, format, args) catch {
        _ = local.isolate.throwException(local.isolate.createError("out of memory"));
        return;
    };
    _ = local.isolate.throwException(local.isolate.createTypeError(message));
}

fn _getNamedQuery(comptime T: type, local: *const Local, func: anytype, name: *const v8.Name, info: PropertyCallbackInfo) !u32 {
    const F = @TypeOf(func);
    var args: ParameterTypes(F) = undefined;
    @field(args, "0") = try TaggedOpaque.fromJS(*T, info.getThis());
    @field(args, "1") = try nameToString(local, @TypeOf(args.@"1"), name);
    if (@typeInfo(F).@"fn".params.len == 3) {
        @field(args, "2") = getGlobalArg(@TypeOf(args.@"2"), local.ctx);
    }
    const result = @call(.auto, func, args);
    const non_error_result = switch (@typeInfo(@TypeOf(result))) {
        .error_union => try result,
        else => result,
    };
    const attributes = queryAttributes(non_error_result) orelse return js.Intercepted.no;
    info.getReturnValue().set(try local.zigValueToJs(attributes, .{}));
    return js.Intercepted.yes;
}

/// Property query callbacks may return a boolean for the common
/// "exists with no attributes" case, or an attribute bitset (optionally null)
/// when an indexed/named property has descriptor constraints such as ReadOnly.
fn queryAttributes(result: anytype) ?u32 {
    return switch (@typeInfo(@TypeOf(result))) {
        .bool => if (result) @as(u32, v8.None) else null,
        .int, .comptime_int => @intCast(result),
        .optional => if (result) |value| queryAttributes(value) else null,
        else => @compileError("property query callback must return bool, an integer attribute bitset, or an optional attribute bitset"),
    };
}

fn handleIndexedReturn(comptime T: type, comptime F: type, comptime with_value: bool, local: *const Local, ret: anytype, info: PropertyCallbackInfo, comptime opts: CallOpts) !u32 {
    // need to unwrap this error immediately for when opts.null_as_undefined == true
    // and we need to compare it to null;
    const non_error_ret = switch (@typeInfo(@TypeOf(ret))) {
        .error_union => |eu| blk: {
            break :blk ret catch |err| {
                // We can't compare err == error.NotHandled if error.NotHandled
                // isn't part of the possible error set. So we first need to check
                // if error.NotHandled is part of the error set.
                if (isInErrorSet(error.NotHandled, eu.error_set)) {
                    if (err == error.NotHandled) {
                        return js.Intercepted.no;
                    }
                }
                handleError(T, F, local, err, info);
                // An exception has been installed on the isolate.  Reporting
                // kNo would make V8 continue the property fallback algorithm
                // and invoke the same throwing interceptor again.
                return js.Intercepted.yes;
            };
        },
        else => ret,
    };

    if (comptime with_value) {
        info.getReturnValue().set(try local.zigValueToJs(non_error_ret, opts));
    }
    return js.Intercepted.yes;
}

fn isInErrorSet(err: anyerror, comptime T: type) bool {
    inline for (@typeInfo(T).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    return false;
}

fn nameToString(local: *const Local, comptime T: type, name: *const v8.Name) !T {
    const name_value: *const v8.Value = @ptrCast(name);
    const is_symbol = v8.v8__Value__IsSymbol(name_value);
    const handle: *const v8.String = if (is_symbol) blk: {
        const description = v8.v8__Symbol__Description(
            @ptrCast(name),
            local.isolate.handle,
        ) orelse return error.TryCatchRethrow;
        break :blk v8.v8__Value__ToString(description, local.handle) orelse
            return error.TryCatchRethrow;
    } else @ptrCast(name);

    if (is_symbol) {
        // Blink formats symbols used as property names as `[description]` in
        // its cross-origin diagnostics (including `[undefined]`).
        const description = try js.String.toSlice(.{ .local = local, .handle = handle });
        if (T == PropertyName) {
            const kind: PropertyName.Kind = if (v8.v8__Value__StrictEquals(
                name_value,
                @ptrCast(v8.v8__Symbol__GetToStringTag(local.isolate.handle)),
            ))
                .to_string_tag
            else if (v8.v8__Value__StrictEquals(
                name_value,
                @ptrCast(v8.v8__Symbol__GetHasInstance(local.isolate.handle)),
            ))
                .has_instance
            else if (v8.v8__Value__StrictEquals(
                name_value,
                @ptrCast(v8.v8__Symbol__GetIsConcatSpreadable(local.isolate.handle)),
            ))
                .is_concat_spreadable
            else
                .symbol;
            return .{
                .text = try std.mem.concat(local.call_arena, u8, &.{ "[", description, "]" }),
                .kind = kind,
            };
        }
        if (T == string.String) {
            return string.String.concat(local.call_arena, &.{ "[", description, "]" });
        }
        if (T == string.Global) {
            return .{
                .str = try string.String.concat(
                    local.ctx.page.frame_arena,
                    &.{ "[", description, "]" },
                ),
            };
        }
        return std.mem.concat(local.call_arena, u8, &.{ "[", description, "]" });
    }

    if (T == PropertyName) {
        return .{
            .text = try js.String.toSlice(.{ .local = local, .handle = handle }),
            .kind = .string,
        };
    }
    if (T == string.String) {
        return js.String.toSSO(.{ .local = local, .handle = handle }, false);
    }
    if (T == string.Global) {
        return js.String.toSSO(.{ .local = local, .handle = handle }, true);
    }
    return try js.String.toSlice(.{ .local = local, .handle = handle });
}

fn handleError(comptime T: type, comptime F: type, local: *const Local, err: anyerror, info: anytype) void {
    const isolate = local.isolate;

    if (comptime IS_DEBUG and @TypeOf(info) == FunctionCallbackInfo) {
        if (log.enabled(.js, .debug)) {
            const DOMException = @import("../webapi/DOMException.zig");
            if (DOMException.fromError(err) == null) {
                // This isn't a DOMException, let's log it
                logFunctionCallError(local, @typeName(T), @typeName(F), err, info);
            }
        }
    }

    const js_err: *const v8.Value = switch (err) {
        error.TryCatchRethrow => return,
        error.InvalidArgument => isolate.createTypeError("invalid argument"),
        error.TypeError => isolate.createTypeError(""),
        error.RangeError => isolate.createRangeError(""),
        error.OutOfMemory => isolate.createError("out of memory"),
        error.IllegalConstructor => isolate.createError("Illegal Constructor"),
        else => domExceptionToJs(local, err) orelse isolate.createError(@errorName(err)),
    };

    const js_exception = isolate.throwException(js_err);
    info.getReturnValue().setValueHandle(js_exception);
}

// Convert a Zig error to a DOMException. If the error is unknown, return null.
fn domExceptionToJs(local: *const Local, err: anyerror) ?*const v8.Value {
    const DOMException = @import("../webapi/DOMException.zig");
    const ex = DOMException.fromError(err) orelse return null;
    const value = local.zigValueToJs(ex, .{}) catch return local.isolate.createError("internal error");
    _ = v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(value.handle));
    return value.handle;
}

// This is extracted to speed up compilation. When left inlined in handleError,
// this can add as much as 10 seconds of compilation time.
fn logFunctionCallError(local: *const Local, type_name: []const u8, func: []const u8, err: anyerror, info: FunctionCallbackInfo) void {
    const args_dump = serializeFunctionArgs(local, info) catch "failed to serialize args";
    log.debug(.js, "function call error", .{
        .type = type_name,
        .func = func,
        .err = err,
        .args = args_dump,
        .stack = local.stackTrace() catch |err1| @errorName(err1),
    });
}

fn serializeFunctionArgs(local: *const Local, info: FunctionCallbackInfo) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(local.call_arena);

    const separator = log.separator();
    for (0..info.length()) |i| {
        try buf.writer.print("{s}{d} - ", .{ separator, i + 1 });
        const js_value = info.getArg(@intCast(i), local);
        try local.debugValue(js_value, &buf.writer);
    }
    return buf.written();
}

// Takes a function, and returns a tuple for its argument. Used when we
// @call a function
fn ParameterTypes(comptime F: type) type {
    const params = @typeInfo(F).@"fn".params;
    var fields: [params.len]std.builtin.Type.StructField = undefined;

    inline for (params, 0..) |param, i| {
        fields[i] = .{
            .name = tupleFieldName(i),
            .type = param.type.?,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(param.type.?),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .decls = &.{},
        .fields = &fields,
        .is_tuple = true,
    } });
}

fn tupleFieldName(comptime i: usize) [:0]const u8 {
    return switch (i) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        8 => "8",
        9 => "9",
        else => std.fmt.comptimePrint("{d}", .{i}),
    };
}

fn isFrame(comptime T: type) bool {
    return T == *Frame or T == *const Frame;
}

fn isPage(comptime T: type) bool {
    return T == *Page or T == *const Page;
}

fn isSession(comptime T: type) bool {
    return T == *Session or T == *const Session;
}

fn isExecution(comptime T: type) bool {
    return T == *js.Execution or T == *const js.Execution;
}

fn getGlobalArg(comptime T: type, ctx: *Context) T {
    if (comptime isFrame(T)) {
        return switch (ctx.global) {
            .frame => |frame| frame,
            .worker => unreachable,
        };
    }

    if (comptime isPage(T)) {
        return ctx.page;
    }

    if (comptime isExecution(T)) {
        return &ctx.execution;
    }

    @compileError("Unsupported global arg type: " ++ @typeName(T));
}

fn interfaceName(comptime T: type) []const u8 {
    if (!@hasDecl(T, "JsApi") or !@hasDecl(T.JsApi, "Meta") or !@hasDecl(T.JsApi.Meta, "name")) {
        @compileError(@typeName(T) ++ " does not expose JsApi.Meta.name for Web IDL exception context");
    }
    return T.JsApi.Meta.name;
}

fn maybeInterfaceName(comptime T: type) ?[]const u8 {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return null,
    }
    if (!@hasDecl(T, "JsApi")) return null;
    if (!@hasDecl(T.JsApi, "Meta")) return null;
    if (!@hasDecl(T.JsApi.Meta, "name")) return null;
    return T.JsApi.Meta.name;
}

/// Return the public Web IDL interface name for a JavaScript-visible pointer
/// parameter.  This mirrors Blink's NativeValueTraits<T>::ArgumentValue path;
/// optional pointers are nullable interfaces and retain the same type name
/// when a supplied non-null value has the wrong brand.
fn interfaceArgumentName(comptime T: type) ?[]const u8 {
    const unwrapped = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    const pointer = switch (@typeInfo(unwrapped)) {
        .pointer => |value| value,
        else => return null,
    };
    if (pointer.size != .one) return null;
    return maybeInterfaceName(pointer.child);
}

fn functionMember(comptime T: type, local: *const Local, info: FunctionCallbackInfo) !?js.WebIDL.Operation {
    const maybe_interface = comptime maybeInterfaceName(T);
    if (comptime maybe_interface == null) return null;
    const interface = maybe_interface.?;
    const data = info.getDataValue() orelse return null;
    if (!v8.v8__Value__IsString(data)) return null;
    const name = try js.String.toSlice(.{
        .local = local,
        .handle = @ptrCast(data),
    });
    return .{
        .interface = interface,
        .name = name,
    };
}

// These wrap the raw v8 C API to provide a cleaner interface.
pub const FunctionCallbackInfo = struct {
    handle: *const v8.FunctionCallbackInfo,

    pub fn length(self: FunctionCallbackInfo) u32 {
        return @intCast(v8.v8__FunctionCallbackInfo__Length(self.handle));
    }

    pub fn getArg(self: FunctionCallbackInfo, index: u32, local: *const js.Local) js.Value {
        return .{ .local = local, .handle = v8.v8__FunctionCallbackInfo__INDEX(self.handle, @intCast(index)).? };
    }

    pub fn getData(self: FunctionCallbackInfo) ?*anyopaque {
        const data = self.getDataValue() orelse return null;
        return v8.v8__External__Value(@ptrCast(data));
    }

    pub fn getDataValue(self: FunctionCallbackInfo) ?*const v8.Value {
        return v8.v8__FunctionCallbackInfo__Data(self.handle);
    }

    pub fn getThis(self: FunctionCallbackInfo) *const v8.Object {
        return v8.v8__FunctionCallbackInfo__This(self.handle).?;
    }

    pub fn getReturnValue(self: FunctionCallbackInfo) ReturnValue {
        var rv: v8.ReturnValue = undefined;
        v8.v8__FunctionCallbackInfo__GetReturnValue(self.handle, &rv);
        return .{ .handle = rv };
    }

    fn isConstructCall(self: FunctionCallbackInfo) bool {
        return v8.v8__FunctionCallbackInfo__IsConstructCall(self.handle);
    }
};

pub const PropertyCallbackInfo = struct {
    handle: *const v8.PropertyCallbackInfo,

    pub fn getThis(self: PropertyCallbackInfo) *const v8.Object {
        return v8.v8__PropertyCallbackInfo__This(self.handle).?;
    }

    pub fn getReturnValue(self: PropertyCallbackInfo) ReturnValue {
        var rv: v8.ReturnValue = undefined;
        v8.v8__PropertyCallbackInfo__GetReturnValue(self.handle, &rv);
        return .{ .handle = rv };
    }

    pub fn shouldThrowOnError(self: PropertyCallbackInfo) bool {
        return v8.v8__PropertyCallbackInfo__ShouldThrowOnError(self.handle);
    }
};

const ReturnValue = struct {
    handle: v8.ReturnValue,

    pub fn set(self: ReturnValue, value: anytype) void {
        const T = @TypeOf(value);
        if (T == *const v8.Object) {
            self.setValueHandle(@ptrCast(value));
        } else if (T == *const v8.Value) {
            self.setValueHandle(value);
        } else if (T == js.Value) {
            self.setValueHandle(value.handle);
        } else {
            @compileError("Unsupported type for ReturnValue.set: " ++ @typeName(T));
        }
    }

    pub fn setValueHandle(self: ReturnValue, handle: *const v8.Value) void {
        v8.v8__ReturnValue__Set(self.handle, handle);
    }
};

pub const Function = struct {
    pub const Opts = struct {
        noop: bool = false,
        static: bool = false,
        wpt_only: bool = false,
        writable: bool = true,
        deletable: bool = true,
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        cache: ?Caching = null,
        embedded_receiver: bool = false,
        exposed: Exposed = .both,
        ce_reactions: bool = false,
        js_name: ?[:0]const u8 = null,
        // Override Function.length when a wrapper deliberately accepts an
        // optional Zig value in order to distinguish an omitted Web IDL
        // argument from an explicit undefined/null value.
        arity: ?usize = null,
        // Bridge-internal minimum argument count. Accessors, iterators, and
        // embedder-created callbacks leave this null because their invocation
        // shape is not an ordinary Web IDL operation.
        required_args: ?usize = null,
        // The final JavaScript-visible parameter is a Web IDL variadic. This
        // is explicit because Zig slices also represent DOMString,
        // BufferSource and sequence<T>, none of which are variadic.
        variadic: bool = false,
        // Accessors and operations share the callback bridge, but Blink gives
        // their conversions different exception prefixes. FunctionTemplate
        // data carries the member name; this tag supplies its Web IDL role.
        webidl_callback_kind: WebIDLCallbackKind = .operation,
        // Promise-returning Web IDL operations deliberately omit V8's
        // receiver Signature in Blink.  Their callback performs the brand
        // check inside the promise exception scope, so an invalid receiver
        // produces a rejected Promise instead of a synchronous throw.
        receiver_mode: ReceiverMode = .v8_signature,
        // Access-checked global interfaces (currently Window) must repeat the
        // caller/receiver origin gate when an author extracts a native member
        // and applies it to another WindowProxy. Ordinary property lookup runs
        // V8's access callback first, but Function.prototype.call/Reflect.get
        // with an explicit receiver reaches this callback directly.
        cross_origin_allowed: bool = false,
        // [CrossOrigin] can apply to only one half of an attribute, notably
        // Window.location's explicit (Getter,Setter) form versus [Replaceable]
        // readonly attributes whose synthetic setter is not exposed cross-
        // origin. Null inherits cross_origin_allowed.
        cross_origin_getter_allowed: ?bool = null,
        cross_origin_setter_allowed: ?bool = null,

        pub const Exposed = enum { both, window, worker };

        pub const ReceiverMode = enum {
            v8_signature,
            reject_promise,
        };

        // We support two ways to cache a value directly into a v8::Object. The
        // difference between the two is like the difference between a Map
        // and a Struct.
        // 1 - Using the object's internal fields. Think of this as
        //     adding a field to the struct. It's fast, but the space is reserved
        //     upfront for _every_ instance, whether we use it or not.
        //
        // 2 - Using the object's private state with a v8::Private key. Think of
        //     this as a HashMap. It takes no memory if the cache isn't used
        //     but has overhead when used.
        //
        // Consider `window.document`, (1) we have relatively few Window objects,
        // (2) They all have a document and (3) The document is accessed _a lot_.
        // An internal field makes sense.
        //
        // Consider `node.childNodes`, (1) we can have 20K+ node objects, (2)
        // 95% of nodes will never have their .childNodes access by JavaScript.
        // Private map lookup makes sense.
        pub const Caching = union(enum) {
            internal: u8,
            private: []const u8,
        };
    };

    pub fn call(comptime T: type, info_handle: *const v8.FunctionCallbackInfo, func: anytype, comptime opts: Opts) void {
        const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(info_handle).?;
        const ctx, const v8_context = Context.fromIsolate(.{ .handle = v8_isolate }) orelse {
            throwDetachedError(v8_isolate);
            return;
        };
        const info = FunctionCallbackInfo{ .handle = info_handle };

        var hs: js.HandleScope = undefined;
        hs.initWithIsolateHandle(v8_isolate);
        defer hs.deinit();

        var caller: Caller = undefined;
        caller.initWithContext(ctx, v8_context);
        defer caller.deinit();

        // This gate deliberately precedes accessor-cache lookup. Otherwise a
        // cached object such as window.document could be returned to an
        // extracted getter's cross-origin WindowProxy receiver before the
        // native callback had any chance to reject it.
        if (comptime !opts.static and
            !opts.embedded_receiver and
            !opts.cross_origin_allowed and
            @hasDecl(T, "checkReceiverAccess"))
        {
            const receiver = TaggedOpaque.fromJS(*T, info.getThis()) catch |err| {
                handleError(T, @TypeOf(func), &caller.local, err, info);
                return;
            };
            const accessing_frame = switch (caller.local.ctx.global) {
                .frame => |frame| frame,
                .worker => {
                    handleError(T, @TypeOf(func), &caller.local, error.SecurityError, info);
                    return;
                },
            };
            receiver.checkReceiverAccess(accessing_frame) catch |err| {
                handleError(T, @TypeOf(func), &caller.local, err, info);
                return;
            };
        }

        var cache_state: CacheState = undefined;
        if (comptime opts.cache) |cache| {
            // This API is a bit weird. On
            if (respondFromCache(cache, ctx, v8_context, info, &cache_state)) {
                // Value was fetched from the cache and returned already
                return;
            } else {
                // Cache miss: cache_state will have been populated
            }
        }

        // [CEReactions] entry: open a reactions scope so any custom-element
        // callbacks queued by DOM mutation inside `func` fire after it
        // returns, never mid-algorithm.
        var ce_checkpoint: usize = undefined;
        const ce_frame: ?*Frame = if (comptime opts.ce_reactions) switch (ctx.global) {
            .frame => |frame| frame,
            .worker => null,
        } else null;

        if (comptime opts.ce_reactions) {
            if (ce_frame) |frame| {
                ce_checkpoint = frame._ce_reactions.push();
            }
        }
        defer if (comptime opts.ce_reactions) {
            if (ce_frame) |frame| {
                frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);
            }
        };

        const js_value = _call(T, &caller.local, info, func, opts) catch |err| {
            handleError(T, @TypeOf(func), &caller.local, err, info);
            return;
        };

        if (comptime opts.cache) |cache| {
            cache_state.save(cache, js_value);
        }
    }

    fn _call(comptime T: type, local: *const Local, info: FunctionCallbackInfo, func: anytype, comptime opts: Opts) !js.Value {
        const F = @TypeOf(func);
        const member = try functionMember(T, local, info);
        const conversion_context: ?js.WebIDL.ConversionContext = if (member) |value|
            switch (opts.webidl_callback_kind) {
                .operation => .{ .operation = value },
                .attribute_get => .{ .attribute_get = .{ .interface = value.interface, .name = value.name } },
                .attribute_set => .{ .attribute_set = .{ .interface = value.interface, .name = value.name } },
            }
        else
            null;

        // This must precede both the required-argument check and all Web IDL
        // conversions.  Chromium's promise-returning bindings explicitly
        // brand-check in their callback and let ExceptionToRejectPromiseScope
        // turn the resulting TypeError into the operation's return Promise.
        const promise_receiver: ?*T = if (comptime !opts.static and !opts.embedded_receiver and opts.receiver_mode == .reject_promise)
            TaggedOpaque.fromJS(*T, info.getThis()) catch {
                const operation = member orelse return error.InvalidArgument;
                const promise = try js.WebIDL.rejectedTypeError(
                    &local.ctx.execution,
                    operation,
                    "Illegal invocation",
                );
                const js_value = try local.zigValueToJs(promise, .{});
                info.getReturnValue().set(js_value);
                return js_value;
            }
        else
            null;

        if (comptime opts.required_args) |required| {
            if (info.length() < required) {
                const required_operation = member orelse return error.InvalidArgument;
                return js.WebIDL.requiredArgument(
                    &local.ctx.execution,
                    required_operation,
                    required,
                    info.length(),
                );
            }
        }
        var args: ParameterTypes(F) = undefined;
        if (comptime opts.static) {
            args = try getArgs(F, 0, local, info, opts.variadic, conversion_context);
        } else if (comptime opts.embedded_receiver) {
            args = try getArgs(F, 1, local, info, opts.variadic, conversion_context);
            @field(args, "0") = @ptrCast(@alignCast(info.getData() orelse unreachable));
        } else {
            args = try getArgs(F, 1, local, info, opts.variadic, conversion_context);
            @field(args, "0") = promise_receiver orelse try TaggedOpaque.fromJS(*T, info.getThis());
        }
        const res = @call(.auto, func, args);
        const js_value = try local.zigValueToJs(res, .{
            .as_typed_array = opts.as_typed_array,
            .null_as_undefined = opts.null_as_undefined,
        });
        info.getReturnValue().set(js_value);
        return js_value;
    }

    // We can cache a value directly into the v8::Object so that our callback to fetch a property
    // can be fast. Generally, think of it like this:
    //   fn callback(handle: *const v8.FunctionCallbackInfo) callconv(.c) void {
    //       const js_obj = info.getThis();
    //       const cached_value = js_obj.getFromCache("Nodes.childNodes");
    //       info.returnValue().set(cached_value);
    //   }
    //
    // That above pseudocode snippet is largely what this respondFromCache is doing.
    // But on miss, it's also setting the `cache_state` with all of the data it
    // got checking the cache, so that, once we get the value from our Zig code,
    // it's quick to store in the v8::Object for subsequent calls.
    fn respondFromCache(comptime cache: Opts.Caching, ctx: *Context, v8_context: *const v8.Context, info: FunctionCallbackInfo, cache_state: *CacheState) bool {
        const js_this = info.getThis();
        const return_value = info.getReturnValue();

        switch (cache) {
            .internal => |idx| {
                // Defensive check: verify object has enough internal fields.
                // This guards against edge cases where signature check passes but
                // the receiver doesn't have expected internal fields (e.g., global
                // proxy vs global object, cross-context scenarios).
                if (v8.v8__Object__InternalFieldCount(js_this) <= idx) {
                    if (comptime IS_DEBUG) {
                        std.debug.assert(false);
                    }
                    return false;
                }

                if (v8.v8__Object__GetInternalField(js_this, idx)) |cached| {
                    // means we can't cache undefined, since we can't tell the
                    // difference between "it isn't in the cache" and  "it's
                    // in the cache with a value of undefined"
                    if (!v8.v8__Value__IsUndefined(cached)) {
                        return_value.set(cached);
                        return true;
                    }
                }

                // store this so that we can quickly save the result into the cache
                cache_state.* = .{
                    .js_this = js_this,
                    .v8_context = v8_context,
                    .mode = .{ .internal = idx },
                };
            },
            .private => |private_symbol| {
                const global_handle = &@field(ctx.env.private_symbols, private_symbol).handle;
                const private_key: *const v8.Private = v8.v8__Global__Get(global_handle, ctx.isolate.handle).?;
                if (v8.v8__Object__GetPrivate(js_this, v8_context, private_key)) |cached| {
                    // This means we can't cache "undefined", since we can't tell
                    // the difference between a (a) undefined == not in the cache
                    // and (b) undefined == the cache value.  If this becomes
                    // important, we can check HasPrivate first. But that requires
                    // calling HasPrivate then GetPrivate.
                    if (!v8.v8__Value__IsUndefined(cached)) {
                        return_value.set(cached);
                        return true;
                    }
                }

                // store this so that we can quickly save the result into the cache
                cache_state.* = .{
                    .js_this = js_this,
                    .v8_context = v8_context,
                    .mode = .{ .private = private_key },
                };
            },
        }

        // cache miss
        return false;
    }

    const CacheState = struct {
        js_this: *const v8.Object,
        v8_context: *const v8.Context,
        mode: union(enum) {
            internal: u8,
            private: *const v8.Private,
        },

        pub fn save(self: *const CacheState, comptime cache: Opts.Caching, js_value: js.Value) void {
            if (comptime cache == .internal) {
                v8.v8__Object__SetInternalField(self.js_this, self.mode.internal, js_value.handle);
            } else {
                var out: v8.MaybeBool = undefined;
                v8.v8__Object__SetPrivate(self.js_this, self.v8_context, self.mode.private, js_value.handle, &out);
            }
        }
    };
};

// If we call a method in javascript: cat.lives('nine');
//
// Then we'd expect a Zig function with 2 parameters: a self and the string.
// In this case, offset == 1. Offset is always 1 for setters or methods.
//
// Offset is always 0 for constructors.
//
// For constructors, setters and methods, we can further increase offset + 1
// if the first parameter is an instance of Page.
//
// A trailing Zig slice only collects additional JavaScript arguments when the
// bridge explicitly marks the Web IDL operation as variadic. Ordinary
// sequence<T>, BufferSource and DOMString parameters are converted once from
// their corresponding JavaScript argument and all later arguments are ignored.
fn getArgs(
    comptime F: type,
    comptime offset: usize,
    local: *const Local,
    info: FunctionCallbackInfo,
    comptime variadic: bool,
    conversion_context: ?js.WebIDL.ConversionContext,
) !ParameterTypes(F) {
    var args: ParameterTypes(F) = undefined;

    const params = @typeInfo(F).@"fn".params[offset..];
    // Except for the constructor, the first parameter is always `self`
    // This isn't something we'll bind from JS, so skip it.
    const params_to_map = blk: {
        if (params.len == 0) {
            return args;
        }

        // If the last parameter is Frame/Page/Session/Execution, set it from
        // context and exclude it from our params slice, because we don't want
        // to bind it to a JS argument.
        const LastParamType = params[params.len - 1].type.?;
        if (comptime isFrame(LastParamType) or isPage(LastParamType) or isExecution(LastParamType) or isSession(LastParamType)) {
            @field(args, tupleFieldName(params.len - 1 + offset)) = getGlobalArg(LastParamType, local.ctx);
            break :blk params[0 .. params.len - 1];
        }

        // we have neither a Frame/Page/Session/Execution nor a JsObject.
        // All params must be bound to a JavaScript value.
        break :blk params;
    };

    if (params_to_map.len == 0) {
        return args;
    }

    const js_parameter_count = info.length();
    const last_js_parameter = params_to_map.len - 1;

    if (comptime variadic) {
        const last_parameter_type = params_to_map[params_to_map.len - 1].type.?;
        const last_parameter_type_info = @typeInfo(last_parameter_type);
        if (last_parameter_type_info != .pointer or last_parameter_type_info.pointer.size != .slice) {
            @compileError("a variadic Web IDL operation must use a trailing Zig slice adapter: " ++ @typeName(F));
        }

        const slice_type = last_parameter_type_info.pointer.child;
        if (js_parameter_count <= last_js_parameter) {
            @field(args, tupleFieldName(params_to_map.len + offset - 1)) = &.{};
        } else {
            const arr = try local.call_arena.alloc(slice_type, js_parameter_count - last_js_parameter);
            for (arr, last_js_parameter..) |*a, i| {
                // Each supplied rest value is one Web IDL argument. In
                // particular, Array and TypedArray values are converted to a
                // single element here; they are not mistaken for the rest
                // container itself.
                a.* = try restValueToZig(
                    slice_type,
                    local,
                    info.getArg(@intCast(i), local),
                    conversion_context,
                );
            }
            @field(args, tupleFieldName(params_to_map.len + offset - 1)) = arr;
        }
    }

    inline for (params_to_map, 0..) |param, i| {
        const field_index = comptime i + offset;
        if (comptime i == params_to_map.len - 1) {
            if (comptime variadic) {
                break;
            }
        }

        if (comptime isFrame(param.type.?)) {
            @compileError("Frame must be the last parameter: " ++ @typeName(F));
        } else if (comptime isPage(param.type.?)) {
            @compileError("Page must be the last parameter: " ++ @typeName(F));
        } else if (comptime isExecution(param.type.?)) {
            @compileError("Execution must be the last parameter: " ++ @typeName(F));
        } else if (comptime isSession(param.type.?)) {
            @compileError("Session must be the last parameter: " ++ @typeName(F));
        } else if (i >= js_parameter_count) {
            if (@typeInfo(param.type.?) != .optional) {
                return error.InvalidArgument;
            }
            @field(args, tupleFieldName(field_index)) = null;
        } else {
            const js_val = info.getArg(@intCast(i), local);
            // Only fold errors we don't recognize into InvalidArgument; let
            // domain-meaningful ones (e.g. InvalidCharacterError from a
            // String.OneByte param) propagate so handleError can map them
            // to the right DOMException. Compared by name because the per-
            // type instantiation of jsValueToZig may not include such errors
            // in its inferred error set.
            @field(args, tupleFieldName(field_index)) = local.jsValueToZigWithContext(
                param.type.?,
                js_val,
                conversion_context,
            ) catch |err| {
                // Conversion helpers use these sentinels only after V8 (or the
                // Web IDL wrapper) has installed the original JavaScript
                // exception. Folding either into InvalidArgument would replace
                // a contextual Symbol/@@toPrimitive TypeError, or an exception
                // thrown by author conversion code, with the bridge's generic
                // "invalid argument" error.
                if (err == error.TryCatchRethrow or err == error.JsException) {
                    return err;
                }
                // Blink uses NativeValueTraits<T>::ArgumentValue for a
                // top-level interface argument.  A failed wrapper brand check
                // is not a generic conversion failure: it identifies the
                // zero-based argument and expected Web IDL interface.
                if (err == error.InvalidArgument) {
                    if (comptime interfaceArgumentName(param.type.?)) |expected_type| {
                        return js.WebIDL.argumentNotOfType(
                            &local.ctx.execution,
                            conversion_context,
                            i,
                            expected_type,
                        );
                    }
                }
                const DOMException = @import("../webapi/DOMException.zig");
                if (DOMException.fromError(err) != null) {
                    return err;
                }
                return error.InvalidArgument;
            };
        }
    }

    return args;
}

// A const byte slice used as a Web IDL rest element is a DOMString adapter.
// Keep this distinction at the rest conversion boundary: the same Zig type is
// also used by ordinary, non-variadic BufferSource parameters, which must keep
// their typed-array backing-store conversion in Local.jsValueToZig.
fn restValueToZig(
    comptime T: type,
    local: *const Local,
    value: js.Value,
    conversion_context: ?js.WebIDL.ConversionContext,
) !T {
    const type_info = @typeInfo(T);
    if (comptime type_info == .pointer and
        type_info.pointer.size == .slice and
        type_info.pointer.is_const and
        type_info.pointer.child == u8 and
        type_info.pointer.sentinel() == null)
    {
        return js.WebIDL.toDOMStringWithContext(
            value,
            &local.ctx.execution,
            conversion_context,
        );
    }
    return local.jsValueToZigWithContext(T, value, conversion_context);
}
