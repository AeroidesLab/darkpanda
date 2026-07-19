// Copyright (C) 2026 Lightpanda
//
// Generic Trusted Types Web IDL surface.  Policy callbacks only transform
// caller-provided strings; enforcement at individual DOM sinks is deliberately
// separate.  TrustedScript is code-like so V8's dynamic-code callback can
// unwrap its payload without accepting look-alike JavaScript objects.

const std = @import("std");
const JS = @import("../js/js.zig");
const TaggedOpaque = @import("../js/TaggedOpaque.zig");

pub fn registerTypes() []const type {
    return &.{
        TrustedTypePolicyFactory,
        TrustedTypePolicy,
        TrustedHTML,
        TrustedScript,
        TrustedScriptURL,
    };
}

const Operation = JS.WebIDL.Operation;
const factory_operation: Operation = .{
    .interface = "TrustedTypePolicyFactory",
    .name = "createPolicy",
};

const html_namespace = "http://www.w3.org/1999/xhtml";
const svg_namespace = "http://www.w3.org/2000/svg";
const mathml_namespace = "http://www.w3.org/1998/Math/MathML";
const xlink_namespace = "http://www.w3.org/1999/xlink";

const PolicyOptions = struct {
    create_html: ?JS.Function.Global = null,
    // Chrome 149 still converts this dictionary member even while the
    // createParserOptions operation itself is behind a disabled runtime flag.
    create_parser_options: ?JS.Function.Global = null,
    create_script: ?JS.Function.Global = null,
    create_script_url: ?JS.Function.Global = null,

    fn release(self: *PolicyOptions) void {
        if (self.create_html) |value| value.release();
        if (self.create_parser_options) |value| value.release();
        if (self.create_script) |value| value.release();
        if (self.create_script_url) |value| value.release();
        self.* = .{};
    }
};

fn persistUtf8String(value: []const u8, exec: *JS.Execution) !JS.Value.Global {
    const local = exec.js.local.?;
    const string = JS.String{
        .local = local,
        .handle = local.isolate.initStringHandle(value),
    };
    return string.toValue().persist();
}

fn persistDOMString(value: JS.String) !JS.Value.Global {
    return value.toValue().persist();
}

fn persistUSVString(value: JS.String, exec: *JS.Execution) !JS.Value.Global {
    // V8's UTF-8 writer replaces unpaired surrogates. Recreating the V8 string
    // from that valid UTF-8 therefore implements Web IDL's USVString scalar
    // value conversion without changing the DOMString paths.
    return persistUtf8String(try value.toSlice(), exec);
}

