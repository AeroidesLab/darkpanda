// Copyright (C) 2026 Lightpanda contributors

const js = @import("../../js/js.zig");

const SpeechSynthesisVoice = @This();

_default: bool,
_lang: []const u8,
_local_service: bool,
_name: []const u8,
_voice_uri: []const u8,

pub fn getDefault(self: *const SpeechSynthesisVoice) bool {
    return self._default;
}

pub fn getLang(self: *const SpeechSynthesisVoice) []const u8 {
    return self._lang;
}

pub fn getLocalService(self: *const SpeechSynthesisVoice) bool {
    return self._local_service;
}

pub fn getName(self: *const SpeechSynthesisVoice) []const u8 {
    return self._name;
}

pub fn getVoiceURI(self: *const SpeechSynthesisVoice) []const u8 {
    return self._voice_uri;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SpeechSynthesisVoice);

    pub const Meta = struct {
        pub const name = "SpeechSynthesisVoice";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const default = bridge.accessor(SpeechSynthesisVoice.getDefault, null, .{});
    pub const lang = bridge.accessor(SpeechSynthesisVoice.getLang, null, .{});
    pub const localService = bridge.accessor(SpeechSynthesisVoice.getLocalService, null, .{});
    pub const name = bridge.accessor(SpeechSynthesisVoice.getName, null, .{});
    pub const voiceURI = bridge.accessor(SpeechSynthesisVoice.getVoiceURI, null, .{});
};
