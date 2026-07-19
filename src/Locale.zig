// Copyright (C) 2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Lightpanda historically exposed this value through Navigator and sent the
/// matching Accept-Language header. Keep that observable default while also
/// making it the ICU/V8 application locale.
pub const default_application_locale: [:0]const u8 = "en-US";
pub const default_accept_language_header: [:0]const u8 =
    "Accept-Language: en-US,en;q=0.9";

/// One immutable, application-wide locale profile. All browser-facing locale
/// surfaces borrow from this object:
///   - navigator.language / navigator.languages
///   - the default Accept-Language request header
///   - ICU/V8's default Intl locale (configured by Platform)
pub const Profile = struct {
    application_locale: [:0]const u8,
    accept_language_header: [:0]const u8,
    language_values: [2][]const u8,
    language_count: u8,

    pub fn init(allocator: Allocator, requested: []const u8) !Profile {
        const application_locale = try canonicalizeApplicationLocale(allocator, requested);
        errdefer allocator.free(application_locale);

        const primary_end = std.mem.indexOfScalar(u8, application_locale, '-') orelse
            application_locale.len;
        const has_fallback = primary_end < application_locale.len;
        const primary_language = application_locale[0..primary_end];

        const accept_language_header = if (has_fallback)
            try std.fmt.allocPrintSentinel(
                allocator,
                "Accept-Language: {s},{s};q=0.9",
                .{ application_locale, primary_language },
                0,
            )
        else
            try std.fmt.allocPrintSentinel(
                allocator,
                "Accept-Language: {s}",
                .{application_locale},
                0,
            );
        errdefer allocator.free(accept_language_header);

        var language_values: [2][]const u8 = .{ application_locale, "" };
        if (has_fallback) language_values[1] = primary_language;

        return .{
            .application_locale = application_locale,
            .accept_language_header = accept_language_header,
            .language_values = language_values,
            .language_count = if (has_fallback) 2 else 1,
        };
    }

    pub fn deinit(self: *const Profile, allocator: Allocator) void {
        allocator.free(self.accept_language_header);
        allocator.free(self.application_locale);
    }

    pub fn languages(self: *const Profile) []const []const u8 {
        return self.language_values[0..self.language_count];
    }
};

/// Canonicalize the application-locale subset Chrome uses for its UI locale:
/// language, optional Script, optional REGION, and optional variants. Unicode,
/// transformed and private-use extensions are deliberately rejected because
/// Intl constructors may selectively drop them, which would make the default
/// locale disagree with navigator.language.
pub fn canonicalizeApplicationLocale(allocator: Allocator, input: []const u8) ![:0]u8 {
    if (input.len < 2 or input.len > 63) return error.InvalidApplicationLocale;

    var output = try allocator.allocSentinel(u8, input.len, 0);
    errdefer allocator.free(output);

    var source_it = std.mem.splitScalar(u8, input, '-');
    const language = source_it.next().?;
    if (language.len < 2 or language.len > 8 or !allAsciiAlpha(language)) {
        return error.InvalidApplicationLocale;
    }

    var out_index: usize = 0;
    const canonical_language = preferredLanguage(language);
    for (canonical_language) |c| {
        output[out_index] = std.ascii.toLower(c);
        out_index += 1;
    }

    var seen_script = false;
    var seen_region = false;
    var seen_variant = false;
    while (source_it.next()) |subtag| {
        if (subtag.len == 0 or subtag.len > 8 or !allAsciiAlphanumeric(subtag)) {
            return error.InvalidApplicationLocale;
        }
        // A singleton begins an extension/private-use sequence. Application
        // locale intentionally excludes these; see the function comment.
        if (subtag.len == 1) return error.InvalidApplicationLocale;

        output[out_index] = '-';
        out_index += 1;

        if (!seen_script and !seen_region and !seen_variant and
            subtag.len == 4 and allAsciiAlpha(subtag))
        {
            for (subtag, 0..) |c, i| {
                output[out_index + i] = if (i == 0)
                    std.ascii.toUpper(c)
                else
                    std.ascii.toLower(c);
            }
            out_index += subtag.len;
            seen_script = true;
            continue;
        }

        if (!seen_region and !seen_variant and
            ((subtag.len == 2 and allAsciiAlpha(subtag)) or
                (subtag.len == 3 and allAsciiDigit(subtag))))
        {
            const region = preferredRegion(subtag);
            for (region) |c| {
                output[out_index] = std.ascii.toUpper(c);
                out_index += 1;
            }
            seen_region = true;
            continue;
        }

        const valid_variant = (subtag.len >= 5 and subtag.len <= 8) or
            (subtag.len == 4 and std.ascii.isDigit(subtag[0]));
        if (!valid_variant) return error.InvalidApplicationLocale;
        for (subtag) |c| {
            output[out_index] = std.ascii.toLower(c);
            out_index += 1;
        }
        seen_variant = true;
    }

    // Deprecated language/region aliases can change byte length. Resize the
    // sentinel allocation only when a preferred value did so.
    if (out_index != input.len) {
        const resized = try allocator.allocSentinel(u8, out_index, 0);
        @memcpy(resized, output[0..out_index]);
        allocator.free(output);
        return resized;
    }
    return output;
}

