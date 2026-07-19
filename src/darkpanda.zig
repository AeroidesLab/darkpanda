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

//! Public root module for the DarkPanda runtime.

const std = @import("std");

pub const log = @import("log.zig");
pub const App = @import("App.zig");
pub const Network = @import("network/Network.zig");
pub const Server = @import("Server.zig");
pub const Config = @import("Config.zig");
pub const ClientProfile = @import("ClientProfile.zig");
pub const FingerprintProfile = @import("FingerprintProfile.zig");
pub const String = @import("string.zig").String;
pub const Notification = @import("Notification.zig");

pub const URL = @import("browser/URL.zig");
pub const SecurityOriginModel = @import("browser/SecurityOriginModel.zig");
pub const Page = @import("browser/Page.zig");
pub const Frame = @import("browser/Frame.zig");
pub const Browser = @import("browser/Browser.zig");
pub const OwnerMailbox = @import("browser/OwnerMailbox.zig");
pub const Session = @import("browser/Session.zig");
pub const Node = @import("browser/webapi/Node.zig");
pub const Element = @import("browser/webapi/Element.zig");

pub const js = @import("browser/js/js.zig");
pub const dump = @import("browser/dump.zig");
pub const CDPNode = @import("cdp/Node.zig");
pub const actions = @import("browser/actions.zig");
pub const Evaluate = @import("browser/Evaluate.zig");
pub const HttpClient = @import("browser/HttpClient.zig");
pub const CanvasBackendProvider = @import("browser/canvas_backend/Provider.zig");

pub const build_config = @import("build_config");
pub const crash_handler = @import("crash_handler.zig");
pub const core_dump = @import("core_dump.zig");
pub inline fn assert(ok: bool, comptime ctx: []const u8, args: anytype) void {
    if (!ok) assertionFailure(ctx, args);
}

noinline fn assertionFailure(comptime ctx: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint("assertion failure: " ++ ctx, args));
    }
    @import("crash_handler.zig").crash(ctx, args, @returnAddress());
}

const rc_canary: u32 = 0x52434E54;
const rc_poison: u32 = 0xDEADC0DE;

pub fn RC(comptime T: type) type {
    return struct {
        _refs: std.atomic.Value(T) = .init(0),
        _canary: u32 = rc_canary,

        pub fn init(refs: T) @This() {
            return .{ ._refs = .init(refs) };
        }

        pub fn acquire(self: *@This()) void {
            _ = self._refs.fetchAdd(1, .monotonic);
        }

        pub fn release(self: *@This(), value: anytype, page: *Page) void {
            const prev = self._refs.fetchSub(1, .acq_rel);
            assert(prev > 0, "release overflow", .{
                .type = @typeName(@TypeOf(value)),
                .canary = self._canary,
                .refs = prev,
                .ptr = @intFromPtr(value),
            });
            if (prev == 1) {
                self._canary = rc_poison;
                value.deinit(page);
            }
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            return writer.print("{d}", .{self._refs.load(.monotonic)});
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
