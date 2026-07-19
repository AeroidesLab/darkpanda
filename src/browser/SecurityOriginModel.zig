// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// Pure SecurityOrigin semantics for the incremental origin-isolation migration.
//
// This module deliberately does not own a V8 security token, URL parser, blob
// registry, PolicyContainer, or storage key. In particular, this is not the
// string-keyed `js/Origin.zig` type: callers should import it through the module
// name (`SecurityOriginModel.SecurityOrigin`) until that legacy type is retired.
//
// Scheme, host, and domain strings are borrowed and must already be canonical.
// Their storage must outlive the model value. document.domain validation and
// ownership/aliasing between Documents belong to the integration layer.

const std = @import("std");

/// Chromium uses unguessable 128-bit tokens for both opaque-origin identity and
/// agent-cluster identity. The model keeps the representation independent from
/// the UUID/random generator that will eventually construct these values.
pub const Nonce = [16]u8;
pub const AgentClusterId = [16]u8;

/// The main world can use Blink's fast V8 token only after both the Document
/// and its WindowAgent have their final security identity.  Other worlds need
/// a composite world token, which is intentionally deferred by this model.
pub const WorldKind = enum {
    main,
    isolated,
    worker,
};

pub const TupleOrigin = struct {
    scheme: []const u8,
    host: []const u8,

    /// Effective port. An omitted HTTP port is therefore stored as 80, and an
    /// omitted HTTPS port as 443. This is the value used by origin comparisons.
    port: u16,

    pub fn init(scheme: []const u8, host: []const u8, explicit_port: ?u16) TupleOrigin {
        return .{
            .scheme = scheme,
            .host = host,
            .port = explicit_port orelse defaultPortForScheme(scheme) orelse 0,
        };
    }
};

pub const OpaqueOrigin = struct {
    /// The only opaque-origin field that participates in an origin comparison.
    nonce: Nonce,

    /// A non-opaque tuple remembered for non-permission uses such as CSP and
    /// trustworthiness. It must never participate in same-origin or CanAccess.
    precursor: ?TupleOrigin = null,
};

/// Immutable origin identity. Copies of an opaque OriginCore retain the nonce;
/// deriving a new opaque origin must be performed by the caller with a new
/// nonce, optionally carrying forward `tupleOrPrecursor()`.
pub const OriginCore = union(enum) {
    tuple: TupleOrigin,
    @"opaque": OpaqueOrigin,

    pub fn initTuple(
        scheme: []const u8,
        host: []const u8,
        explicit_port: ?u16,
    ) OriginCore {
        return .{ .tuple = TupleOrigin.init(scheme, host, explicit_port) };
    }

    pub fn initOpaque(nonce: Nonce, precursor: ?TupleOrigin) OriginCore {
        return .{ .@"opaque" = .{ .nonce = nonce, .precursor = precursor } };
    }

    pub fn isOpaque(self: OriginCore) bool {
        return switch (self) {
            .tuple => false,
            .@"opaque" => true,
        };
    }

    /// Returns the tuple carried directly by a tuple origin or remembered by an
    /// opaque origin. This helper is intentionally absent from permission APIs.
    pub fn tupleOrPrecursor(self: OriginCore) ?TupleOrigin {
        return switch (self) {
            .tuple => |value| value,
            .@"opaque" => |value| value.precursor,
        };
    }
};

/// Mutable, per-Document security state. Normal Documents with equal tuple
/// origins have distinct SecurityOrigin values; owner-inherited about:blank and
/// srcdoc Documents may deliberately share one value in the integration layer.
pub const SecurityOrigin = struct {
    core: OriginCore,

    /// Starts as the tuple host (or empty for opaque origins). Only an accepted
    /// document.domain mutation changes this field and sets the flag below.
    domain: []const u8,
    domain_was_set: bool = false,

    /// Empty before the origin is assigned to a Document. CanAccess compares
    /// IDs only when both sides have one, matching Blink's transitional state.
    agent_cluster_id: ?AgentClusterId = null,

    /// These grants are directional: only the accessing/source origin's flags
    /// are consulted by canAccess.
    universal_access: bool = false,
    cross_agent_cluster_access: bool = false,

    pub fn init(core: OriginCore) SecurityOrigin {
        return .{
            .core = core,
            .domain = switch (core) {
                .tuple => |value| value.host,
                .@"opaque" => "",
            },
        };
    }

    pub fn initTuple(
        scheme: []const u8,
        host: []const u8,
        explicit_port: ?u16,
    ) SecurityOrigin {
        return init(OriginCore.initTuple(scheme, host, explicit_port));
    }

    pub fn initOpaque(nonce: Nonce, precursor: ?TupleOrigin) SecurityOrigin {
        return init(OriginCore.initOpaque(nonce, precursor));
    }

    /// Records a domain mutation after the Document layer has performed scheme,
    /// sandbox, OAC, suffix, and public-suffix validation.
    pub fn setDomainFromDOM(self: *SecurityOrigin, domain: []const u8) void {
        self.domain = domain;
        self.domain_was_set = true;
    }

    pub fn isOpaque(self: *const SecurityOrigin) bool {
        return self.core.isOpaque();
    }

    pub fn serialize(self: *const SecurityOrigin, buffer: []u8) SerializeError![]const u8 {
        return serializeSecurityOrigin(self, buffer);
    }
};

