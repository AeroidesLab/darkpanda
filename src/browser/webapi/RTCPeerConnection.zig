const std = @import("std");
const lp = @import("darkpanda");

const js = @import("../js/js.zig");
const OwnerMailbox = @import("../OwnerMailbox.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const Blob = @import("Blob.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const WebSocket = @import("net/WebSocket.zig");
const webrtc = @import("../../sys/webrtc.zig");

const Execution = js.Execution;
const allocator = std.heap.c_allocator;
const RTCPeerConnection = @This();

pub const RTCSessionDescription = struct {
    _type: []const u8,
    _sdp: []const u8,

    pub const Init = struct { type: []const u8, sdp: []const u8 = "" };

    pub fn init(value: Init, exec: *Execution) !*RTCSessionDescription {
        return exec._factory.create(RTCSessionDescription{
            ._type = try exec.arena.dupe(u8, value.type),
            ._sdp = try exec.arena.dupe(u8, value.sdp),
        });
    }

    pub fn getType(self: *const RTCSessionDescription) []const u8 {
        return self._type;
    }

    pub fn getSdp(self: *const RTCSessionDescription) []const u8 {
        return self._sdp;
    }

    pub fn toJSON(self: *RTCSessionDescription) *RTCSessionDescription {
        return self;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCSessionDescription);
        pub const Meta = struct {
            pub const name = "RTCSessionDescription";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(RTCSessionDescription.init, .{ .arity = 1, .required_args = 1 });
        pub const @"type" = bridge.accessor(RTCSessionDescription.getType, null, .{});
        pub const sdp = bridge.accessor(RTCSessionDescription.getSdp, null, .{});
        pub const toJSON = bridge.function(RTCSessionDescription.toJSON, .{});
    };
};

pub const RTCIceCandidate = struct {
    _candidate: []const u8,
    _sdp_mid: ?[]const u8,
    _sdp_m_line_index: ?u16,

    pub const Init = struct {
        candidate: []const u8 = "",
        sdpMid: ?[]const u8 = null,
        sdpMLineIndex: ?u16 = null,
    };

    pub fn init(value: ?Init, exec: *Execution) !*RTCIceCandidate {
        const init_value: Init = value orelse .{};
        return exec._factory.create(RTCIceCandidate{
            ._candidate = try exec.arena.dupe(u8, init_value.candidate),
            ._sdp_mid = if (init_value.sdpMid) |mid| try exec.arena.dupe(u8, mid) else null,
            ._sdp_m_line_index = init_value.sdpMLineIndex,
        });
    }

    pub fn getCandidate(self: *const RTCIceCandidate) []const u8 {
        return self._candidate;
    }

    pub fn getSdpMid(self: *const RTCIceCandidate) ?[]const u8 {
        return self._sdp_mid;
    }

    pub fn getSdpMLineIndex(self: *const RTCIceCandidate) ?u16 {
        return self._sdp_m_line_index;
    }

    fn tokenAt(self: *const RTCIceCandidate, wanted: usize) ?[]const u8 {
        var tokens = std.mem.tokenizeScalar(u8, self._candidate, ' ');
        var index: usize = 0;
        while (tokens.next()) |token| : (index += 1) {
            if (index == wanted) return token;
        }
        return null;
    }

    fn tokenAfter(self: *const RTCIceCandidate, key: []const u8) ?[]const u8 {
        var tokens = std.mem.tokenizeScalar(u8, self._candidate, ' ');
        while (tokens.next()) |token| {
            if (std.ascii.eqlIgnoreCase(token, key)) return tokens.next();
        }
        return null;
    }

    pub fn getFoundation(self: *const RTCIceCandidate) ?[]const u8 {
        const token = self.tokenAt(0) orelse return null;
        return if (std.mem.startsWith(u8, token, "candidate:")) token[10..] else token;
    }

    pub fn getComponent(self: *const RTCIceCandidate) ?[]const u8 {
        const token = self.tokenAt(1) orelse return null;
        if (std.mem.eql(u8, token, "1")) return "rtp";
        if (std.mem.eql(u8, token, "2")) return "rtcp";
        return null;
    }

    pub fn getPriority(self: *const RTCIceCandidate) ?u32 {
        const token = self.tokenAt(3) orelse return null;
        return std.fmt.parseInt(u32, token, 10) catch null;
    }

    pub fn getProtocol(self: *const RTCIceCandidate) ?[]const u8 {
        return self.tokenAt(2);
    }

    pub fn getAddress(self: *const RTCIceCandidate) ?[]const u8 {
        return self.tokenAt(4);
    }

    pub fn getPort(self: *const RTCIceCandidate) ?u16 {
        const token = self.tokenAt(5) orelse return null;
        return std.fmt.parseInt(u16, token, 10) catch null;
    }

    pub fn getType(self: *const RTCIceCandidate) ?[]const u8 {
        return self.tokenAfter("typ");
    }

    pub fn getTcpType(self: *const RTCIceCandidate) ?[]const u8 {
        return self.tokenAfter("tcptype");
    }

    pub fn getRelatedAddress(self: *const RTCIceCandidate) ?[]const u8 {
        return self.tokenAfter("raddr");
    }

    pub fn getRelatedPort(self: *const RTCIceCandidate) ?u16 {
        const token = self.tokenAfter("rport") orelse return null;
        return std.fmt.parseInt(u16, token, 10) catch null;
    }

    pub fn getUsernameFragment(self: *const RTCIceCandidate) ?[]const u8 {
        return self.tokenAfter("ufrag");
    }

    pub fn getRelayProtocol(_: *const RTCIceCandidate) ?[]const u8 {
        return null;
    }

    pub fn getUrl(_: *const RTCIceCandidate) ?[]const u8 {
        return null;
    }

    pub fn toJSON(self: *RTCIceCandidate) *RTCIceCandidate {
        return self;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCIceCandidate);
        pub const Meta = struct {
            pub const name = "RTCIceCandidate";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(RTCIceCandidate.init, .{});
        pub const candidate = bridge.accessor(RTCIceCandidate.getCandidate, null, .{});
        pub const sdpMid = bridge.accessor(RTCIceCandidate.getSdpMid, null, .{});
        pub const sdpMLineIndex = bridge.accessor(RTCIceCandidate.getSdpMLineIndex, null, .{});
        pub const foundation = bridge.accessor(RTCIceCandidate.getFoundation, null, .{});
        pub const component = bridge.accessor(RTCIceCandidate.getComponent, null, .{});
        pub const priority = bridge.accessor(RTCIceCandidate.getPriority, null, .{});
        pub const protocol = bridge.accessor(RTCIceCandidate.getProtocol, null, .{});
        pub const address = bridge.accessor(RTCIceCandidate.getAddress, null, .{});
        pub const port = bridge.accessor(RTCIceCandidate.getPort, null, .{});
        pub const @"type" = bridge.accessor(RTCIceCandidate.getType, null, .{});
        pub const tcpType = bridge.accessor(RTCIceCandidate.getTcpType, null, .{});
        pub const relatedAddress = bridge.accessor(RTCIceCandidate.getRelatedAddress, null, .{});
        pub const relatedPort = bridge.accessor(RTCIceCandidate.getRelatedPort, null, .{});
        pub const usernameFragment = bridge.accessor(RTCIceCandidate.getUsernameFragment, null, .{});
        pub const relayProtocol = bridge.accessor(RTCIceCandidate.getRelayProtocol, null, .{});
        pub const url = bridge.accessor(RTCIceCandidate.getUrl, null, .{});
        pub const toJSON = bridge.function(RTCIceCandidate.toJSON, .{});
    };
};

pub const RTCPeerConnectionIceEvent = struct {
    _proto: *Event,
    _candidate: ?*RTCIceCandidate,

    pub const Init = Event.inheritOptions(RTCPeerConnectionIceEvent, struct {
        candidate: ?*RTCIceCandidate = null,
    });

    pub fn init(typ: []const u8, options: ?Init, exec: *Execution) !*RTCPeerConnectionIceEvent {
        const opts: Init = options orelse .{};
        const arena = try exec.page.getArena(.tiny, "RTCPeerConnectionIceEvent");
        errdefer exec.page.releaseArena(arena);
        const type_string = try lp.String.init(arena, typ, .{});
        const event = try exec.page.factory.event(arena, type_string, RTCPeerConnectionIceEvent{
            ._proto = undefined,
            ._candidate = opts.candidate,
        });
        Event.populatePrototypes(event, opts, false);
        return event;
    }

    fn trusted(candidate: ?*RTCIceCandidate, exec: *Execution) !*RTCPeerConnectionIceEvent {
        const arena = try exec.page.getArena(.tiny, "RTCPeerConnectionIceEvent.trusted");
        errdefer exec.page.releaseArena(arena);
        const event = try exec.page.factory.event(arena, comptime lp.String.wrap("icecandidate"), RTCPeerConnectionIceEvent{
            ._proto = undefined,
            ._candidate = candidate,
        });
        Event.populatePrototypes(event, Init{}, true);
        return event;
    }

    pub fn asEvent(self: *RTCPeerConnectionIceEvent) *Event {
        return self._proto;
    }

    pub fn getCandidate(self: *const RTCPeerConnectionIceEvent) ?*RTCIceCandidate {
        return self._candidate;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCPeerConnectionIceEvent);
        pub const Meta = struct {
            pub const name = "RTCPeerConnectionIceEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(RTCPeerConnectionIceEvent.init, .{ .arity = 1, .required_args = 1 });
        pub const candidate = bridge.accessor(RTCPeerConnectionIceEvent.getCandidate, null, .{});
    };
};

pub const RTCDataChannelEvent = struct {
    _proto: *Event,
    _channel: *RTCDataChannel,

    pub const Init = Event.inheritOptions(RTCDataChannelEvent, struct { channel: *RTCDataChannel });

    pub fn init(typ: []const u8, options: Init, exec: *Execution) !*RTCDataChannelEvent {
        const arena = try exec.page.getArena(.tiny, "RTCDataChannelEvent");
        errdefer exec.page.releaseArena(arena);
        const event = try exec.page.factory.event(arena, try lp.String.init(arena, typ, .{}), RTCDataChannelEvent{
            ._proto = undefined,
            ._channel = options.channel,
        });
        Event.populatePrototypes(event, options, false);
        return event;
    }

    fn trusted(channel: *RTCDataChannel, exec: *Execution) !*RTCDataChannelEvent {
        const arena = try exec.page.getArena(.tiny, "RTCDataChannelEvent.trusted");
        errdefer exec.page.releaseArena(arena);
        const event = try exec.page.factory.event(arena, comptime lp.String.wrap("datachannel"), RTCDataChannelEvent{
            ._proto = undefined,
            ._channel = channel,
        });
        Event.populatePrototypes(event, Init{ .channel = channel }, true);
        return event;
    }

    pub fn asEvent(self: *RTCDataChannelEvent) *Event {
        return self._proto;
    }

    pub fn getChannel(self: *const RTCDataChannelEvent) *RTCDataChannel {
        return self._channel;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCDataChannelEvent);
        pub const Meta = struct {
            pub const name = "RTCDataChannelEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(RTCDataChannelEvent.init, .{ .arity = 2, .required_args = 2 });
        pub const channel = bridge.accessor(RTCDataChannelEvent.getChannel, null, .{});
    };
};

pub const RTCDataChannel = struct {
    _proto: *EventTarget,
    _peer: *RTCPeerConnection,
    _native_id: i32,
    _label: []const u8,
    _protocol: []const u8,
    _ordered: bool,
    _id: ?u16,
    _max_packet_lifetime: ?u16,
    _max_retransmits: ?u16,
    _negotiated: bool,
    _binary_type: enum { blob, arraybuffer } = .blob,
    _buffered_amount_low_threshold: u32 = 0,
    _on_open: ?js.Function.Global = null,
    _on_message: ?js.Function.Global = null,
    _on_close: ?js.Function.Global = null,
    _on_error: ?js.Function.Global = null,
    _on_buffered_amount_low: ?js.Function.Global = null,

    pub fn asEventTarget(self: *RTCDataChannel) *EventTarget {
        return self._proto;
    }

    fn create(peer: *RTCPeerConnection, native_id: i32, label: []const u8, options: DataChannelInit) !*RTCDataChannel {
        errdefer _ = webrtc.dpw_data_channel_delete(native_id);
        const channel = try peer._exec._factory.eventTarget(RTCDataChannel{
            ._proto = undefined,
            ._peer = peer,
            ._native_id = native_id,
            ._label = try peer._exec.arena.dupe(u8, label),
            ._protocol = try peer._exec.arena.dupe(u8, options.protocol),
            ._ordered = options.ordered,
            ._id = if (options.negotiated) options.id else null,
            ._max_packet_lifetime = options.maxPacketLifeTime,
            ._max_retransmits = options.maxRetransmits,
            ._negotiated = options.negotiated,
        });
        try peer._channels.append(peer._exec.arena, channel);
        webrtc.dpw_set_user_pointer(native_id, peer);
        if (webrtc.dpw_set_open_callback(native_id, onChannelOpen) < 0 or
            webrtc.dpw_set_closed_callback(native_id, onChannelClosed) < 0 or
            webrtc.dpw_set_error_callback(native_id, onChannelError) < 0 or
            webrtc.dpw_set_message_callback(native_id, onChannelMessage) < 0 or
            webrtc.dpw_set_buffered_amount_low_callback(native_id, onChannelBufferedAmountLow) < 0)
        {
            return error.WebRtcBackendFailure;
        }
        return channel;
    }

    fn handler(comptime field: []const u8, self: *RTCDataChannel) ?js.Function.Global {
        return @field(self, field);
    }

    fn setHandler(comptime field: []const u8, self: *RTCDataChannel, cb: ?js.Function) !void {
        if (@field(self, field)) |old| old.release();
        @field(self, field) = if (cb) |value| try value.persistWithThis(self) else null;
    }

    pub fn getLabel(self: *const RTCDataChannel) []const u8 {
        return self._label;
    }
    pub fn getOrdered(self: *const RTCDataChannel) bool {
        return self._ordered;
    }
    pub fn getProtocol(self: *const RTCDataChannel) []const u8 {
        return self._protocol;
    }
    pub fn getId(self: *const RTCDataChannel) ?u16 {
        return self._id;
    }
    pub fn getMaxPacketLifeTime(self: *const RTCDataChannel) ?u16 {
        return self._max_packet_lifetime;
    }
    pub fn getMaxRetransmits(self: *const RTCDataChannel) ?u16 {
        return self._max_retransmits;
    }
    pub fn getNegotiated(self: *const RTCDataChannel) bool {
        return self._negotiated;
    }
    pub fn getReadyState(self: *const RTCDataChannel) []const u8 {
        if (webrtc.dpw_is_open(self._native_id)) return "open";
        if (webrtc.dpw_is_closed(self._native_id)) return "closed";
        return "connecting";
    }
    pub fn getBufferedAmount(self: *const RTCDataChannel) u32 {
        return @intCast(@max(0, webrtc.dpw_get_buffered_amount(self._native_id)));
    }
    pub fn getBufferedAmountLowThreshold(self: *const RTCDataChannel) u32 {
        return self._buffered_amount_low_threshold;
    }
    pub fn setBufferedAmountLowThreshold(self: *RTCDataChannel, value: u32) void {
        self._buffered_amount_low_threshold = value;
        _ = webrtc.dpw_set_buffered_amount_low_threshold(self._native_id, @intCast(@min(value, std.math.maxInt(i32))));
    }
    pub fn getBinaryType(self: *const RTCDataChannel) []const u8 {
        return @tagName(self._binary_type);
    }
    pub fn setBinaryType(self: *RTCDataChannel, value: []const u8) void {
        if (std.meta.stringToEnum(@TypeOf(self._binary_type), value)) |binary_type|
            self._binary_type = binary_type;
    }
    fn sendBytes(self: *RTCDataChannel, data: []const u8, text: bool) !void {
        if (!webrtc.dpw_is_open(self._native_id)) return error.InvalidStateError;
        if (data.len > std.math.maxInt(i32)) return error.MessageTooLarge;
        const size: i32 = if (text) -1 else @intCast(data.len);
        if (webrtc.dpw_data_channel_send(self._native_id, data.ptr, size) < 0)
            return error.WebRtcBackendFailure;
    }
    pub fn send(self: *RTCDataChannel, data: WebSocket.SendData) !void {
        switch (data) {
            .blob => |blob| try self.sendBytes(blob._slice, false),
            .js_val => |value| if (value.isString()) |string| {
                const text = try string.toSliceWithAlloc(self._peer._exec.call_arena);
                const terminated = try self._peer._exec.call_arena.dupeZ(u8, text);
                try self.sendBytes(terminated, true);
            } else {
                const binary = try value.toZig(WebSocket.BinaryData);
                try self.sendBytes(binary.asBuffer(), false);
            },
        }
    }
    pub fn close(self: *RTCDataChannel) void {
        _ = webrtc.dpw_data_channel_close(self._native_id);
    }
    pub fn getOnOpen(self: *RTCDataChannel) ?js.Function.Global {
        return handler("_on_open", self);
    }
    pub fn setOnOpen(self: *RTCDataChannel, cb: ?js.Function) !void {
        try setHandler("_on_open", self, cb);
    }
    pub fn getOnMessage(self: *RTCDataChannel) ?js.Function.Global {
        return handler("_on_message", self);
    }
    pub fn setOnMessage(self: *RTCDataChannel, cb: ?js.Function) !void {
        try setHandler("_on_message", self, cb);
    }
    pub fn getOnClose(self: *RTCDataChannel) ?js.Function.Global {
        return handler("_on_close", self);
    }
    pub fn setOnClose(self: *RTCDataChannel, cb: ?js.Function) !void {
        try setHandler("_on_close", self, cb);
    }
    pub fn getOnError(self: *RTCDataChannel) ?js.Function.Global {
        return handler("_on_error", self);
    }
    pub fn setOnError(self: *RTCDataChannel, cb: ?js.Function) !void {
        try setHandler("_on_error", self, cb);
    }
    pub fn getOnBufferedAmountLow(self: *RTCDataChannel) ?js.Function.Global {
        return handler("_on_buffered_amount_low", self);
    }
    pub fn setOnBufferedAmountLow(self: *RTCDataChannel, cb: ?js.Function) !void {
        try setHandler("_on_buffered_amount_low", self, cb);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCDataChannel);
        pub const Meta = struct {
            pub const name = "RTCDataChannel";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const label = bridge.accessor(RTCDataChannel.getLabel, null, .{});
        pub const ordered = bridge.accessor(RTCDataChannel.getOrdered, null, .{});
        pub const protocol = bridge.accessor(RTCDataChannel.getProtocol, null, .{});
        pub const id = bridge.accessor(RTCDataChannel.getId, null, .{});
        pub const maxPacketLifeTime = bridge.accessor(RTCDataChannel.getMaxPacketLifeTime, null, .{});
        pub const maxRetransmits = bridge.accessor(RTCDataChannel.getMaxRetransmits, null, .{});
        pub const negotiated = bridge.accessor(RTCDataChannel.getNegotiated, null, .{});
        pub const readyState = bridge.accessor(RTCDataChannel.getReadyState, null, .{});
        pub const bufferedAmount = bridge.accessor(RTCDataChannel.getBufferedAmount, null, .{});
        pub const bufferedAmountLowThreshold = bridge.accessor(RTCDataChannel.getBufferedAmountLowThreshold, RTCDataChannel.setBufferedAmountLowThreshold, .{});
        pub const binaryType = bridge.accessor(RTCDataChannel.getBinaryType, RTCDataChannel.setBinaryType, .{});
        pub const send = bridge.function(RTCDataChannel.send, .{ .arity = 1, .required_args = 1 });
        pub const close = bridge.function(RTCDataChannel.close, .{});
        pub const onopen = bridge.accessor(RTCDataChannel.getOnOpen, RTCDataChannel.setOnOpen, .{});
        pub const onmessage = bridge.accessor(RTCDataChannel.getOnMessage, RTCDataChannel.setOnMessage, .{});
        pub const onclose = bridge.accessor(RTCDataChannel.getOnClose, RTCDataChannel.setOnClose, .{});
        pub const onerror = bridge.accessor(RTCDataChannel.getOnError, RTCDataChannel.setOnError, .{});
        pub const onbufferedamountlow = bridge.accessor(RTCDataChannel.getOnBufferedAmountLow, RTCDataChannel.setOnBufferedAmountLow, .{});
    };
};

const DataChannelInit = struct {
    ordered: bool = true,
    maxPacketLifeTime: ?u16 = null,
    maxRetransmits: ?u16 = null,
    protocol: []const u8 = "",
    negotiated: bool = false,
    id: u16 = 0,
};

const Configuration = struct {
    iceServers: []const IceServer = &.{},
    iceTransportPolicy: []const u8 = "all",

    const IceServer = struct { urls: Urls };
    const Urls = union(enum) { single: []const u8, sequence: []const []const u8 };
};

_proto: *EventTarget,
_exec: *Execution,
_native_id: i32,
_owner_target: OwnerMailbox.Target,
_sender: OwnerMailbox.Sender,
_channels: std.ArrayListUnmanaged(*RTCDataChannel) = .empty,
_closed: bool = false,
_disposed: bool = false,
_signaling_state: []const u8 = "stable",
_ice_gathering_state: []const u8 = "new",
_ice_connection_state: []const u8 = "new",
_connection_state: []const u8 = "new",
_local_description_type: ?[]const u8 = null,
_remote_description_type: ?[]const u8 = null,
_on_ice_candidate: ?js.Function.Global = null,
_on_data_channel: ?js.Function.Global = null,
_on_connection_state_change: ?js.Function.Global = null,
_on_ice_gathering_state_change: ?js.Function.Global = null,
_on_ice_connection_state_change: ?js.Function.Global = null,
_on_signaling_state_change: ?js.Function.Global = null,
_on_negotiation_needed: ?js.Function.Global = null,

pub fn init(configuration_: ?Configuration, exec: *Execution) !*RTCPeerConnection {
    const bind_address = exec.session.browser.app.config.webRtcTunBindAddress() orelse
        return error.NotSupportedError;
    const configuration: Configuration = configuration_ orelse .{};
    const address = try exec.call_arena.dupeZ(u8, bind_address);
    var urls: std.ArrayListUnmanaged([*:0]const u8) = .empty;
    for (configuration.iceServers) |server| switch (server.urls) {
        .single => |url| try urls.append(exec.call_arena, (try exec.call_arena.dupeZ(u8, url)).ptr),
        .sequence => |values| for (values) |url|
            try urls.append(exec.call_arena, (try exec.call_arena.dupeZ(u8, url)).ptr),
    };

    var native_config: webrtc.PeerConfig = .{
        .ice_servers = if (urls.items.len == 0) null else urls.items.ptr,
        .ice_servers_count = @intCast(urls.items.len),
        .tun_bind_address = address,
        .transport_policy = if (std.mem.eql(u8, configuration.iceTransportPolicy, "relay")) 1 else 0,
    };
    const native_id = webrtc.dpw_peer_create(&native_config);
    if (native_id < 0) return error.WebRtcBackendFailure;
    errdefer _ = webrtc.dpw_peer_delete(native_id);

    const self = try exec._factory.eventTarget(RTCPeerConnection{
        ._proto = undefined,
        ._exec = exec,
        ._native_id = native_id,
        ._owner_target = undefined,
        ._sender = undefined,
    });
    self._owner_target = try exec.ownerMailbox().createTarget(self);
    errdefer self._owner_target.deinit();
    self._sender = try self._owner_target.sender();
    errdefer self._sender.deinit();
    webrtc.dpw_set_user_pointer(native_id, self);
    if (webrtc.dpw_set_local_candidate_callback(native_id, onCandidate) < 0 or
        webrtc.dpw_set_peer_state_callback(native_id, onPeerState) < 0 or
        webrtc.dpw_set_ice_state_callback(native_id, onIceState) < 0 or
        webrtc.dpw_set_gathering_state_callback(native_id, onGatheringState) < 0 or
        webrtc.dpw_set_signaling_state_callback(native_id, onSignalingState) < 0 or
        webrtc.dpw_set_data_channel_callback(native_id, onDataChannel) < 0)
    {
        return error.WebRtcBackendFailure;
    }
    return self;
}

pub fn asEventTarget(self: *RTCPeerConnection) *EventTarget {
    return self._proto;
}

pub fn deinit(self: *RTCPeerConnection, _: *@import("../Page.zig")) void {
    if (self._disposed) return;
    self._disposed = true;
    self._closed = true;
    self._owner_target.close();
    _ = webrtc.dpw_set_local_candidate_callback(self._native_id, null);
    _ = webrtc.dpw_set_peer_state_callback(self._native_id, null);
    _ = webrtc.dpw_set_ice_state_callback(self._native_id, null);
    _ = webrtc.dpw_set_gathering_state_callback(self._native_id, null);
    _ = webrtc.dpw_set_signaling_state_callback(self._native_id, null);
    _ = webrtc.dpw_set_data_channel_callback(self._native_id, null);
    _ = webrtc.dpw_peer_close(self._native_id);
    for (self._channels.items) |channel| {
        _ = webrtc.dpw_data_channel_delete(channel._native_id);
        inline for (.{ "_on_open", "_on_message", "_on_close", "_on_error", "_on_buffered_amount_low" }) |field|
            if (@field(channel, field)) |handler_value| handler_value.release();
    }
    _ = webrtc.dpw_peer_delete(self._native_id);
    self._sender.deinit();
    self._owner_target.deinit();
    inline for (.{
        "_on_ice_candidate",
        "_on_data_channel",
        "_on_connection_state_change",
        "_on_ice_gathering_state_change",
        "_on_ice_connection_state_change",
        "_on_signaling_state_change",
        "_on_negotiation_needed",
    }) |field|
        if (@field(self, field)) |handler_value| handler_value.release();
}

fn sdpResult(self: *RTCPeerConnection, comptime kind: []const u8, exec: *Execution) !js.Promise {
    const get = comptime if (std.mem.eql(u8, kind, "offer")) webrtc.dpw_create_offer else webrtc.dpw_create_answer;
    const required = get(self._native_id, null, 0);
    if (required <= 0) return error.WebRtcBackendFailure;
    const buffer = try exec.call_arena.alloc(u8, @intCast(required));
    if (get(self._native_id, buffer.ptr, required) < 0) return error.WebRtcBackendFailure;
    const description = try RTCSessionDescription.init(.{
        .type = kind,
        .sdp = std.mem.sliceTo(buffer, 0),
    }, exec);
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.resolve("RTCPeerConnection.createDescription", description);
    return resolver.promise();
}

pub fn createOffer(self: *RTCPeerConnection, exec: *Execution) !js.Promise {
    return sdpResult(self, "offer", exec);
}
pub fn createAnswer(self: *RTCPeerConnection, exec: *Execution) !js.Promise {
    return sdpResult(self, "answer", exec);
}

fn resolvedVoid(exec: *Execution, comptime context: []const u8) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.resolve(context, {});
    return resolver.promise();
}

