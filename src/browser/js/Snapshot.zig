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

const js = @import("js.zig");
const bridge = @import("bridge.zig");

const v8 = js.v8;
const log = lp.log;
const JsApis = bridge.JsApis;
const PageJsApis = bridge.PageJsApis;
const WorkerJsApis = bridge.WorkerJsApis;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Snapshot = @This();

const Caller = @import("Caller.zig");

const Realm = enum {
    window,
    worker,

    fn asExposed(comptime self: Realm) Caller.Function.Opts.Exposed {
        return switch (self) {
            .window => .window,
            .worker => .worker,
        };
    }
};

const embedded_snapshot_blob = if (lp.build_config.snapshot_path) |path| @embedFile(path) else "";

// When creating our Snapshot, we use local function templates for every Zig type.
// You cannot, from what I can tell, create persisted FunctionTemplates at
// snapshot creation time. But you can embed those templates (or any other v8
// Data) so that it's available to contexts created from the snapshot. This is
// the starting index of those function templates, which we can extract. At
// creation time, in debug, we assert that this is actually a consecutive integer
// sequence
data_start: usize,

// The snapshot data (v8.StartupData is a ptr to the data and len).
startup_data: v8.StartupData,

// V8 doesn't know how to serialize external references, and pretty much any hook
// into Zig is an external reference (e.g. every accessor and function callback).
// When we create the snapshot, we give it an array with the address of every
// external reference. When we load the snapshot, we need to give it the same
// array with the exact same number of entries in the same order (but, of course
// cross-process, the value (address) might be different).
external_references: [countExternalReferences()]isize,

// Track whether this snapshot owns its data (was created in-process)
// If false, the data points into embedded_snapshot_blob and will not be freed
owns_data: bool = false,

pub fn load() !Snapshot {
    if (comptime embedded_snapshot_blob.len > 0) {
        return loadEmbedded();
    }
    return create();
}

fn loadEmbedded() !Snapshot {
    // Binary format: [data_start: usize][blob data]
    const min_size = @sizeOf(usize) + 1000;
    if (embedded_snapshot_blob.len < min_size) {
        // our blob should be in the MB, this is just a quick sanity check
        return error.InvalidSnapshot;
    }

    const data_start = std.mem.readInt(usize, embedded_snapshot_blob[0..@sizeOf(usize)], .little);
    const blob = embedded_snapshot_blob[@sizeOf(usize)..];

    const startup_data = v8.StartupData{ .data = blob.ptr, .raw_size = @intCast(blob.len) };
    if (!v8.v8__StartupData__IsValid(startup_data)) {
        return error.InvalidSnapshot;
    }

    return .{
        .owns_data = false,
        .data_start = data_start,
        .startup_data = startup_data,
        .external_references = collectExternalReferences(),
    };
}

pub fn deinit(self: Snapshot) void {
    // Only free if we own the data (was created in-process)
    if (self.owns_data) {
        // V8 allocated this with `new char[]`, so we need to use the C++ delete[] operator
        v8.v8__StartupData__DELETE(self.startup_data.data);
    }
}

pub fn write(self: Snapshot, writer: *std.Io.Writer) !void {
    if (!self.isValid()) {
        return error.InvalidSnapshot;
    }

    try writer.writeInt(usize, self.data_start, .little);
    try writer.writeAll(self.startup_data.data[0..@intCast(self.startup_data.raw_size)]);
}

pub fn fromEmbedded(self: Snapshot) bool {
    // if the snapshot comes from the embedFile, then it'll be flagged as not
    // owning (aka, not needing to free) the data.
    return self.owns_data == false;
}

fn isValid(self: Snapshot) bool {
    return v8.v8__StartupData__IsValid(self.startup_data);
}

pub fn create() !Snapshot {
    var external_references = collectExternalReferences();

    var params: v8.CreateParams = undefined;
    v8.v8__Isolate__CreateParams__CONSTRUCT(&params);
    params.array_buffer_allocator = v8.v8__ArrayBuffer__Allocator__NewDefaultAllocator();
    defer v8.v8__ArrayBuffer__Allocator__DELETE(params.array_buffer_allocator.?);
    params.external_references = @ptrCast(&external_references);

    const snapshot_creator = v8.v8__SnapshotCreator__CREATE(&params);
    defer v8.v8__SnapshotCreator__DESTRUCT(snapshot_creator);

    var data_start: usize = 0;
    const isolate = v8.v8__SnapshotCreator__getIsolate(snapshot_creator).?;
    // SnapshotCreator's constructor enters this owned isolate and its
    // destructor exits it (v8-snapshot.h). Run the final collection before the
    // creator is destroyed, while that implicit Isolate::Scope is still live.
    defer v8.v8__Isolate__LowMemoryNotification(isolate);

    {
        // CreateBlob, which we'll call once everything is setup, MUST NOT
        // be called from an active HandleScope. Hence we have this scope to
        // clean it up before we call CreateBlob
        var handle_scope: v8.HandleScope = undefined;
        v8.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);
        defer v8.v8__HandleScope__DESTRUCT(&handle_scope);

        // Create templates for ALL types (JsApis).
        var templates: [JsApis.len]*const v8.FunctionTemplate = undefined;
        inline for (JsApis, 0..) |JsApi, i| {
            @setEvalBranchQuota(10_000);
            templates[i] = generateConstructor(JsApi, isolate);
        }

        inline for (JsApis, 0..) |JsApi, i| {
            @setEvalBranchQuota(10_000);
            attachClass(JsApi, false, isolate, templates[i], null);
        }

        // Every implementation template participates in V8's FunctionTemplate
        // inheritance chain, including transparent Zig-only wrappers. Method
        // Signatures validate receivers through this parent_template chain;
        // SetPrototypeProviderTemplate only changes the visible prototype and
        // would make inherited operations throw "Illegal invocation". Local
        // replaces a transparent instance's visible prototype after creation
        // while retaining this template ancestry and the child InstanceTemplate.
        inline for (JsApis, 0..) |JsApi, i| {
            if (comptime protoIndexLookup(JsApi)) |proto_index| {
                v8.v8__FunctionTemplate__Inherit(templates[i], templates[proto_index]);

                // FunctionTemplate inheritance links prototype members and
                // receiver signatures, but V8 does not copy properties from
                // the parent's InstanceTemplate. Web IDL
                // [LegacyUnforgeable] attributes are own properties of every
                // implementing object, including objects whose concrete
                // wrapper uses a derived interface (HTMLDocument implements
                // Document.location). Mirror ancestor attributes explicitly
                // onto the derived InstanceTemplate.
                const child_instance = v8.v8__FunctionTemplate__InstanceTemplate(templates[i]).?;
                attachInheritedLegacyUnforgeableMembers(JsApi, isolate, &templates, child_instance);
            }
        }

        // Keep the test path above the first-GC threshold even if the exposed
        // interface set later shrinks.  This makes a missing Isolate::Scope a
        // deterministic setup failure instead of a template-count-dependent
        // latent crash.
        if (comptime @import("builtin").is_test) {
            v8.v8__Isolate__LowMemoryNotification(isolate);
        }

        // Add ALL templates to snapshot (done once, in any context)
        // We need a context to call AddData, so create a temporary one
        {
            const temp_context = v8.v8__Context__New(isolate, null, null);
            v8.v8__Context__Enter(temp_context);
            defer v8.v8__Context__Exit(temp_context);

            var last_data_index: usize = 0;
            inline for (JsApis, 0..) |_, i| {
                @setEvalBranchQuota(10_000);
                const data_index = v8.v8__SnapshotCreator__AddData(snapshot_creator, @ptrCast(templates[i]));
                if (i == 0) {
                    data_start = data_index;
                    last_data_index = data_index;
                } else {
                    if (data_index != last_data_index + 1) {
                        return error.InvalidDataIndex;
                    }
                    last_data_index = data_index;
                }
            }

            // V8 requires a default context. We could probably make this our
            // Page context, but having both the Page and Worker context be
            // added via addContext makes things a little more consistent.
            v8.v8__SnapshotCreator__setDefaultContext(snapshot_creator, temp_context);
        }

        {
            const Window = @import("../webapi/Window.zig");
            const index = try createSnapshotContext(.window, &PageJsApis, Window.JsApi, isolate, snapshot_creator.?, &templates);
            std.debug.assert(index == 0);
        }

        {
            const DedicatedWorkerGlobalScope = @import("../webapi/DedicatedWorkerGlobalScope.zig");
            const index = try createSnapshotContext(.worker, &WorkerJsApis, DedicatedWorkerGlobalScope.JsApi, isolate, snapshot_creator.?, &templates);
            std.debug.assert(index == 1);
        }
    }

    const blob = v8.v8__SnapshotCreator__createBlob(snapshot_creator, v8.kKeep);

    return .{
        .owns_data = true,
        .data_start = data_start,
        .startup_data = blob,
        .external_references = external_references,
    };
}

