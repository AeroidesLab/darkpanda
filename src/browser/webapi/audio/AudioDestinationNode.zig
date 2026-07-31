// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const js = @import("../../js/js.zig");

const Execution = js.Execution;

/// AudioDestinationNode — OfflineAudioContext.destination 的占位对象。
/// connect 到此节点表示连接到最终输出。
pub const AudioDestinationNode = @This();

pub fn init(exec: *const Execution) !*AudioDestinationNode {
    return exec._factory.create(AudioDestinationNode{});
}

/// connect 的 no-op 实现:返回 undefined(Web Audio connect 返回 destination,
/// 但大多数代码忽略返回值)。
pub fn connect(_: *AudioDestinationNode) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioDestinationNode);

    pub const Meta = struct {
        pub const name = "AudioDestinationNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const connect = bridge.function(AudioDestinationNode.connect, .{});
};
