// Copyright (C) 2026 DarkPanda contributors
//
// Minimal, generic implementations of the capability objects exposed through
// Navigator and WorkerNavigator supplements in Chromium.  These objects are
// deliberately not challenge-specific: their shape follows Blink's Web IDL
// and the methods provide conservative, device-free behavior.

const js = @import("../js/js.zig");
const EventTarget = @import("EventTarget.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        NetworkInformation,
        HID,
        MediaCapabilities,
        Serial,
        USB,
        LockManager,
        GPU,
        WGSLLanguageFeatures,
        StorageBucketManager,
    };
}

const EventHandlerSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

fn eventHandlerValue(setter: ?EventHandlerSetter) ?js.Function.Global {
    const value = setter orelse return null;
    return switch (value) {
        .func => |function| function,
        .anything => null,
    };
}

const EmptySequence = [0]u32;

pub const NetworkInformation = struct {
    _proto: *EventTarget,
    _on_change: ?js.Function.Global = null,

    pub fn asEventTarget(self: *NetworkInformation) *EventTarget {
        return self._proto;
    }

    fn getOnChange(self: *const NetworkInformation) ?js.Function.Global {
        return self._on_change;
    }

    fn setOnChange(self: *NetworkInformation, setter: ?EventHandlerSetter) void {
        self._on_change = eventHandlerValue(setter);
    }

    fn getEffectiveType(_: *const NetworkInformation) []const u8 {
        return "4g";
    }

    fn getRtt(_: *const NetworkInformation) u32 {
        return 100;
    }

    fn getDownlink(_: *const NetworkInformation) f64 {
        return 10.0;
    }

    fn getSaveData(_: *const NetworkInformation) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NetworkInformation);
        pub const Meta = struct {
            pub const name = "NetworkInformation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // NetInfoDownlinkMax is disabled in the Chrome 149 oracle, so `type`,
        // `downlinkMax`, and `ontypechange` are intentionally absent.
        pub const onchange = bridge.accessor(NetworkInformation.getOnChange, NetworkInformation.setOnChange, .{});
        pub const effectiveType = bridge.accessor(NetworkInformation.getEffectiveType, null, .{});
        pub const rtt = bridge.accessor(NetworkInformation.getRtt, null, .{});
        pub const downlink = bridge.accessor(NetworkInformation.getDownlink, null, .{});
        pub const saveData = bridge.accessor(NetworkInformation.getSaveData, null, .{});
    };
};

