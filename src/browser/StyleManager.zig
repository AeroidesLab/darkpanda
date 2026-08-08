// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const std = @import("std");
const lp = @import("darkpanda");

const Frame = @import("Frame.zig");

const CssParser = @import("css/Parser.zig");
const MediaQuery = @import("css/MediaQuery.zig");
const Element = @import("webapi/Element.zig");

const Selector = @import("webapi/selector/Selector.zig");
const SelectorParser = @import("webapi/selector/Parser.zig");
const SelectorList = @import("webapi/selector/List.zig");

const CSSStyleRule = @import("webapi/css/CSSStyleRule.zig");
const CSSStyleSheet = @import("webapi/css/CSSStyleSheet.zig");
const CSSStyleProperties = @import("webapi/css/CSSStyleProperties.zig");
const CSSStyleProperty = @import("webapi/css/CSSStyleDeclaration.zig").Property;

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

pub const VisibilityCache = std.AutoHashMapUnmanaged(*Element, bool);
pub const PointerEventsCache = std.AutoHashMapUnmanaged(*Element, bool);

// Tracks the authored declarations needed by the no-layout computed-style and
// visibility surfaces. Rules are bucketed by their rightmost selector part for
// fast lookup; declaration values remain lazy and are resolved only when read.
const StyleManager = @This();

const Tag = Element.Tag;
const Input = Element.Html.Input;
const RuleList = std.MultiArrayList(VisibilityRule);

frame: *Frame,

arena: Allocator,

// Bucketed rules for fast lookup - keyed by rightmost selector part
id_rules: std.StringHashMapUnmanaged(RuleList) = .empty,
class_rules: std.StringHashMapUnmanaged(RuleList) = .empty,
tag_rules: std.AutoHashMapUnmanaged(Tag, RuleList) = .empty,
other_rules: RuleList = .empty, // universal, attribute, pseudo-class endings

// Document order counter for tie-breaking equal specificity
next_doc_order: u32 = 0,

// When true, rules need to be rebuilt
dirty: bool = false,

// DOM child mutations do not have a stylesheet-specific notification path.
// Tracking the Page generation makes connected <style>.textContent replacement
// invalidate lazily without rebuilding on every write.
last_dom_version: usize,

pub fn init(frame: *Frame) !StyleManager {
    return .{
        .frame = frame,
        .arena = try frame.getArena(.medium, "StyleManager"),
        .last_dom_version = frame._page.dom_version,
    };
}

pub fn deinit(self: *StyleManager) void {
    self.frame.releaseArena(self.arena);
}

/// Hard cap on `@media` nesting depth. CSS Nesting allows arbitrarily-deep
/// at-rule nesting; without a cap a hostile inline stylesheet could blow the
/// Zig stack via mutually-recursive `applyMediaAtRule` frames. 32 is well
/// past anything seen in the wild.
const MAX_MEDIA_NESTING: u8 = 32;

fn parseSheet(self: *StyleManager, sheet: *CSSStyleSheet) !void {
    try sheet.refreshOwnerTextIfChanged(self.frame);
    if (sheet._css_rules) |css_rules| {
        for (css_rules._rules.items) |rule| {
            switch (rule._type) {
                .style => |sr| try self.addRule(sr),
                // Re-parse the stored source so an `@media` rule inserted via
                // `insertRule` / `replaceSync` participates in the cascade
                // when its query matches the viewport.
                .media => try self.applyMediaAtRule(rule._text, 0),
                else => {},
            }
        }
        return;
    }

    const owner_node = sheet.getOwnerNode() orelse return;
    if (owner_node.is(Element.Html.Style)) |style| {
        const text = try style.asNode().getTextContentAlloc(self.arena);
        var it = CssParser.parseStylesheet(text);
        while (it.next()) |parsed_rule| {
            switch (parsed_rule) {
                .style => |s| try self.addRawRule(s.selector, s.block),
                .at_rule => |a| {
                    // Only `@media` participates in the cascade here. Other
                    // at-rules (`@keyframes`, `@supports`, `@font-face`, …)
                    // don't carry top-level declarations relevant to the
                    // visibility filter and stay skipped as before.
                    if (std.ascii.eqlIgnoreCase(a.keyword, "media")) {
                        try self.applyMediaAtRule(a.text, 0);
                    }
                },
            }
        }
    }
}