fn createSnapshotContext(
    comptime realm: Realm,
    comptime ContextApis: []const type,
    comptime GlobalScopeApi: type,
    isolate: *v8.Isolate,
    snapshot_creator: *v8.SnapshotCreator,
    templates: []*const v8.FunctionTemplate,
) !usize {
    // Blink creates a context from the [Global] interface's InstanceTemplate
    // directly. Wrapping it in another FunctionTemplate and inheriting from the
    // interface adds an author-visible prototype between the global proxy and
    // Window.prototype (and likewise for worker globals).
    const global_scope_index = comptime bridge.JsApiLookup.getId(GlobalScopeApi);
    const global_template = v8.v8__FunctionTemplate__InstanceTemplate(templates[global_scope_index]).?;
    v8.v8__ObjectTemplate__SetInternalFieldCount(global_template, comptime countInternalFields(GlobalScopeApi));

    // Window's indexed children are own WindowProxy properties. Named children
    // are different: Blink exposes them from the hidden WindowProperties
    // prototype installed below, so Object.hasOwn(window, name) stays false.
    if (comptime std.mem.eql(u8, GlobalScopeApi.Meta.name, "Window")) {
        v8.v8__ObjectTemplate__SetIndexedHandler(global_template, &.{
            .getter = @import("../webapi/Window.zig").JsApi.index.getter,
            .setter = null,
            .query = null,
            .deleter = null,
            .enumerator = null,
            .definer = @import("../webapi/Window.zig").JsApi.index.definer,
            .descriptor = @import("../webapi/Window.zig").JsApi.index.descriptor,
            .data = null,
            .flags = 0,
        });
    }

    // [Global] installs only the interface's own attributes and operations on
    // the global object. Inherited interfaces remain ordinary prototypes; for
    // example addEventListener lives on EventTarget.prototype rather than as an
    // own Window property.
    comptime {
        if (hasGatedMember(GlobalScopeApi)) {
            @compileError("[Global] scope interface " ++ @typeName(GlobalScopeApi) ++ " has [Exposed]-gated members. This is not supported");
        }
    }
    attachClass(GlobalScopeApi, true, isolate, templates[global_scope_index], global_template);

    const context = v8.v8__Context__New(isolate, global_template, null) orelse
        return error.ContextCreateFailed;
    v8.v8__Context__Enter(context);
    defer v8.v8__Context__Exit(context);

    // Initialize embedder data to null so callbacks can detect snapshot creation
    v8.v8__Context__SetAlignedPointerInEmbedderData(context, 1, null);

    const global_obj = v8.v8__Context__Global(context);

    // Attach constructors for this context's APIs to the global, and for any
    // type with members tagged [Exposed=Window]/[Exposed=Worker], prune the
    // ones that don't match this realm from the per-context Func.prototype.
    const prototype_key = v8.v8__String__NewFromUtf8(isolate, "prototype", v8.kNormal, 9);

    inline for (ContextApis) |JsApi| {
        @setEvalBranchQuota(10_000);
        const template_index = comptime bridge.JsApiLookup.getId(JsApi);
        const func = v8.v8__FunctionTemplate__GetFunction(templates[template_index], context);
        if (comptime exportsGlobalConstructor(JsApi)) {
            if (@hasDecl(JsApi.Meta, "constructor_alias")) {
                const alias = JsApi.Meta.constructor_alias;
                const v8_class_name = v8.v8__String__NewFromUtf8(isolate, alias.ptr, v8.kNormal, @intCast(alias.len));
                var maybe_result: v8.MaybeBool = undefined;
                v8.v8__Object__Set(global_obj, context, v8_class_name, func, &maybe_result);

                const name = JsApi.Meta.name;
                const illegal_class_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                var maybe_result2: v8.MaybeBool = undefined;
                v8.v8__Object__DefineOwnProperty(global_obj, context, illegal_class_name, func, 0, &maybe_result2);
            } else {
                const name = JsApi.Meta.name;
                const v8_class_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                var maybe_result: v8.MaybeBool = undefined;
                // Web IDL: interface objects on the global are non-enumerable.
                v8.v8__Object__DefineOwnProperty(global_obj, context, v8_class_name, func, v8.DontEnum, &maybe_result);
            }
        }

        // WebIDL [Exposed=...] gating. Members are installed on the shared
        // FunctionTemplate by attachClass; here we delete the ones that don't
        // match this realm from the per-context Func.prototype.
        if (comptime hasGatedMember(JsApi)) {
            const func_obj: *const v8.Object = @ptrCast(func);
            if (v8.v8__Object__Get(func_obj, context, prototype_key)) |proto_handle| {
                const proto_obj: *const v8.Object = @ptrCast(proto_handle);
                inline for (@typeInfo(JsApi).@"struct".decls) |d| {
                    const exposed = comptime memberExposed(@field(JsApi, d.name));
                    if (comptime exposed != .both and exposed != realm.asExposed()) {
                        const name: [:0]const u8 = d.name;
                        const name_v8 = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                        var maybe_deleted: v8.MaybeBool = undefined;
                        v8.v8__Object__Delete(proto_obj, context, name_v8, &maybe_deleted);
                    }
                }
            }
        }
    }

    try installPrototypeAliases(ContextApis, isolate, context, templates, prototype_key.?);

    if (comptime realm == .window) {
        try installWindowPropertiesPrototype(isolate, context, templates);
    }

    if (comptime realm == .worker) {
        // A Window exposes V8's snapshot console as an own, writable data
        // property, which matches Blink's [Replaceable] console attribute.
        // A worker instead inherits DarkPanda's Console accessor from
        // WorkerGlobalScope.prototype, so remove the V8 own property there to
        // avoid shadowing that Web IDL member.
        const console_key = v8.v8__String__NewFromUtf8(isolate, "console", v8.kNormal, 7);
        var maybe_deleted: v8.MaybeBool = undefined;
        v8.v8__Object__Delete(global_obj, context, console_key, &maybe_deleted);
        if (maybe_deleted.value == false) {
            return error.ConsoleDeleteError;
        }
    }

    // Set prototype chains on function objects
    // https://groups.google.com/g/v8-users/c/qAQQBmbi--8
    inline for (JsApis, 0..) |JsApi, i| {
        if (comptime protoIndexLookup(JsApi)) |proto_index| {
            const proto_func = v8.v8__FunctionTemplate__GetFunction(templates[proto_index], context);
            const proto_obj: *const v8.Object = @ptrCast(proto_func);

            const self_func = v8.v8__FunctionTemplate__GetFunction(templates[i], context);
            const self_obj: *const v8.Object = @ptrCast(self_func);

            var maybe_result: v8.MaybeBool = undefined;
            v8.v8__Object__SetPrototype(self_obj, context, proto_obj, &maybe_result);
        }
    }

    {
        // DOMException prototype setup
        const code_str = "DOMException.prototype.__proto__ = Error.prototype";
        const code = v8.v8__String__NewFromUtf8(isolate, code_str.ptr, v8.kNormal, @intCast(code_str.len));
        const script = v8.v8__Script__Compile(context, code, null) orelse return error.ScriptCompileFailed;
        _ = v8.v8__Script__Run(script, context) orelse return error.ScriptRunFailed;
    }

    if (comptime realm == .window) {
        // Blink installs the runtime-enabled notRestoredReasons supplement
        // after the generated interface constructor property. Reinsert the
        // existing native accessor at that point so Reflect.ownKeys preserves
        // Chrome 149's ... confidence, constructor, notRestoredReasons,
        // @@toStringTag order without changing its descriptor or callback.
        const code_str =
            \\{
            \\  const p = PerformanceNavigationTiming.prototype;
            \\  const d = Object.getOwnPropertyDescriptor(p, "notRestoredReasons");
            \\  delete p.notRestoredReasons;
            \\  Object.defineProperty(p, "notRestoredReasons", d);
            \\}
        ;
        const code = v8.v8__String__NewFromUtf8(isolate, code_str.ptr, v8.kNormal, @intCast(code_str.len));
        const script = v8.v8__Script__Compile(context, code, null) orelse return error.ScriptCompileFailed;
        _ = v8.v8__Script__Run(script, context) orelse return error.ScriptRunFailed;

        // Performance is assembled from the base interface and several
        // Window-only supplements. Blink installs those supplements after V8's
        // implicit `constructor`; preserve the native descriptors while moving
        // only their realized properties into Chrome 149's observable order.
        const performance_code_str =
            \\{
            \\  const p = Performance.prototype;
            \\  const later = [
            \\    "timing", "navigation", "memory", "eventCounts",
            \\    "interactionCount",
            \\  ];
            \\  const descriptors = later.map(name =>
            \\    Object.getOwnPropertyDescriptor(p, name));
            \\  for (const name of later) delete p[name];
            \\  for (let i = 0; i < later.length; ++i) {
            \\    Object.defineProperty(p, later[i], descriptors[i]);
            \\  }
            \\}
        ;
        const performance_code = v8.v8__String__NewFromUtf8(isolate, performance_code_str.ptr, v8.kNormal, @intCast(performance_code_str.len));
        const performance_script = v8.v8__Script__Compile(context, performance_code, null) orelse return error.ScriptCompileFailed;
        _ = v8.v8__Script__Run(performance_script, context) orelse return error.ScriptRunFailed;

        // Worker combines members from AbstractWorker and Worker in Blink's
        // generated bindings. That installation order places `onmessage`
        // first and `onerror` after the implicit constructor. Reinsert the
        // already-realized native descriptors in Chrome 149 order; retaining
        // the descriptors preserves their V8 signatures/receiver checks and
        // avoids a FunctionTemplate self-reference in the startup snapshot.
        const worker_code_str =
            \\{
            \\  const p = Worker.prototype;
            \\  const order = [
            \\    "onmessage", "postMessage", "terminate", "constructor", "onerror",
            \\  ];
            \\  const descriptors = order.map(name =>
            \\    Object.getOwnPropertyDescriptor(p, name));
            \\  for (const name of order) delete p[name];
            \\  for (let i = 0; i < order.length; ++i) {
            \\    Object.defineProperty(p, order[i], descriptors[i]);
            \\  }
            \\}
        ;
        const worker_code = v8.v8__String__NewFromUtf8(isolate, worker_code_str.ptr, v8.kNormal, @intCast(worker_code_str.len));
        const worker_script = v8.v8__Script__Compile(context, worker_code, null) orelse return error.ScriptCompileFailed;
        _ = v8.v8__Script__Run(worker_script, context) orelse return error.ScriptRunFailed;
    }

    if (comptime realm == .worker) {
        // WorkerNavigator is assembled from several Blink partial interfaces.
        // The base interface and NavigatorNetworkInformation are installed
        // before V8 materializes the implicit `constructor`; later supplements
        // follow it. Our single ObjectTemplate initially puts constructor after
        // every string member, so reinsert only the later members once the
        // prototype is a real object. Copying their native descriptors keeps
        // the original accessors and receiver checks while avoiding a
        // FunctionTemplate self-reference during snapshot construction.
        const code_str =
            \\{
            \\  const p = WorkerNavigator.prototype;
            \\  const later = [
            \\    "hid", "mediaCapabilities", "permissions", "serial", "usb",
            \\    "deviceMemory", "userAgentData", "locks", "storage", "gpu",
            \\    "storageBuckets",
            \\  ];
            \\  const descriptors = later.map(name =>
            \\    Object.getOwnPropertyDescriptor(p, name));
            \\  for (const name of later) delete p[name];
            \\  for (let i = 0; i < later.length; ++i) {
            \\    Object.defineProperty(p, later[i], descriptors[i]);
            \\  }
            \\}
        ;
        const code = v8.v8__String__NewFromUtf8(isolate, code_str.ptr, v8.kNormal, @intCast(code_str.len));
        const script = v8.v8__Script__Compile(context, code, null) orelse return error.ScriptCompileFailed;
        _ = v8.v8__Script__Run(script, context) orelse return error.ScriptRunFailed;
    }

    return v8.v8__SnapshotCreator__AddContext(snapshot_creator, context);
}

