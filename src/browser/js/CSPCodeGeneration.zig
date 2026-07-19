// Copyright (C) 2026 Lightpanda
//
// This is intentionally not a complete Content Security Policy engine. It is
// the small, self-contained part of CSP needed by V8's dynamic-code callbacks:
// `eval`/Function and WebAssembly code generation. Script fetching, inline
// script checks, nonces/hashes, violation reporting, and Trusted Types belong
// to the document/loader CSP implementation rather than here.

const std = @import("std");

const Allocator = std.mem.Allocator;
const CSPCodeGeneration = @This();

allow_eval: bool = true,
allow_wasm: bool = true,

// The first enforced policy which blocks each operation. CSP policies combine
// by intersection, so a later permissive policy can never remove these blocks.
eval_blocking_directive: ?[]const u8 = null,
wasm_blocking_directive: ?[]const u8 = null,

pub const Update = struct {
    eval_became_blocked: bool = false,
    wasm_became_blocked: bool = false,
};

/// Add one serialized enforced CSP header/meta value. A serialized policy list
/// can contain comma-separated policies; every policy is enforced and their
/// permissions intersect.
pub fn addSerialized(
    self: *CSPCodeGeneration,
    allocator: Allocator,
    serialized: []const u8,
) !Update {
    var update: Update = .{};
    var policies = std.mem.splitScalar(u8, serialized, ',');
    while (policies.next()) |policy| {
        const single = try self.applyPolicy(allocator, policy);
        update.eval_became_blocked = update.eval_became_blocked or single.eval_became_blocked;
        update.wasm_became_blocked = update.wasm_became_blocked or single.wasm_became_blocked;
    }
    return update;
}

fn applyPolicy(
    self: *CSPCodeGeneration,
    allocator: Allocator,
    serialized: []const u8,
) !Update {
    var script_src: ?Directive = null;
    var default_src: ?Directive = null;

    // Per CSP parsing, only the first occurrence of a directive in one policy
    // is honored. script-src takes precedence over default-src regardless of
    // their textual order.
    var directives = std.mem.splitScalar(u8, serialized, ';');
    while (directives.next()) |raw_directive| {
        const directive = std.mem.trim(u8, raw_directive, ascii_whitespace);
        if (directive.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, directive, ascii_whitespace);
        const name = tokens.next() orelse continue;
        const sources = std.mem.trimLeft(u8, directive[name.len..], ascii_whitespace);

        if (script_src == null and std.ascii.eqlIgnoreCase(name, "script-src")) {
            script_src = .{ .serialized = directive, .sources = sources };
        } else if (default_src == null and std.ascii.eqlIgnoreCase(name, "default-src")) {
            default_src = .{ .serialized = directive, .sources = sources };
        }
    }

    const directive = script_src orelse default_src orelse return .{};
    const policy_allows_eval = hasKeyword(directive.sources, "'unsafe-eval'");
    // `unsafe-eval` is the broader legacy permission and enables Wasm too;
    // `wasm-unsafe-eval` permits only WebAssembly code generation.
    const policy_allows_wasm = policy_allows_eval or
        hasKeyword(directive.sources, "'wasm-unsafe-eval'");

    const block_eval = self.allow_eval and !policy_allows_eval;
    const block_wasm = self.allow_wasm and !policy_allows_wasm;

    // Allocate every value needed by this policy before changing observable
    // state. In particular, failure of the Wasm copy must not leave eval in
    // the impossible `allow_eval == false && directive == null` state.
    var eval_directive: ?[]u8 = null;
    errdefer if (eval_directive) |value| allocator.free(value);
    var wasm_directive: ?[]u8 = null;
    errdefer if (wasm_directive) |value| allocator.free(value);

    if (block_eval) {
        eval_directive = try allocator.dupe(u8, directive.serialized);
    }
    if (block_wasm) {
        wasm_directive = try allocator.dupe(u8, directive.serialized);
    }

    if (eval_directive) |value| {
        self.allow_eval = false;
        self.eval_blocking_directive = value;
    }
    if (wasm_directive) |value| {
        self.allow_wasm = false;
        self.wasm_blocking_directive = value;
    }
    return .{
        .eval_became_blocked = block_eval,
        .wasm_became_blocked = block_wasm,
    };
}

pub fn evalErrorMessage(self: *const CSPCodeGeneration, allocator: Allocator) ![]const u8 {
    // Only called on the allow -> block transition, where addSerialized has
    // already retained the responsible directive.
    const directive = self.eval_blocking_directive orelse unreachable;
    // Matches Chromium 149's ScriptController/ContentSecurityPolicy wording,
    // including the trailing quote and newline used by V8's EvalError.
    return std.fmt.allocPrint(
        allocator,
        "Evaluating a string as JavaScript violates the following Content Security Policy directive because 'unsafe-eval' is not an allowed source of script: {s}\".\n",
        .{directive},
    );
}