/// Apply an `@media` at-rule by evaluating its query against the current
/// viewport and, if it matches, parsing the inner block as if its declarations
/// lived at the top level. Non-matching queries silently drop the inner
/// rules. Inline-only by design: external `<link rel="stylesheet">` is out
/// of scope for the headless engine.
fn applyMediaAtRule(self: *StyleManager, text: []const u8, depth: u8) !void {
    if (depth >= MAX_MEDIA_NESTING) return;

    // text shape: `@media <query> { <inner> }` for well-formed input.
    // `CssParser.RulesIterator.consumeAtRule` always emits a span starting
    // at `@`; for unclosed blocks it runs to EOF, so the closing `}` is
    // located explicitly rather than assumed to be the final byte.

    if (text.len < @as(usize, "@media".len) + 2) return;
    if (!std.ascii.startsWithIgnoreCase(text, "@media")) return;

    const rest = text["@media".len..];
    // Use a comment-aware brace finder; a `/* { */` in the prelude would
    // otherwise split the rule at the wrong place. The inner block's
    // contents are re-parsed by CssParser below, which has its own trivia
    // handling, so only this outer boundary needs the special-case scan.
    const open = indexOfOpenBraceSkippingComments(rest) orelse return;
    // Search only past the opening brace — the matching `}` lives there, and
    // any returned position is naturally `> open` (since `rest[open] == '{'`).
    const close = open + (std.mem.lastIndexOfScalar(u8, rest[open..], '}') orelse return);

    const query = std.mem.trim(u8, rest[0..open], &std.ascii.whitespace);
    const inner = rest[open + 1 .. close];

    if (!MediaQuery.matches(query, self.frame._page.getViewport())) return;

    var it = CssParser.parseStylesheet(inner);
    while (it.next()) |nested_rule| {
        switch (nested_rule) {
            .style => |s| try self.addRawRule(s.selector, s.block),
            .at_rule => |nested| {
                if (std.ascii.eqlIgnoreCase(nested.keyword, "media")) {
                    try self.applyMediaAtRule(nested.text, depth + 1);
                }
            },
        }
    }
}

/// Find the first `{` in `s` that is not inside a CSS `/* ... */` comment.
/// An unclosed comment returns `null` (treat the whole rule as malformed).
fn indexOfOpenBraceSkippingComments(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '*') {
            const close = std.mem.indexOf(u8, s[i + 2 ..], "*/") orelse return null;
            i = i + 2 + close + 2;
            continue;
        }
        if (s[i] == '{') return i;
        i += 1;
    }
    return null;
}