// Window's named-properties object is a special, deliberately unexported link
// in Blink's prototype chain:
//   Window.prototype -> WindowProperties -> EventTarget.prototype.
// It is not an IDL interface object, so using a FunctionTemplate would add an
// observable own `constructor`. Build the one-property object explicitly.
fn installWindowPropertiesPrototype(
    isolate: *v8.Isolate,
    context: *const v8.Context,
    templates: []*const v8.FunctionTemplate,
) !void {
    const Window = @import("../webapi/Window.zig");
    const EventTarget = @import("../webapi/EventTarget.zig");
    const window_index = comptime bridge.JsApiLookup.getId(Window.JsApi);
    const event_target_index = comptime bridge.JsApiLookup.getId(EventTarget.JsApi);

    const prototype_key = v8.v8__String__NewFromUtf8(isolate, "prototype", v8.kNormal, 9);
    const window_function = v8.v8__FunctionTemplate__GetFunction(templates[window_index], context);
    const event_target_function = v8.v8__FunctionTemplate__GetFunction(templates[event_target_index], context);

    const window_prototype_value = v8.v8__Object__Get(@ptrCast(window_function), context, prototype_key) orelse
        return error.WindowPrototypeMissing;
    const event_target_prototype_value = v8.v8__Object__Get(@ptrCast(event_target_function), context, prototype_key) orelse
        return error.EventTargetPrototypeMissing;
    if (!v8.v8__Value__IsObject(window_prototype_value) or !v8.v8__Value__IsObject(event_target_prototype_value)) {
        return error.InvalidWindowPrototypeChain;
    }

    const window_prototype: *const v8.Object = @ptrCast(window_prototype_value);
    const event_target_prototype: *const v8.Object = @ptrCast(event_target_prototype_value);
    const window_properties_template = v8.v8__ObjectTemplate__New__DEFAULT(isolate) orelse
        return error.WindowPropertiesTemplateCreateFailed;
    v8.v8__ObjectTemplate__SetNamedHandler(window_properties_template, &.{
        .getter = bridge.unknownWindowPropertyCallback,
        .setter = null,
        .query = null,
        .deleter = null,
        .enumerator = null,
        .definer = null,
        .descriptor = null,
        .data = null,
        .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
    });
    const window_properties = v8.v8__ObjectTemplate__NewInstance(window_properties_template, context) orelse
        return error.WindowPropertiesCreateFailed;

    var maybe_result: v8.MaybeBool = undefined;
    v8.v8__Object__SetPrototype(window_properties, context, event_target_prototype, &maybe_result);
    if (!maybe_result.value) return error.WindowPropertiesPrototypeSetFailed;

    const tag_key = v8.v8__Symbol__GetToStringTag(isolate);
    const tag_value = v8.v8__String__NewFromUtf8(isolate, "WindowProperties", v8.kNormal, 16);
    v8.v8__Object__DefineOwnProperty(
        window_properties,
        context,
        @ptrCast(tag_key),
        tag_value,
        v8.ReadOnly + v8.DontEnum,
        &maybe_result,
    );
    if (!maybe_result.value) return error.WindowPropertiesTagDefineFailed;

    v8.v8__Object__SetPrototype(window_prototype, context, window_properties, &maybe_result);
    if (!maybe_result.value) return error.WindowPrototypeSetFailed;
    // Blink finishes the Window.prototype -> WindowProperties link before
    // making the realized prototype object immutable. Doing this on the
    // template would reject the setup transition above.
    v8.v8__Object__SetImmutableProto(isolate, window_prototype);
}

fn exportsGlobalConstructor(comptime JsApi: type) bool {
    if (!@hasDecl(JsApi.Meta, "name")) return false;
    if (@hasDecl(JsApi.Meta, "global_export")) return JsApi.Meta.global_export;
    return true;
}

/// A transparent implementation retains its own V8 InstanceTemplate while its
/// instances use the exact prototype object supplied by the `_proto` parent.
/// This is for Zig-side implementation wrappers, not Web IDL interfaces with a
/// distinct author-visible prototype.
fn usesTransparentPrototype(comptime JsApi: type) bool {
    if (!@hasDecl(JsApi.Meta, "transparent_prototype")) return false;
    if (@TypeOf(JsApi.Meta.transparent_prototype) != bool) {
        @compileError(@typeName(JsApi) ++ ".Meta.transparent_prototype must be a bool");
    }
    if (JsApi.Meta.transparent_prototype and exportsGlobalConstructor(JsApi)) {
        @compileError(@typeName(JsApi) ++ " cannot export a global constructor with a transparent prototype");
    }
    return JsApi.Meta.transparent_prototype;
}

fn usesLegacyUnforgeableMembers(comptime JsApi: type) bool {
    if (!@hasDecl(JsApi.Meta, "legacy_unforgeable_members")) return false;
    if (@TypeOf(JsApi.Meta.legacy_unforgeable_members) != bool) {
        @compileError(@typeName(JsApi) ++ ".Meta.legacy_unforgeable_members must be a bool");
    }
    return JsApi.Meta.legacy_unforgeable_members;
}

fn immutableProto(comptime JsApi: type) ?bridge.ImmutableProto {
    if (!@hasDecl(JsApi.Meta, "immutable_proto")) return null;
    if (@TypeOf(JsApi.Meta.immutable_proto) != bridge.ImmutableProto) {
        @compileError(@typeName(JsApi) ++ ".Meta.immutable_proto must be a bridge.ImmutableProto");
    }
    return JsApi.Meta.immutable_proto;
}

fn templatePropertyAttributes(property: bridge.InstanceTemplateProperty) v8.PropertyAttribute {
    var attributes: v8.PropertyAttribute = v8.None;
    if (!property.writable) attributes |= v8.ReadOnly;
    if (!property.enumerable) attributes |= v8.DontEnum;
    if (!property.configurable) attributes |= v8.DontDelete;
    return attributes;
}