/// A shared token is keyed by the immutable raw tuple and WindowAgent id.  It
/// deliberately excludes document.domain, opaque nonces and serialized origin
/// strings: sharing such a token would make V8 bypass the access callback.
pub const FastTokenKey = struct {
    tuple: TupleOrigin,
    agent_cluster_id: AgentClusterId,
};

pub const TokenDecision = union(enum) {
    use_default,
    shared: FastTokenKey,
};

/// Mirrors the main-world eligibility gate in Chromium's
/// LocalWindowProxy::UpdateDocumentProperty.  This function is deliberately
/// conservative for special schemes until their file/local-origin checks are
/// represented; a default token is slower but cannot grant excess access.
pub fn tokenDecision(
    origin: *const SecurityOrigin,
    agent_cluster_id: ?AgentClusterId,
    is_initial_empty_document: bool,
    world_kind: WorldKind,
) TokenDecision {
    if (world_kind != .main or is_initial_empty_document or origin.domain_was_set) {
        return .use_default;
    }

    const tuple = switch (origin.core) {
        .@"opaque" => return .use_default,
        .tuple => |value| value,
    };
    if (!supportsFastToken(tuple.scheme)) return .use_default;

    const agent_id = agent_cluster_id orelse return .use_default;
    return .{ .shared = .{
        .tuple = tuple,
        .agent_cluster_id = agent_id,
    } };
}

/// HTML's "same origin" relation. document.domain and agent-cluster state do
/// not participate here.
pub fn sameOrigin(first: *const SecurityOrigin, second: *const SecurityOrigin) bool {
    if (first == second) return true;

    return switch (first.core) {
        .tuple => |first_tuple| switch (second.core) {
            .tuple => |second_tuple| sameTuple(first_tuple, second_tuple),
            .@"opaque" => false,
        },
        .@"opaque" => |first_opaque| switch (second.core) {
            .tuple => false,
            .@"opaque" => |second_opaque| sameId(first_opaque.nonce, second_opaque.nonce),
        },
    };
}

/// HTML's "same origin-domain" relation used by Window scripting access.
/// Explicitly setting document.domain on only one side makes even an otherwise
/// identical tuple fail this relation.
pub fn sameOriginDomain(first: *const SecurityOrigin, second: *const SecurityOrigin) bool {
    if (first == second) return true;

    if (first.isOpaque() or second.isOpaque()) {
        return sameOrigin(first, second);
    }

    const first_tuple = switch (first.core) {
        .tuple => |value| value,
        .@"opaque" => unreachable,
    };
    const second_tuple = switch (second.core) {
        .tuple => |value| value,
        .@"opaque" => unreachable,
    };

    if (!std.mem.eql(u8, first_tuple.scheme, second_tuple.scheme)) return false;

    if (!first.domain_was_set and !second.domain_was_set) {
        return std.mem.eql(u8, first_tuple.host, second_tuple.host) and
            first_tuple.port == second_tuple.port;
    }

    if (first.domain_was_set and second.domain_was_set) {
        return std.mem.eql(u8, first.domain, second.domain);
    }

    return false;
}

/// Blink-style scripting access: same-origin-domain followed by the independent
/// agent-cluster gate. Universal and cross-cluster grants are source-directed.
pub fn canAccess(accessing: *const SecurityOrigin, target: *const SecurityOrigin) bool {
    if (accessing.universal_access) return true;
    if (!sameOriginDomain(accessing, target)) return false;
    if (accessing.cross_agent_cluster_access) return true;

    if (accessing.agent_cluster_id) |accessing_id| {
        if (target.agent_cluster_id) |target_id| {
            if (!sameId(accessing_id, target_id)) return false;
        }
    }

    return true;
}

pub const SerializeError = error{BufferTooSmall};

