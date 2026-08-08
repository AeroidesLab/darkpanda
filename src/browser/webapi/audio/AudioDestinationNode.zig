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
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioNode = @import("AudioNode.zig");

const Execution = js.Execution;

/// AudioDestinationNode — OfflineAudioContext.destination 的占位对象。
/// connect 到此节点表示连接到最终输出。
pub const AudioDestinationNode = @This();
_proto: *AudioNode,

pub fn init(context: *BaseAudioContext, exec: *const Execution) !*AudioDestinationNode {
    return exec._factory.audioNode(context, AudioDestinationNode{ ._proto = undefined });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioDestinationNode);

    pub const Meta = struct {
        pub const name = "AudioDestinationNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