fn wellKnownSymbol(isolate: *v8.Isolate, symbol: bridge.WellKnownSymbol) ?*const v8.Name {
    return @ptrCast(switch (symbol) {
        .async_iterator => v8.v8__Symbol__GetAsyncIterator(isolate),
        .has_instance => v8.v8__Symbol__GetHasInstance(isolate),
        .is_concat_spreadable => v8.v8__Symbol__GetIsConcatSpreadable(isolate),
        .iterator => v8.v8__Symbol__GetIterator(isolate),
        .match => v8.v8__Symbol__GetMatch(isolate),
        .replace => v8.v8__Symbol__GetReplace(isolate),
        .search => v8.v8__Symbol__GetSearch(isolate),
        .split => v8.v8__Symbol__GetSplit(isolate),
        .to_primitive => v8.v8__Symbol__GetToPrimitive(isolate),
        .to_string_tag => v8.v8__Symbol__GetToStringTag(isolate),
        .unscopables => v8.v8__Symbol__GetUnscopables(isolate),
    });
}

fn templatePropertyKey(isolate: *v8.Isolate, key: bridge.InstanceTemplateProperty.Key) ?*const v8.Name {
    return switch (key) {
        .string => |name| @ptrCast(v8.v8__String__NewFromUtf8(
            isolate,
            name.ptr,
            v8.kNormal,
            @intCast(name.len),
        )),
        .well_known_symbol => |symbol| wellKnownSymbol(isolate, symbol),
    };
}

fn templateIntrinsic(intrinsic: bridge.TemplateIntrinsic) v8.Intrinsic {
    return @intCast(switch (intrinsic) {
        .array_prototype_entries => v8.kArrayProto_entries,
        .array_prototype_for_each => v8.kArrayProto_forEach,
        .array_prototype_keys => v8.kArrayProto_keys,
        .array_prototype_values => v8.kArrayProto_values,
        .array_prototype => v8.kArrayPrototype,
        .async_iterator_prototype => v8.kAsyncIteratorPrototype,
        .error_prototype => v8.kErrorPrototype,
        .iterator_prototype => v8.kIteratorPrototype,
        .map_iterator_prototype => v8.kMapIteratorPrototype,
        .object_prototype_value_of => v8.kObjProto_valueOf,
        .set_iterator_prototype => v8.kSetIteratorPrototype,
    });
}

fn installInstanceTemplateProperties(
    comptime JsApi: type,
    comptime phase: bridge.InstanceTemplateProperty.Phase,
    isolate: *v8.Isolate,
    instance: *const v8.ObjectTemplate,
) void {
    if (!@hasDecl(JsApi.Meta, "instance_template_properties")) return;

    inline for (JsApi.Meta.instance_template_properties) |property| {
        if (@TypeOf(property) != bridge.InstanceTemplateProperty) {
            @compileError(@typeName(JsApi) ++ ".Meta.instance_template_properties must contain bridge.InstanceTemplateProperty values");
        }
        if (property.phase != phase) continue;

        const key = templatePropertyKey(isolate, property.key);
        const attributes = templatePropertyAttributes(property);
        switch (property.value) {
            .undefined_value => {
                const value = js.simpleZigValueToJs(.{ .handle = isolate }, js.Undefined{}, true, false);
                v8.v8__Template__Set(@ptrCast(instance), key, value, attributes);
            },
            .intrinsic => |intrinsic| v8.v8__Template__SetIntrinsicDataProperty(
                @ptrCast(instance),
                key,
                templateIntrinsic(intrinsic),
                attributes,
            ),
        }
    }
}

fn installPrototypeTemplateProperties(
    comptime JsApi: type,
    comptime phase: bridge.InstanceTemplateProperty.Phase,
    isolate: *v8.Isolate,
    prototype: *const v8.ObjectTemplate,
) void {
    if (!@hasDecl(JsApi.Meta, "prototype_template_properties")) return;

    inline for (JsApi.Meta.prototype_template_properties) |property| {
        if (@TypeOf(property) != bridge.InstanceTemplateProperty) {
            @compileError(@typeName(JsApi) ++ ".Meta.prototype_template_properties must contain bridge.InstanceTemplateProperty values");
        }
        if (property.phase != phase) continue;

        const key = templatePropertyKey(isolate, property.key);
        const attributes = templatePropertyAttributes(property);
        switch (property.value) {
            .undefined_value => {
                const value = js.simpleZigValueToJs(.{ .handle = isolate }, js.Undefined{}, true, false);
                v8.v8__Template__Set(@ptrCast(prototype), key, value, attributes);
            },
            .intrinsic => |intrinsic| v8.v8__Template__SetIntrinsicDataProperty(
                @ptrCast(prototype),
                key,
                templateIntrinsic(intrinsic),
                attributes,
            ),
        }
    }
}

fn hasGatedMember(comptime JsApi: type) bool {
    comptime {
        for (@typeInfo(JsApi).@"struct".decls) |d| {
            if (memberExposed(@field(JsApi, d.name)) != .both) {
                return true;
            }
        }
        return false;
    }
}

fn memberExposed(value: anytype) Caller.Function.Opts.Exposed {
    const T = @TypeOf(value);
    if (T == bridge.Accessor or T == bridge.Function) {
        return value.exposed;
    }
    return .both;
}

fn countExternalReferences() comptime_int {
    @setEvalBranchQuota(100_000);

    var count: comptime_int = 0;

    // +1 for the illegal constructor callback shared by various types
    count += 1;

    // +1 for the noop function shared by various types
    count += 1;

    // +1 for unknownWindowPropertyCallback used on Window's global template
    count += 1;

    const wpt_extensions_enabled = lp.build_config.wpt_extensions;

    inline for (JsApis) |JsApi| {
        if (@hasDecl(JsApi.Meta, "access_check")) {
            const access = JsApi.Meta.access_check;
            count += 1; // AccessCheckCallback

            const named = access.named;
            count += 1; // named getter is required
            if (named.setter != null) count += 1;
            if (named.query != null) count += 1;
            if (named.deleter != null) count += 1;
            if (named.enumerator != null) count += 1;
            if (named.definer != null) count += 1;
            if (named.descriptor != null) count += 1;

            const indexed = access.indexed;
            count += 1; // indexed getter is required
            if (indexed.setter != null) count += 1;
            if (indexed.query != null) count += 1;
            if (indexed.deleter != null) count += 1;
            if (indexed.enumerator != null) count += 1;
            if (indexed.definer != null) count += 1;
            if (indexed.descriptor != null) count += 1;
        }

        if (@hasDecl(JsApi, "constructor")) {
            count += 1;
        }

        if (@hasDecl(JsApi, "callable")) {
            count += 1;
        }

        const declarations = @typeInfo(JsApi).@"struct".decls;
        inline for (declarations) |d| {
            const value = @field(JsApi, d.name);
            const T = @TypeOf(value);
            if (T == bridge.Accessor) {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }
                if (value.getter != null) count += 1;
                if (value.setter != null) {
                    count += 1;
                }
            } else if (T == bridge.Function) {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }
                count += 1;
            } else if (T == bridge.Iterator) {
                count += 1;
            } else if (T == bridge.Indexed) {
                count += 1;
                if (value.enumerator != null) {
                    count += 1;
                }
                if (value.setter != null) count += 1;
                if (value.deleter != null) count += 1;
                if (value.query != null) count += 1;
                if (value.definer != null) count += 1;
                if (value.descriptor != null) count += 1;
            } else if (T == bridge.NamedIndexed) {
                count += 1;
                if (value.setter != null) count += 1;
                if (value.deleter != null) count += 1;
                if (value.enumerator != null) count += 1;
                if (value.query != null) count += 1;
                if (value.definer != null) count += 1;
                if (value.descriptor != null) count += 1;
            }
        }
    }

    if (comptime IS_DEBUG) {
        inline for (JsApis) |JsApi| {
            if (comptime installsDebugUnknownPropertyHandler(JsApi)) {
                count += 1;
            }
        }
    }

    return count + 1; // +1 for null terminator
}