pub const TrustedTypePolicyFactory = struct {
    _empty_html: ?*TrustedHTML = null,
    _empty_script: ?*TrustedScript = null,
    _default_policy: ?*TrustedTypePolicy = null,
    _context: ?*JS.Context = null,
    _created_names: std.StringHashMapUnmanaged(void) = .empty,

    pub const init: TrustedTypePolicyFactory = .{};

    pub fn bindContext(self: *TrustedTypePolicyFactory, context: *JS.Context) void {
        self._context = context;
    }

    pub fn getEmptyHTML(self: *TrustedTypePolicyFactory, exec: *JS.Execution) !*TrustedHTML {
        if (self._empty_html) |value| return value;
        const payload = try persistUtf8String("", exec);
        errdefer payload.release();
        const value = try exec._factory.create(TrustedHTML{ ._value = payload });
        self._empty_html = value;
        return value;
    }

    pub fn getEmptyScript(self: *TrustedTypePolicyFactory, exec: *JS.Execution) !*TrustedScript {
        if (self._empty_script) |value| return value;
        const payload = try persistUtf8String("", exec);
        errdefer payload.release();
        const value = try exec._factory.create(TrustedScript{ ._value = payload });
        self._empty_script = value;
        return value;
    }

    pub fn getDefaultPolicy(self: *const TrustedTypePolicyFactory) ?*TrustedTypePolicy {
        return self._default_policy;
    }

    pub fn createPolicy(
        self: *TrustedTypePolicyFactory,
        policy_name_: JS.Value,
        raw_options: ?JS.Value,
        exec: *JS.Execution,
    ) !*TrustedTypePolicy {
        // Keep the V8 string itself: DOMString is a sequence of UTF-16 code
        // units, so a UTF-8 round-trip would corrupt unpaired surrogates.
        const policy_name = try JS.WebIDL.toDOMStringValue(policy_name_, exec, factory_operation);
        var options = try parsePolicyOptions(raw_options, exec);
        var transferred = false;
        defer if (!transferred) options.release();

        const policy_name_utf8 = try policy_name.toSlice();
        const owner_context = self._context orelse exec.js;
        const is_duplicate = self._created_names.contains(policy_name_utf8);
        var decision = owner_context.csp_trusted_types.policyDecision(
            policy_name_utf8,
            is_duplicate,
        );
        // `default` is unique even without a trusted-types directive and even
        // when every policy contains 'allow-duplicates'.
        if (is_duplicate and std.mem.eql(u8, policy_name_utf8, "default")) {
            decision = .disallowed_duplicate;
        }
        switch (decision) {
            .allowed => {},
            .disallowed_duplicate => {
                const reason = try std.fmt.allocPrint(
                    exec.call_arena,
                    "Policy with name \"{s}\" already exists.",
                    .{policy_name_utf8},
                );
                return JS.WebIDL.typeError(exec, factory_operation, reason);
            },
            .disallowed_name => {
                const reason = try std.fmt.allocPrint(
                    exec.call_arena,
                    "Policy \"{s}\" disallowed.",
                    .{policy_name_utf8},
                );
                return JS.WebIDL.typeError(exec, factory_operation, reason);
            },
        }

        const persisted_name = try persistDOMString(policy_name);
        errdefer persisted_name.release();
        const policy = try exec._factory.create(TrustedTypePolicy{
            ._name = persisted_name,
            ._options = options,
        });
        if (!is_duplicate) {
            const retained_name = try owner_context.arena.dupe(u8, policy_name_utf8);
            try self._created_names.put(owner_context.arena, retained_name, {});
        }
        transferred = true;
        if (std.mem.eql(u8, policy_name_utf8, "default")) self._default_policy = policy;
        return policy;
    }

    pub fn getAttributeType(
        _: *const TrustedTypePolicyFactory,
        tag_name_: JS.DOMString,
        attribute_: JS.DOMString,
        element_namespace_: ?JS.DOMString,
        attribute_namespace_: ?JS.DOMString,
    ) ?[]const u8 {
        const element_namespace = normalizeElementNamespace(element_namespace_);
        const attribute_namespace = if (attribute_namespace_) |value| value.value else "";
        const sink = attributeSink(
            tag_name_.value,
            attribute_.value,
            element_namespace,
            attribute_namespace,
        ) orelse return null;
        return sink.required.interfaceName();
    }

    pub fn getPropertyType(
        _: *const TrustedTypePolicyFactory,
        tag_name_: JS.DOMString,
        property_: JS.DOMString,
        element_namespace_: ?JS.DOMString,
    ) ?[]const u8 {
        const tag_name = tag_name_.value;
        const property = property_.value;
        const element_namespace = normalizeElementNamespace(element_namespace_);

        if (std.mem.eql(u8, property, "innerHTML") or std.mem.eql(u8, property, "outerHTML")) {
            return "TrustedHTML";
        }
        if (std.mem.eql(u8, element_namespace, html_namespace)) {
            if (asciiEq(tag_name, "iframe") and std.mem.eql(u8, property, "srcdoc")) return "TrustedHTML";
            if ((asciiEq(tag_name, "embed") and std.mem.eql(u8, property, "src")) or
                (asciiEq(tag_name, "object") and (std.mem.eql(u8, property, "codeBase") or std.mem.eql(u8, property, "data"))) or
                (asciiEq(tag_name, "script") and std.mem.eql(u8, property, "src")))
            {
                return "TrustedScriptURL";
            }
            if (asciiEq(tag_name, "script") and
                (std.mem.eql(u8, property, "innerText") or
                    std.mem.eql(u8, property, "text") or
                    std.mem.eql(u8, property, "textContent")))
            {
                return "TrustedScript";
            }
        }
        if (std.mem.eql(u8, element_namespace, svg_namespace) and
            asciiEq(tag_name, "script") and
            std.mem.eql(u8, property, "href"))
        {
            return "TrustedScriptURL";
        }
        return null;
    }

    pub fn getTypeMapping(
        _: *const TrustedTypePolicyFactory,
        namespace_: ?JS.NullableString,
        exec: *JS.Execution,
    ) !?JS.Object {
        if (namespace_) |namespace| {
            if (namespace.value.len != 0) return null;
        }

        const local = exec.js.local.?;
        const top = local.newObject();
        // Preserve Blink's vector-population order. It is observable through
        // Reflect.ownKeys() on both the top-level object and nested maps.
        try addMapping(local, top, "embed", &.{.{ "src", "TrustedScriptURL" }}, &.{.{ "src", "TrustedScriptURL" }});
        try addMapping(local, top, "iframe", &.{.{ "srcdoc", "TrustedHTML" }}, &.{.{ "srcdoc", "TrustedHTML" }});
        try addMapping(local, top, "object", &.{
            .{ "codebase", "TrustedScriptURL" },
            .{ "data", "TrustedScriptURL" },
        }, &.{
            .{ "codeBase", "TrustedScriptURL" },
            .{ "data", "TrustedScriptURL" },
        });
        try addMapping(local, top, "script", &.{
            .{ "src", "TrustedScriptURL" },
            .{ "href", "TrustedScriptURL" },
        }, &.{
            .{ "innerText", "TrustedScript" },
            .{ "src", "TrustedScriptURL" },
            .{ "text", "TrustedScript" },
            .{ "textContent", "TrustedScript" },
            .{ "href", "TrustedScriptURL" },
        });
        try addEventHandlerMapping(local, top);
        return top;
    }

    pub fn isHTML(_: *const TrustedTypePolicyFactory, value: JS.Value) bool {
        return hasInstance(TrustedHTML, value);
    }

    pub fn isScript(_: *const TrustedTypePolicyFactory, value: JS.Value) bool {
        return hasInstance(TrustedScript, value);
    }

    pub fn isScriptURL(_: *const TrustedTypePolicyFactory, value: JS.Value) bool {
        return hasInstance(TrustedScriptURL, value);
    }

    pub const JsApi = struct {
        pub const bridge = JS.Bridge(TrustedTypePolicyFactory);

        pub const Meta = struct {
            pub const name = "TrustedTypePolicyFactory";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Keep declaration order aligned with Chromium's generated IDL surface.
        pub const emptyHTML = bridge.accessor(TrustedTypePolicyFactory.getEmptyHTML, null, .{});
        pub const emptyScript = bridge.accessor(TrustedTypePolicyFactory.getEmptyScript, null, .{});
        pub const defaultPolicy = bridge.accessor(TrustedTypePolicyFactory.getDefaultPolicy, null, .{});
        pub const createPolicy = bridge.function(TrustedTypePolicyFactory.createPolicy, .{ .arity = 1, .required_args = 1 });
        pub const getAttributeType = bridge.function(TrustedTypePolicyFactory.getAttributeType, .{ .arity = 2, .required_args = 2 });
        pub const getPropertyType = bridge.function(TrustedTypePolicyFactory.getPropertyType, .{ .arity = 2, .required_args = 2 });
        pub const getTypeMapping = bridge.function(TrustedTypePolicyFactory.getTypeMapping, .{ .arity = 0 });
        pub const isHTML = bridge.function(TrustedTypePolicyFactory.isHTML, .{ .arity = 1, .required_args = 1 });
        pub const isScript = bridge.function(TrustedTypePolicyFactory.isScript, .{ .arity = 1, .required_args = 1 });
        pub const isScriptURL = bridge.function(TrustedTypePolicyFactory.isScriptURL, .{ .arity = 1, .required_args = 1 });
    };
};

pub const TrustedTypePolicy = struct {
    _name: JS.Value.Global,
    _options: PolicyOptions,

    pub fn getName(self: *const TrustedTypePolicy) JS.Value.Global {
        return self._name;
    }

    pub fn createHTML(
        self: *TrustedTypePolicy,
        input_: JS.Value,
        args: []JS.Value.Global,
        exec: *JS.Execution,
    ) !*TrustedHTML {
        defer releaseRest(args);
        const operation: Operation = .{ .interface = "TrustedTypePolicy", .name = "createHTML" };
        const input = try JS.WebIDL.toDOMStringValue(input_, exec, operation);
        const value = try self.invoke(self._options.create_html, operation, input, args, false, exec);
        errdefer value.release();
        return exec._factory.create(TrustedHTML{ ._value = value });
    }

    pub fn createScript(
        self: *TrustedTypePolicy,
        input_: JS.Value,
        args: []JS.Value.Global,
        exec: *JS.Execution,
    ) !*TrustedScript {
        defer releaseRest(args);
        const operation: Operation = .{ .interface = "TrustedTypePolicy", .name = "createScript" };
        const input = try JS.WebIDL.toDOMStringValue(input_, exec, operation);
        const value = try self.invoke(self._options.create_script, operation, input, args, false, exec);
        errdefer value.release();
        return exec._factory.create(TrustedScript{ ._value = value });
    }

    pub fn createScriptURL(
        self: *TrustedTypePolicy,
        input_: JS.Value,
        args: []JS.Value.Global,
        exec: *JS.Execution,
    ) !*TrustedScriptURL {
        defer releaseRest(args);
        const operation: Operation = .{ .interface = "TrustedTypePolicy", .name = "createScriptURL" };
        const input = try JS.WebIDL.toDOMStringValue(input_, exec, operation);
        const value = try self.invoke(self._options.create_script_url, operation, input, args, true, exec);
        errdefer value.release();
        return exec._factory.create(TrustedScriptURL{ ._value = value });
    }

    fn invoke(
        self: *const TrustedTypePolicy,
        callback_: ?JS.Function.Global,
        operation: Operation,
        input: JS.String,
        rest: []const JS.Value.Global,
        normalize_to_usv: bool,
        exec: *JS.Execution,
    ) !JS.Value.Global {
        const callback = callback_ orelse {
            const policy_name = self._name.local(exec.js.local.?).isString().?;
            const reason = try std.fmt.allocPrint(
                exec.call_arena,
                "Policy {s}'s TrustedTypePolicyOptions did not specify a '{s}' member.",
                .{ try policy_name.toSlice(), operation.name },
            );
            return JS.WebIDL.typeError(exec, operation, reason);
        };

        const local = exec.js.local.?;
        const values = try exec.call_arena.alloc(JS.Value, 1 + rest.len);
        values[0] = input.toValue();
        for (rest, 0..) |value, index| values[index + 1] = value.local(local);

        const result = try local.toLocal(callback).callRethrowWithThis(
            JS.Value,
            JS.Undefined{},
            values,
        );
        if (result.isNullOrUndefined()) return persistUtf8String("", exec);

        const string = try JS.WebIDL.toDOMStringValue(result, exec, null);
        return if (normalize_to_usv)
            persistUSVString(string, exec)
        else
            persistDOMString(string);
    }

    const SinkResult = union(enum) {
        missing,
        nullish,
        value: JS.String,
    };

    /// Internal default-policy invocation used by assignment sinks.  Unlike
    /// the public create* methods, a missing member and a nullish callback
    /// result stay distinguishable and the callback receives type/sink data.
    fn invokeForSink(
        self: *const TrustedTypePolicy,
        required: RequiredType,
        input: JS.String,
        sink_sample: []const u8,
        exec: *JS.Execution,
    ) !SinkResult {
        const callback = switch (required) {
            .html => self._options.create_html,
            .script => self._options.create_script,
            .script_url => self._options.create_script_url,
        } orelse return .missing;

        const local = exec.js.local.?;
        const type_name = required.interfaceName();
        const values = [_]JS.Value{
            input.toValue(),
            (JS.String{
                .local = local,
                .handle = local.isolate.initStringHandle(type_name),
            }).toValue(),
            (JS.String{
                .local = local,
                .handle = local.isolate.initStringHandle(sink_sample),
            }).toValue(),
        };
        const result = try local.toLocal(callback).callRethrowWithThis(
            JS.Value,
            JS.Undefined{},
            &values,
        );
        if (result.isNullOrUndefined()) return .nullish;

        const string = try JS.WebIDL.toDOMStringValue(result, exec, null);
        if (required != .script_url) return .{ .value = string };

        // TrustedScriptURL uses USVString conversion: V8's UTF-8 writer
        // replaces unpaired surrogates before the value reaches the sink.
        return .{ .value = .{
            .local = local,
            .handle = local.isolate.initStringHandle(try string.toSlice()),
        } };
    }

    const CodeGenerationPolicyResult = union(enum) {
        missing,
        nullish,
        exception,
        value: JS.String,
    };

    fn invokeForCodeGeneration(
        self: *const TrustedTypePolicy,
        input: JS.String,
        sink: []const u8,
        exec: *JS.Execution,
    ) CodeGenerationPolicyResult {
        const callback = self._options.create_script orelse return .missing;
        const local = exec.js.local orelse return .exception;
        const values = [_]JS.Value{
            input.toValue(),
            (JS.String{
                .local = local,
                .handle = local.isolate.initStringHandle("TrustedScript"),
            }).toValue(),
            (JS.String{
                .local = local,
                .handle = local.isolate.initStringHandle(sink),
            }).toValue(),
        };

        const function = local.toLocal(callback);
        const argv = [_]?*const JS.v8.Value{
            values[0].handle,
            values[1].handle,
            values[2].handle,
        };

        // Cover both the callback and its return-value DOMString conversion
        // with one TryCatch.  Do not use the higher-level call helpers here:
        // their diagnostics read author-controlled message/stack properties,
        // while Blink silently converts every failure into V8's TT EvalError.
        var try_catch: JS.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();
        const result_handle = JS.v8.v8__Function__Call(
            function.handle,
            local.handle,
            local.isolate.initUndefined(),
            @intCast(values.len),
            @ptrCast(&argv),
        ) orelse return .exception;
        if (try_catch.hasCaught()) return .exception;
        const result = JS.Value{ .local = local, .handle = result_handle };
        if (result.isNullOrUndefined()) return .nullish;

        const string = JS.WebIDL.toDOMStringValue(result, exec, null) catch return .exception;
        if (try_catch.hasCaught()) return .exception;
        return .{ .value = string };
    }

    pub const JsApi = struct {
        pub const bridge = JS.Bridge(TrustedTypePolicy);

        pub const Meta = struct {
            pub const name = "TrustedTypePolicy";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(TrustedTypePolicy.getName, null, .{});
        pub const createHTML = bridge.function(TrustedTypePolicy.createHTML, .{ .arity = 1, .required_args = 1, .variadic = true });
        pub const createScript = bridge.function(TrustedTypePolicy.createScript, .{ .arity = 1, .required_args = 1, .variadic = true });
        pub const createScriptURL = bridge.function(TrustedTypePolicy.createScriptURL, .{ .arity = 1, .required_args = 1, .variadic = true });
    };
};

pub const TrustedHTML = struct {
    _value: JS.Value.Global,

    pub fn toJSON(self: *const TrustedHTML) JS.Value.Global {
        return self._value;
    }

    pub fn toString(self: *const TrustedHTML) JS.Value.Global {
        return self._value;
    }

    pub const JsApi = ValueApi(TrustedHTML, "TrustedHTML", false);
};

pub const TrustedScript = struct {
    _value: JS.Value.Global,

    pub fn toJSON(self: *const TrustedScript) JS.Value.Global {
        return self._value;
    }

    pub fn toString(self: *const TrustedScript) JS.Value.Global {
        return self._value;
    }

    pub const JsApi = ValueApi(TrustedScript, "TrustedScript", true);
};

pub const TrustedScriptURL = struct {
    _value: JS.Value.Global,

    pub fn toJSON(self: *const TrustedScriptURL) JS.Value.Global {
        return self._value;
    }

    pub fn toString(self: *const TrustedScriptURL) JS.Value.Global {
        return self._value;
    }

    pub const JsApi = ValueApi(TrustedScriptURL, "TrustedScriptURL", false);
};

pub const RequiredType = enum {
    html,
    script,
    script_url,

    fn interfaceName(self: RequiredType) []const u8 {
        return switch (self) {
            .html => "TrustedHTML",
            .script => "TrustedScript",
            .script_url => "TrustedScriptURL",
        };
    }
};

pub const StringConversion = enum {
    dom_string,
    legacy_null_to_empty,
    usv_string,
};

pub const AttributeSink = struct {
    required: RequiredType,
    interface: []const u8,
    member: []const u8,
};

/// Blink-generated Trusted Types attribute mapping, including the interface
/// and member used for the default-policy sink sample.  The Web IDL error
/// prefix remains Element.setAttribute/Element.setAttributeNS at the caller.
pub fn attributeSink(
    tag_name: []const u8,
    attribute: []const u8,
    element_namespace_: ?[]const u8,
    attribute_namespace_: ?[]const u8,
) ?AttributeSink {
    const element_namespace = element_namespace_ orelse html_namespace;
    const attribute_namespace = attribute_namespace_ orelse "";

    if (std.mem.eql(u8, element_namespace, html_namespace) and attribute_namespace.len == 0) {
        if (asciiEq(tag_name, "iframe") and asciiEq(attribute, "srcdoc")) {
            return .{ .required = .html, .interface = "HTMLIFrameElement", .member = "srcdoc" };
        }
        if (asciiEq(tag_name, "embed") and asciiEq(attribute, "src")) {
            return .{ .required = .script_url, .interface = "HTMLEmbedElement", .member = "src" };
        }
        if (asciiEq(tag_name, "object") and asciiEq(attribute, "codebase")) {
            return .{ .required = .script_url, .interface = "HTMLObjectElement", .member = "codeBase" };
        }
        if (asciiEq(tag_name, "object") and asciiEq(attribute, "data")) {
            return .{ .required = .script_url, .interface = "HTMLObjectElement", .member = "data" };
        }
        if (asciiEq(tag_name, "script") and asciiEq(attribute, "src")) {
            return .{ .required = .script_url, .interface = "HTMLScriptElement", .member = "src" };
        }
    }

    if (std.mem.eql(u8, element_namespace, svg_namespace) and
        asciiEq(tag_name, "script") and
        asciiEq(attribute, "href") and
        (attribute_namespace.len == 0 or std.mem.eql(u8, attribute_namespace, xlink_namespace)))
    {
        return .{ .required = .script_url, .interface = "SVGScriptElement", .member = "href" };
    }

    if (attribute_namespace.len == 0 and
        isHtmlKnownNamespace(element_namespace) and
        isEventHandlerAttribute(attribute))
    {
        return .{ .required = .script, .interface = "Element", .member = attribute };
    }
    return null;
}

/// Convert a String-or-Trusted-Type sink input before any caller can erase its
/// native brand.  CSP and default-policy lookup are based on the sink owner's
/// execution context, not the same-origin realm which invoked the setter.
pub fn getCompliantString(
    raw: JS.Value,
    owner_context: *JS.Context,
    factory: *TrustedTypePolicyFactory,
    required: RequiredType,
    sink_interface: []const u8,
    sink_member: []const u8,
    error_context: JS.WebIDL.ConversionContext,
    conversion: StringConversion,
    exec: *JS.Execution,
) !JS.String {
    const local = exec.js.local.?;
    if (trustedPayload(raw, required, local)) |payload| return payload;

    var input = if (conversion == .legacy_null_to_empty and raw.isNull())
        JS.String{
            .local = local,
            .handle = local.isolate.initStringHandle(""),
        }
    else
        try JS.WebIDL.toDOMStringValueWithContext(raw, exec, error_context);
    if (conversion == .usv_string) {
        input = .{
            .local = local,
            .handle = local.isolate.initStringHandle(try input.toSlice()),
        };
    }

    if (!owner_context.csp_trusted_types.requiresScriptCheck()) return input;

    const type_name = required.interfaceName();
    const default_policy = factory.getDefaultPolicy() orelse {
        if (!owner_context.csp_trusted_types.requiresScript()) return input;
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "This document requires '{s}' assignment.",
            .{type_name},
        );
        return JS.WebIDL.contextualTypeError(exec, error_context, reason);
    };
    const sink_sample = try std.fmt.allocPrint(
        exec.call_arena,
        "{s} {s}",
        .{ sink_interface, sink_member },
    );
    return switch (try default_policy.invokeForSink(required, input, sink_sample, exec)) {
        .value => |value| value,
        .missing => {
            if (!owner_context.csp_trusted_types.requiresScript()) return input;
            const reason = try std.fmt.allocPrint(
                exec.call_arena,
                "This document requires '{s}' assignment and no 'default' policy for '{s}' has been defined.",
                .{ type_name, type_name },
            );
            return JS.WebIDL.contextualTypeError(exec, error_context, reason);
        },
        .nullish => {
            // The callback may have synchronously installed an enforced meta
            // policy. Re-read the disposition at the failure point.
            if (!owner_context.csp_trusted_types.requiresScript()) return input;
            const reason = try std.fmt.allocPrint(
                exec.call_arena,
                "This document requires '{s}' assignment and the 'default' policy failed to execute.",
                .{type_name},
            );
            return JS.WebIDL.contextualTypeError(exec, error_context, reason);
        },
    };
}

/// Run the default policy for V8's eval/Function code-generation callback.
/// Blink contains every author exception and nullish/missing result inside its
/// callback, then lets V8 create the single public Trusted Types EvalError.
/// The caller still has to perform the spec's exact content-equality check.
pub const CodeGenerationResult = union(enum) {
    blocked,
    replacement: JS.String,
};

pub fn checkCodeGenerationString(
    factory: *TrustedTypePolicyFactory,
    input: JS.String,
    owner_context: *JS.Context,
    exec: *JS.Execution,
) CodeGenerationResult {
    if (!owner_context.csp_trusted_types.requiresScriptCheck()) {
        return .{ .replacement = input };
    }

    const enforced = owner_context.csp_trusted_types.requiresScript();
    const policy = factory.getDefaultPolicy() orelse return if (enforced)
        .blocked
    else
        .{ .replacement = input };
    const source = input.toSlice() catch return .blocked;
    const sink = if (isFunctionConstructorSource(source)) "Function" else "eval";
    const output = switch (policy.invokeForCodeGeneration(input, sink, exec)) {
        .value => |value| value,
        .missing, .nullish => return if (enforced)
            .blocked
        else
            .{ .replacement = input },
        .exception => return .blocked,
    };

    // The can-compile-strings equality rule applies even when the only TT
    // requirement is report-only. String StrictEquals compares UTF-16 code
    // units without corrupting lone surrogates.
    if (!JS.v8.v8__Value__StrictEquals(
        input.toValue().handle,
        output.toValue().handle,
    )) return .blocked;
    return .{ .replacement = output };
}

fn isFunctionConstructorSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "(function anonymous") or
        std.mem.startsWith(u8, source, "(async function anonymous") or
        std.mem.startsWith(u8, source, "(function* anonymous") or
        std.mem.startsWith(u8, source, "(async function* anonymous");
}

