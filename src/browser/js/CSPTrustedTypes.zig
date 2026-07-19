// Copyright (C) 2026 Lightpanda
//
// Narrow, enforced Content-Security-Policy state for Trusted Types.  This is
// intentionally independent from CSPCodeGeneration: DOM sink assignment and
// policy-name creation have different directives and composition rules from
// eval/WebAssembly code generation.

const std = @import("std");

const Allocator = std.mem.Allocator;
const CSPTrustedTypes = @This();

const ascii_whitespace = " \t\r\n\x0c";

pub const code_generation_error_message =
    "Evaluating a string as JavaScript violates this document's Trusted Type assignment requirements.";

pub const PolicyDecision = enum {
    allowed,
    disallowed_name,
    disallowed_duplicate,
};

pub const Disposition = enum {
    enforce,
    report_only,
};

const TrustedTypesDirective = struct {
    allow_any: bool = false,
    allow_duplicates: bool = false,
    names: []const []const u8 = &.{},
};

const Policy = struct {
    // Retain one policy rather than the whole comma-separated header.  Local
    // documents/workers can replay these immutable values into a new arena.
    serialized: []const u8,
    disposition: Disposition,
    requires_script: bool = false,
    allows_trusted_types_eval: bool = false,
    trusted_types: ?TrustedTypesDirective = null,
};

policies: std.ArrayList(Policy) = .empty,

/// Add one serialized enforced CSP header/meta value.  A header can contain a
/// comma-separated policy list; every policy is retained because decisions
/// intersect rather than allowing a later policy to relax an earlier one.
pub fn addSerialized(
    self: *CSPTrustedTypes,
    allocator: Allocator,
    serialized: []const u8,
) !void {
    return self.addSerializedWithDisposition(allocator, serialized, .enforce);
}

pub fn addSerializedReportOnly(
    self: *CSPTrustedTypes,
    allocator: Allocator,
    serialized: []const u8,
) !void {
    return self.addSerializedWithDisposition(allocator, serialized, .report_only);
}

fn addSerializedWithDisposition(
    self: *CSPTrustedTypes,
    allocator: Allocator,
    serialized: []const u8,
    disposition: Disposition,
) !void {
    var staged: std.ArrayList(Policy) = .empty;
    defer staged.deinit(allocator);

    var policies = std.mem.splitScalar(u8, serialized, ',');
    while (policies.next()) |raw_policy| {
        const policy = std.mem.trim(u8, raw_policy, ascii_whitespace);
        if (policy.len == 0) continue;
        try staged.append(allocator, try parsePolicy(allocator, policy, disposition));
    }

    // Reserve the destination before publishing any staged policy.  Parsing
    // and all per-policy allocations have already succeeded at this point.
    try self.policies.ensureUnusedCapacity(allocator, staged.items.len);
    self.policies.appendSliceAssumeCapacity(staged.items);
}

/// Clone the enforced Trusted Types subset into a new execution context.
pub fn inheritFrom(
    self: *CSPTrustedTypes,
    allocator: Allocator,
    source: *const CSPTrustedTypes,
) !void {
    for (source.policies.items) |policy| {
        try self.addSerializedWithDisposition(
            allocator,
            policy.serialized,
            policy.disposition,
        );
    }
}

/// True when an enforced or report-only policy requires the TT algorithm to
/// run. Report-only still invokes the default policy and affects successful
/// conversion values; it only changes whether a reported failure blocks.
pub fn requiresScriptCheck(self: *const CSPTrustedTypes) bool {
    for (self.policies.items) |policy| {
        if (policy.requires_script) return true;
    }
    return false;
}

/// Compatibility name for the blocking decision used by assignment sinks.
pub fn requiresScript(self: *const CSPTrustedTypes) bool {
    for (self.policies.items) |policy| {
        if (policy.disposition == .enforce and policy.requires_script) return true;
    }
    return false;
}

/// Chromium only consults `trusted-types-eval` while at least one enforced
/// policy requires Trusted Types for script.  The keyword is an explicit
/// escape hatch rather than an intersecting source expression: one operative
/// enforced script/default directive containing it enables the pass-through.
pub fn allowsTrustedTypesEval(self: *const CSPTrustedTypes) bool {
    if (!self.requiresScript()) return false;
    for (self.policies.items) |policy| {
        if (policy.disposition == .enforce and policy.allows_trusted_types_eval) return true;
    }
    return false;
}