fn collectExternalReferences() [countExternalReferences()]isize {
    var idx: usize = 0;
    var references = std.mem.zeroes([countExternalReferences()]isize);

    references[idx] = @bitCast(@intFromPtr(&illegalConstructorCallback));
    idx += 1;

    references[idx] = @bitCast(@intFromPtr(&bridge.Function.noopFunction));
    idx += 1;

    references[idx] = @bitCast(@intFromPtr(&bridge.unknownWindowPropertyCallback));
    idx += 1;

    const wpt_extensions_enabled = lp.build_config.wpt_extensions;

    inline for (JsApis) |JsApi| {
        if (@hasDecl(JsApi.Meta, "access_check")) {
            const access = JsApi.Meta.access_check;
            references[idx] = @bitCast(@intFromPtr(&access.callback));
            idx += 1;

            const named = access.named;
            references[idx] = @bitCast(@intFromPtr(named.getter));
            idx += 1;
            if (named.setter) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (named.query) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (named.deleter) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (named.enumerator) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (named.definer) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (named.descriptor) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }

            const indexed = access.indexed;
            references[idx] = @bitCast(@intFromPtr(indexed.getter));
            idx += 1;
            if (indexed.setter) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (indexed.query) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (indexed.deleter) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (indexed.enumerator) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (indexed.definer) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
            if (indexed.descriptor) |callback| {
                references[idx] = @bitCast(@intFromPtr(callback));
                idx += 1;
            }
        }

        if (@hasDecl(JsApi, "constructor")) {
            references[idx] = @bitCast(@intFromPtr(JsApi.constructor.func));
            idx += 1;
        }

        if (@hasDecl(JsApi, "callable")) {
            references[idx] = @bitCast(@intFromPtr(JsApi.callable.func));
            idx += 1;
        }

        const declarations = @typeInfo(JsApi).@"struct".decls;
        inline for (declarations) |d| {
            const value = @field(JsApi, d.name);
            const T = @TypeOf(value);
            if (T == bridge.Accessor) {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }

                if (value.getter) |getter| {
                    references[idx] = @bitCast(@intFromPtr(getter));
                    idx += 1;
                }
                if (value.setter) |setter| {
                    references[idx] = @bitCast(@intFromPtr(setter));
                    idx += 1;
                }
            } else if (T == bridge.Function) {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }
                references[idx] = @bitCast(@intFromPtr(value.func));
                idx += 1;
            } else if (T == bridge.Iterator) {
                references[idx] = @bitCast(@intFromPtr(value.func));
                idx += 1;
            } else if (T == bridge.Indexed) {
                references[idx] = @bitCast(@intFromPtr(value.getter));
                idx += 1;
                if (value.enumerator) |enumerator| {
                    references[idx] = @bitCast(@intFromPtr(enumerator));
                    idx += 1;
                }
                if (value.setter) |setter| {
                    references[idx] = @bitCast(@intFromPtr(setter));
                    idx += 1;
                }
                if (value.deleter) |deleter| {
                    references[idx] = @bitCast(@intFromPtr(deleter));
                    idx += 1;
                }
                if (value.query) |query| {
                    references[idx] = @bitCast(@intFromPtr(query));
                    idx += 1;
                }
                if (value.definer) |definer| {
                    references[idx] = @bitCast(@intFromPtr(definer));
                    idx += 1;
                }
                if (value.descriptor) |descriptor| {
                    references[idx] = @bitCast(@intFromPtr(descriptor));
                    idx += 1;
                }
            } else if (T == bridge.NamedIndexed) {
                references[idx] = @bitCast(@intFromPtr(value.getter));
                idx += 1;
                if (value.setter) |setter| {
                    references[idx] = @bitCast(@intFromPtr(setter));
                    idx += 1;
                }
                if (value.deleter) |deleter| {
                    references[idx] = @bitCast(@intFromPtr(deleter));
                    idx += 1;
                }
                if (value.enumerator) |enumerator| {
                    references[idx] = @bitCast(@intFromPtr(enumerator));
                    idx += 1;
                }
                if (value.query) |query| {
                    references[idx] = @bitCast(@intFromPtr(query));
                    idx += 1;
                }
                if (value.definer) |definer| {
                    references[idx] = @bitCast(@intFromPtr(definer));
                    idx += 1;
                }
                if (value.descriptor) |descriptor| {
                    references[idx] = @bitCast(@intFromPtr(descriptor));
                    idx += 1;
                }
            }
        }
    }

    if (comptime IS_DEBUG) {
        inline for (JsApis) |JsApi| {
            if (comptime installsDebugUnknownPropertyHandler(JsApi)) {
                references[idx] = @bitCast(@intFromPtr(bridge.unknownObjectPropertyCallback(JsApi)));
                idx += 1;
            }
        }
    }

    return references;
}

fn countInternalFields(comptime JsApi: type) u8 {
    var last_used_id = 0;
    var cache_count: u8 = 0;

    inline for (@typeInfo(JsApi).@"struct".decls) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        switch (definition) {
            inline bridge.Accessor, bridge.Function => {
                const cache = value.cache orelse continue;
                if (cache != .internal) {
                    continue;
                }
                // We assert that they are declared in-order. This isn't necessary
                // but I don't want to do anything fancy to look for gaps or
                // duplicates.
                const internal_id = cache.internal;
                if (internal_id != last_used_id + 1) {
                    @compileError(@typeName(JsApi) ++ "." ++ name ++ " has a non-monotonic cache index");
                }
                last_used_id = internal_id;
                cache_count += 1; // this is just last_used, but it's more explicit this way
            },
            else => {},
        }
    }

    if (@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        return cache_count;
    }

    // we need cache_count internal fields, + 1 for the TAO pointer (the v8 -> Zig)
    // mapping) itself.
    return cache_count + 1;
}

// Shared illegal constructor callback for types without explicit constructors
fn illegalConstructorCallback(raw_info: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(raw_info);

    // Recover the constructor's name via NewTarget, whose .name property was
    // set via SetClassName when the FunctionTemplate was built. Lets us tell
    // `new DOMException()` apart from `new MutationRecord()` in the warning.
    var name_buf: [128]u8 = undefined;
    var name: []const u8 = "<unknown>";
    if (v8.v8__FunctionCallbackInfo__NewTarget(raw_info)) |new_target| {
        if (v8.v8__Value__IsFunction(new_target)) {
            const func: *const v8.Function = @ptrCast(new_target);
            if (v8.v8__Function__GetName(func)) |name_value| {
                if (v8.v8__Value__IsString(name_value)) {
                    const str: *const v8.String = @ptrCast(name_value);
                    const n = v8.v8__String__WriteUtf8(str, isolate, &name_buf, name_buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
                    name = name_buf[0..@intCast(n)];
                }
            }
        }
    }
    log.info(.js, "Illegal constructor call", .{ .name = name });

    // V8's exception propagation callback decorates this compact reason using
    // the constructor template metadata while retaining the short stack line.
    const reason = "Illegal constructor";
    const message = v8.v8__String__NewFromUtf8(isolate, reason.ptr, v8.kNormal, @intCast(reason.len)).?;
    const js_exception = v8.v8__Exception__TypeError(message).?;

    _ = v8.v8__Isolate__ThrowException(isolate, js_exception);
    var return_value: v8.ReturnValue = undefined;
    v8.v8__FunctionCallbackInfo__GetReturnValue(raw_info, &return_value);
    v8.v8__ReturnValue__Set(return_value, js_exception);
}

// Helper to check if a JsApi has a NamedIndexed handler (public for reuse)
fn hasNamedIndexedGetter(comptime JsApi: type) bool {
    const declarations = @typeInfo(JsApi).@"struct".decls;
    inline for (declarations) |d| {
        const value = @field(JsApi, d.name);
        const T = @TypeOf(value);
        if (T == bridge.NamedIndexed) {
            return true;
        }
    }
    return false;
}

// Snapshot [Global] instance templates are also used as the actual V8 global
// templates. Their embedder Context pointer is deliberately null while the
// snapshot is being assembled, so the generic debug-only property logger
// (which enters through Caller.init) must never be attached to them. Window's
// unknown named-property behavior is provided separately by WindowProperties.
//
// Access-checked platform objects are another important exclusion. V8 keeps
// SetAccessCheckCallbackAndHandler's fallback handlers in AccessCheckInfo; it
// does not mark the object's map as having ordinary property interceptors.
// Installing the debug logger with SetNamedHandler would do exactly that, and
// V8 intentionally rejects Object.preventExtensions/seal/freeze on maps with
// interceptors. In particular that made Debug Location wrappers observably
// differ from Blink's wrappers.
fn installsDebugUnknownPropertyHandler(comptime JsApi: type) bool {
    const global_scope = @hasDecl(JsApi.Meta, "global_scope") and JsApi.Meta.global_scope;
    const access_checked = @hasDecl(JsApi.Meta, "access_check");
    return IS_DEBUG and !global_scope and !access_checked and !hasNamedIndexedGetter(JsApi);
}

comptime {
    const Window = @import("../webapi/Window.zig");
    const DedicatedWorkerGlobalScope = @import("../webapi/DedicatedWorkerGlobalScope.zig");
    const Location = @import("../webapi/Location.zig");
    if (installsDebugUnknownPropertyHandler(Window.JsApi) or
        installsDebugUnknownPropertyHandler(DedicatedWorkerGlobalScope.JsApi) or
        installsDebugUnknownPropertyHandler(Location.JsApi))
    {
        @compileError("snapshot global/access-checked templates must not install the generic debug unknown-property callback");
    }
}

// Generic prototype index lookup for a given API list
fn protoIndexLookup(comptime JsApi: type) ?u16 {
    @setEvalBranchQuota(100_000);
    comptime {
        const T = JsApi.bridge.type;
        if (!@hasField(T, "_proto")) {
            return null;
        }
        const Ptr = std.meta.fieldInfo(T, ._proto).type;
        const F = @typeInfo(Ptr).pointer.child;
        // Look up in the provided API list
        for (JsApis, 0..) |Api, i| {
            if (Api == F.JsApi) {
                return i;
            }
        }
        @compileError("Prototype " ++ @typeName(F.JsApi) ++ " not found in API list");
    }
}

fn setWebIDLExceptionContext(
    comptime JsApi: type,
    isolate: *v8.Isolate,
    function_template: *const v8.FunctionTemplate,
    context: v8.ExceptionContext,
) void {
    const interface_name = comptime if (@hasDecl(JsApi.Meta, "name"))
        JsApi.Meta.name
    else
        @typeName(JsApi);
    const interface_name_v8 = v8.v8__String__NewFromUtf8(
        isolate,
        interface_name.ptr,
        v8.kNormal,
        @intCast(interface_name.len),
    );
    v8.v8__FunctionTemplate__SetInterfaceName(function_template, interface_name_v8);
    v8.v8__FunctionTemplate__SetExceptionContext(function_template, context);
}

// Generate a constructor template for a JsApi type (public for reuse)
pub fn generateConstructor(comptime JsApi: type, isolate: *v8.Isolate) *const v8.FunctionTemplate {
    const callback = blk: {
        if (@hasDecl(JsApi, "constructor")) {
            break :blk JsApi.constructor.func;
        }
        break :blk illegalConstructorCallback;
    };

    const arity: c_int = if (@hasDecl(JsApi, "constructor")) JsApi.constructor.arity else 0;
    const template = v8.v8__FunctionTemplate__New__Config(isolate, &.{
        .length = arity,
        .callback = callback,
        .behavior = v8.kConstructorBehavior_Allow,
    }).?;
    {
        const internal_field_count = comptime countInternalFields(JsApi);
        if (internal_field_count > 0) {
            const instance_template = v8.v8__FunctionTemplate__InstanceTemplate(template);
            v8.v8__ObjectTemplate__SetInternalFieldCount(instance_template, internal_field_count);
        }
    }
    const name_str = if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi);
    const class_name = v8.v8__String__NewFromUtf8(isolate, name_str.ptr, v8.kNormal, @intCast(name_str.len));
    v8.v8__FunctionTemplate__SetClassName(template, class_name);
    v8.v8__FunctionTemplate__SetInterfaceName(template, class_name);
    v8.v8__FunctionTemplate__SetExceptionContext(template, v8.kExceptionContext_Constructor);
    // Web IDL: interface object's `prototype` property is non-writable/non-configurable.
    v8.v8__FunctionTemplate__ReadOnlyPrototype(template);
    return template;
}