pub fn setLocalDescription(self: *RTCPeerConnection, description: RTCSessionDescription.Init, exec: *Execution) !js.Promise {
    const typ = try exec.call_arena.dupeZ(u8, description.type);
    if (webrtc.dpw_set_local_description(self._native_id, typ) < 0) return error.WebRtcBackendFailure;
    self._local_description_type = try exec.arena.dupe(u8, description.type);
    return resolvedVoid(exec, "RTCPeerConnection.setLocalDescription");
}

pub fn setRemoteDescription(self: *RTCPeerConnection, description: RTCSessionDescription.Init, exec: *Execution) !js.Promise {
    const sdp = try exec.call_arena.dupeZ(u8, description.sdp);
    const typ = try exec.call_arena.dupeZ(u8, description.type);
    if (webrtc.dpw_set_remote_description(self._native_id, sdp, typ) < 0) return error.WebRtcBackendFailure;
    self._remote_description_type = try exec.arena.dupe(u8, description.type);
    return resolvedVoid(exec, "RTCPeerConnection.setRemoteDescription");
}

pub fn addIceCandidate(self: *RTCPeerConnection, candidate_: ?RTCIceCandidate.Init, exec: *Execution) !js.Promise {
    if (candidate_) |candidate| {
        const value = try exec.call_arena.dupeZ(u8, candidate.candidate);
        const mid = try exec.call_arena.dupeZ(u8, candidate.sdpMid orelse "0");
        if (webrtc.dpw_add_remote_candidate(self._native_id, value, mid) < 0)
            return error.WebRtcBackendFailure;
    }
    return resolvedVoid(exec, "RTCPeerConnection.addIceCandidate");
}