pub fn trustedPayload(
    raw: JS.Value,
    required: RequiredType,
    local: *const JS.Local,
) ?JS.String {
    return switch (required) {
        .html => payloadFor(TrustedHTML, raw, local),
        .script => payloadFor(TrustedScript, raw, local),
        .script_url => payloadFor(TrustedScriptURL, raw, local),
    };
}

fn payloadFor(comptime T: type, raw: JS.Value, local: *const JS.Local) ?JS.String {
    if (!raw.isObject()) return null;
    const object: *const JS.v8.Object = @ptrCast(raw.handle);
    if (JS.v8.v8__Object__InternalFieldCount(object) == 0) return null;
    if (JS.v8.v8__Object__GetAlignedPointerFromInternalField(object, 0) == null) return null;
    const trusted = TaggedOpaque.fromJS(*T, object) catch return null;
    return trusted._value.local(local).isString();
}

fn ValueApi(comptime T: type, comptime interface_name: []const u8, comptime is_code_like: bool) type {
    return struct {
        pub const bridge = JS.Bridge(T);

        pub const Meta = struct {
            pub const name = interface_name;
            pub const code_like = is_code_like;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const toJSON = bridge.function(T.toJSON, .{ .arity = 0 });
        pub const toString = bridge.function(T.toString, .{ .arity = 0 });
    };
}

/// Return a payload only for a genuine native TrustedScript wrapper.  Merely
/// inheriting from TrustedScript.prototype or copying its toString method does
/// not create the TaggedOpaque class identity required here.
pub fn codeGenerationPayload(source: *const JS.v8.Value) ?*JS.GlobalSlot {
    if (!JS.v8.v8__Value__IsObject(source)) return null;
    const object: *const JS.v8.Object = @ptrCast(source);
    // Do not ask TaggedOpaque to unwrap arbitrary V8 host objects. Native
    // Lightpanda wrappers always carry a non-null TaggedOpaque in field zero;
    // a forged object inheriting from TrustedScript.prototype carries none.
    if (JS.v8.v8__Object__InternalFieldCount(object) == 0) return null;
    if (JS.v8.v8__Object__GetAlignedPointerFromInternalField(object, 0) == null) return null;
    const script = TaggedOpaque.fromJS(*TrustedScript, object) catch return null;
    return script._value.slot;
}

fn parsePolicyOptions(raw_options: ?JS.Value, exec: *JS.Execution) !PolicyOptions {
    const raw = raw_options orelse return .{};
    if (raw.isNullOrUndefined()) return .{};
    if (!raw.isObject()) {
        return JS.WebIDL.typeError(
            exec,
            factory_operation,
            "The provided value is not of type 'TrustedTypePolicyOptions'.",
        );
    }

    const object = raw.toObject();
    var options: PolicyOptions = .{};
    errdefer options.release();
    options.create_html = try readCallback(object, "createHTML", exec);
    options.create_parser_options = try readCallback(object, "createParserOptions", exec);
    options.create_script = try readCallback(object, "createScript", exec);
    options.create_script_url = try readCallback(object, "createScriptURL", exec);
    return options;
}

fn readCallback(object: JS.Object, name: []const u8, exec: *JS.Execution) !?JS.Function.Global {
    // Limit the nested TryCatch to the author-visible [[Get]]. Native
    // dictionary validation below may itself throw a Web IDL TypeError; if
    // that happens while this TryCatch is still alive it would capture and
    // then silently discard our own exception on destruction.
    const value = blk: {
        var try_catch: JS.TryCatch = undefined;
        try_catch.init(object.local);
        defer try_catch.deinit();
        break :blk object.get(name) catch |err| {
            if (err == error.JsException and try_catch.hasCaught()) {
                try_catch.rethrow();
                return error.TryCatchRethrow;
            }
            return err;
        };
    };
    if (value.isUndefined()) return null;
    if (!value.isFunction()) {
        const reason = try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to read the '{s}' property from 'TrustedTypePolicyOptions': The given value is not a function.",
            .{name},
        );
        return JS.WebIDL.typeError(exec, factory_operation, reason);
    }
    const callback = try (JS.Function{ .local = value.local, .handle = @ptrCast(value.handle) }).persist();
    return callback;
}

