// Copyright (C) 2026 Lightpanda contributors

const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const FingerprintView = @import("../../FingerprintView.zig");
const EventTarget = @import("../EventTarget.zig");
const SpeechSynthesisVoice = @import("SpeechSynthesisVoice.zig");

const SpeechSynthesis = @This();

_proto: *EventTarget,
_voices: ?[]*SpeechSynthesisVoice = null,
_on_voices_changed: ?js.Function.Global = null,

pub fn init(frame: *Frame) !*SpeechSynthesis {
    return frame._factory.eventTarget(SpeechSynthesis{ ._proto = undefined });
}

pub fn asEventTarget(self: *SpeechSynthesis) *EventTarget {
    return self._proto;
}

pub fn getVoices(self: *SpeechSynthesis, frame: *Frame) ![]*SpeechSynthesisVoice {
    if (self._voices) |voices| return voices;
    const locale = FingerprintView.navigator(frame._session.browser.app).language;
    const name = if (std.mem.startsWith(u8, locale, "en"))
        "Microsoft David - English (United States)"
    else
        try std.fmt.allocPrint(frame.arena, "Microsoft {s}", .{locale});
    const voice = try frame._factory.create(SpeechSynthesisVoice{
        ._default = true,
        ._lang = locale,
        ._local_service = true,
        ._name = name,
        ._voice_uri = name,
    });
    const voices = try frame.arena.alloc(*SpeechSynthesisVoice, 1);
    voices[0] = voice;
    self._voices = voices;
    return voices;
}

pub fn getOnVoicesChanged(self: *const SpeechSynthesis) ?js.Function.Global {
    return self._on_voices_changed;
}

pub fn setOnVoicesChanged(self: *SpeechSynthesis, callback: ?js.Function.Global) void {
    self._on_voices_changed = callback;
}

pub fn cancel(_: *SpeechSynthesis) void {}
pub fn pause(_: *SpeechSynthesis) void {}
pub fn @"resume"(_: *SpeechSynthesis) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SpeechSynthesis);

    pub const Meta = struct {
        pub const name = "SpeechSynthesis";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const pending = bridge.constantAccessor(false);
    pub const speaking = bridge.constantAccessor(false);
    pub const paused = bridge.constantAccessor(false);
    pub const onvoiceschanged = bridge.accessor(SpeechSynthesis.getOnVoicesChanged, SpeechSynthesis.setOnVoicesChanged, .{});
    pub const getVoices = bridge.function(SpeechSynthesis.getVoices, .{});
    pub const cancel = bridge.function(SpeechSynthesis.cancel, .{});
    pub const pause = bridge.function(SpeechSynthesis.pause, .{});
    pub const @"resume" = bridge.function(SpeechSynthesis.@"resume", .{});
};