pub fn createDataChannel(self: *RTCPeerConnection, label: []const u8, init_: ?DataChannelInit) !*RTCDataChannel {
    const init_value: DataChannelInit = init_ orelse .{};
    if (init_value.maxPacketLifeTime != null and init_value.maxRetransmits != null)
        return error.TypeError;
    const label_z = try self._exec.call_arena.dupeZ(u8, label);
    const protocol_z = try self._exec.call_arena.dupeZ(u8, init_value.protocol);
    var config: webrtc.DataChannelConfig = .{
        .unordered = !init_value.ordered,
        .unreliable = init_value.maxPacketLifeTime != null or init_value.maxRetransmits != null,
        .max_packet_lifetime = init_value.maxPacketLifeTime orelse 0,
        .max_retransmits = init_value.maxRetransmits orelse 0,
        .protocol = protocol_z,
        .negotiated = init_value.negotiated,
        .id = init_value.id,
    };
    const native_id = webrtc.dpw_data_channel_create(self._native_id, label_z, &config);
    if (native_id < 0) return error.WebRtcBackendFailure;
    return RTCDataChannel.create(self, native_id, label, init_value);
}

pub fn close(self: *RTCPeerConnection) void {
    if (self._closed) return;
    self._closed = true;
    _ = webrtc.dpw_peer_close(self._native_id);
    self._connection_state = "closed";
    self._ice_connection_state = "closed";
    self._signaling_state = "closed";
}