// Attach JsApi members to a template (public for reuse). This is called on all
// types. But, for globals (window, WGS) it's called twice. The first time, it's
// called like any other interface. The 2nd time, it's called with flatten == true
// and define_on != null. This is the "flattening" pass, and it defines all of
// the functions/accessors on directly on the global instance. Thus, globals have
// it defined on both their prototype (first pass) and their own instance (2nd pass).
fn attachInheritedLegacyUnforgeableMembers(
    comptime JsApi: type,
    isolate: *v8.Isolate,
    templates: []const *const v8.FunctionTemplate,
    target: *const v8.ObjectTemplate,
) void {
    if (comptime protoIndexLookup(JsApi)) |parent_index| {
        const ParentApi = JsApis[parent_index];
        attachInheritedLegacyUnforgeableMembers(ParentApi, isolate, templates, target);
        attachLegacyUnforgeableMembers(ParentApi, isolate, templates[parent_index], target);
    }
}

fn attachLegacyUnforgeableMembers(
    comptime JsApi: type,
    isolate: *v8.Isolate,
    template: *const v8.FunctionTemplate,
    target: *const v8.ObjectTemplate,
) void {
    const signature = v8.v8__Signature__New(isolate, template);
    const members_non_enumerable = @hasDecl(JsApi.Meta, "members_non_enumerable") and JsApi.Meta.members_non_enumerable;
    const wpt_extensions_enabled = lp.build_config.wpt_extensions;

    inline for (@typeInfo(JsApi).@"struct".decls) |declaration| {
        const name: [:0]const u8 = declaration.name;
        const value = @field(JsApi, name);
        switch (@TypeOf(value)) {
            bridge.Accessor => {
                if (!value.legacy_unforgeable or value.static) continue;
                if (value.wpt_only and !wpt_extensions_enabled) continue;

                const js_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                const getter_callback = if (value.getter) |getter| blk: {
                    const callback = v8.v8__FunctionTemplate__New__Config(isolate, &.{
                        .callback = getter,
                        .data = @ptrCast(js_name),
                        .signature = signature,
                    }).?;
                    const getter_name = "get " ++ name;
                    const getter_name_v8 = v8.v8__String__NewFromUtf8(isolate, getter_name.ptr, v8.kNormal, @intCast(getter_name.len));
                    v8.v8__FunctionTemplate__SetClassName(callback, getter_name_v8);
                    setWebIDLExceptionContext(JsApi, isolate, callback, v8.kExceptionContext_AttributeGet);
                    break :blk callback;
                } else null;
                const setter_callback = if (value.setter) |setter| blk: {
                    const callback = v8.v8__FunctionTemplate__New__Config(isolate, &.{
                        .callback = setter,
                        .data = @ptrCast(js_name),
                        .signature = signature,
                        .length = 1,
                    }).?;
                    const setter_name = "set " ++ name;
                    const setter_name_v8 = v8.v8__String__NewFromUtf8(isolate, setter_name.ptr, v8.kNormal, @intCast(setter_name.len));
                    v8.v8__FunctionTemplate__SetClassName(callback, setter_name_v8);
                    setWebIDLExceptionContext(JsApi, isolate, callback, v8.kExceptionContext_AttributeSet);
                    break :blk callback;
                } else null;

                // A getter-only Web IDL attribute is an accessor with an
                // absent setter. v8.ReadOnly is a data-property attribute and
                // changes V8's [[Set]] failure into the wrong "read only
                // property" diagnostic.
                var attributes: v8.PropertyAttribute = v8.DontDelete;
                if (members_non_enumerable) attributes |= v8.DontEnum;
                v8.v8__ObjectTemplate__SetAccessorProperty__Config(target, &.{
                    .key = js_name,
                    .getter = getter_callback,
                    .setter = setter_callback,
                    .attribute = attributes,
                });
            },
            else => {},
        }
    }
}

