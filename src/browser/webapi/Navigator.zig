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

const std = @import("std");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Execution = js.Execution;

const PluginArray = @import("PluginArray.zig");
const Permissions = @import("Permissions.zig");
const StorageManager = @import("StorageManager.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");
const UserActivation = @import("UserActivation.zig");
const ModelContext = @import("ModelContext.zig");
const FingerprintView = @import("../FingerprintView.zig");

const Navigator = @This();
_pad: bool = false,
_plugins: PluginArray = .{},
_permissions: Permissions = .{},
_storage: StorageManager = .{},
_ua_data: NavigatorUAData = .{},
_user_activation: UserActivation = .init,

pub const init: Navigator = .{};

pub fn getUserAgent(_: *const Navigator, exec: *const Execution) []const u8 {
    return exec.session.browser.http_client.getUserAgent();
}

pub fn getLanguages(_: *const Navigator, exec: *const Execution) []const []const u8 {
    return identity(exec).languages;
}

pub fn getDoNotTrack(_: *const Navigator) ?[]const u8 {
    return null;
}

pub fn getAppName(_: *const Navigator) []const u8 {
    return "Netscape";
}

pub fn getAppCodeName(_: *const Navigator) []const u8 {
    return "Mozilla";
}

pub fn getAppVersion(_: *const Navigator, exec: *const Execution) []const u8 {
    return identity(exec).app_version;
}

pub fn getLanguage(_: *const Navigator, exec: *const Execution) []const u8 {
    return identity(exec).language;
}

pub fn getOnLine(_: *const Navigator) bool {
    return true;
}

pub fn getCookieEnabled(_: *const Navigator) bool {
    return true;
}

pub fn getHardwareConcurrency(_: *const Navigator, exec: *const Execution) u32 {
    return identity(exec).hardware_concurrency;
}

pub fn getDeviceMemory(_: *const Navigator, exec: *const Execution) f64 {
    return identity(exec).device_memory;
}

pub fn getMaxTouchPoints(_: *const Navigator, exec: *const Execution) u32 {
    return identity(exec).max_touch_points;
}

pub fn getVendorSub(_: *const Navigator) []const u8 {
    return "";
}

pub fn getProductSub(_: *const Navigator) []const u8 {
    return "20030107";
}

pub fn getVendor(_: *const Navigator, exec: *const Execution) []const u8 {
    return identity(exec).vendor;
}

pub fn getProduct(_: *const Navigator, exec: *const Execution) []const u8 {
    return identity(exec).product;
}

pub fn getWebdriver(_: *const Navigator) bool {
    return false;
}

pub fn getPlatform(_: *const Navigator, exec: *const Execution) []const u8 {
    return identity(exec).platform;
}

fn identity(exec: *const Execution) FingerprintView.NavigatorIdentity {
    return FingerprintView.navigator(exec.session.browser.app);
}

/// Returns whether Java is enabled (always false)
pub fn javaEnabled(_: *const Navigator) bool {
    return false;
}

/// Noop, signal that the data was successfully queued
pub fn sendBeacon(_: *const Navigator, url: js.Value, data: ?js.Value) bool {
    _ = url;
    _ = data;
    return true;
}

pub fn getPlugins(self: *Navigator) *PluginArray {
    return &self._plugins;
}

pub fn getPermissions(self: *Navigator) *Permissions {
    return &self._permissions;
}

pub fn getStorage(self: *Navigator) *StorageManager {
    return &self._storage;
}

pub fn getUserAgentData(self: *Navigator) *NavigatorUAData {
    return &self._ua_data;
}

pub fn getUserActivation(self: *Navigator) *UserActivation {
    return &self._user_activation;
}

pub fn getModelContext(_: *const Navigator, frame: *Frame) *ModelContext {
    return &frame.window._model_context;
}

pub fn registerProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}
pub fn unregisterProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}