fn releaseRest(args: []const JS.Value.Global) void {
    for (args) |value| value.release();
}

fn hasInstance(comptime T: type, value: JS.Value) bool {
    if (!value.isObject()) return false;
    const object: *const JS.v8.Object = @ptrCast(value.handle);
    if (JS.v8.v8__Object__InternalFieldCount(object) == 0) return false;
    if (JS.v8.v8__Object__GetAlignedPointerFromInternalField(object, 0) == null) return false;
    _ = TaggedOpaque.fromJS(*T, object) catch return false;
    return true;
}

fn asciiEq(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn normalizeElementNamespace(namespace: ?JS.DOMString) []const u8 {
    const value = if (namespace) |present| present.value else "";
    return if (value.len == 0) html_namespace else value;
}

fn isHtmlKnownNamespace(namespace: []const u8) bool {
    return std.mem.eql(u8, namespace, html_namespace) or
        std.mem.eql(u8, namespace, svg_namespace) or
        std.mem.eql(u8, namespace, mathml_namespace);
}

// Chrome 149.0.7827.203's generated EVENT_HANDLER_LIST, in the observable
// order emitted by TrustedTypePolicyFactory.getTypeMapping(). The source list
// is generated from Blink's complete Web IDL database, including handler
// attributes whose owning API is runtime-gated; it is intentionally broader
// than GlobalEventHandlers and intentionally does not accept arbitrary `on*`.
const event_handler_names =
    "onabort,onabortpayment,onactivate,onactive,onaddsourcebuffer," ++
    "onaddstream,onaddtrack,onadvertisementreceived,onafterprint,onanimationcancel," ++
    "onanimationend,onanimationiteration,onanimationstart,onappinstalled,onaudioend," ++
    "onaudioprocess,onaudiostart,onautofill,onauxclick,onbackgroundfetchabort," ++
    "onbackgroundfetchclick,onbackgroundfetchfail,onbackgroundfetchsuccess,onbeforecopy,onbeforecut," ++
    "onbeforefilter,onbeforeinput,onbeforeinstallprompt,onbeforematch,onbeforepaste," ++
    "onbeforeprint,onbeforetoggle,onbeforeunload,onbeforexrselect,onbegin," ++
    "onblocked,onblur,onboundary,onbufferedamountlow,oncancel," ++
    "oncanmakepayment,oncanplay,oncanplaythrough,oncapturedmousechange,oncapturehandlechange," ++
    "onchange,oncharacterboundsupdate,oncharacteristicvaluechanged,onchargingchange,onchargingtimechange," ++
    "onclick,onclipboardchange,onclose,onclosing,oncommand," ++
    "oncomplete,oncompositionend,oncompositionstart,onconfigurationchange,onconnect," ++
    "onconnecting,onconnectionavailable,onconnectionstatechange,oncontentdelete,oncontentvisibilityautostatechange," ++
    "oncontextlost,oncontextmenu,oncontextoverflow,oncontextrestored,oncontrollerchange," ++
    "oncookiechange,oncopy,oncuechange,oncurrententrychange,oncurrentscreenchange," ++
    "oncut,ondataavailable,ondatachannel,ondblclick,ondequeue," ++
    "ondevicechange,ondevicemotion,ondeviceorientation,ondeviceorientationabsolute,ondischargingtimechange," ++
    "ondisconnect,ondispose,ondownloadprogress,ondrag,ondragend," ++
    "ondragenter,ondragleave,ondragover,ondragstart,ondrop," ++
    "ondurationchange,onemptied,onencrypted,onend,onended," ++
    "onenter,onenterpictureinpicture,onerror,onexit,onfetch," ++
    "onfinish,onfocus,onformdata,onframeratechange,onfreeze," ++
    "onfullscreenchange,onfullscreenerror,ongamepadconnected,ongamepaddisconnected,ongamepadrawinputchanged," ++
    "ongatheringstatechange,ongattserverdisconnected,ongeometrychange,ongotpointercapture,onhashchange," ++
    "onhdrheadroomchange,onicecandidate,onicecandidateerror,oniceconnectionstatechange,onicegatheringstatechange," ++
    "oninactive,oninput,oninputreport,oninputsourceschange,oninstall," ++
    "oninterfacerequest,oninvalid,onjobstatechange,onkeydown,onkeypress," ++
    "onkeystatuseschange,onkeyup,onlanguagechange,onleavepictureinpicture,onlevelchange," ++
    "onload,onloadeddata,onloadedmetadata,onloadend,onloading," ++
    "onloadingdone,onloadingerror,onloadstart,onlocation,onlostpointercapture," ++
    "onmanagedconfigurationchange,onmark,onmessage,onmessageerror,onmidimessage," ++
    "onmousedown,onmouseenter,onmouseleave,onmousemove,onmouseout," ++
    "onmouseover,onmouseup,onmousewheel,onmove,onmute," ++
    "onnavigate,onnavigateerror,onnavigatesuccess,onnegotiationneeded,onnomatch," ++
    "onnotificationclick,onnotificationclose,onoffline,ononline,onopen," ++
    "onorientationchange,onoverscrollcancel,onoverscrollchanging,onoverscrollend,onoverscrollstart," ++
    "onpagehide,onpagereveal,onpageshow,onpageswap,onpaint," ++
    "onpaste,onpause,onpayerdetailchange,onpaymentmethodchange,onpaymentrequest," ++
    "onperiodicsync,onplay,onplaying,onpointercancel,onpointerdown," ++
    "onpointerenter,onpointerleave,onpointerlockchange,onpointerlockerror,onpointermove," ++
    "onpointerout,onpointerover,onpointerrawupdate,onpointerup,onpopstate," ++
    "onprerenderingchange,onprioritychange,onprocessorerror,onprogress,onpromptaction," ++
    "onpromptdismiss,onpush,onpushsubscriptionchange,onquotaoverflow,onratechange," ++
    "onreading,onreadingerror,onreadystatechange,onredraw,onreflectionchange," ++
    "onrejectionhandled,onrelease,onremove,onremovesourcebuffer,onremovestream," ++
    "onremovetrack,onrepeat,onreset,onresize,onresourcetimingbufferfull," ++
    "onresult,onresume,onrtctransform,onscreenschange,onscroll," ++
    "onscrollend,onscrollsnapchange,onscrollsnapchanging,onsearch,onsecuritypolicyviolation," ++
    "onseeked,onseeking,onselect,onselectedcandidatepairchange,onselectend," ++
    "onselectionchange,onselectstart,onshippingaddresschange,onshippingoptionchange,onshow," ++
    "onsignalingstatechange,onsinkchange,onslotchange,onsoundend,onsoundstart," ++
    "onsourceclose,onsourceended,onsourceopen,onspeechend,onspeechstart," ++
    "onsqueeze,onsqueezeend,onsqueezestart,onstalled,onstart," ++
    "onstatechange,onstop,onstorage,onstream,onsubmit," ++
    "onsuccess,onsuspend,onsync,onterminate,ontextformatupdate," ++
    "ontextupdate,ontimeout,ontimeupdate,ontimezonechange,ontoggle," ++
    "ontonechange,ontoolchange,ontouchcancel,ontouchend,ontouchmove," ++
    "ontouchstart,ontrack,ontransitioncancel,ontransitionend,ontransitionrun," ++
    "ontransitionstart,ontypechange,onuncapturederror,onunhandledrejection,onunload," ++
    "onunmute,onupdate,onupdateend,onupdatefound,onupdatestart," ++
    "onupgradeneeded,onvalidationstatuschange,onversionchange,onvisibilitychange,onvisibilitymaskchange," ++
    "onvoiceschanged,onvolumechange,onwaiting,onwaitingforkey,onwebkitanimationend," ++
    "onwebkitanimationiteration,onwebkitanimationstart,onwebkitfullscreenchange,onwebkitfullscreenerror,onwebkittransitionend," ++
    "onwheel,onwritablechange,onwrite,onwriteend,onwritestart," ++
    "onzoomlevelchange";

fn isEventHandlerAttribute(attribute: []const u8) bool {
    var lower_buffer: [64]u8 = undefined;
    if (attribute.len > lower_buffer.len) return false;
    const lower = std.ascii.lowerString(lower_buffer[0..attribute.len], attribute);
    var names = std.mem.splitScalar(u8, event_handler_names, ',');
    while (names.next()) |name| {
        if (std.mem.eql(u8, lower, name)) return true;
    }
    return false;
}

const Mapping = struct { []const u8, []const u8 };

fn addMapping(
    local: *const JS.Local,
    top: JS.Object,
    tag: []const u8,
    attributes: []const Mapping,
    properties: []const Mapping,
) !void {
    const entry = local.newObject();
    const attribute_map = local.newObject();
    const property_map = local.newObject();
    for (attributes) |mapping| _ = try attribute_map.set(mapping[0], mapping[1], .{});
    for (properties) |mapping| _ = try property_map.set(mapping[0], mapping[1], .{});
    _ = try entry.set("attributes", attribute_map, .{});
    _ = try entry.set("properties", property_map, .{});
    _ = try top.set(tag, entry, .{});
}

fn addEventHandlerMapping(local: *const JS.Local, top: JS.Object) !void {
    const entry = local.newObject();
    const attribute_map = local.newObject();
    const property_map = local.newObject();
    var names = std.mem.splitScalar(u8, event_handler_names, ',');
    while (names.next()) |name| {
        _ = try attribute_map.set(name, "TrustedScript", .{});
    }
    _ = try property_map.set("innerHTML", "TrustedHTML", .{});
    _ = try property_map.set("outerHTML", "TrustedHTML", .{});
    _ = try entry.set("attributes", attribute_map, .{});
    _ = try entry.set("properties", property_map, .{});
    _ = try top.set("*", entry, .{});
}

const testing = @import("../../testing.zig");
test "WebApi: Trusted Types Chrome 149 surface and dynamic code" {
    try testing.htmlRunner("window/trusted_types.html", .{ .timeout_ms = 5000 });
}
