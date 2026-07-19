// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("js.zig");
const v8 = js.v8;
const Locale = @import("../../Locale.zig");

const Platform = @This();
handle: *v8.Platform,

/// Backward-compatible initializer: preserve Lightpanda's historical en-US
/// application locale and detect the host timezone.
pub fn init(v8_flags: ?[]const u8) !Platform {
    return initWithLocale(
        v8_flags,
        Locale.default_application_locale,
        null,
    );
}

pub fn initWithLocale(
    v8_flags: ?[]const u8,
    application_locale: [:0]const u8,
    timezone: ?[:0]const u8,
) !Platform {
    // Chromium 149 enables these Blink-shipped JavaScript features before
    // InitializePlatform. Keep them before caller-provided --js-flags so an
    // explicit embedding override has the same last-word ordering as gin.
    const chromium_default_enabled_flags =
        "--js-float16array " ++
        "--js-explicit-resource-management " ++
        "--js-regexp-escape";
    v8.v8__V8__SetFlagsFromString(
        chromium_default_enabled_flags.ptr,
        chromium_default_enabled_flags.len,
    );

    if (v8_flags) |flags| {
        v8.v8__V8__SetFlagsFromString(flags.ptr, flags.len);
    }

    // Chromium gates SharedArrayBuffer per Context. This must be set before
    // V8::Initialize; Env installs the embedder callback and explicitly
    // installs conditional features only after its Context metadata is ready.
    const conditional_features_flag = "--enable-sharedarraybuffer-per-context";
    v8.v8__V8__SetFlagsFromString(conditional_features_flag.ptr, conditional_features_flag.len);

    if (v8.v8__V8__InitializeICU() == false) {
        return error.FailedToInitializeICU;
    }
    const icu_result = v8.v8__V8__ConfigureICU(
        application_locale.ptr,
        if (timezone) |value| value.ptr else null,
    );
    if (icu_result != v8.kICUConfigOk) {
        return switch (icu_result) {
            v8.kICUConfigInvalidLocale => error.InvalidApplicationLocale,
            v8.kICUConfigInvalidTimeZone => error.InvalidTimeZone,
            else => error.FailedToConfigureICU,
        };
    }
    // 0 - threadpool size, 0 == let v8 decide
    // 1 - idle_task_support, 1 == enabled
    const handle = v8.v8__Platform__NewDefaultPlatform(0, 1).?;
    v8.v8__V8__InitializePlatform(handle);
    v8.v8__V8__Initialize();
    return .{ .handle = handle };
}

pub fn deinit(self: Platform) void {
    _ = v8.v8__V8__Dispose();
    v8.v8__V8__DisposePlatform();
    v8.v8__Platform__DELETE(self.handle);
}