pub const HID = struct {
    _proto: *EventTarget,
    _on_connect: ?js.Function.Global = null,
    _on_disconnect: ?js.Function.Global = null,

    pub fn asEventTarget(self: *HID) *EventTarget {
        return self._proto;
    }

    fn getOnConnect(self: *const HID) ?js.Function.Global {
        return self._on_connect;
    }

    fn setOnConnect(self: *HID, setter: ?EventHandlerSetter) void {
        self._on_connect = eventHandlerValue(setter);
    }

    fn getOnDisconnect(self: *const HID) ?js.Function.Global {
        return self._on_disconnect;
    }

    fn setOnDisconnect(self: *HID, setter: ?EventHandlerSetter) void {
        self._on_disconnect = eventHandlerValue(setter);
    }

    fn getDevices(_: *const HID, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(EmptySequence{});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(HID);
        pub const Meta = struct {
            pub const name = "HID";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.accessor(HID.getOnConnect, HID.setOnConnect, .{});
        pub const ondisconnect = bridge.accessor(HID.getOnDisconnect, HID.setOnDisconnect, .{});
        pub const getDevices = bridge.function(HID.getDevices, .{});
    };
};

pub const MediaCapabilities = struct {
    _pad: bool = false,

    pub const init: MediaCapabilities = .{};

    const Info = struct {
        powerEfficient: bool,
        smooth: bool,
        supported: bool,
    };

    fn decodingInfo(_: *const MediaCapabilities, _: js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(Info{
            .powerEfficient = false,
            .smooth = false,
            .supported = false,
        });
    }

    fn encodingInfo(_: *const MediaCapabilities, _: js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(Info{
            .powerEfficient = false,
            .smooth = false,
            .supported = false,
        });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaCapabilities);
        pub const Meta = struct {
            pub const name = "MediaCapabilities";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const decodingInfo = bridge.function(MediaCapabilities.decodingInfo, .{});
        pub const encodingInfo = bridge.function(MediaCapabilities.encodingInfo, .{});
    };
};

pub const Serial = struct {
    _proto: *EventTarget,
    _on_connect: ?js.Function.Global = null,
    _on_disconnect: ?js.Function.Global = null,

    pub fn asEventTarget(self: *Serial) *EventTarget {
        return self._proto;
    }

    fn getOnConnect(self: *const Serial) ?js.Function.Global {
        return self._on_connect;
    }

    fn setOnConnect(self: *Serial, setter: ?EventHandlerSetter) void {
        self._on_connect = eventHandlerValue(setter);
    }

    fn getOnDisconnect(self: *const Serial) ?js.Function.Global {
        return self._on_disconnect;
    }

    fn setOnDisconnect(self: *Serial, setter: ?EventHandlerSetter) void {
        self._on_disconnect = eventHandlerValue(setter);
    }

    fn getPorts(_: *const Serial, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(EmptySequence{});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Serial);
        pub const Meta = struct {
            pub const name = "Serial";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.accessor(Serial.getOnConnect, Serial.setOnConnect, .{});
        pub const ondisconnect = bridge.accessor(Serial.getOnDisconnect, Serial.setOnDisconnect, .{});
        pub const getPorts = bridge.function(Serial.getPorts, .{});
    };
};

pub const USB = struct {
    _proto: *EventTarget,
    _on_connect: ?js.Function.Global = null,
    _on_disconnect: ?js.Function.Global = null,

    pub fn asEventTarget(self: *USB) *EventTarget {
        return self._proto;
    }

    fn getOnConnect(self: *const USB) ?js.Function.Global {
        return self._on_connect;
    }

    fn setOnConnect(self: *USB, setter: ?EventHandlerSetter) void {
        self._on_connect = eventHandlerValue(setter);
    }

    fn getOnDisconnect(self: *const USB) ?js.Function.Global {
        return self._on_disconnect;
    }

    fn setOnDisconnect(self: *USB, setter: ?EventHandlerSetter) void {
        self._on_disconnect = eventHandlerValue(setter);
    }

    fn getDevices(_: *const USB, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(EmptySequence{});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(USB);
        pub const Meta = struct {
            pub const name = "USB";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const onconnect = bridge.accessor(USB.getOnConnect, USB.setOnConnect, .{});
        pub const ondisconnect = bridge.accessor(USB.getOnDisconnect, USB.setOnDisconnect, .{});
        pub const getDevices = bridge.function(USB.getDevices, .{});
    };
};

pub const LockManager = struct {
    _pad: bool = false,

    pub const init: LockManager = .{};

    const Snapshot = struct {
        held: EmptySequence,
        pending: EmptySequence,
    };

    fn query(_: *const LockManager, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(Snapshot{
            .held = .{},
            .pending = .{},
        });
    }

    // A full cross-agent Web Locks scheduler is outside this surface layer.
    // Resolve a conservative null result while preserving the real Promise
    // contract and Web IDL-visible operation signature.
    fn request(_: *const LockManager, _: []const u8, _: js.Function, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(LockManager);
        pub const Meta = struct {
            pub const name = "LockManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chromium 149's generated overload binding installs these in this
        // observed order even though request precedes query in the IDL.
        pub const query = bridge.function(LockManager.query, .{});
        pub const request = bridge.function(LockManager.request, .{ .arity = 2, .required_args = 2 });
    };
};

pub const WGSLLanguageFeatures = struct {
    _pad: bool = false,

    pub const init: WGSLLanguageFeatures = .{};

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WGSLLanguageFeatures);
        pub const Meta = struct {
            pub const name = "WGSLLanguageFeatures";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
    };
};

pub const GPU = struct {
    _wgsl_features: WGSLLanguageFeatures = .init,

    pub const init: GPU = .{};

    fn getWgslLanguageFeatures(self: *GPU) *WGSLLanguageFeatures {
        return &self._wgsl_features;
    }

    fn getPreferredCanvasFormat(_: *const GPU) []const u8 {
        return "bgra8unorm";
    }

    fn requestAdapter(_: *const GPU, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GPU);
        pub const Meta = struct {
            pub const name = "GPU";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const wgslLanguageFeatures = bridge.accessor(GPU.getWgslLanguageFeatures, null, .{});
        pub const getPreferredCanvasFormat = bridge.function(GPU.getPreferredCanvasFormat, .{});
        pub const requestAdapter = bridge.function(GPU.requestAdapter, .{});
    };
};

pub const StorageBucketManager = struct {
    _pad: bool = false,

    pub const init: StorageBucketManager = .{};

    fn delete(_: *const StorageBucketManager, _: []const u8, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(js.Undefined{});
    }

    fn keys(_: *const StorageBucketManager, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(EmptySequence{});
    }

    fn open(_: *const StorageBucketManager, _: []const u8, _: ?js.Value, exec: *const Execution) !js.Promise {
        // The manager surface exists independently of persistent bucket
        // backends. Until StorageBucket is implemented, a null result is safer
        // than fabricating storage state.
        return exec.js.local.?.resolvePromise(@as(?u8, null));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageBucketManager);
        pub const Meta = struct {
            pub const name = "StorageBucketManager";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const delete = bridge.function(StorageBucketManager.delete, .{});
        pub const keys = bridge.function(StorageBucketManager.keys, .{});
        pub const open = bridge.function(StorageBucketManager.open, .{});
    };
};
