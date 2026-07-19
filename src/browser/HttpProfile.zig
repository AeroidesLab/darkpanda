// Copyright (C) 2026 DarkPanda contributors
//
// Owned wire-header adapter for ResolvedFingerprintProfile. The resolved
// profile remains the source of truth; this module only adds C-string
// termination and the HTTP header syntax required by wreq.

const std = @import("std");
const ClientProfile = @import("../ClientProfile.zig");
const FingerprintProfile = @import("../FingerprintProfile.zig");

const Allocator = std.mem.Allocator;

pub const Owned = struct {
    profile: ClientProfile.Data,
    user_agent: [:0]u8,
    user_agent_header: [:0]u8,
    accept_language_header: [:0]u8,
    sec_ch_ua_header: [:0]u8,
    sec_ch_ua_mobile_header: [:0]u8,
    sec_ch_ua_platform_header: [:0]u8,

    pub fn init(
        allocator: Allocator,
        resolved: *const FingerprintProfile.ResolvedFingerprintProfile,
        legacy: *const ClientProfile.Data,
    ) !Owned {
        const user_agent = try allocator.dupeZ(u8, resolved.browser.user_agent);
        errdefer allocator.free(user_agent);
        const user_agent_header = try std.fmt.allocPrintSentinel(
            allocator,
            "User-Agent: {s}",
            .{resolved.browser.user_agent},
            0,
        );
        errdefer allocator.free(user_agent_header);
        const accept_language_header = try std.fmt.allocPrintSentinel(
            allocator,
            "Accept-Language: {s}",
            .{resolved.locale.accept_language},
            0,
        );
        errdefer allocator.free(accept_language_header);
        const sec_ch_ua_header = try formatBrandsHeader(allocator, resolved.browser.brands);
        errdefer allocator.free(sec_ch_ua_header);
        const sec_ch_ua_mobile_header = try allocator.dupeZ(
            u8,
            if (resolved.browser.mobile) "sec-ch-ua-mobile: ?1" else "sec-ch-ua-mobile: ?0",
        );
        errdefer allocator.free(sec_ch_ua_mobile_header);
        const sec_ch_ua_platform_header = try std.fmt.allocPrintSentinel(
            allocator,
            "sec-ch-ua-platform: \"{s}\"",
            .{resolved.browser.ua_platform},
            0,
        );
        errdefer allocator.free(sec_ch_ua_platform_header);

        return .{
            .profile = .{
                .id = .chrome149,
                .user_agent = user_agent,
                .app_version = resolved.browser.app_version,
                .vendor = legacy.vendor,
                .product = legacy.product,
                .navigator_platform = resolved.navigator.platform,
                .brands = resolved.browser.brands,
                .full_version_list = resolved.browser.full_version_list,
                .mobile = resolved.browser.mobile,
                .ua_platform = resolved.browser.ua_platform,
                .ua_full_version = resolved.browser.full_version,
                .architecture = resolved.browser.architecture,
                .bitness = resolved.browser.bitness,
                .model = resolved.browser.model,
                .platform_version = resolved.browser.platform_version,
                .wow64 = resolved.browser.wow64,
                .form_factors = resolved.browser.form_factors,
                .sec_ch_ua_header = sec_ch_ua_header,
                .sec_ch_ua_mobile_header = sec_ch_ua_mobile_header,
                .sec_ch_ua_platform_header = sec_ch_ua_platform_header,
                // These request-shape fields belong to the exact Chrome149
                // catalog entry and are not projection-controlled.
                .navigation_accept_header = legacy.navigation_accept_header,
                .accept_encoding_header = legacy.accept_encoding_header,
                .navigation_priority_header = legacy.navigation_priority_header,
            },
            .user_agent = user_agent,
            .user_agent_header = user_agent_header,
            .accept_language_header = accept_language_header,
            .sec_ch_ua_header = sec_ch_ua_header,
            .sec_ch_ua_mobile_header = sec_ch_ua_mobile_header,
            .sec_ch_ua_platform_header = sec_ch_ua_platform_header,
        };
    }

    pub fn deinit(self: *Owned, allocator: Allocator) void {
        allocator.free(self.sec_ch_ua_platform_header);
        allocator.free(self.sec_ch_ua_mobile_header);
        allocator.free(self.sec_ch_ua_header);
        allocator.free(self.accept_language_header);
        allocator.free(self.user_agent_header);
        allocator.free(self.user_agent);
        self.* = undefined;
    }
};

fn formatBrandsHeader(allocator: Allocator, brands: []const FingerprintProfile.Brand) ![:0]u8 {
    const prefix = "sec-ch-ua: ";
    var length: usize = prefix.len;
    for (brands, 0..) |brand, index| {
        if (index != 0) length += 2; // comma + space
        length += 1 + brand.brand.len + 5 + brand.version.len + 1;
    }

    const output = try allocator.allocSentinel(u8, length, 0);
    var cursor: usize = 0;
    append(output, &cursor, prefix);
    for (brands, 0..) |brand, index| {
        if (index != 0) append(output, &cursor, ", ");
        append(output, &cursor, "\"");
        append(output, &cursor, brand.brand);
        append(output, &cursor, "\";v=\"");
        append(output, &cursor, brand.version);
        append(output, &cursor, "\"");
    }
    std.debug.assert(cursor == length);
    return output;
}

fn append(output: []u8, cursor: *usize, value: []const u8) void {
    @memcpy(output[cursor.* .. cursor.* + value.len], value);
    cursor.* += value.len;
}

test "resolved profile produces one coherent wire identity" {
    var resolved = try FingerprintProfile.Owned.legacyChrome149Windows(std.testing.allocator);
    defer resolved.deinit();
    const legacy = ClientProfile.get(.chrome149);
    var owned = try Owned.init(std.testing.allocator, resolved.get(), &legacy);
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
        owned.user_agent_header,
    );
    try std.testing.expectEqualStrings("Accept-Language: en-US,en;q=0.9", owned.accept_language_header);
    try std.testing.expectEqualStrings(
        "sec-ch-ua: \"Google Chrome\";v=\"149\", \"Chromium\";v=\"149\", \"Not)A;Brand\";v=\"24\"",
        owned.profile.sec_ch_ua_header,
    );
    try std.testing.expectEqualStrings("sec-ch-ua-platform: \"Windows\"", owned.profile.sec_ch_ua_platform_header);
}
