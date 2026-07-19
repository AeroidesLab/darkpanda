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

const FingerprintProfile = @import("../../FingerprintProfile.zig");
const FingerprintView = @import("../FingerprintView.zig");
const js = @import("../js/js.zig");
const Execution = js.Execution;

const NavigatorUAData = @This();

_pad: bool = false,

const Brand = FingerprintProfile.Brand;

pub fn getBrands(_: *const NavigatorUAData, exec: *const Execution) []const Brand {
    return profile(exec).brands;
}

pub fn getMobile(_: *const NavigatorUAData, exec: *const Execution) bool {
    return profile(exec).mobile;
}

pub fn getPlatform(_: *const NavigatorUAData, exec: *const Execution) []const u8 {
    return profile(exec).ua_platform;
}

pub fn toJSON(_: *const NavigatorUAData, exec: *const Execution) struct {
    brands: []const Brand,
    mobile: bool,
    platform: []const u8,
} {
    const selected = profile(exec);
    return .{
        .mobile = selected.mobile,
        .brands = selected.brands,
        .platform = selected.ua_platform,
    };
}

pub fn getHighEntropyValues(_: *const NavigatorUAData, hints: []const []const u8, exec: *const Execution) !js.Promise {
    const selected = profile(exec);
    const local = exec.js.local.?;
    const result = local.newObject();

    // Low-entropy values are always present. High-entropy properties are own
    // properties only when the caller requested the corresponding hint.
    try set(&result, "brands", selected.brands);
    try set(&result, "mobile", selected.mobile);
    try set(&result, "platform", selected.ua_platform);

    for (hints) |hint| {
        if (std.mem.eql(u8, hint, "architecture")) {
            try set(&result, "architecture", selected.architecture);
        } else if (std.mem.eql(u8, hint, "bitness")) {
            try set(&result, "bitness", selected.bitness);
        } else if (std.mem.eql(u8, hint, "model")) {
            try set(&result, "model", selected.model);
        } else if (std.mem.eql(u8, hint, "platformVersion")) {
            try set(&result, "platformVersion", selected.platform_version);
        } else if (std.mem.eql(u8, hint, "uaFullVersion")) {
            try set(&result, "uaFullVersion", selected.ua_full_version);
        } else if (std.mem.eql(u8, hint, "fullVersionList")) {
            try set(&result, "fullVersionList", selected.full_version_list);
        } else if (std.mem.eql(u8, hint, "wow64")) {
            try set(&result, "wow64", selected.wow64);
        } else if (std.mem.eql(u8, hint, "formFactors")) {
            try set(&result, "formFactors", selected.form_factors);
        }
    }
    return local.resolvePromise(result);
}

const std = @import("std");

fn set(object: *const js.Object, key: []const u8, value: anytype) !void {
    if (!try object.set(key, value, .{})) return error.CreateObjectFailure;
}

fn profile(exec: *const Execution) FingerprintView.NavigatorIdentity {
    return FingerprintView.navigator(exec.session.browser.app);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigatorUAData);

    pub const Meta = struct {
        pub const name = "NavigatorUAData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const brands = bridge.accessor(NavigatorUAData.getBrands, null, .{});
    pub const mobile = bridge.accessor(NavigatorUAData.getMobile, null, .{});
    pub const platform = bridge.accessor(NavigatorUAData.getPlatform, null, .{});
    pub const toJSON = bridge.function(NavigatorUAData.toJSON, .{});
    pub const getHighEntropyValues = bridge.function(NavigatorUAData.getHighEntropyValues, .{});
};