fn getDescription(self: *RTCPeerConnection, exec: *Execution, comptime getter: anytype, typ: []const u8) !?*RTCSessionDescription {
    const required = getter(self._native_id, null, 0);
    if (required <= 0) return null;
    const buffer = try exec.call_arena.alloc(u8, @intCast(required));
    if (getter(self._native_id, buffer.ptr, required) < 0) return null;
    return RTCSessionDescription.init(.{ .type = typ, .sdp = std.mem.sliceTo(buffer, 0) }, exec);
}

pub fn getLocalDescription(self: *RTCPeerConnection, exec: *Execution) !?*RTCSessionDescription {
    const typ = self._local_description_type orelse return null;
    return self.getDescription(exec, webrtc.dpw_get_local_description, typ);
}

pub fn getRemoteDescription(self: *RTCPeerConnection, exec: *Execution) !?*RTCSessionDescription {
    const typ = self._remote_description_type orelse return null;
    return self.getDescription(exec, webrtc.dpw_get_remote_description, typ);
}

pub fn getCurrentLocalDescription(self: *RTCPeerConnection, exec: *Execution) !?*RTCSessionDescription {
    if (!std.mem.eql(u8, self._signaling_state, "stable")) return null;
    return self.getLocalDescription(exec);
}

pub fn getCurrentRemoteDescription(self: *RTCPeerConnection, exec: *Execution) !?*RTCSessionDescription {
    if (!std.mem.eql(u8, self._signaling_state, "stable")) return null;
    return self.getRemoteDescription(exec);
}

