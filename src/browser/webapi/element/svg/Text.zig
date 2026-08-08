// Copyright (C) 2026 Lightpanda contributors

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const TextContent = @import("TextContent.zig");

const Text = @This();
_proto: *TextContent,

pub fn asElement(self: *Text) *Element {
    return self._proto.asElement();
}

pub fn asNode(self: *Text) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Text);

    pub const Meta = struct {
        pub const name = "SVGTextElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
