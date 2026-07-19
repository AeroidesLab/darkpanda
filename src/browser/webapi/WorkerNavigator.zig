// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// WorkerNavigator is a distinct Web IDL interface from Navigator.  Sharing the
// Navigator backing type here is observably wrong: it exports `Navigator` in a
// worker realm, gives navigator the [object Navigator] tag, and exposes
// Window-only members such as plugins, webdriver and maxTouchPoints.

const js = @import("../js/js.zig");
const Navigator = @import("Navigator.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");
const Permissions = @import("Permissions.zig");
const StorageManager = @import("StorageManager.zig");
const Capabilities = @import("NavigatorCapabilities.zig");

const NetworkInformation = Capabilities.NetworkInformation;
const HID = Capabilities.HID;
const MediaCapabilities = Capabilities.MediaCapabilities;
const Serial = Capabilities.Serial;
const USB = Capabilities.USB;
const LockManager = Capabilities.LockManager;
const GPU = Capabilities.GPU;
const StorageBucketManager = Capabilities.StorageBucketManager;

const Execution = js.Execution;
const WorkerNavigator = @This();

// Keep the common state in one implementation object.  The JS wrapper is still
// WorkerNavigator, so receiver checks and all author-visible prototype details
// use the worker-only interface template.
_common: Navigator = .init,
_connection: ?*NetworkInformation = null,
_hid: ?*HID = null,
_media_capabilities: MediaCapabilities = .init,
_serial: ?*Serial = null,
_usb: ?*USB = null,
_locks: LockManager = .init,
_gpu: GPU = .init,
_storage_buckets: StorageBucketManager = .init,

pub const init: WorkerNavigator = .{};

pub fn getHardwareConcurrency(self: *const WorkerNavigator, exec: *const Execution) u32 {
    return self._common.getHardwareConcurrency(exec);
}

pub fn getAppCodeName(self: *const WorkerNavigator) []const u8 {
    return self._common.getAppCodeName();
}

pub fn getAppName(self: *const WorkerNavigator) []const u8 {
    return self._common.getAppName();
}

pub fn getAppVersion(self: *const WorkerNavigator, exec: *const Execution) []const u8 {
    return self._common.getAppVersion(exec);
}

pub fn getPlatform(self: *const WorkerNavigator, exec: *const Execution) []const u8 {
    return self._common.getPlatform(exec);
}

pub fn getProduct(self: *const WorkerNavigator, exec: *const Execution) []const u8 {
    return self._common.getProduct(exec);
}

pub fn getUserAgent(self: *const WorkerNavigator, exec: *const Execution) []const u8 {
    return self._common.getUserAgent(exec);
}

pub fn getLanguage(self: *const WorkerNavigator, exec: *const Execution) []const u8 {
    return self._common.getLanguage(exec);
}

pub fn getLanguages(self: *const WorkerNavigator, exec: *const Execution) []const []const u8 {
    return self._common.getLanguages(exec);
}

pub fn getOnLine(self: *const WorkerNavigator) bool {
    return self._common.getOnLine();
}

pub fn getConnection(self: *WorkerNavigator, exec: *const Execution) !*NetworkInformation {
    if (self._connection) |connection| return connection;
    const connection = try exec._factory.eventTarget(NetworkInformation{ ._proto = undefined });
    self._connection = connection;
    return connection;
}

pub fn getHID(self: *WorkerNavigator, exec: *const Execution) !*HID {
    if (self._hid) |hid| return hid;
    const hid = try exec._factory.eventTarget(HID{ ._proto = undefined });
    self._hid = hid;
    return hid;
}

pub fn getMediaCapabilities(self: *WorkerNavigator) *MediaCapabilities {
    return &self._media_capabilities;
}

pub fn getPermissions(self: *WorkerNavigator) *Permissions {
    return self._common.getPermissions();
}

pub fn getSerial(self: *WorkerNavigator, exec: *const Execution) !*Serial {
    if (self._serial) |serial| return serial;
    const serial = try exec._factory.eventTarget(Serial{ ._proto = undefined });
    self._serial = serial;
    return serial;
}

pub fn getUSB(self: *WorkerNavigator, exec: *const Execution) !*USB {
    if (self._usb) |usb| return usb;
    const usb = try exec._factory.eventTarget(USB{ ._proto = undefined });
    self._usb = usb;
    return usb;
}

pub fn getDeviceMemory(self: *const WorkerNavigator, exec: *const Execution) f64 {
    return self._common.getDeviceMemory(exec);
}

pub fn getUserAgentData(self: *WorkerNavigator) *NavigatorUAData {
    return self._common.getUserAgentData();
}

pub fn getLocks(self: *WorkerNavigator) *LockManager {
    return &self._locks;
}

pub fn getStorage(self: *WorkerNavigator) *StorageManager {
    return self._common.getStorage();
}

pub fn getGPU(self: *WorkerNavigator) *GPU {
    return &self._gpu;
}

pub fn getStorageBuckets(self: *WorkerNavigator) *StorageBucketManager {
    return &self._storage_buckets;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WorkerNavigator);

    pub const Meta = struct {
        pub const name = "WorkerNavigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // This is the worker-exposed subset implemented by DarkPanda, in Blink's
    // relative installation order.  In particular, do not copy Navigator's
    // window-only vendor, touch, cookie, webdriver, plugin or protocol-handler
    // members onto this interface.
    pub const hardwareConcurrency = bridge.accessor(WorkerNavigator.getHardwareConcurrency, null, .{});
    pub const appCodeName = bridge.accessor(WorkerNavigator.getAppCodeName, null, .{});
    pub const appName = bridge.accessor(WorkerNavigator.getAppName, null, .{});
    pub const appVersion = bridge.accessor(WorkerNavigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(WorkerNavigator.getPlatform, null, .{});
    pub const product = bridge.accessor(WorkerNavigator.getProduct, null, .{});
    pub const userAgent = bridge.accessor(WorkerNavigator.getUserAgent, null, .{});
    pub const language = bridge.accessor(WorkerNavigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(WorkerNavigator.getLanguages, null, .{});
    pub const onLine = bridge.accessor(WorkerNavigator.getOnLine, null, .{});
    pub const connection = bridge.accessor(WorkerNavigator.getConnection, null, .{});
    pub const hid = bridge.accessor(WorkerNavigator.getHID, null, .{});
    pub const mediaCapabilities = bridge.accessor(WorkerNavigator.getMediaCapabilities, null, .{});
    pub const permissions = bridge.accessor(WorkerNavigator.getPermissions, null, .{});
    pub const serial = bridge.accessor(WorkerNavigator.getSerial, null, .{});
    pub const usb = bridge.accessor(WorkerNavigator.getUSB, null, .{});
    pub const deviceMemory = bridge.accessor(WorkerNavigator.getDeviceMemory, null, .{});
    pub const userAgentData = bridge.accessor(WorkerNavigator.getUserAgentData, null, .{});
    pub const locks = bridge.accessor(WorkerNavigator.getLocks, null, .{});
    pub const storage = bridge.accessor(WorkerNavigator.getStorage, null, .{});
    pub const gpu = bridge.accessor(WorkerNavigator.getGPU, null, .{});
    pub const storageBuckets = bridge.accessor(WorkerNavigator.getStorageBuckets, null, .{});
};