pub fn getPendingLocalDescription(self: *RTCPeerConnection, exec: *Execution) !?*RTCSessionDescription {
    if (!std.mem.startsWith(u8, self._signaling_state, "have-local-")) return null;
    return self.getLocalDescription(exec);
}

pub fn getPendingRemoteDescription(self: *RTCPeerConnection, exec: *Execution) !?*RTCSessionDescription {
    if (!std.mem.startsWith(u8, self._signaling_state, "have-remote-")) return null;
    return self.getRemoteDescription(exec);
}

pub fn getConfiguration(_: *RTCPeerConnection) Configuration {
    return .{};
}

pub fn setConfiguration(_: *RTCPeerConnection, _: Configuration) void {}

pub fn restartIce(_: *RTCPeerConnection) void {}

pub fn getStats(_: *RTCPeerConnection, exec: *Execution) js.Promise {
    return resolvedVoid(exec, "RTCPeerConnection.getStats");
}

pub fn getSignalingState(self: *const RTCPeerConnection) []const u8 {
    return self._signaling_state;
}
pub fn getIceGatheringState(self: *const RTCPeerConnection) []const u8 {
    return self._ice_gathering_state;
}
pub fn getIceConnectionState(self: *const RTCPeerConnection) []const u8 {
    return self._ice_connection_state;
}
pub fn getConnectionState(self: *const RTCPeerConnection) []const u8 {
    return self._connection_state;
}