fn addRawRule(self: *StyleManager, selector_text: []const u8, block_text: []const u8) !void {
    if (selector_text.len == 0) return;

    var props = VisibilityProperties{};
    var it = CssParser.parseDeclarationsList(block_text);
    while (it.next()) |decl| {
        props.set(decl.name, decl.value, decl.important);
    }

    if (!props.isRelevant()) return;

    const selectors = SelectorParser.parseList(self.arena, selector_text) catch return;
    for (selectors) |selector| {
        const rightmost = if (selector.segments.len > 0) selector.segments[selector.segments.len - 1].compound else selector.first;
        const bucket_key = getBucketKey(rightmost) orelse continue;
        const rule = VisibilityRule{
            .props = props,
            .selector = selector,
            .priority = (@as(u64, computeSpecificity(selector)) << 32) | @as(u64, self.next_doc_order),
        };
        self.next_doc_order += 1;

        switch (bucket_key) {
            .id => |id| {
                const gop = try self.id_rules.getOrPut(self.arena, id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .class => |class| {
                const gop = try self.class_rules.getOrPut(self.arena, class);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .tag => |tag| {
                const gop = try self.tag_rules.getOrPut(self.arena, tag);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .other => {
                try self.other_rules.append(self.arena, rule);
            },
        }
    }
}

pub fn sheetRemoved(self: *StyleManager) void {
    self.dirty = true;
}

pub fn sheetModified(self: *StyleManager) void {
    self.dirty = true;
}

/// Rebuilds the rule list from all document stylesheets.
/// Called lazily when dirty flag is set and rules are needed.
fn rebuildIfDirty(self: *StyleManager) !void {
    const current_dom_version = self.frame._page.dom_version;
    if (current_dom_version != self.last_dom_version) self.dirty = true;
    if (!self.dirty) {
        return;
    }

    self.dirty = false;
    errdefer self.dirty = true;
    const id_rules_count = self.id_rules.count();
    const class_rules_count = self.class_rules.count();
    const tag_rules_count = self.tag_rules.count();
    const other_rules_count = self.other_rules.len;

    self.frame._session.arena_pool.resetRetain(self.arena);

    self.next_doc_order = 0;

    self.id_rules = .empty;
    try self.id_rules.ensureTotalCapacity(self.arena, id_rules_count);

    self.class_rules = .empty;
    try self.class_rules.ensureTotalCapacity(self.arena, class_rules_count);

    self.tag_rules = .empty;
    try self.tag_rules.ensureTotalCapacity(self.arena, tag_rules_count);

    self.other_rules = .{};
    try self.other_rules.ensureTotalCapacity(self.arena, other_rules_count);

    const sheets = self.frame.document._style_sheets orelse {
        self.last_dom_version = current_dom_version;
        return;
    };
    for (sheets._sheets.items) |sheet| {
        if (sheet.getDisabled()) continue;
        self.parseSheet(sheet) catch |err| {
            log.err(.browser, "StyleManager parseSheet", .{ .err = err });
            return err;
        };
    }
    self.last_dom_version = current_dom_version;
}

/// Resolve the winning authored declaration for the bounded property surface
/// tracked by this manager. The returned slice is owned by the stylesheet or
/// declaration object and remains valid until the next style-manager rebuild.
///
/// `inherited_by_default` models the property's CSS inheritance flag. Explicit
/// cascade-wide keywords are handled here so all consumers observe one result.
pub fn resolvedAuthoredPropertyValue(
    self: *StyleManager,
    el: *Element,
    property_name: String,
    inherited_by_default: bool,
) ?[]const u8 {
    self.rebuildIfDirty() catch return null;

    var current: ?*Element = el;
    var should_inherit = inherited_by_default;
    while (current) |element| {
        if (self.ownAuthoredProperty(element, property_name)) |declaration| {
            const value = std.mem.trim(u8, declaration.value, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(value, "initial") or
                std.ascii.eqlIgnoreCase(value, "revert") or
                std.ascii.eqlIgnoreCase(value, "revert-layer"))
            {
                return null;
            }
            if (std.ascii.eqlIgnoreCase(value, "unset")) {
                if (!inherited_by_default) return null;
                should_inherit = true;
            } else if (std.ascii.eqlIgnoreCase(value, "inherit")) {
                should_inherit = true;
            } else {
                return value;
            }
        } else if (!should_inherit) {
            return null;
        }

        current = element.parentElement();
    }
    return null;
}

fn ownAuthoredProperty(self: *StyleManager, el: *Element, property_name: String) ?AuthoredDeclaration {
    var best: ?CascadeCandidate = null;

    if (getInlineStyleProperty(el, property_name, self.frame)) |property| {
        best = .{
            .declaration = .{
                .value = property._value.str(),
                .important = property._important,
            },
            .inline_style = true,
            .priority = 0,
        };
    }

    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (self.id_rules.get(id)) |rules| {
            considerRules(&best, &rules, el, property_name, self.frame);
        }
    }

    if (el.getAttributeSafe(comptime .wrap("class"))) |class_attr| {
        var it = std.mem.tokenizeAny(u8, class_attr, &std.ascii.whitespace);
        while (it.next()) |class| {
            if (self.class_rules.get(class)) |rules| {
                considerRules(&best, &rules, el, property_name, self.frame);
            }
        }
    }

    if (self.tag_rules.get(el.getTag())) |rules| {
        considerRules(&best, &rules, el, property_name, self.frame);
    }
    considerRules(&best, &self.other_rules, el, property_name, self.frame);

    return if (best) |candidate| candidate.declaration else null;
}

fn considerRules(
    best: *?CascadeCandidate,
    rules: *const RuleList,
    el: *Element,
    property_name: String,
    frame: *Frame,
) void {
    const priorities = rules.items(.priority);
    const props_list = rules.items(.props);
    const selectors = rules.items(.selector);

    for (priorities, props_list, selectors) |priority, props, selector| {
        const declaration = props.get(property_name) orelse continue;
        const candidate = CascadeCandidate{
            .declaration = declaration,
            .inline_style = false,
            .priority = priority,
        };
        if (best.*) |existing| {
            if (!candidate.outranks(existing)) continue;
        }
        if (matchesSelector(el, selector, frame)) best.* = candidate;
    }
}

// Check if an element is hidden based on options.
// By default only checks display:none.
// Walks up the tree to check ancestors.
pub fn isHidden(self: *StyleManager, el: *Element, cache: ?*VisibilityCache, options: CheckVisibilityOptions) bool {
    self.rebuildIfDirty() catch return false;

    // `visibility` is inherited but can be explicitly restored to `visible`
    // on a descendant. Resolve it once for the target instead of treating an
    // ancestor's specified value as an unconditional hiding condition.
    var ancestor_options = options;
    if (options.check_visibility) {
        if (self.resolvedAuthoredPropertyValue(el, comptime .wrap("visibility"), true)) |value| {
            if (std.ascii.eqlIgnoreCase(value, "hidden") or std.ascii.eqlIgnoreCase(value, "collapse")) return true;
        }
        ancestor_options.check_visibility = false;
    }

    var current: ?*Element = el;

    while (current) |elem| {
        // Check cache first (only when checking all properties for caching consistency)
        if (cache) |c| {
            if (c.get(elem)) |hidden| {
                if (hidden) {
                    return true;
                }
                current = elem.parentElement();
                continue;
            }
        }

        const hidden = self.isElementHidden(elem, ancestor_options);

        // Store in cache
        if (cache) |c| {
            c.put(self.frame.call_arena, elem, hidden) catch |err| {
                log.warn(.browser, "StyleManager cache", .{ .err = err, .src = "isHidden" });
            };
        }

        if (hidden) {
            return true;
        }
        current = elem.parentElement();
    }

    return false;
}

/// Computed display:none for a single element (own property, no ancestor walk).
/// Honors the UA stylesheet rules per HTML Rendering §15.3.1 "Hidden elements"
/// via `isElementHidden`.
pub fn hasDisplayNone(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;
    return self.isElementHidden(el, .{});
}

/// Computed display:none coming only from inline style or an author stylesheet
/// rule — the UA stylesheet's hidden elements (<head>, <script>, [hidden], …)
/// are NOT counted, so document scaffolding is preserved. Used by the HTML
/// dump's "invisible" strip mode.
pub fn hasAuthorDisplayNone(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;
    return self.isElementHidden(el, .{ .ua_display_none = false });
}

/// Centralizes UA-stylesheet display:none truth so `getComputedStyle().display`
/// (via `hasDisplayNone`) and `el.checkVisibility()` (via `isHidden`) agree.
/// Spec: HTML Rendering §15.3.1 "Hidden elements".
fn matchesUaDisplayNoneRule(el: *Element) bool {
    // Tag check first: O(1) switch, exits for the ~95% of elements with
    // ordinary tags before we touch the attribute list.
    const tag = el.getTag();
    if (tag.isHiddenByUaStylesheet()) return true;

    if (el.hasAttributeSafe(comptime .wrap("hidden"))) return true;

    // input[type="hidden" i] { display: none !important }
    // _input_type is parsed case-insensitively at attribute-set time.
    if (tag == .input) {
        if (el.is(Input)) |input| {
            if (input._input_type == .hidden) return true;
        }
    }

    // details:not([open]) > *:not(summary) { display: none }
    if (tag != .summary) {
        if (el.parentElement()) |parent| {
            if (parent.getTag() == .details and !parent.hasAttributeSafe(comptime .wrap("open"))) {
                return true;
            }
        }
    }

    return false;
}

/// Computed visibility:hidden for an element, considering only the `visibility`
/// chain (walks ancestors since `visibility` inherits by default). Ignores
/// display:none: an ancestor with display:none means the element isn't
/// rendered, but its computed `visibility` still reflects inherited visibility.
pub fn hasVisibilityHiddenInherited(self: *StyleManager, el: *Element) bool {
    const value = self.resolvedAuthoredPropertyValue(el, comptime .wrap("visibility"), true) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "hidden") or std.ascii.eqlIgnoreCase(value, "collapse");
}

/// `Element.checkVisibility()` always treats a descendant of
/// `content-visibility:hidden` as not visible, independently of its options.
/// The element establishing the skipped subtree still has its own principal
/// box, so this intentionally starts at the parent rather than at `el`.
///
/// Blink implements the same distinction through the ancestor display-lock
/// walk in Element::checkVisibility: the inclusive element is skipped and
/// only a locked ancestor rejects the query.
pub fn hasContentVisibilityHiddenAncestor(self: *StyleManager, el: *Element) bool {
    self.rebuildIfDirty() catch return false;

    var current = el.parentElement();
    while (current) |ancestor| {
        if (self.resolvedAuthoredPropertyValue(
            ancestor,
            .wrap("content-visibility"),
            false,
        )) |value| {
            if (std.ascii.eqlIgnoreCase(value, "hidden")) return true;
        }
        current = ancestor.parentElement();
    }
    return false;
}

/// Check if a single element (not ancestors) is hidden.
fn isElementHidden(self: *StyleManager, el: *Element, options: CheckVisibilityOptions) bool {
    if (options.check_display) {
        if (self.resolvedAuthoredPropertyValue(el, comptime .wrap("display"), false)) |value| {
            if (std.ascii.eqlIgnoreCase(value, "none")) return true;
        } else if (options.ua_display_none and authoredDisplayAllowsUaFallback(self, el) and matchesUaDisplayNoneRule(el)) {
            return true;
        }
    }

    if (options.check_visibility) {
        if (self.resolvedAuthoredPropertyValue(el, comptime .wrap("visibility"), true)) |value| {
            if (std.ascii.eqlIgnoreCase(value, "hidden") or std.ascii.eqlIgnoreCase(value, "collapse")) return true;
        }
    }

    if (options.check_opacity) {
        if (self.resolvedAuthoredPropertyValue(el, comptime .wrap("opacity"), false)) |value| {
            if (std.ascii.eqlIgnoreCase(value, "0")) return true;
        }
    }

    return false;
}

fn authoredDisplayAllowsUaFallback(self: *StyleManager, el: *Element) bool {
    const declaration = self.ownAuthoredProperty(el, comptime .wrap("display")) orelse return true;
    const value = std.mem.trim(u8, declaration.value, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(value, "revert") or std.ascii.eqlIgnoreCase(value, "revert-layer");
}

/// Check if an element has pointer-events:none.
/// Checks inline style first - if set, skips stylesheet lookup.
/// Walks up the tree to check ancestors.
pub fn hasPointerEventsNone(self: *StyleManager, el: *Element, cache: ?*PointerEventsCache) bool {
    self.rebuildIfDirty() catch return false;

    var current: ?*Element = el;

    while (current) |elem| {
        // Check cache first
        if (cache) |c| {
            if (c.get(elem)) |pe_none| {
                if (pe_none) return true;
                current = elem.parentElement();
                continue;
            }
        }

        const pe_none = self.elementHasPointerEventsNone(elem);

        if (cache) |c| {
            c.put(self.frame.call_arena, elem, pe_none) catch |err| {
                log.warn(.browser, "StyleManager cache", .{ .err = err, .src = "hasPointerEventsNone" });
            };
        }

        if (pe_none) {
            return true;
        }
        current = elem.parentElement();
    }

    return false;
}

/// Check if a single element (not ancestors) has pointer-events:none.
fn elementHasPointerEventsNone(self: *StyleManager, el: *Element) bool {
    const value = self.resolvedAuthoredPropertyValue(el, .wrap("pointer-events"), false) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "none");
}

// Extracts visibility-relevant rules from a CSS rule.
// Creates one VisibilityRule per selector (not per selector list) so each has correct specificity.
// Buckets rules by their rightmost selector part for fast lookup.
fn addRule(self: *StyleManager, style_rule: *CSSStyleRule) !void {
    const selector_text = style_rule._selector_text;
    if (selector_text.len == 0) {
        return;
    }

    // Check if the rule has visibility-relevant properties
    const style = style_rule._style orelse return;
    const props = extractVisibilityProperties(style);
    if (!props.isRelevant()) {
        return;
    }

    // Parse the selector list
    const selectors = SelectorParser.parseList(self.arena, selector_text) catch return;
    if (selectors.len == 0) {
        return;
    }

    // Create one rule per selector - each has its own specificity
    // e.g., "#id, .class { display: none }" becomes two rules with different specificities
    for (selectors) |selector| {
        // Get the rightmost compound (last segment, or first if no segments)
        const rightmost = if (selector.segments.len > 0)
            selector.segments[selector.segments.len - 1].compound
        else
            selector.first;

        // Find the bucketing key from rightmost compound
        const bucket_key = getBucketKey(rightmost) orelse continue; // skip if dynamic pseudo-class

        const rule = VisibilityRule{
            .props = props,
            .selector = selector,
            .priority = (@as(u64, computeSpecificity(selector)) << 32) | @as(u64, self.next_doc_order),
        };
        self.next_doc_order += 1;

        // Add to appropriate bucket
        switch (bucket_key) {
            .id => |id| {
                const gop = try self.id_rules.getOrPut(self.arena, id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .class => |class| {
                const gop = try self.class_rules.getOrPut(self.arena, class);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .tag => |tag| {
                const gop = try self.tag_rules.getOrPut(self.arena, tag);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.arena, rule);
            },
            .other => {
                try self.other_rules.append(self.arena, rule);
            },
        }
    }
}

const BucketKey = union(enum) {
    id: []const u8,
    class: []const u8,
    tag: Tag,
    other,
};

/// Returns the best bucket key for a compound selector, or null if it contains
/// a dynamic pseudo-class we should skip (hover, active, focus, etc.)
/// Priority: id > class > tag > other
fn getBucketKey(compound: Selector.Compound) ?BucketKey {
    var best_key: BucketKey = .other;

    for (compound.parts) |part| {
        switch (part) {
            .id => |id| {
                best_key = .{ .id = id };
            },
            .class => |class| {
                if (best_key != .id) {
                    best_key = .{ .class = class };
                }
            },
            .tag => |tag| {
                if (best_key == .other) {
                    best_key = .{ .tag = tag };
                }
            },
            .tag_name => {
                // Custom tag - put in other bucket (can't efficiently look up)
                // Keep current best_key if we have something better
            },
            .pseudo_class => |pc| {
                // Skip dynamic pseudo-classes - they depend on interaction state
                switch (pc) {
                    .hover, .active, .focus, .focus_within, .focus_visible, .visited, .target => {
                        return null; // Skip this selector entirely
                    },
                    else => {},
                }
            },
            .universal, .attribute => {},
        }
    }

    return best_key;
}

/// Extract the bounded authored-property surface from a CSSOM style rule.
fn extractVisibilityProperties(style: *CSSStyleProperties) VisibilityProperties {
    var props = VisibilityProperties{};
    const decl = style.asCSSStyleDeclaration();

    if (decl.findProperty(comptime .wrap("display"))) |property| {
        props.set("display", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("visibility"))) |property| {
        props.set("visibility", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("opacity"))) |property| {
        props.set("opacity", property._value.str(), property._important);
    }

    if (decl.findProperty(.wrap("pointer-events"))) |property| {
        props.set("pointer-events", property._value.str(), property._important);
    }

    if (decl.findProperty(.wrap("content-visibility"))) |property| {
        props.set("content-visibility", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("color"))) |property| {
        props.set("color", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("width"))) |property| {
        props.set("width", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("height"))) |property| {
        props.set("height", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("position"))) |property| {
        props.set("position", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("left"))) |property| {
        props.set("left", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("top"))) |property| {
        props.set("top", property._value.str(), property._important);
    }

    if (decl.findProperty(.wrap("margin-left"))) |property| {
        props.set("margin-left", property._value.str(), property._important);
    }

    if (decl.findProperty(comptime .wrap("transform"))) |property| {
        props.set("transform", property._value.str(), property._important);
    }

    return props;
}

// Computes CSS specificity for a selector.
// Returns packed value: (id_count << 20) | (class_count << 10) | element_count
pub fn computeSpecificity(selector: Selector.Selector) u32 {
    var ids: u32 = 0;
    var classes: u32 = 0; // includes classes, attributes, pseudo-classes
    var elements: u32 = 0; // includes elements, pseudo-elements

    // Count specificity for first compound
    countCompoundSpecificity(selector.first, &ids, &classes, &elements);

    // Count specificity for subsequent segments
    for (selector.segments) |segment| {
        countCompoundSpecificity(segment.compound, &ids, &classes, &elements);
    }

    // Pack into single u32: (ids << 20) | (classes << 10) | elements
    // This gives us 10 bits each, supporting up to 1023 of each type
    return (@as(u32, @min(ids, 1023)) << 20) | (@as(u32, @min(classes, 1023)) << 10) | @min(elements, 1023);
}

fn countCompoundSpecificity(compound: Selector.Compound, ids: *u32, classes: *u32, elements: *u32) void {
    for (compound.parts) |part| {
        switch (part) {
            .id => ids.* += 1,
            .class => classes.* += 1,
            .tag, .tag_name => elements.* += 1,
            .universal => {}, // zero specificity
            .attribute => classes.* += 1,
            .pseudo_class => |pc| {
                switch (pc) {
                    // :where() has zero specificity
                    .where => {},
                    // :not(), :is(), :has() take specificity of their most specific argument
                    .not, .is, .has => |nested| {
                        var max_nested: u32 = 0;
                        for (nested) |nested_sel| {
                            const spec = computeSpecificity(nested_sel);
                            if (spec > max_nested) max_nested = spec;
                        }
                        // Unpack and add to our counts
                        ids.* += (max_nested >> 20) & 0x3FF;
                        classes.* += (max_nested >> 10) & 0x3FF;
                        elements.* += max_nested & 0x3FF;
                    },
                    // All other pseudo-classes count as class-level specificity
                    else => classes.* += 1,
                }
            },
        }
    }
}

fn matchesSelector(el: *Element, selector: Selector.Selector, frame: *Frame) bool {
    const node = el.asNode();
    return SelectorList.matches(node, selector, node, frame);
}

const VisibilityProperties = struct {
    display: ?AuthoredDeclaration = null,
    visibility: ?AuthoredDeclaration = null,
    opacity: ?AuthoredDeclaration = null,
    pointer_events: ?AuthoredDeclaration = null,
    content_visibility: ?AuthoredDeclaration = null,
    color: ?AuthoredDeclaration = null,
    width: ?AuthoredDeclaration = null,
    height: ?AuthoredDeclaration = null,
    position: ?AuthoredDeclaration = null,
    left: ?AuthoredDeclaration = null,
    top: ?AuthoredDeclaration = null,
    margin_left: ?AuthoredDeclaration = null,
    transform: ?AuthoredDeclaration = null,

    fn setSlot(slot: *?AuthoredDeclaration, value: []const u8, important: bool) void {
        if (slot.*) |existing| {
            // Within one declaration block, a later normal declaration cannot
            // displace an earlier !important declaration. Equal importance is
            // resolved by declaration order, so the later value wins.
            if (existing.important and !important) return;
        }
        slot.* = .{ .value = value, .important = important };
    }

    fn set(self: *VisibilityProperties, name: []const u8, value: []const u8, important: bool) void {
        if (std.ascii.eqlIgnoreCase(name, "display")) {
            setSlot(&self.display, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "visibility")) {
            setSlot(&self.visibility, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "opacity")) {
            setSlot(&self.opacity, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "pointer-events")) {
            setSlot(&self.pointer_events, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "content-visibility")) {
            setSlot(&self.content_visibility, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "color")) {
            setSlot(&self.color, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "width")) {
            setSlot(&self.width, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "height")) {
            setSlot(&self.height, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "position")) {
            setSlot(&self.position, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "left")) {
            setSlot(&self.left, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "top")) {
            setSlot(&self.top, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "margin-left")) {
            setSlot(&self.margin_left, value, important);
        } else if (std.ascii.eqlIgnoreCase(name, "transform")) {
            setSlot(&self.transform, value, important);
        }
    }

    fn get(self: VisibilityProperties, name: String) ?AuthoredDeclaration {
        if (name.eql(comptime .wrap("display"))) return self.display;
        if (name.eql(comptime .wrap("visibility"))) return self.visibility;
        if (name.eql(comptime .wrap("opacity"))) return self.opacity;
        if (name.eqlSlice("pointer-events")) return self.pointer_events;
        if (name.eqlSlice("content-visibility")) return self.content_visibility;
        if (name.eql(comptime .wrap("color"))) return self.color;
        if (name.eql(comptime .wrap("width"))) return self.width;
        if (name.eql(comptime .wrap("height"))) return self.height;
        if (name.eql(comptime .wrap("position"))) return self.position;
        if (name.eql(comptime .wrap("left"))) return self.left;
        if (name.eql(comptime .wrap("top"))) return self.top;
        if (name.eqlSlice("margin-left")) return self.margin_left;
        if (name.eql(comptime .wrap("transform"))) return self.transform;
        return null;
    }

    fn isRelevant(self: VisibilityProperties) bool {
        return self.display != null or
            self.visibility != null or
            self.opacity != null or
            self.pointer_events != null or
            self.content_visibility != null or
            self.color != null or
            self.width != null or
            self.height != null or
            self.position != null or
            self.left != null or
            self.top != null or
            self.margin_left != null or
            self.transform != null;
    }
};

const AuthoredDeclaration = struct {
    value: []const u8,
    important: bool,
};

const CascadeCandidate = struct {
    declaration: AuthoredDeclaration,
    inline_style: bool,
    priority: u64,

    fn outranks(self: CascadeCandidate, other: CascadeCandidate) bool {
        if (self.declaration.important != other.declaration.important) {
            return self.declaration.important;
        }
        if (self.inline_style != other.inline_style) return self.inline_style;
        return self.priority > other.priority;
    }
};

const VisibilityRule = struct {
    selector: Selector.Selector, // Single selector, not a list
    props: VisibilityProperties,

    // Packed priority: (specificity << 32) | doc_order
    priority: u64,
};

const CheckVisibilityOptions = struct {
    check_display: bool = true,
    check_visibility: bool = false,
    check_opacity: bool = false,
    ua_display_none: bool = true,
};

fn getInlineStyleProperty(el: *Element, property_name: String, frame: *Frame) ?*CSSStyleProperty {
    const style = frame._element_styles.get(el) orelse blk: {
        // No JS-set style object and no style attribute -> nothing inline to read.
        if (el.getAttributeSafe(comptime .wrap("style")) == null) return null;
        break :blk el.getOrCreateStyle(frame) catch |err| {
            log.err(.browser, "StyleManager getOrCreateStyle", .{ .err = err });
            return null;
        };
    };
    return style.asCSSStyleDeclaration().findProperty(property_name);
}

/// Resolved value of an element's inline `style=` declaration for `property_name`,
/// or null when the element has no such declaration. Reads the element's parsed
/// inline style (the same source `el.style` exposes), so `getComputedStyle` and
/// `el.style` agree on inline values instead of resolving them independently.
pub fn inlineStyleValue(self: *StyleManager, el: *Element, property_name: String) ?[]const u8 {
    const property = getInlineStyleProperty(el, property_name, self.frame) orelse return null;
    return property._value.str();
}

const testing = @import("../testing.zig");
test "StyleManager: computeSpecificity: element selector" {
    // div -> (0, 0, 1)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .tag = .div }} },
        .segments = &.{},
    };
    try testing.expectEqual(1, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: class selector" {
    // .foo -> (0, 1, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: id selector" {
    // #bar -> (1, 0, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .id = "bar" }} },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 20, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: combined selector" {
    // div.foo#bar -> (1, 1, 1)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .tag = .div },
            .{ .class = "foo" },
            .{ .id = "bar" },
        } },
        .segments = &.{},
    };
    try testing.expectEqual((1 << 20) | (1 << 10) | 1, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: universal selector" {
    // * -> (0, 0, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.universal} },
        .segments = &.{},
    };
    try testing.expectEqual(0, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: multiple classes" {
    // .a.b.c -> (0, 3, 0)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .class = "a" },
            .{ .class = "b" },
            .{ .class = "c" },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(3 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: descendant combinator" {
    // div span -> (0, 0, 2)
    const selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .tag = .div }} },
        .segments = &.{
            .{ .combinator = .descendant, .compound = .{ .parts = &.{.{ .tag = .span }} } },
        },
    };
    try testing.expectEqual(2, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :where() has zero specificity" {
    // :where(.foo) -> (0, 0, 0) regardless of what's inside
    const inner_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .where = &.{inner_selector} } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(0, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :not() takes inner specificity" {
    // :not(.foo) -> (0, 1, 0) - takes specificity of .foo
    const inner_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .not = &.{inner_selector} } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: :is() takes most specific inner" {
    // :is(.foo, #bar) -> (1, 0, 0) - takes the most specific (#bar)
    const class_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .class = "foo" }} },
        .segments = &.{},
    };
    const id_selector = Selector.Selector{
        .first = .{ .parts = &.{.{ .id = "bar" }} },
        .segments = &.{},
    };
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .{ .is = &.{ class_selector, id_selector } } },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 20, computeSpecificity(selector));
}

test "StyleManager: computeSpecificity: pseudo-class (general)" {
    // :hover -> (0, 1, 0) - pseudo-classes count as class-level
    const selector = Selector.Selector{
        .first = .{ .parts = &.{
            .{ .pseudo_class = .hover },
        } },
        .segments = &.{},
    };
    try testing.expectEqual(1 << 10, computeSpecificity(selector));
}

test "StyleManager: document order tie-breaking" {
    // When specificity is equal, higher doc_order (later in document) wins
    const beats = struct {
        fn f(spec: u32, doc_order: u32, best_spec: u32, best_doc_order: u32) bool {
            return spec > best_spec or (spec == best_spec and doc_order > best_doc_order);
        }
    }.f;

    // Higher specificity always wins regardless of doc_order
    try testing.expect(beats(2, 0, 1, 10));
    try testing.expect(!beats(1, 10, 2, 0));

    // Equal specificity: higher doc_order wins
    try testing.expect(beats(1, 5, 1, 3)); // doc_order 5 > 3
    try testing.expect(!beats(1, 3, 1, 5)); // doc_order 3 < 5

    // Equal specificity and doc_order: no win
    try testing.expect(!beats(1, 5, 1, 5));
}
