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

const IdleDeadline = @This();
const milliTimestamp = @import("../../datetime.zig").milliTimestamp;

_did_timeout: bool,
_deadline_ms: u64,

pub fn init(did_timeout: bool) IdleDeadline {
    const now = milliTimestamp(.monotonic);
    return .{
        ._did_timeout = did_timeout,
        ._deadline_ms = if (did_timeout) now else now + 50,
    };
}

pub fn getDidTimeout(self: *const IdleDeadline) bool {
    return self._did_timeout;
}

pub fn timeRemaining(self: *const IdleDeadline) f64 {
    // A callback dispatched because its timeout elapsed has no idle budget.
    if (self._did_timeout) return 0.0;
    const now = milliTimestamp(.monotonic);
    if (now >= self._deadline_ms) return 0.0;
    return @floatFromInt(self._deadline_ms - now);
}

pub const JsApi = struct {
    const js = @import("../js/js.zig");
    pub const bridge = js.Bridge(IdleDeadline);

    pub const Meta = struct {
        pub const name = "IdleDeadline";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const didTimeout = bridge.accessor(IdleDeadline.getDidTimeout, null, .{});
    pub const timeRemaining = bridge.function(IdleDeadline.timeRemaining, .{});
};