fn peerHandler(comptime field: []const u8, self: *RTCPeerConnection) ?js.Function.Global {
    return @field(self, field);
}
fn setPeerHandler(comptime field: []const u8, self: *RTCPeerConnection, cb: ?js.Function) !void {
    if (@field(self, field)) |old| old.release();
    @field(self, field) = if (cb) |value| try value.persistWithThis(self) else null;
}
pub fn getOnIceCandidate(self: *RTCPeerConnection) ?js.Function.Global {
    return peerHandler("_on_ice_candidate", self);
}
pub fn setOnIceCandidate(self: *RTCPeerConnection, cb: ?js.Function) !void {
    try setPeerHandler("_on_ice_candidate", self, cb);
}
pub fn getOnDataChannel(self: *RTCPeerConnection) ?js.Function.Global {
    return peerHandler("_on_data_channel", self);
}
pub fn setOnDataChannel(self: *RTCPeerConnection, cb: ?js.Function) !void {
    try setPeerHandler("_on_data_channel", self, cb);
}
pub fn getOnConnectionStateChange(self: *RTCPeerConnection) ?js.Function.Global {
    return peerHandler("_on_connection_state_change", self);
}
pub fn setOnConnectionStateChange(self: *RTCPeerConnection, cb: ?js.Function) !void {
    try setPeerHandler("_on_connection_state_change", self, cb);
}
pub fn getOnIceGatheringStateChange(self: *RTCPeerConnection) ?js.Function.Global {
    return peerHandler("_on_ice_gathering_state_change", self);
}
pub fn setOnIceGatheringStateChange(self: *RTCPeerConnection, cb: ?js.Function) !void {
    try setPeerHandler("_on_ice_gathering_state_change", self, cb);
}
pub fn getOnIceConnectionStateChange(self: *RTCPeerConnection) ?js.Function.Global {
    return peerHandler("_on_ice_connection_state_change", self);
}
pub fn setOnIceConnectionStateChange(self: *RTCPeerConnection, cb: ?js.Function) !void {
    try setPeerHandler("_on_ice_connection_state_change", self, cb);
}
pub fn getOnSignalingStateChange(self: *RTCPeerConnection) ?js.Function.Global {
    return peerHandler("_on_signaling_state_change", self);
}
pub fn setOnSignalingStateChange(self: *RTCPeerConnection, cb: ?js.Function) !void {
    try setPeerHandler("_on_signaling_state_change", self, cb);
}
pub fn getOnNegotiationNeeded(self: *RTCPeerConnection) ?js.Function.Global {
    return peerHandler("_on_negotiation_needed", self);
}
pub fn setOnNegotiationNeeded(self: *RTCPeerConnection, cb: ?js.Function) !void {
    try setPeerHandler("_on_negotiation_needed", self, cb);
}

const CallbackKind = union(enum) {
    candidate: struct { candidate: []u8, mid: []u8 },
    peer_state: i32,
    ice_state: i32,
    gathering_state: i32,
    signaling_state: i32,
    data_channel: i32,
    channel_open: i32,
    channel_closed: i32,
    channel_buffered_amount_low: i32,
    channel_error: struct { channel: i32, message: []u8 },
    channel_message: struct { channel: i32, data: []u8, binary: bool },
};

const CallbackPayload = struct {
    kind: CallbackKind,

    fn destroy(raw: *anyopaque) void {
        const self: *CallbackPayload = @ptrCast(@alignCast(raw));
        switch (self.kind) {
            .candidate => |value| {
                allocator.free(value.candidate);
                allocator.free(value.mid);
            },
            .channel_error => |value| allocator.free(value.message),
            .channel_message => |value| allocator.free(value.data),
            else => {},
        }
        allocator.destroy(self);
    }

    fn invoke(raw: *anyopaque, owner_context: *anyopaque) !void {
        const self: *CallbackPayload = @ptrCast(@alignCast(raw));
        const peer: *RTCPeerConnection = @ptrCast(@alignCast(owner_context));
        if (peer._closed or peer._exec.isShuttingDown()) return;
        try peer.handleCallback(self.kind);
    }
};