fn validateProtocolHandlerScheme(scheme: []const u8) !void {
    const allowed = std.StaticStringMap(void).initComptime(.{
        .{ "bitcoin", {} },
        .{ "cabal", {} },
        .{ "dat", {} },
        .{ "did", {} },
        .{ "dweb", {} },
        .{ "ethereum", .{} },
        .{ "ftp", {} },
        .{ "ftps", {} },
        .{ "geo", {} },
        .{ "im", {} },
        .{ "ipfs", {} },
        .{ "ipns", .{} },
        .{ "irc", {} },
        .{ "ircs", {} },
        .{ "hyper", {} },
        .{ "magnet", {} },
        .{ "mailto", {} },
        .{ "matrix", {} },
        .{ "mms", {} },
        .{ "news", {} },
        .{ "nntp", {} },
        .{ "openpgp4fpr", {} },
        .{ "sftp", {} },
        .{ "sip", {} },
        .{ "sms", {} },
        .{ "smsto", {} },
        .{ "ssb", {} },
        .{ "ssh", {} },
        .{ "tel", {} },
        .{ "urn", {} },
        .{ "webcal", {} },
        .{ "wtai", {} },
        .{ "xmpp", {} },
    });
    if (allowed.has(scheme)) {
        return;
    }

    if (scheme.len < 5 or !std.mem.startsWith(u8, scheme, "web+")) {
        return error.SecurityError;
    }
    for (scheme[4..]) |b| {
        if (std.ascii.isLower(b) == false) {
            return error.SecurityError;
        }
    }
}

fn validateProtocolHandlerURL(url: [:0]const u8, frame: *const Frame) !void {
    if (std.mem.indexOf(u8, url, "%s") == null) {
        return error.SyntaxError;
    }
    if (frame.isSameOrigin(url) == false) {
        return error.SyntaxError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigator);

    pub const Meta = struct {
        pub const name = "Navigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Preserve Chromium's relative installation order for the supported
    // Navigator members. Reflect.ownKeys(Navigator.prototype) is observable.
    pub const vendorSub = bridge.accessor(Navigator.getVendorSub, null, .{});
    pub const productSub = bridge.accessor(Navigator.getProductSub, null, .{});
    pub const vendor = bridge.accessor(Navigator.getVendor, null, .{});
    pub const maxTouchPoints = bridge.accessor(Navigator.getMaxTouchPoints, null, .{});
    pub const doNotTrack = bridge.accessor(Navigator.getDoNotTrack, null, .{});
    pub const hardwareConcurrency = bridge.accessor(Navigator.getHardwareConcurrency, null, .{});
    pub const cookieEnabled = bridge.accessor(Navigator.getCookieEnabled, null, .{});
    pub const appCodeName = bridge.accessor(Navigator.getAppCodeName, null, .{});
    pub const appName = bridge.accessor(Navigator.getAppName, null, .{});
    pub const appVersion = bridge.accessor(Navigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(Navigator.getPlatform, null, .{});
    pub const product = bridge.accessor(Navigator.getProduct, null, .{});
    pub const userAgent = bridge.accessor(Navigator.getUserAgent, null, .{});
    pub const language = bridge.accessor(Navigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{});
    pub const onLine = bridge.accessor(Navigator.getOnLine, null, .{});
    pub const webdriver = bridge.accessor(Navigator.getWebdriver, null, .{});
    pub const plugins = bridge.accessor(Navigator.getPlugins, null, .{ .exposed = .window });
    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{});
    pub const sendBeacon = bridge.function(Navigator.sendBeacon, .{ .exposed = .window, .noop = true });
    pub const modelContext = bridge.accessor(Navigator.getModelContext, null, .{ .exposed = .window });
    pub const deviceMemory = bridge.accessor(Navigator.getDeviceMemory, null, .{});
    pub const userAgentData = bridge.accessor(Navigator.getUserAgentData, null, .{});
    pub const userActivation = bridge.accessor(Navigator.getUserActivation, null, .{ .exposed = .window });
    pub const storage = bridge.accessor(Navigator.getStorage, null, .{});
    pub const permissions = bridge.accessor(Navigator.getPermissions, null, .{});
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{ .exposed = .window });
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{ .exposed = .window });
};

const testing = @import("../../testing.zig");
test "WebApi: Navigator" {
    try testing.htmlRunner("navigator", .{});
}
