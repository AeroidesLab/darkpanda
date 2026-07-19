// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// Secure Contexts' "Is origin potentially trustworthy?" subset used by the
// Window and Worker environment-settings implementations.
//
// Reference implementations for the Chrome 149 baseline:
//   services/network/public/cpp/is_potentially_trustworthy.cc
//   third_party/blink/renderer/core/execution_context/security_context.cc
//   third_party/blink/renderer/core/frame/local_dom_window.cc
//
// Inputs to isOriginPotentiallyTrustworthy are serialized, non-opaque origins
// (and therefore already canonicalized by the URL parser in production). An
// absent origin is never made trustworthy merely because its URL says https.

const std = @import("std");

const URL = @import("URL.zig");

/// Implements the observable Chrome/W3C potentially-trustworthy-origin rules
/// needed by the schemes DarkPanda supports. `origin` must describe a tuple
/// origin; opaque origins are represented by null at the caller.
pub fn isOriginPotentiallyTrustworthy(origin: []const u8) bool {
    const scheme = getScheme(origin);

    // Secure transports are authenticated independently of the host.
    if (std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "wss"))
    {
        return URL.getOriginHostname(origin).len != 0;
    }

    // Local files are potentially trustworthy in Chromium. DarkPanda does not
    // currently serialize file origins in Frame.origin, so Frame uses this via
    // the narrowly-scoped URL fallback below.
    if (std.ascii.eqlIgnoreCase(scheme, "file")) return true;

    // The localhost/loopback step precedes authenticated-scheme handling in
    // the specification. It therefore also applies to ws/ftp tuple origins.
    const hostname = URL.getOriginHostname(origin);
    return hostname.len != 0 and isLocalhost(hostname);
}

/// DarkPanda currently stores null for two non-opaque origin forms that Chrome
/// can still classify from the URL: file URLs and blob URLs (whose origin is
/// the inner URL's origin). This must not be used as a general URL fallback:
/// in particular data:, about:, and an opaque context carrying an https-looking
/// URL remain untrustworthy.
pub fn isTrustworthyMissingOriginURL(url: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(url, "file:")) return true;

    if (std.ascii.startsWithIgnoreCase(url, "blob:")) {
        const inner = url["blob:".len..];
        // Nested blob URLs and opaque inner URLs produce opaque origins.
        if (std.ascii.startsWithIgnoreCase(inner, "blob:") or
            std.ascii.startsWithIgnoreCase(inner, "data:") or
            std.ascii.startsWithIgnoreCase(inner, "about:"))
        {
            return false;
        }
        return isOriginPotentiallyTrustworthy(inner);
    }

    return false;
}

pub fn isInheritedAboutURL(url: []const u8) bool {
    return std.ascii.eqlIgnoreCase(url, "about:blank") or
        std.ascii.eqlIgnoreCase(url, "about:srcdoc");
}

fn getScheme(value: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value, ':') orelse return "";
    return value[0..end];
}

/// Mirrors net::HostStringIsLocalhost for canonical host strings: localhost
/// and *.localhost (with an optional trailing dot), IPv4 127/8, and ::1.
fn isLocalhost(hostname_: []const u8) bool {
    var hostname = hostname_;
    if (hostname.len >= 2 and hostname[0] == '[' and hostname[hostname.len - 1] == ']') {
        hostname = hostname[1 .. hostname.len - 1];
    }

    if (hostname.len > 0 and hostname[hostname.len - 1] == '.') {
        hostname = hostname[0 .. hostname.len - 1];
    }

    if (std.ascii.eqlIgnoreCase(hostname, "localhost") or
        std.ascii.endsWithIgnoreCase(hostname, ".localhost"))
    {
        return true;
    }

    return isIPv4Loopback(hostname) or isIPv6Loopback(hostname);
}

fn isIPv4Loopback(hostname: []const u8) bool {
    var parts = std.mem.splitScalar(u8, hostname, '.');
    var count: usize = 0;
    var first: u8 = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or count == 4) return false;
        const value = std.fmt.parseInt(u8, part, 10) catch return false;
        if (count == 0) first = value;
        count += 1;
    }
    return count == 4 and first == 127;
}

fn isIPv6Loopback(hostname: []const u8) bool {
    // Production URL strings are canonicalized to ::1. Accept the expanded
    // spelling too because SecurityOrigin tests and embedder callers may pass
    // an already-serialized origin without going through rust-url here.
    if (std.ascii.eqlIgnoreCase(hostname, "::1")) return true;

    var parts = std.mem.splitScalar(u8, hostname, ':');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or count == 8) return false;
        const value = std.fmt.parseInt(u16, part, 16) catch return false;
        if (count < 7 and value != 0) return false;
        if (count == 7 and value != 1) return false;
        count += 1;
    }
    return count == 8;
}

const testing = std.testing;

test "SecureContext: Chrome potentially trustworthy origins" {
    const Case = struct { origin: []const u8, trustworthy: bool };
    const cases = [_]Case{
        .{ .origin = "https://example.com", .trustworthy = true },
        .{ .origin = "wss://example.com", .trustworthy = true },
        .{ .origin = "file:///tmp/a", .trustworthy = true },
        .{ .origin = "http://localhost", .trustworthy = true },
        .{ .origin = "http://LOCALHOST.", .trustworthy = true },
        .{ .origin = "http://a.b.localhost:8080", .trustworthy = true },
        .{ .origin = "http://127.0.0.1", .trustworthy = true },
        .{ .origin = "http://127.255.0.7", .trustworthy = true },
        .{ .origin = "ws://[::1]", .trustworthy = true },
        .{ .origin = "ftp://127.0.0.2", .trustworthy = true },
        .{ .origin = "http://example.com", .trustworthy = false },
        .{ .origin = "http://localhost.example", .trustworthy = false },
        .{ .origin = "http://127.0.0.1.example", .trustworthy = false },
        .{ .origin = "ws://example.com", .trustworthy = false },
        .{ .origin = "ftp://example.com", .trustworthy = false },
    };

    for (cases) |case| {
        try testing.expectEqual(case.trustworthy, isOriginPotentiallyTrustworthy(case.origin));
    }
}

test "SecureContext: missing-origin fallback is deliberately narrow" {
    try testing.expect(isTrustworthyMissingOriginURL("file:///tmp/index.html"));
    try testing.expect(isTrustworthyMissingOriginURL("blob:https://example.com/id"));
    try testing.expect(isTrustworthyMissingOriginURL("blob:http://localhost:8000/id"));
    try testing.expect(!isTrustworthyMissingOriginURL("blob:http://example.com/id"));
    try testing.expect(!isTrustworthyMissingOriginURL("blob:data:text/plain,x"));
    try testing.expect(!isTrustworthyMissingOriginURL("blob:about:blank"));
    try testing.expect(!isTrustworthyMissingOriginURL("blob:blob:https://example.com/id"));
    try testing.expect(!isTrustworthyMissingOriginURL("data:text/html,x"));
    try testing.expect(!isTrustworthyMissingOriginURL("about:blank"));
    try testing.expect(!isTrustworthyMissingOriginURL("https://example.com"));
}