fn attachClass(comptime JsApi: type, comptime flatten: bool, isolate: *v8.Isolate, template: *const v8.FunctionTemplate, define_on: ?*const v8.ObjectTemplate) void {
    const instance = v8.v8__FunctionTemplate__InstanceTemplate(template);
    const transparent_prototype = comptime usesTransparentPrototype(JsApi);
    const prototype: ?*const v8.ObjectTemplate = if (transparent_prototype)
        null
    else
        v8.v8__FunctionTemplate__PrototypeTemplate(template);
    const signature = v8.v8__Signature__New(isolate, template);

    // Namespace objects (e.g. console) expose their members as own properties
    // of each instance rather than via the prototype, so Object.entries(...)
    // returns them. See https://console.spec.whatwg.org/#console-namespace.
    const own_properties = @hasDecl(JsApi.Meta, "own_properties") and JsApi.Meta.own_properties;
    const legacy_unforgeable_members = comptime usesLegacyUnforgeableMembers(JsApi);
    const global_scope = @hasDecl(JsApi.Meta, "global_scope") and JsApi.Meta.global_scope;
    const cross_origin_surface = @hasDecl(JsApi.Meta, "cross_origin_surface") and JsApi.Meta.cross_origin_surface;
    const members_also_on_hidden_prototype = @hasDecl(JsApi.Meta, "members_also_on_hidden_prototype") and JsApi.Meta.members_also_on_hidden_prototype;
    const members_non_enumerable = @hasDecl(JsApi.Meta, "members_non_enumerable") and JsApi.Meta.members_non_enumerable;
    const methods_readonly = @hasDecl(JsApi.Meta, "methods_readonly") and JsApi.Meta.methods_readonly;
    if (comptime transparent_prototype and (own_properties or legacy_unforgeable_members or global_scope)) {
        @compileError(@typeName(JsApi) ++ " cannot combine Meta.transparent_prototype with own_properties/legacy_unforgeable_members/global_scope");
    }
    if (comptime legacy_unforgeable_members and (own_properties or global_scope)) {
        @compileError(@typeName(JsApi) ++ " cannot combine Meta.legacy_unforgeable_members with own_properties/global_scope");
    }
    const member_template: ?*const v8.ObjectTemplate = if (own_properties or legacy_unforgeable_members) instance else prototype;

    // Blink's SetupIDLInterfaceTemplate installs @@toStringTag on the
    // interface prototype before installing any IDL members. Apart from
    // putting the property on the right object, doing this before the member
    // loop preserves Reflect.ownKeys ordering when an interface also exposes
    // another well-known symbol (for example ReadableStream@@asyncIterator).
    // Namespace objects have no interface prototype, so their tag remains an
    // own property of the namespace object, matching SetupIDLNamespaceTemplate.
    if (comptime !flatten and !transparent_prototype and !cross_origin_surface and @hasDecl(JsApi.Meta, "name")) {
        const tag_template = if (own_properties) instance else prototype.?;
        const tag_key = v8.v8__Symbol__GetToStringTag(isolate);
        const tag_value = v8.v8__String__NewFromUtf8(isolate, JsApi.Meta.name.ptr, v8.kNormal, @intCast(JsApi.Meta.name.len));
        // Web IDL: { writable: false, enumerable: false, configurable: true }.
        v8.v8__Template__Set(@ptrCast(tag_template), tag_key, tag_value, v8.ReadOnly + v8.DontEnum);
    }

    if (comptime !flatten) {
        installInstanceTemplateProperties(JsApi, .before_members, isolate, instance.?);
        if (comptime @hasDecl(JsApi.Meta, "prototype_template_properties")) {
            if (comptime transparent_prototype) {
                @compileError(@typeName(JsApi) ++ " requests prototype template properties but has no public prototype");
            }
            installPrototypeTemplateProperties(JsApi, .before_members, isolate, prototype.?);
        }
    }

    const declarations = @typeInfo(JsApi).@"struct".decls;
    const wpt_extensions_enabled = lp.build_config.wpt_extensions;

    inline for (declarations) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        // Attributes and operations declared by a [Global] interface are own
        // properties of its global object. They must not also appear on the
        // interface prototype. Constants and other interface-object metadata
        // still use the ordinary installation path below.
        if (comptime !flatten and global_scope) {
            switch (definition) {
                bridge.Accessor, bridge.Function => continue,
                else => {},
            }
        }

        if (comptime flatten) {
            // [Global] flattening only mirrors non-static accessors/methods onto itself
            switch (definition) {
                bridge.Accessor, bridge.Function => if (value.static) continue,
                else => continue,
            }
        }

        switch (definition) {
            bridge.Accessor => {
                if (comptime transparent_prototype) {
                    @compileError(@typeName(JsApi) ++ " is transparent but declares accessor " ++ name ++ "; put prototype members on its public parent");
                }
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }

                const js_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                const getter_signature = if (value.static) null else signature;
                const getter_callback = if (value.getter) |getter| blk: {
                    const cb = v8.v8__FunctionTemplate__New__Config(isolate, &.{
                        .callback = getter,
                        .data = @ptrCast(js_name),
                        .signature = getter_signature,
                    }).?;
                    // WebIDL: getter function's .name should be "get X"
                    const getter_name_str = "get " ++ name;
                    const getter_name_v8 = v8.v8__String__NewFromUtf8(isolate, getter_name_str.ptr, v8.kNormal, @intCast(getter_name_str.len));
                    v8.v8__FunctionTemplate__SetClassName(cb, getter_name_v8);
                    setWebIDLExceptionContext(JsApi, isolate, cb, v8.kExceptionContext_AttributeGet);
                    break :blk cb;
                } else null;

                const setter_callback = if (value.setter) |setter| blk: {
                    const cb = v8.v8__FunctionTemplate__New__Config(isolate, &.{
                        .callback = setter,
                        .data = @ptrCast(js_name),
                        .signature = getter_signature,
                        .length = 1,
                    }).?;
                    const setter_name_str = "set " ++ name;
                    const setter_name_v8 = v8.v8__String__NewFromUtf8(isolate, setter_name_str.ptr, v8.kNormal, @intCast(setter_name_str.len));
                    v8.v8__FunctionTemplate__SetClassName(cb, setter_name_v8);
                    setWebIDLExceptionContext(JsApi, isolate, cb, v8.kExceptionContext_AttributeSet);
                    break :blk cb;
                } else null;

                // Leave getter-only accessors without v8.ReadOnly. The null
                // setter supplies the Web IDL [[Set]] semantics and Chrome's
                // "which has only a getter" TypeError in strict mode.
                var attribute: v8.PropertyAttribute = 0;
                if (value.deletable == false) {
                    attribute |= v8.DontDelete;
                }
                if (legacy_unforgeable_members and !value.static) {
                    attribute |= v8.DontDelete;
                }
                if (value.legacy_unforgeable) {
                    attribute |= v8.DontDelete;
                }
                if (members_non_enumerable) {
                    attribute |= v8.DontEnum;
                }

                if (value.static) {
                    v8.v8__Template__SetAccessorProperty(@ptrCast(template), js_name, getter_callback, setter_callback, attribute);
                } else {
                    // Web IDL: attributes on the interface prototype object
                    // (and mirrored onto [Global] instances) are enumerable.
                    const target_template = if (value.legacy_unforgeable)
                        (define_on orelse instance.?)
                    else
                        (define_on orelse member_template.?);
                    v8.v8__ObjectTemplate__SetAccessorProperty__Config(target_template, &.{
                        .key = js_name,
                        .getter = getter_callback,
                        .setter = setter_callback,
                        .attribute = attribute,
                    });
                    if (comptime members_also_on_hidden_prototype and !value.legacy_unforgeable) {
                        v8.v8__ObjectTemplate__SetAccessorProperty__Config(prototype.?, &.{
                            .key = js_name,
                            .getter = getter_callback,
                            .setter = setter_callback,
                            .attribute = attribute,
                        });
                        if (comptime value.getter != null) {
                            const getter_template = getter_callback;
                            const backing_name = bridge.crossOriginGetterBackingName(name);
                            const backing_key = v8.v8__String__NewFromUtf8(isolate, backing_name.ptr, v8.kNormal, @intCast(backing_name.len));
                            v8.v8__Template__Set(
                                @ptrCast(prototype.?),
                                backing_key,
                                @ptrCast(getter_template),
                                v8.ReadOnly | v8.DontEnum,
                            );
                        }
                        if (comptime value.setter != null) {
                            const setter_template = setter_callback;
                            const backing_name = bridge.crossOriginSetterBackingName(name);
                            const backing_key = v8.v8__String__NewFromUtf8(isolate, backing_name.ptr, v8.kNormal, @intCast(backing_name.len));
                            v8.v8__Template__Set(
                                @ptrCast(prototype.?),
                                backing_key,
                                @ptrCast(setter_template),
                                v8.ReadOnly | v8.DontEnum,
                            );
                        }
                    }
                }
            },
            bridge.Function => {
                if (comptime transparent_prototype) {
                    @compileError(@typeName(JsApi) ++ " is transparent but declares operation " ++ name ++ "; put prototype members on its public parent");
                }
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    continue;
                }

                // For non-static functions, use the signature to validate the receiver
                const func_signature = if (value.static or value.receiver_mode == .reject_promise) null else signature;
                // A member may override its JS-visible name (see Response.json_static).
                // Keep that name in FunctionTemplate.data as snapshot-safe caller
                // metadata so the shared bridge can compose Blink's Web IDL exception
                // context without a per-interface callback.
                const fn_name = value.js_name orelse name;
                const js_name = v8.v8__String__NewFromUtf8(isolate, fn_name.ptr, v8.kNormal, @intCast(fn_name.len));
                const function_template = v8.v8__FunctionTemplate__New__Config(isolate, &.{
                    .callback = value.func,
                    .data = @ptrCast(js_name),
                    .length = value.arity,
                    .signature = func_signature,
                }).?;
                v8.v8__FunctionTemplate__SetClassName(function_template, js_name);
                setWebIDLExceptionContext(JsApi, isolate, function_template, v8.kExceptionContext_Operation);
                var attributes: v8.PropertyAttribute = 0;
                if (methods_readonly or !value.writable) attributes |= v8.ReadOnly;
                if (!value.deletable) attributes |= v8.DontDelete;
                if (legacy_unforgeable_members and !value.static) {
                    attributes |= v8.ReadOnly | v8.DontDelete;
                }
                if (members_non_enumerable) attributes |= v8.DontEnum;
                if (value.static and !own_properties) {
                    v8.v8__Template__Set(@ptrCast(template), js_name, @ptrCast(function_template), attributes);
                } else {
                    // Web IDL: operations on the interface prototype object
                    // (and mirrored onto [Global] instances) are enumerable.
                    v8.v8__Template__Set(@ptrCast(define_on orelse member_template.?), js_name, @ptrCast(function_template), attributes);
                    if (comptime members_also_on_hidden_prototype) {
                        v8.v8__Template__Set(@ptrCast(prototype.?), js_name, @ptrCast(function_template), attributes);
                    }
                }
            },
            bridge.Indexed => {
                var configuration: v8.IndexedPropertyHandlerConfiguration = .{
                    .getter = value.getter,
                    .enumerator = value.enumerator,
                    .setter = value.setter,
                    .query = value.query,
                    .deleter = value.deleter,
                    .definer = value.definer,
                    .descriptor = value.descriptor,
                    .index_of = null,
                    .data = null,
                    .flags = 0,
                };
                v8.v8__ObjectTemplate__SetIndexedHandler(instance, &configuration);
            },
            bridge.NamedIndexed => {
                var configuration: v8.NamedPropertyHandlerConfiguration = .{
                    .getter = value.getter,
                    .setter = value.setter,
                    .query = value.query,
                    .deleter = value.deleter,
                    .enumerator = value.enumerator,
                    .definer = value.definer,
                    .descriptor = value.descriptor,
                    .data = null,
                    .flags = v8.kOnlyInterceptStrings | if (@hasDecl(JsApi.Meta, "masking_named_interceptor") and JsApi.Meta.masking_named_interceptor) 0 else v8.kNonMasking,
                };
                v8.v8__ObjectTemplate__SetNamedHandler(instance, &configuration);
            },
            bridge.Iterator => {
                if (comptime transparent_prototype) {
                    @compileError(@typeName(JsApi) ++ " is transparent but declares an iterator; put prototype members on its public parent");
                }
                const function_template = v8.v8__FunctionTemplate__New__Config(isolate, &.{ .callback = value.func }).?;
                const iterator_name = if (value.async) "[Symbol.asyncIterator]" else "[Symbol.iterator]";
                const iterator_name_v8 = v8.v8__String__NewFromUtf8(isolate, iterator_name.ptr, v8.kNormal, @intCast(iterator_name.len));
                v8.v8__FunctionTemplate__SetClassName(function_template, iterator_name_v8);
                setWebIDLExceptionContext(JsApi, isolate, function_template, v8.kExceptionContext_Operation);
                const js_name = if (value.async)
                    v8.v8__Symbol__GetAsyncIterator(isolate)
                else
                    v8.v8__Symbol__GetIterator(isolate);
                // Web IDL: @@iterator is { writable, enumerable: false, configurable }.
                v8.v8__Template__Set(@ptrCast(prototype.?), js_name, @ptrCast(function_template), v8.DontEnum);
            },
            bridge.Property => {
                if (comptime transparent_prototype) {
                    @compileError(@typeName(JsApi) ++ " is transparent but declares property " ++ name ++ "; put prototype members on its public parent");
                }
                const js_value = switch (value.value) {
                    .null => js.simpleZigValueToJs(.{ .handle = isolate }, null, true, false),
                    inline .bool, .int, .float, .string => |v| js.simpleZigValueToJs(.{ .handle = isolate }, v, true, false),
                };
                const js_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));

                {
                    const flags = if (value.readonly) v8.ReadOnly + v8.DontDelete else 0;
                    v8.v8__Template__Set(@ptrCast(prototype.?), js_name, js_value, flags);
                }

                if (value.template) {
                    v8.v8__Template__Set(@ptrCast(template), js_name, js_value, v8.ReadOnly + v8.DontDelete);
                }
            },
            bridge.Constructor => {},
            else => {},
        }
    }

    if (comptime !flatten) {
        installInstanceTemplateProperties(JsApi, .after_members, isolate, instance.?);
        if (comptime @hasDecl(JsApi.Meta, "prototype_template_properties")) {
            if (comptime transparent_prototype) {
                @compileError(@typeName(JsApi) ++ " requests prototype template properties but has no public prototype");
            }
            installPrototypeTemplateProperties(JsApi, .after_members, isolate, prototype.?);
        }
    }

    // HTML's cross-origin Window/Location objects expose a fixed set of own
    // string properties followed by `then` and three well-known-symbol keys.
    // Their symbol values are deliberately undefined (including
    // @@toStringTag), which gives Object.prototype.toString.call(...) the
    // ordinary "[object Object]" result while preserving Reflect.ownKeys order.
    if (comptime !flatten and cross_origin_surface) {
        const undefined_value = js.simpleZigValueToJs(.{ .handle = isolate }, js.Undefined{}, true, false);
        const attributes = v8.ReadOnly + v8.DontEnum;
        const then_key = v8.v8__String__NewFromUtf8(isolate, "then", v8.kNormal, 4);
        v8.v8__Template__Set(@ptrCast(instance), then_key, undefined_value, attributes);
        v8.v8__Template__Set(@ptrCast(instance), v8.v8__Symbol__GetToStringTag(isolate), undefined_value, attributes);
        v8.v8__Template__Set(@ptrCast(instance), v8.v8__Symbol__GetHasInstance(isolate), undefined_value, attributes);
        v8.v8__Template__Set(@ptrCast(instance), v8.v8__Symbol__GetIsConcatSpreadable(isolate), undefined_value, attributes);
    }

    // WindowProxy and Location keep their ordinary same-origin Web IDL
    // templates.  When V8's security-token fast check does not match, these
    // separate handlers expose HTML's small cross-origin surface while the
    // access callback makes the decision against the target's current realm.
    if (comptime !flatten and @hasDecl(JsApi.Meta, "access_check")) {
        const access = JsApi.Meta.access_check;
        const named = access.named;
        const indexed = access.indexed;
        var named_configuration: v8.NamedPropertyHandlerConfiguration = .{
            .getter = named.getter,
            .setter = named.setter,
            .query = named.query,
            .deleter = named.deleter,
            .enumerator = named.enumerator,
            .definer = named.definer,
            .descriptor = named.descriptor,
            .data = null,
            // Symbols participate in the cross-origin fallback surface, so
            // kOnlyInterceptStrings would be a security bypass here.
            .flags = 0,
        };
        var indexed_configuration: v8.IndexedPropertyHandlerConfiguration = .{
            .getter = indexed.getter,
            .setter = indexed.setter,
            .query = indexed.query,
            .deleter = indexed.deleter,
            .enumerator = indexed.enumerator,
            .definer = indexed.definer,
            .descriptor = indexed.descriptor,
            .index_of = null,
            .data = null,
            .flags = 0,
        };
        v8.v8__ObjectTemplate__SetAccessCheckCallbackAndHandler(
            instance,
            access.callback,
            &named_configuration,
            &indexed_configuration,
            null,
        );
    }

    // Immutable-prototype semantics are independent from access checks.
    // A [Global] prototype is locked after its realized WindowProperties link
    // is installed; ordinary interface prototypes can be locked here.
    if (comptime immutableProto(JsApi)) |target| {
        if (target == .instance or target == .both) {
            v8.v8__ObjectTemplate__SetImmutableProto(instance);
        }
        if ((target == .prototype or target == .both) and !global_scope) {
            if (comptime transparent_prototype) {
                @compileError(@typeName(JsApi) ++ " requests an immutable prototype template but has no public prototype");
            }
            v8.v8__ObjectTemplate__SetImmutableProto(prototype.?);
        }
    }

    // The remaining per-class setup targets the class's own instance template;
    // in [Global] flattening mode the global already has these (or doesn't need
    // them), so skip it.
    if (comptime flatten) {
        return;
    }

    // V8 only routes non-string dynamic-code inputs through the embedder's
    // modified-source path when their native instance template is code-like.
    // TrustedScript is the sole Web IDL wrapper that opts into this bit.
    if (comptime @hasDecl(JsApi.Meta, "code_like") and JsApi.Meta.code_like) {
        v8.v8__ObjectTemplate__SetCodeLike(instance);
    }

    if (@hasDecl(JsApi.Meta, "htmldda")) {
        v8.v8__ObjectTemplate__MarkAsUndetectable(instance);
        v8.v8__ObjectTemplate__SetCallAsFunctionHandler(instance, JsApi.Meta.callable.func);
    }

    if (comptime installsDebugUnknownPropertyHandler(JsApi)) {
        var configuration: v8.NamedPropertyHandlerConfiguration = .{
            .getter = bridge.unknownObjectPropertyCallback(JsApi),
            .setter = null,
            .query = null,
            .deleter = null,
            .enumerator = null,
            .definer = null,
            .descriptor = null,
            .data = null,
            .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
        };
        v8.v8__ObjectTemplate__SetNamedHandler(instance, &configuration);
    }
}

