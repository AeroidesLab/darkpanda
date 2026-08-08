const std = @import("std");

pub const abi_version: u32 = 1;

pub const PeerConfig = extern struct {
    abi_version: u32 = 1,
    struct_size: u32 = @sizeOf(PeerConfig),
    ice_servers: ?[*]const [*:0]const u8 = null,
    ice_servers_count: i32 = 0,
    tun_bind_address: ?[*:0]const u8 = null,
    transport_policy: u32 = 0,
    port_range_begin: u16 = 0,
    port_range_end: u16 = 0,
    max_message_size: i32 = 0,
};

pub const DataChannelConfig = extern struct {
    abi_version: u32 = 1,
    struct_size: u32 = @sizeOf(DataChannelConfig),
    unordered: bool = false,
    unreliable: bool = false,
    max_packet_lifetime: u16 = 0,
    max_retransmits: u16 = 0,
    protocol: ?[*:0]const u8 = null,
    negotiated: bool = false,
    id: u16 = 0,
};

pub const DescriptionCallback = *const fn (i32, [*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void;
pub const CandidateCallback = *const fn (i32, [*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void;
pub const StateCallback = *const fn (i32, i32, ?*anyopaque) callconv(.c) void;
pub const DataChannelCallback = *const fn (i32, i32, ?*anyopaque) callconv(.c) void;
pub const VoidCallback = *const fn (i32, ?*anyopaque) callconv(.c) void;
pub const ErrorCallback = *const fn (i32, [*:0]const u8, ?*anyopaque) callconv(.c) void;
pub const MessageCallback = *const fn (i32, [*]const u8, i32, ?*anyopaque) callconv(.c) void;

extern fn dpw_abi_version() callconv(.c) u32;
extern fn dpw_version() callconv(.c) [*:0]const u8;
extern fn dpw_validate_bind_address(address: [*:0]const u8) callconv(.c) i32;
pub extern fn dpw_peer_config_init(out: *PeerConfig) callconv(.c) void;
pub extern fn dpw_data_channel_config_init(out: *DataChannelConfig) callconv(.c) void;
pub extern fn dpw_peer_create(config: *const PeerConfig) callconv(.c) i32;
pub extern fn dpw_peer_close(peer: i32) callconv(.c) i32;
pub extern fn dpw_peer_delete(peer: i32) callconv(.c) i32;
pub extern fn dpw_set_user_pointer(id: i32, user: ?*anyopaque) callconv(.c) void;
pub extern fn dpw_get_user_pointer(id: i32) callconv(.c) ?*anyopaque;
pub extern fn dpw_set_local_candidate_callback(peer: i32, cb: ?CandidateCallback) callconv(.c) i32;
pub extern fn dpw_set_peer_state_callback(peer: i32, cb: ?StateCallback) callconv(.c) i32;
pub extern fn dpw_set_ice_state_callback(peer: i32, cb: ?StateCallback) callconv(.c) i32;
pub extern fn dpw_set_gathering_state_callback(peer: i32, cb: ?StateCallback) callconv(.c) i32;
pub extern fn dpw_set_signaling_state_callback(peer: i32, cb: ?StateCallback) callconv(.c) i32;
pub extern fn dpw_set_data_channel_callback(peer: i32, cb: ?DataChannelCallback) callconv(.c) i32;
pub extern fn dpw_create_offer(peer: i32, buffer: ?[*]u8, size: i32) callconv(.c) i32;
pub extern fn dpw_create_answer(peer: i32, buffer: ?[*]u8, size: i32) callconv(.c) i32;
pub extern fn dpw_set_local_description(peer: i32, typ: [*:0]const u8) callconv(.c) i32;
pub extern fn dpw_set_remote_description(peer: i32, sdp: [*:0]const u8, typ: [*:0]const u8) callconv(.c) i32;
pub extern fn dpw_add_remote_candidate(peer: i32, candidate: [*:0]const u8, mid: [*:0]const u8) callconv(.c) i32;
pub extern fn dpw_get_local_description(peer: i32, buffer: ?[*]u8, size: i32) callconv(.c) i32;
pub extern fn dpw_get_remote_description(peer: i32, buffer: ?[*]u8, size: i32) callconv(.c) i32;
pub extern fn dpw_data_channel_create(peer: i32, label: [*:0]const u8, config: *const DataChannelConfig) callconv(.c) i32;
pub extern fn dpw_set_open_callback(channel: i32, cb: ?VoidCallback) callconv(.c) i32;
pub extern fn dpw_set_closed_callback(channel: i32, cb: ?VoidCallback) callconv(.c) i32;
pub extern fn dpw_set_error_callback(channel: i32, cb: ?ErrorCallback) callconv(.c) i32;
pub extern fn dpw_set_message_callback(channel: i32, cb: ?MessageCallback) callconv(.c) i32;
pub extern fn dpw_set_buffered_amount_low_callback(channel: i32, cb: ?VoidCallback) callconv(.c) i32;
pub extern fn dpw_data_channel_send(channel: i32, data: [*]const u8, size: i32) callconv(.c) i32;
pub extern fn dpw_data_channel_close(channel: i32) callconv(.c) i32;
pub extern fn dpw_data_channel_delete(channel: i32) callconv(.c) i32;
pub extern fn dpw_data_channel_get_label(channel: i32, buffer: ?[*]u8, size: i32) callconv(.c) i32;
pub extern fn dpw_data_channel_get_protocol(channel: i32, buffer: ?[*]u8, size: i32) callconv(.c) i32;
pub extern fn dpw_get_buffered_amount(channel: i32) callconv(.c) i32;
pub extern fn dpw_set_buffered_amount_low_threshold(channel: i32, amount: i32) callconv(.c) i32;
pub extern fn dpw_is_open(channel: i32) callconv(.c) bool;
pub extern fn dpw_is_closed(channel: i32) callconv(.c) bool;
pub extern fn dpw_cleanup() callconv(.c) void;

/// Validate the packaged backend and prove that the configured numeric TUN
/// address is locally bindable before V8 or any browser thread starts.
pub fn preflight(
    allocator: std.mem.Allocator,
    explicit_path: ?[]const u8,
    bind_address: []const u8,
) !void {
    if (bind_address.len == 0 or
        std.mem.indexOfScalar(u8, bind_address, 0) != null or
        !std.unicode.utf8ValidateSlice(bind_address))
    {
        return error.InvalidWebRtcBindAddress;
    }
    const address = try allocator.dupeZ(u8, bind_address);
    defer allocator.free(address);

    if (explicit_path) |path| {
        var library = try std.DynLib.open(path);
        defer library.close();
        const version = library.lookup(*const fn () callconv(.c) u32, "dpw_abi_version") orelse
            return error.WebRtcAbiMismatch;
        const validate = library.lookup(*const fn ([*:0]const u8) callconv(.c) i32, "dpw_validate_bind_address") orelse
            return error.WebRtcAbiMismatch;
        if (version() != abi_version or validate(address) != 0) {
            return error.WebRtcBindAddressUnavailable;
        }
        return;
    }

    if (dpw_abi_version() != abi_version or dpw_version()[0] == 0) {
        return error.WebRtcAbiMismatch;
    }
    if (dpw_validate_bind_address(address) != 0) {
        return error.WebRtcBindAddressUnavailable;
    }
}

test "WebRTC preflight requires a numeric local address" {
    try preflight(std.testing.allocator, null, "127.0.0.1");
    try std.testing.expectError(
        error.WebRtcBindAddressUnavailable,
        preflight(std.testing.allocator, null, "192.0.2.1"),
    );
    try std.testing.expectError(
        error.WebRtcBindAddressUnavailable,
        preflight(std.testing.allocator, null, "not-an-ip"),
    );
}