/// Serializes the Document's SecurityOrigin, not the origin of its URL.
/// Opaque origins always serialize as "null" and document.domain is never
/// encoded. The caller owns the returned slice through `buffer`.
pub fn serializeSecurityOrigin(
    origin: *const SecurityOrigin,
    buffer: []u8,
) SerializeError![]const u8 {
    const tuple = switch (origin.core) {
        .@"opaque" => {
            if (buffer.len < "null".len) return error.BufferTooSmall;
            @memcpy(buffer[0.."null".len], "null");
            return buffer[0.."null".len];
        },
        .tuple => |value| value,
    };

    if (defaultPortForScheme(tuple.scheme)) |default_port| {
        if (tuple.port != default_port) {
            const result = std.fmt.bufPrint(
                buffer,
                "{s}://{s}:{d}",
                .{ tuple.scheme, tuple.host, tuple.port },
            ) catch return error.BufferTooSmall;
            return result;
        }
    }

    const result = std.fmt.bufPrint(
        buffer,
        "{s}://{s}",
        .{ tuple.scheme, tuple.host },
    ) catch return error.BufferTooSmall;
    return result;
}

/// Default ports needed by DarkPanda's standard tuple schemes. Inputs are
/// expected to be canonical lowercase strings; case-insensitive matching keeps
/// this pure boundary robust while URL parsing is migrated.
pub fn defaultPortForScheme(scheme: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "ws"))
    {
        return 80;
    }
    if (std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "wss"))
    {
        return 443;
    }
    if (std.ascii.eqlIgnoreCase(scheme, "ftp")) return 21;
    return null;
}

fn sameTuple(first: TupleOrigin, second: TupleOrigin) bool {
    return std.mem.eql(u8, first.scheme, second.scheme) and
        std.mem.eql(u8, first.host, second.host) and
        first.port == second.port;
}

fn sameId(first: [16]u8, second: [16]u8) bool {
    return std.mem.eql(u8, first[0..], second[0..]);
}

fn supportsFastToken(scheme: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "ws") or
        std.ascii.eqlIgnoreCase(scheme, "wss");
}

fn repeatedId(value: u8) [16]u8 {
    return @splat(value);
}

const testing = std.testing;

test "SecurityOriginModel: opaque nonce is identity and precursor is not permission" {
    const tuple_a = TupleOrigin.init("https", "a.example", null);
    const tuple_b = TupleOrigin.init("https", "b.example", 8443);

    var first = SecurityOrigin.initOpaque(repeatedId(0x11), tuple_a);
    var same_nonce_different_precursor = SecurityOrigin.initOpaque(repeatedId(0x11), tuple_b);
    var different_nonce_same_precursor = SecurityOrigin.initOpaque(repeatedId(0x22), tuple_a);
    var precursor_tuple = SecurityOrigin.init(.{ .tuple = tuple_a });

    try testing.expect(sameOrigin(&first, &same_nonce_different_precursor));
    try testing.expect(sameOriginDomain(&first, &same_nonce_different_precursor));
    try testing.expect(canAccess(&first, &same_nonce_different_precursor));
    try testing.expect(!sameOrigin(&first, &different_nonce_same_precursor));
    try testing.expect(!canAccess(&first, &different_nonce_same_precursor));
    try testing.expect(!sameOrigin(&first, &precursor_tuple));
    try testing.expect(!canAccess(&first, &precursor_tuple));

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("null", try first.serialize(&buffer));
}

test "SecurityOriginModel: tuple effective ports and serialization" {
    var implicit_https = SecurityOrigin.initTuple("https", "example.test", null);
    var explicit_default = SecurityOrigin.initTuple("https", "example.test", 443);
    var explicit_non_default = SecurityOrigin.initTuple("https", "example.test", 8443);

    try testing.expectEqual(@as(u16, 443), implicit_https.core.tuple.port);
    try testing.expect(sameOrigin(&implicit_https, &explicit_default));
    try testing.expect(!sameOrigin(&implicit_https, &explicit_non_default));

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "https://example.test",
        try serializeSecurityOrigin(&implicit_https, &buffer),
    );
    try testing.expectEqualStrings(
        "https://example.test",
        try serializeSecurityOrigin(&explicit_default, &buffer),
    );
    try testing.expectEqualStrings(
        "https://example.test:8443",
        try serializeSecurityOrigin(&explicit_non_default, &buffer),
    );

    var too_small: [3]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        serializeSecurityOrigin(&implicit_https, &too_small),
    );
}

test "SecurityOriginModel: one-sided and two-sided document.domain" {
    var first = SecurityOrigin.initTuple("https", "a.example.test", 443);
    var second = SecurityOrigin.initTuple("https", "a.example.test", null);

    try testing.expect(sameOrigin(&first, &second));
    try testing.expect(sameOriginDomain(&first, &second));

    first.setDomainFromDOM("a.example.test");
    try testing.expect(sameOrigin(&first, &second));
    try testing.expect(!sameOriginDomain(&first, &second));

    second.setDomainFromDOM("a.example.test");
    try testing.expect(sameOriginDomain(&first, &second));

    var other_host_and_port = SecurityOrigin.initTuple("https", "b.example.test", 9443);
    other_host_and_port.setDomainFromDOM("example.test");
    first.setDomainFromDOM("example.test");
    try testing.expect(!sameOrigin(&first, &other_host_and_port));
    try testing.expect(sameOriginDomain(&first, &other_host_and_port));

    var other_scheme = SecurityOrigin.initTuple("http", "b.example.test", 80);
    other_scheme.setDomainFromDOM("example.test");
    try testing.expect(!sameOriginDomain(&first, &other_scheme));

    other_host_and_port.setDomainFromDOM("other.test");
    try testing.expect(!sameOriginDomain(&first, &other_host_and_port));
}