pub fn wasmErrorMessage(self: *const CSPCodeGeneration, allocator: Allocator) ![]const u8 {
    // ScriptController installs this text in V8's distinct Wasm codegen error
    // slot. V8 prepends the calling WebAssembly API name (for example
    // `WebAssembly.Module():`) when it creates the CompileError.
    const directive = self.wasm_blocking_directive orelse unreachable;
    return std.fmt.allocPrint(
        allocator,
        "Compiling or instantiating WebAssembly module violates the following Content Security policy directive because 'unsafe-eval' is not an allowed source of script in the following Content Security Policy directive: \"{s}\".",
        .{directive},
    );
}

fn hasKeyword(sources: []const u8, expected: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, sources, ascii_whitespace);
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, expected)) return true;
    }
    return false;
}

const Directive = struct {
    serialized: []const u8,
    sources: []const u8,
};

const ascii_whitespace = " \t\r\n\x0c";

test "CSP code generation directive fallback and keywords" {
    const testing = std.testing;

    var default_only: CSPCodeGeneration = .{};
    _ = try default_only.addSerialized(testing.allocator, "default-src 'self'");
    defer if (default_only.eval_blocking_directive) |value| testing.allocator.free(value);
    defer if (default_only.wasm_blocking_directive) |value| testing.allocator.free(value);
    try testing.expect(!default_only.allow_eval);
    try testing.expect(!default_only.allow_wasm);
    try testing.expectEqualStrings("default-src 'self'", default_only.eval_blocking_directive.?);

    var unsafe_eval: CSPCodeGeneration = .{};
    _ = try unsafe_eval.addSerialized(testing.allocator, "default-src 'none'; script-src 'unsafe-eval'");
    try testing.expect(unsafe_eval.allow_eval);
    try testing.expect(unsafe_eval.allow_wasm);

    var wasm_only: CSPCodeGeneration = .{};
    _ = try wasm_only.addSerialized(testing.allocator, "script-src 'wasm-unsafe-eval'");
    defer if (wasm_only.eval_blocking_directive) |value| testing.allocator.free(value);
    try testing.expect(!wasm_only.allow_eval);
    try testing.expect(wasm_only.allow_wasm);
}

test "CSP code generation policies intersect and first duplicate wins" {
    const testing = std.testing;

    var policy: CSPCodeGeneration = .{};
    _ = try policy.addSerialized(
        testing.allocator,
        "script-src 'unsafe-eval'; script-src 'none', default-src 'self'",
    );
    defer if (policy.eval_blocking_directive) |value| testing.allocator.free(value);
    defer if (policy.wasm_blocking_directive) |value| testing.allocator.free(value);

    // The duplicate script-src in policy 1 is ignored, but policy 2 still
    // intersects with it and blocks both operations.
    try testing.expect(!policy.allow_eval);
    try testing.expect(!policy.allow_wasm);
    try testing.expectEqualStrings("default-src 'self'", policy.eval_blocking_directive.?);

    // A later permissive policy cannot relax an earlier enforced policy.
    _ = try policy.addSerialized(testing.allocator, "script-src 'unsafe-eval'");
    try testing.expect(!policy.allow_eval);
    try testing.expect(!policy.allow_wasm);
}

test "CSP code generation error messages match Chromium 149" {
    const testing = std.testing;

    var policy: CSPCodeGeneration = .{};
    _ = try policy.addSerialized(
        testing.allocator,
        "script-src 'self' 'unsafe-inline'",
    );
    defer if (policy.eval_blocking_directive) |value| testing.allocator.free(value);
    defer if (policy.wasm_blocking_directive) |value| testing.allocator.free(value);

    const eval_message = try policy.evalErrorMessage(testing.allocator);
    defer testing.allocator.free(eval_message);
    try testing.expectEqualStrings(
        "Evaluating a string as JavaScript violates the following Content Security Policy directive because 'unsafe-eval' is not an allowed source of script: script-src 'self' 'unsafe-inline'\".\n",
        eval_message,
    );

    const wasm_message = try policy.wasmErrorMessage(testing.allocator);
    defer testing.allocator.free(wasm_message);
    try testing.expectEqualStrings(
        "Compiling or instantiating WebAssembly module violates the following Content Security policy directive because 'unsafe-eval' is not an allowed source of script in the following Content Security Policy directive: \"script-src 'self' 'unsafe-inline'\".",
        wasm_message,
    );
}

test "CSP code generation policy commit is atomic on allocation failure" {
    const testing = std.testing;
    const serialized = "script-src 'none'";

    // One directive copy fits; the second allocation must fail. applyPolicy
    // must release the first copy and leave both permissions untouched.
    var buffer: [serialized.len]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var policy: CSPCodeGeneration = .{};
    try testing.expectError(
        error.OutOfMemory,
        policy.addSerialized(fixed.allocator(), serialized),
    );

    try testing.expect(policy.allow_eval);
    try testing.expect(policy.allow_wasm);
    try testing.expectEqual(@as(?[]const u8, null), policy.eval_blocking_directive);
    try testing.expectEqual(@as(?[]const u8, null), policy.wasm_blocking_directive);
}
