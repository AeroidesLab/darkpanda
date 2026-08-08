// Copyright (C) 2026 Lightpanda contributors

const lp = @import("darkpanda");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const AudioBuffer = @import("../audio/AudioBuffer.zig");

const OfflineAudioCompletionEvent = @This();

_proto: *Event,
_rendered_buffer: *AudioBuffer,

pub fn initTrusted(buffer: *AudioBuffer, page: *Page) !*OfflineAudioCompletionEvent {
    const arena = try page.getArena(.tiny, "OfflineAudioCompletionEvent.trusted");
    errdefer page.releaseArena(arena);
    const event = try page.factory.event(
        arena,
        comptime lp.String.wrap("complete"),
        OfflineAudioCompletionEvent{ ._proto = undefined, ._rendered_buffer = buffer },
    );
    Event.populatePrototypes(event, Event.Options{}, true);
    return event;
}

pub fn asEvent(self: *OfflineAudioCompletionEvent) *Event {
    return self._proto;
}

pub fn getRenderedBuffer(self: *OfflineAudioCompletionEvent) *AudioBuffer {
    return self._rendered_buffer;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OfflineAudioCompletionEvent);

    pub const Meta = struct {
        pub const name = "OfflineAudioCompletionEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const renderedBuffer = bridge.accessor(OfflineAudioCompletionEvent.getRenderedBuffer, null, .{});
};
