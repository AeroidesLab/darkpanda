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

/// AudioParam — 简化实现,只支持 .value get/set。
/// fp_audio 探针通过 `osc.frequency.value = 1000` 和 `comp.threshold.value = -50` 设置参数。
pub const AudioParam = @This();

_value: f32,
_default_value: f32,

pub fn init(exec: *const Execution, value: f32) !*AudioParam {
    return exec._factory.create(AudioParam{
        ._value = value,
        ._default_value = value,
    });
}

pub fn getValue(self: *const AudioParam) f32 {
    return self._value;
}

pub fn setValue(self: *AudioParam, value: f32) void {
    self._value = value;
}

pub fn getDefaultValue(self: *const AudioParam) f32 {
    return self._default_value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioParam);

    pub const Meta = struct {
        pub const name = "AudioParam";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(AudioParam.getValue, AudioParam.setValue, .{});
    pub const defaultValue = bridge.accessor(AudioParam.getDefaultValue, null, .{});
};