/// Apply Chromium's policy-name and duplicate-name decision for every
/// enforced CSP policy.  The first enforced violation determines the public
/// TypeError category; policies without `trusted-types` impose no constraint.
pub fn policyDecision(
    self: *const CSPTrustedTypes,
    name: []const u8,
    is_duplicate: bool,
) PolicyDecision {
    for (self.policies.items) |policy| {
        if (policy.disposition != .enforce) continue;
        const directive = policy.trusted_types orelse continue;

        // Blink checks duplicates before policy-name grammar/allowlist.
        if (is_duplicate and
            (!directive.allow_duplicates or std.mem.eql(u8, name, "default")))
        {
            return .disallowed_duplicate;
        }
        if (!isPolicyName(name)) return .disallowed_name;
        if (directive.allow_any) continue;

        var found = false;
        for (directive.names) |allowed_name| {
            if (std.mem.eql(u8, name, allowed_name)) {
                found = true;
                break;
            }
        }
        if (!found) return .disallowed_name;
    }
    return .allowed;
}

pub fn deinit(self: *CSPTrustedTypes, allocator: Allocator) void {
    for (self.policies.items) |policy| {
        if (policy.trusted_types) |directive| {
            if (directive.names.len > 0) allocator.free(directive.names);
        }
        allocator.free(policy.serialized);
    }
    self.policies.deinit(allocator);
    self.* = .{};
}

fn parsePolicy(
    allocator: Allocator,
    serialized: []const u8,
    disposition: Disposition,
) !Policy {
    const owned = try allocator.dupe(u8, serialized);
    errdefer allocator.free(owned);

    var result: Policy = .{ .serialized = owned, .disposition = disposition };
    var saw_require = false;
    var saw_trusted_types = false;
    var saw_script_src = false;
    var saw_default_src = false;
    var script_src_allows_trusted_types_eval = false;
    var default_src_allows_trusted_types_eval = false;

    var directives = std.mem.splitScalar(u8, owned, ';');
    while (directives.next()) |raw_directive| {
        const directive = std.mem.trim(u8, raw_directive, ascii_whitespace);
        if (directive.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, directive, ascii_whitespace);
        const name = tokens.next() orelse continue;

        if (!saw_script_src and std.ascii.eqlIgnoreCase(name, "script-src")) {
            saw_script_src = true;
            script_src_allows_trusted_types_eval = hasKeyword(
                tokens.rest(),
                "'trusted-types-eval'",
            );
            continue;
        }
        if (!saw_default_src and std.ascii.eqlIgnoreCase(name, "default-src")) {
            saw_default_src = true;
            default_src_allows_trusted_types_eval = hasKeyword(
                tokens.rest(),
                "'trusted-types-eval'",
            );
            continue;
        }

        if (!saw_require and std.ascii.eqlIgnoreCase(name, "require-trusted-types-for")) {
            saw_require = true;
            while (tokens.next()) |expression| {
                // The directive value is intentionally case-sensitive.
                if (std.mem.eql(u8, expression, "'script'")) {
                    result.requires_script = true;
                }
            }
            continue;
        }

        if (!saw_trusted_types and std.ascii.eqlIgnoreCase(name, "trusted-types")) {
            saw_trusted_types = true;
            result.trusted_types = try parseTrustedTypesDirective(allocator, tokens.rest());
        }
    }
    result.allows_trusted_types_eval = if (saw_script_src)
        script_src_allows_trusted_types_eval
    else
        default_src_allows_trusted_types_eval;
    return result;
}

fn parseTrustedTypesDirective(
    allocator: Allocator,
    value: []const u8,
) !TrustedTypesDirective {
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(allocator);

    var tokens = std.mem.tokenizeAny(u8, value, ascii_whitespace);
    while (tokens.next()) |token| try pieces.append(allocator, token);

    // `trusted-types 'none'` is an empty allowlist.  Alongside another token,
    // 'none' is invalid and ignored while the remaining expressions apply.
    if (pieces.items.len == 1 and std.mem.eql(u8, pieces.items[0], "'none'")) {
        return .{};
    }

    var result: TrustedTypesDirective = .{};
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);

    for (pieces.items) |expression| {
        if (std.mem.eql(u8, expression, "*")) {
            result.allow_any = true;
        } else if (std.ascii.eqlIgnoreCase(expression, "'allow-duplicates'")) {
            result.allow_duplicates = true;
        } else if (std.ascii.eqlIgnoreCase(expression, "'none'")) {
            continue;
        } else if (isPolicyName(expression)) {
            try names.append(allocator, expression);
        }
    }
    result.names = try names.toOwnedSlice(allocator);
    return result;
}

fn isPolicyName(value: []const u8) bool {
    for (value) |character| {
        if (std.ascii.isAlphanumeric(character)) continue;
        if (std.mem.indexOfScalar(u8, "-#=_/@.%", character) != null) continue;
        return false;
    }
    return true;
}

