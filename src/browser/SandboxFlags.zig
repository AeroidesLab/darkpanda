// Chromium 149 WebSandboxFlags and iframe sandbox-token parsing.
//
// The bits intentionally match services/network/public/mojom/
// web_sandbox_flags.mojom. A sandbox attribute is an allow-list: its presence
// starts with every restriction enabled and each recognized token clears the
// corresponding restriction. Missing the attribute means no frame sandbox.

const std = @import("std");

pub const Mask = u32;

pub const none: Mask = 0;
pub const all: Mask = std.math.maxInt(Mask);

pub const navigation: Mask = 1 << 0;
pub const plugins: Mask = 1 << 1;
pub const origin: Mask = 1 << 2;
pub const forms: Mask = 1 << 3;
pub const scripts: Mask = 1 << 4;
pub const top_navigation: Mask = 1 << 5;
pub const popups: Mask = 1 << 6;
pub const automatic_features: Mask = 1 << 7;
pub const pointer_lock: Mask = 1 << 8;
pub const document_domain: Mask = 1 << 9;
pub const orientation_lock: Mask = 1 << 10;
pub const propagates_to_auxiliary_browsing_contexts: Mask = 1 << 11;
pub const modals: Mask = 1 << 12;
pub const presentation_controller: Mask = 1 << 13;
pub const top_navigation_by_user_activation: Mask = 1 << 14;
pub const downloads: Mask = 1 << 15;
pub const storage_access_by_user_activation: Mask = 1 << 16;
pub const top_navigation_to_custom_protocols: Mask = 1 << 17;
pub const allow_same_site_none_cookies: Mask = 1 << 18;

pub fn contains(flags: Mask, restriction: Mask) bool {
    return flags & restriction != 0;
}

fn allowedByToken(token: []const u8) Mask {
    if (std.ascii.eqlIgnoreCase(token, "allow-downloads")) return downloads;
    if (std.ascii.eqlIgnoreCase(token, "allow-forms")) return forms;
    if (std.ascii.eqlIgnoreCase(token, "allow-modals")) return modals;
    if (std.ascii.eqlIgnoreCase(token, "allow-orientation-lock")) return orientation_lock;
    if (std.ascii.eqlIgnoreCase(token, "allow-pointer-lock")) return pointer_lock;
    if (std.ascii.eqlIgnoreCase(token, "allow-popups")) return popups | top_navigation_to_custom_protocols;
    if (std.ascii.eqlIgnoreCase(token, "allow-popups-to-escape-sandbox")) return propagates_to_auxiliary_browsing_contexts;
    if (std.ascii.eqlIgnoreCase(token, "allow-presentation")) return presentation_controller;
    if (std.ascii.eqlIgnoreCase(token, "allow-same-origin")) return origin;
    if (std.ascii.eqlIgnoreCase(token, "allow-scripts")) return scripts | automatic_features;
    if (std.ascii.eqlIgnoreCase(token, "allow-storage-access-by-user-activation")) return storage_access_by_user_activation;
    if (std.ascii.eqlIgnoreCase(token, "allow-top-navigation")) return top_navigation | top_navigation_to_custom_protocols;
    if (std.ascii.eqlIgnoreCase(token, "allow-top-navigation-by-user-activation")) return top_navigation_by_user_activation;
    if (std.ascii.eqlIgnoreCase(token, "allow-top-navigation-to-custom-protocols")) return top_navigation_to_custom_protocols;
    if (std.ascii.eqlIgnoreCase(token, "allow-same-site-none-cookies")) return allow_same_site_none_cookies;
    return none;
}

pub fn parseAttribute(value: ?[]const u8) Mask {
    const raw = value orelse return none;
    var flags = all;
    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c");
    while (tokens.next()) |token| {
        flags &= ~allowedByToken(token);
    }
    return flags;
}

/// Returns the restriction mask from an enforced CSP `sandbox` directive, or
/// null when this policy does not contain one. CSP uses the same allow-token
/// grammar as iframe@sandbox; multiple policy fields are combined by OR by
/// the caller.
pub fn parseContentSecurityPolicy(value: []const u8) ?Mask {
    var directives = std.mem.splitScalar(u8, value, ';');
    while (directives.next()) |raw_directive| {
        const directive = std.mem.trim(u8, raw_directive, " \t\r\n\x0c");
        if (directive.len == 0) continue;

        const name_end = std.mem.indexOfAny(u8, directive, " \t\r\n\x0c") orelse directive.len;
        if (!std.ascii.eqlIgnoreCase(directive[0..name_end], "sandbox")) continue;

        const tokens = std.mem.trimLeft(u8, directive[name_end..], " \t\r\n\x0c");
        return parseAttribute(tokens);
    }
    return null;
}

test "SandboxFlags: Chrome 149 token masks" {
    try std.testing.expectEqual(none, parseAttribute(null));
    try std.testing.expectEqual(all, parseAttribute(""));

    const common = parseAttribute("allow-scripts allow-same-origin");
    try std.testing.expect(contains(common, navigation));
    try std.testing.expect(!contains(common, scripts));
    try std.testing.expect(!contains(common, automatic_features));
    try std.testing.expect(!contains(common, origin));
    try std.testing.expect(contains(common, top_navigation));
    try std.testing.expect(contains(common, top_navigation_by_user_activation));

    const by_activation = parseAttribute("allow-top-navigation-by-user-activation");
    try std.testing.expect(contains(by_activation, top_navigation));
    try std.testing.expect(!contains(by_activation, top_navigation_by_user_activation));

    const unrestricted_top = parseAttribute("allow-top-navigation");
    try std.testing.expect(!contains(unrestricted_top, top_navigation));
    try std.testing.expect(contains(unrestricted_top, top_navigation_by_user_activation));
    try std.testing.expect(!contains(unrestricted_top, top_navigation_to_custom_protocols));

    const popup = parseAttribute("allow-popups allow-popups-to-escape-sandbox");
    try std.testing.expect(!contains(popup, popups));
    try std.testing.expect(!contains(popup, propagates_to_auxiliary_browsing_contexts));

    // Unknown tokens do not grant a capability.
    try std.testing.expectEqual(all, parseAttribute("unknown-token"));

    try std.testing.expectEqual(
        parseAttribute("allow-scripts allow-same-origin"),
        parseContentSecurityPolicy("default-src 'self'; SANDBOX allow-scripts allow-same-origin").?,
    );
    try std.testing.expectEqual(all, parseContentSecurityPolicy("sandbox; script-src 'none'").?);
    try std.testing.expect(parseContentSecurityPolicy("script-src 'none'") == null);
}