fn installPrototypeAliases(
    comptime ContextApis: []const type,
    isolate: *v8.Isolate,
    context: *const v8.Context,
    templates: []*const v8.FunctionTemplate,
    prototype_key: *const v8.String,
) !void {
    inline for (ContextApis) |JsApi| {
        if (comptime !@hasDecl(JsApi.Meta, "prototype_aliases")) continue;

        const template_index = comptime bridge.JsApiLookup.getId(JsApi);
        const func = v8.v8__FunctionTemplate__GetFunction(templates[template_index], context) orelse
            return error.PrototypeAliasConstructorMissing;
        const prototype_value = v8.v8__Object__Get(@ptrCast(func), context, prototype_key) orelse
            return error.PrototypeAliasPrototypeMissing;
        if (!v8.v8__Value__IsObject(prototype_value)) return error.PrototypeAliasPrototypeInvalid;
        const prototype: *const v8.Object = @ptrCast(prototype_value);

        inline for (JsApi.Meta.prototype_aliases) |alias| {
            if (@TypeOf(alias) != bridge.PrototypeAlias) {
                @compileError(@typeName(JsApi) ++ ".Meta.prototype_aliases must contain bridge.PrototypeAlias values");
            }
            const source_key = v8.v8__String__NewFromUtf8(
                isolate,
                alias.source.ptr,
                v8.kNormal,
                @intCast(alias.source.len),
            );
            const value = v8.v8__Object__Get(prototype, context, source_key) orelse
                return error.PrototypeAliasSourceMissing;
            const target_key = templatePropertyKey(isolate, alias.target);
            var attributes: v8.PropertyAttribute = v8.None;
            if (!alias.writable) attributes |= v8.ReadOnly;
            if (!alias.enumerable) attributes |= v8.DontEnum;
            if (!alias.configurable) attributes |= v8.DontDelete;
            var maybe_result: v8.MaybeBool = undefined;
            v8.v8__Object__DefineOwnProperty(
                prototype,
                context,
                target_key,
                value,
                attributes,
                &maybe_result,
            );
            if (!maybe_result.value) return error.PrototypeAliasDefineFailed;
        }
    }
}