test "SecurityOriginModel: agent-cluster access gate is independent and directional" {
    var accessing = SecurityOrigin.initTuple("https", "example.test", null);
    var target = SecurityOrigin.initTuple("https", "example.test", 443);
    accessing.agent_cluster_id = repeatedId(0x01);
    target.agent_cluster_id = repeatedId(0x02);

    try testing.expect(sameOriginDomain(&accessing, &target));
    try testing.expect(!canAccess(&accessing, &target));

    target.cross_agent_cluster_access = true;
    try testing.expect(!canAccess(&accessing, &target));

    accessing.cross_agent_cluster_access = true;
    try testing.expect(canAccess(&accessing, &target));

    accessing.cross_agent_cluster_access = false;
    target.agent_cluster_id = null;
    try testing.expect(canAccess(&accessing, &target));

    var cross_origin = SecurityOrigin.initTuple("https", "other.test", null);
    cross_origin.agent_cluster_id = repeatedId(0x03);
    accessing.universal_access = true;
    try testing.expect(canAccess(&accessing, &cross_origin));

    accessing.universal_access = false;
    cross_origin.universal_access = true;
    try testing.expect(!canAccess(&accessing, &cross_origin));
}

test "SecurityOriginModel: document.domain never changes serialization" {
    var origin = SecurityOrigin.initTuple("https", "a.example.test", 8443);
    origin.setDomainFromDOM("example.test");

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "https://a.example.test:8443",
        try serializeSecurityOrigin(&origin, &buffer),
    );
}

test "SecurityOriginModel: V8 fast token eligibility is fail closed" {
    const agent_id = repeatedId(0x41);
    var tuple = SecurityOrigin.initTuple("https", "a.example.test", null);

    const eligible = tokenDecision(&tuple, agent_id, false, .main);
    try testing.expect(eligible == .shared);
    try testing.expectEqualStrings("https", eligible.shared.tuple.scheme);
    try testing.expectEqualStrings("a.example.test", eligible.shared.tuple.host);
    try testing.expectEqual(@as(u16, 443), eligible.shared.tuple.port);
    try testing.expect(sameId(agent_id, eligible.shared.agent_cluster_id));

    try testing.expect(tokenDecision(&tuple, null, false, .main) == .use_default);
    try testing.expect(tokenDecision(&tuple, agent_id, true, .main) == .use_default);
    try testing.expect(tokenDecision(&tuple, agent_id, false, .isolated) == .use_default);
    try testing.expect(tokenDecision(&tuple, agent_id, false, .worker) == .use_default);

    tuple.setDomainFromDOM("example.test");
    try testing.expect(tokenDecision(&tuple, agent_id, false, .main) == .use_default);

    var opaque_origin = SecurityOrigin.initOpaque(repeatedId(0x42), null);
    try testing.expect(tokenDecision(&opaque_origin, agent_id, false, .main) == .use_default);

    var special_scheme = SecurityOrigin.initTuple("file", "", null);
    try testing.expect(tokenDecision(&special_scheme, agent_id, false, .main) == .use_default);
}

test "SecurityOriginModel: fast token key contains raw tuple and agent id" {
    const first_agent = repeatedId(0x51);
    const second_agent = repeatedId(0x52);
    var first = SecurityOrigin.initTuple("https", "a.example.test", null);
    var second = SecurityOrigin.initTuple("https", "a.example.test", 443);

    const first_key = tokenDecision(&first, first_agent, false, .main).shared;
    const equivalent_tuple_key = tokenDecision(&second, first_agent, false, .main).shared;
    const other_agent_key = tokenDecision(&second, second_agent, false, .main).shared;

    try testing.expect(sameTuple(first_key.tuple, equivalent_tuple_key.tuple));
    try testing.expect(sameId(first_key.agent_cluster_id, equivalent_tuple_key.agent_cluster_id));
    try testing.expect(!sameId(first_key.agent_cluster_id, other_agent_key.agent_cluster_id));

    first.setDomainFromDOM("example.test");
    second.setDomainFromDOM("example.test");
    try testing.expect(sameOriginDomain(&first, &second));
    try testing.expect(tokenDecision(&first, first_agent, false, .main) == .use_default);
}