/// Early syntax validation. Platform performs the authoritative ICU lookup
/// after ICU data is initialized. Null means "use the host system timezone".
pub fn validateTimeZone(timezone: ?[]const u8) !void {
    const value = timezone orelse return;
    if (value.len == 0 or value.len > 255) return error.InvalidTimeZone;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or
            c == '-' or c == '+' or c == '.')) return error.InvalidTimeZone;
    }
}

fn preferredLanguage(input: []const u8) []const u8 {
    // ICU/BCP47 preferred values for the common deprecated two-letter tags.
    if (std.ascii.eqlIgnoreCase(input, "in")) return "id";
    if (std.ascii.eqlIgnoreCase(input, "iw")) return "he";
    if (std.ascii.eqlIgnoreCase(input, "ji")) return "yi";
    if (std.ascii.eqlIgnoreCase(input, "jw")) return "jv";
    if (std.ascii.eqlIgnoreCase(input, "mo")) return "ro";
    return input;
}

fn preferredRegion(input: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(input, "BU")) return "MM";
    if (std.ascii.eqlIgnoreCase(input, "DD")) return "DE";
    if (std.ascii.eqlIgnoreCase(input, "FX")) return "FR";
    if (std.ascii.eqlIgnoreCase(input, "TP")) return "TL";
    if (std.ascii.eqlIgnoreCase(input, "YD")) return "YE";
    if (std.ascii.eqlIgnoreCase(input, "ZR")) return "CD";
    return input;
}

fn allAsciiAlpha(value: []const u8) bool {
    for (value) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

fn allAsciiDigit(value: []const u8) bool {
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn allAsciiAlphanumeric(value: []const u8) bool {
    for (value) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

test "locale profile canonicalizes every public surface together" {
    const allocator = std.testing.allocator;
    var profile = try Profile.init(allocator, "ZH-hans-cn");
    defer profile.deinit(allocator);

    try std.testing.expectEqualStrings("zh-Hans-CN", profile.application_locale);
    try std.testing.expectEqualStrings(
        "Accept-Language: zh-Hans-CN,zh;q=0.9",
        profile.accept_language_header,
    );
    try std.testing.expectEqual(@as(usize, 2), profile.languages().len);
    try std.testing.expectEqualStrings("zh-Hans-CN", profile.languages()[0]);
    try std.testing.expectEqualStrings("zh", profile.languages()[1]);
}

test "language-only locale has no duplicate fallback" {
    const allocator = std.testing.allocator;
    var profile = try Profile.init(allocator, "fr");
    defer profile.deinit(allocator);

    try std.testing.expectEqualStrings("Accept-Language: fr", profile.accept_language_header);
    try std.testing.expectEqual(@as(usize, 1), profile.languages().len);
    try std.testing.expectEqualStrings("fr", profile.languages()[0]);
}

test "locale and timezone validation rejects header and ICU injection" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidApplicationLocale,
        canonicalizeApplicationLocale(allocator, "en-US\r\nX-Test"),
    );
    try std.testing.expectError(
        error.InvalidApplicationLocale,
        canonicalizeApplicationLocale(allocator, "en-US-u-ca-buddhist"),
    );
    try std.testing.expectError(error.InvalidTimeZone, validateTimeZone("UTC\r\nX-Test"));
    try validateTimeZone(null);
    try validateTimeZone("America/New_York");
}