fn post(peer: *RTCPeerConnection, kind: CallbackKind) void {
    const payload = allocator.create(CallbackPayload) catch return;
    payload.* = .{ .kind = kind };
    _ = peer._sender.postOwned(.{
        .data = payload,
        .invoke = CallbackPayload.invoke,
        .destroy = CallbackPayload.destroy,
    }) catch {};
}

fn peerFrom(id: i32) ?*RTCPeerConnection {
    return @ptrCast(@alignCast(webrtc.dpw_get_user_pointer(id) orelse return null));
}

fn onCandidate(id: i32, candidate: [*:0]const u8, mid: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const peer = peerFrom(id) orelse return;
    const candidate_copy = allocator.dupe(u8, std.mem.span(candidate)) catch return;
    const mid_copy = allocator.dupe(u8, std.mem.span(mid)) catch {
        allocator.free(candidate_copy);
        return;
    };
    post(peer, .{ .candidate = .{ .candidate = candidate_copy, .mid = mid_copy } });
}
fn onPeerState(id: i32, state: i32, _: ?*anyopaque) callconv(.c) void {
    if (peerFrom(id)) |peer| post(peer, .{ .peer_state = state });
}
fn onIceState(id: i32, state: i32, _: ?*anyopaque) callconv(.c) void {
    if (peerFrom(id)) |peer| post(peer, .{ .ice_state = state });
}
fn onGatheringState(id: i32, state: i32, _: ?*anyopaque) callconv(.c) void {
    if (peerFrom(id)) |peer| post(peer, .{ .gathering_state = state });
}
fn onSignalingState(id: i32, state: i32, _: ?*anyopaque) callconv(.c) void {
    if (peerFrom(id)) |peer| post(peer, .{ .signaling_state = state });
}
fn onDataChannel(id: i32, channel: i32, _: ?*anyopaque) callconv(.c) void {
    if (peerFrom(id)) |peer| post(peer, .{ .data_channel = channel });
}
fn onChannelOpen(id: i32, _: ?*anyopaque) callconv(.c) void {
    if (peerFrom(id)) |peer| post(peer, .{ .channel_open = id });
}
fn onChannelClosed(id: i32, _: ?*anyopaque) callconv(.c) void {
    if (peerFrom(id)) |peer| post(peer, .{ .channel_closed = id });
}
fn onChannelBufferedAmountLow(id: i32, _: ?*anyopaque) callconv(.c) void {
    if (peerFrom(id)) |peer| post(peer, .{ .channel_buffered_amount_low = id });
}
fn onChannelError(id: i32, message: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const peer = peerFrom(id) orelse return;
    const copy = allocator.dupe(u8, std.mem.span(message)) catch return;
    post(peer, .{ .channel_error = .{ .channel = id, .message = copy } });
}
fn onChannelMessage(id: i32, data: [*]const u8, size: i32, _: ?*anyopaque) callconv(.c) void {
    const peer = peerFrom(id) orelse return;
    const bytes = if (size < 0)
        std.mem.span(@as([*:0]const u8, @ptrCast(data)))
    else
        data[0..@intCast(size)];
    const copy = allocator.dupe(u8, bytes) catch return;
    post(peer, .{ .channel_message = .{ .channel = id, .data = copy, .binary = size >= 0 } });
}

fn findChannel(self: *RTCPeerConnection, id: i32) ?*RTCDataChannel {
    for (self._channels.items) |channel| if (channel._native_id == id) return channel;
    return null;
}

fn dataChannelString(self: *RTCPeerConnection, id: i32, comptime getter: anytype) ![]const u8 {
    const required = getter(id, null, 0);
    if (required <= 0) return "";
    const buffer = try self._exec.call_arena.alloc(u8, @intCast(required));
    if (getter(id, buffer.ptr, required) < 0) return error.WebRtcBackendFailure;
    return std.mem.sliceTo(buffer, 0);
}

fn dispatchSimple(self: *RTCPeerConnection, target: *EventTarget, handler: ?js.Function.Global, typ: []const u8) !void {
    const event = try Event.init(typ, null, self._exec.page);
    try self._exec.dispatch(target, event, handler, .{ .context = "WebRTC" });
}

fn handleCallback(self: *RTCPeerConnection, kind: CallbackKind) !void {
    switch (kind) {
        .candidate => |value| {
            const candidate = try RTCIceCandidate.init(.{ .candidate = value.candidate, .sdpMid = value.mid }, self._exec);
            const event = try RTCPeerConnectionIceEvent.trusted(candidate, self._exec);
            try self._exec.dispatch(self._proto, event.asEvent(), self._on_ice_candidate, .{ .context = "RTCPeerConnection.icecandidate" });
        },
        .peer_state => |state| {
            self._connection_state = stateName(state);
            try self.dispatchSimple(self._proto, self._on_connection_state_change, "connectionstatechange");
        },
        .ice_state => |state| {
            self._ice_connection_state = iceStateName(state);
            try self.dispatchSimple(self._proto, self._on_ice_connection_state_change, "iceconnectionstatechange");
        },
        .gathering_state => |state| {
            self._ice_gathering_state = gatheringStateName(state);
            try self.dispatchSimple(self._proto, self._on_ice_gathering_state_change, "icegatheringstatechange");
            if (state == 2) {
                const event = try RTCPeerConnectionIceEvent.trusted(null, self._exec);
                try self._exec.dispatch(self._proto, event.asEvent(), self._on_ice_candidate, .{ .context = "RTCPeerConnection.icecandidate.complete" });
            }
        },
        .signaling_state => |state| {
            self._signaling_state = signalingStateName(state);
            try self.dispatchSimple(self._proto, self._on_signaling_state_change, "signalingstatechange");
        },
        .data_channel => |id| {
            const label = try self.dataChannelString(id, webrtc.dpw_data_channel_get_label);
            const protocol = try self.dataChannelString(id, webrtc.dpw_data_channel_get_protocol);
            const channel = try RTCDataChannel.create(self, id, label, .{ .protocol = protocol });
            const event = try RTCDataChannelEvent.trusted(channel, self._exec);
            try self._exec.dispatch(self._proto, event.asEvent(), self._on_data_channel, .{ .context = "RTCPeerConnection.datachannel" });
        },
        .channel_open => |id| if (findChannel(self, id)) |channel|
            try self.dispatchSimple(channel._proto, channel._on_open, "open"),
        .channel_closed => |id| if (findChannel(self, id)) |channel|
            try self.dispatchSimple(channel._proto, channel._on_close, "close"),
        .channel_buffered_amount_low => |id| if (findChannel(self, id)) |channel|
            try self.dispatchSimple(channel._proto, channel._on_buffered_amount_low, "bufferedamountlow"),
        .channel_error => |value| if (findChannel(self, value.channel)) |channel|
            try self.dispatchSimple(channel._proto, channel._on_error, "error"),
        .channel_message => |value| if (findChannel(self, value.channel)) |channel| {
            // CallbackPayload owns `value.data` and is destroyed after this
            // turn. MessageEvent may outlive the callback, so copy it into the
            // execution arena before exposing it to JavaScript.
            const data = try self._exec.arena.dupe(u8, value.data);
            const message_data: MessageEvent.Data = if (!value.binary)
                .{ .string = data }
            else switch (channel._binary_type) {
                .arraybuffer => .{ .arraybuffer = .{ .values = data } },
                .blob => blk: {
                    const blob = try Blob.initFromBytes(data, "", self._exec.page);
                    blob.acquireRef();
                    break :blk .{ .blob = blob };
                },
            };
            const event = try MessageEvent.initTrusted(comptime lp.String.wrap("message"), .{ .data = message_data }, self._exec.page);
            try self._exec.dispatch(channel._proto, event.asEvent(), channel._on_message, .{ .context = "RTCDataChannel.message" });
        },
    }
}