fn hasKeyword(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, value, ascii_whitespace);
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, expected)) return true;
    }
    return false;
}

test "CSP Trusted Types parses first directives and require script" {
    const testing = std.testing;

    var state: CSPTrustedTypes = .{};
    defer state.deinit(testing.allocator);
    try state.addSerialized(
        testing.allocator,
        "require-trusted-types-for invalid; require-trusted-types-for 'script', " ++
            "default-src 'self'; require-trusted-types-for 'script'",
    );
    // The first policy's duplicate is ignored, while the second policy still
    // requires Trusted Types.  Policies combine by intersection.
    try testing.expect(state.requiresScript());

    var first_invalid: CSPTrustedTypes = .{};
    defer first_invalid.deinit(testing.allocator);
    try first_invalid.addSerialized(
        testing.allocator,
        "require-trusted-types-for invalid; require-trusted-types-for 'script'",
    );
    try testing.expect(!first_invalid.requiresScript());
}

test "CSP Trusted Types allowlist duplicate and grammar decisions" {
    const testing = std.testing;

    var state: CSPTrustedTypes = .{};
    defer state.deinit(testing.allocator);
    try state.addSerialized(
        testing.allocator,
        "trusted-types alpha default 'allow-duplicates'; trusted-types ignored, trusted-types beta",
    );

    // alpha is rejected by the second comma-separated policy; beta is
    // rejected by the first.  `default` is always duplicate-protected.
    try testing.expectEqual(.disallowed_name, state.policyDecision("alpha", false));
    try testing.expectEqual(.disallowed_name, state.policyDecision("beta", false));
    try testing.expectEqual(.disallowed_duplicate, state.policyDecision("default", true));
    try testing.expectEqual(.disallowed_name, state.policyDecision("colon:name", false));

    var wildcard: CSPTrustedTypes = .{};
    defer wildcard.deinit(testing.allocator);
    try wildcard.addSerialized(testing.allocator, "trusted-types * 'ALLOW-DUPLICATES'");
    try testing.expectEqual(.allowed, wildcard.policyDecision("a-zA-Z09#=_/@.%", true));
    try testing.expectEqual(.disallowed_name, wildcard.policyDecision("space name", false));
}

test "CSP Trusted Types missing directive permits names and duplicates" {
    const testing = std.testing;

    var state: CSPTrustedTypes = .{};
    defer state.deinit(testing.allocator);
    try state.addSerialized(testing.allocator, "default-src 'none'");
    try testing.expectEqual(.allowed, state.policyDecision("unicode-\xc3\xa9", true));

    var none: CSPTrustedTypes = .{};
    defer none.deinit(testing.allocator);
    try none.addSerialized(testing.allocator, "trusted-types 'none'");
    try testing.expectEqual(.disallowed_name, none.policyDecision("alpha", false));
}

test "CSP Trusted Types parses trusted-types-eval from the operative directive" {
    const testing = std.testing;

    var state: CSPTrustedTypes = .{};
    defer state.deinit(testing.allocator);
    try state.addSerialized(
        testing.allocator,
        "require-trusted-types-for 'script'; default-src 'trusted-types-eval'; " ++
            "script-src 'self'; script-src 'trusted-types-eval'",
    );
    try testing.expect(!state.allowsTrustedTypesEval());

    try state.addSerialized(
        testing.allocator,
        "script-src 'trusted-types-eval'",
    );
    try testing.expect(state.allowsTrustedTypesEval());

    var keyword_without_require: CSPTrustedTypes = .{};
    defer keyword_without_require.deinit(testing.allocator);
    try keyword_without_require.addSerialized(
        testing.allocator,
        "script-src 'trusted-types-eval'",
    );
    try testing.expect(!keyword_without_require.allowsTrustedTypesEval());
}

test "CSP Trusted Types report-only runs checks without enforcing decisions" {
    const testing = std.testing;

    var state: CSPTrustedTypes = .{};
    defer state.deinit(testing.allocator);
    try state.addSerializedReportOnly(
        testing.allocator,
        "require-trusted-types-for 'script'; trusted-types alpha; " ++
            "script-src 'trusted-types-eval'",
    );

    try testing.expect(state.requiresScriptCheck());
    try testing.expect(!state.requiresScript());
    try testing.expect(!state.allowsTrustedTypesEval());
    try testing.expectEqual(.allowed, state.policyDecision("beta", true));

    var inherited: CSPTrustedTypes = .{};
    defer inherited.deinit(testing.allocator);
    try inherited.inheritFrom(testing.allocator, &state);
    try testing.expect(inherited.requiresScriptCheck());
    try testing.expect(!inherited.requiresScript());
    try testing.expectEqual(.allowed, inherited.policyDecision("beta", true));
}