fn stateName(state: i32) []const u8 {
    return switch (state) {
        0 => "new",
        1 => "connecting",
        2 => "connected",
        3 => "disconnected",
        4 => "failed",
        else => "closed",
    };
}
fn iceStateName(state: i32) []const u8 {
    return switch (state) {
        0 => "new",
        1 => "checking",
        2 => "connected",
        3 => "completed",
        4 => "failed",
        5 => "disconnected",
        else => "closed",
    };
}
fn gatheringStateName(state: i32) []const u8 {
    return switch (state) {
        0 => "new",
        1 => "gathering",
        else => "complete",
    };
}
fn signalingStateName(state: i32) []const u8 {
    return switch (state) {
        1 => "have-local-offer",
        2 => "have-remote-offer",
        3 => "have-local-pranswer",
        4 => "have-remote-pranswer",
        5 => "closed",
        else => "stable",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCPeerConnection);
    pub const Meta = struct {
        pub const name = "RTCPeerConnection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const constructor = bridge.constructor(RTCPeerConnection.init, .{});
    pub const createOffer = bridge.function(RTCPeerConnection.createOffer, .{ .receiver_mode = .reject_promise });
    pub const createAnswer = bridge.function(RTCPeerConnection.createAnswer, .{ .receiver_mode = .reject_promise });
    pub const setLocalDescription = bridge.function(RTCPeerConnection.setLocalDescription, .{ .arity = 1, .required_args = 1, .receiver_mode = .reject_promise });
    pub const setRemoteDescription = bridge.function(RTCPeerConnection.setRemoteDescription, .{ .arity = 1, .required_args = 1, .receiver_mode = .reject_promise });
    pub const addIceCandidate = bridge.function(RTCPeerConnection.addIceCandidate, .{ .receiver_mode = .reject_promise });
    pub const createDataChannel = bridge.function(RTCPeerConnection.createDataChannel, .{ .arity = 1, .required_args = 1 });
    pub const close = bridge.function(RTCPeerConnection.close, .{});
    pub const localDescription = bridge.accessor(RTCPeerConnection.getLocalDescription, null, .{});
    pub const remoteDescription = bridge.accessor(RTCPeerConnection.getRemoteDescription, null, .{});
    pub const currentLocalDescription = bridge.accessor(RTCPeerConnection.getCurrentLocalDescription, null, .{});
    pub const currentRemoteDescription = bridge.accessor(RTCPeerConnection.getCurrentRemoteDescription, null, .{});
    pub const pendingLocalDescription = bridge.accessor(RTCPeerConnection.getPendingLocalDescription, null, .{});
    pub const pendingRemoteDescription = bridge.accessor(RTCPeerConnection.getPendingRemoteDescription, null, .{});
    pub const signalingState = bridge.accessor(RTCPeerConnection.getSignalingState, null, .{});
    pub const iceGatheringState = bridge.accessor(RTCPeerConnection.getIceGatheringState, null, .{});
    pub const iceConnectionState = bridge.accessor(RTCPeerConnection.getIceConnectionState, null, .{});
    pub const connectionState = bridge.accessor(RTCPeerConnection.getConnectionState, null, .{});
    pub const getConfiguration = bridge.function(RTCPeerConnection.getConfiguration, .{});
    pub const setConfiguration = bridge.function(RTCPeerConnection.setConfiguration, .{ .arity = 1, .required_args = 1 });
    pub const restartIce = bridge.function(RTCPeerConnection.restartIce, .{});
    pub const getStats = bridge.function(RTCPeerConnection.getStats, .{ .receiver_mode = .reject_promise });
    pub const onicecandidate = bridge.accessor(RTCPeerConnection.getOnIceCandidate, RTCPeerConnection.setOnIceCandidate, .{});
    pub const ondatachannel = bridge.accessor(RTCPeerConnection.getOnDataChannel, RTCPeerConnection.setOnDataChannel, .{});
    pub const onconnectionstatechange = bridge.accessor(RTCPeerConnection.getOnConnectionStateChange, RTCPeerConnection.setOnConnectionStateChange, .{});
    pub const onicegatheringstatechange = bridge.accessor(RTCPeerConnection.getOnIceGatheringStateChange, RTCPeerConnection.setOnIceGatheringStateChange, .{});
    pub const oniceconnectionstatechange = bridge.accessor(RTCPeerConnection.getOnIceConnectionStateChange, RTCPeerConnection.setOnIceConnectionStateChange, .{});
    pub const onsignalingstatechange = bridge.accessor(RTCPeerConnection.getOnSignalingStateChange, RTCPeerConnection.setOnSignalingStateChange, .{});
    pub const onnegotiationneeded = bridge.accessor(RTCPeerConnection.getOnNegotiationNeeded, RTCPeerConnection.setOnNegotiationNeeded, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: RTCPeerConnection" {
    try testing.htmlRunner("webrtc.html", .{ .timeout_ms = 6000 });
}
