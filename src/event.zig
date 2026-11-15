//! What a document reads as: a stream of events, each with its exact span
//! in the text. Containers and leaves enter and exit; their content comes
//! between as text, escapes, references, code, HTML and breaks. Every
//! payload is `u32` offsets and small integers, so nothing depends on the
//! target's word size.
const std = @import("std");
const Span = @import("Span.zig");
const Block = @import("block/Block.zig");

/// A table cell's alignment, from its delimiter row.
pub const Alignment = enum(u8) { none, left, center, right };

/// A link or an image: how it was written, its destination as written
/// (`writeDestination` unescapes it and decodes its references), and the
/// index of its title and label in the leaf's side table (`Events.title`,
/// `Events.label`).
pub const Link = struct {
    kind: Kind,
    destination: Span,
    parts: u32 = none,

    pub const Kind = enum(u8) {
        /// `[text](destination "title")`
        inline_,
        /// `[text][label]`
        reference,
        /// `[label][]`
        collapsed,
        /// `[label]`
        shortcut,
        /// `<scheme:...>`
        autolink,
        /// `<local@domain>`
        email,
        /// GFM's `www.`, `http://` and bare addresses.
        extended,
        /// `[[target]]`
        wiki,
    };

    /// No side-table entry.
    pub const none = std.math.maxInt(u32);
};

pub const Node = union(enum) {
    paragraph,
    block_quote,
    heading: struct { level: Block.Level, setext: bool },
    list: struct { ordered: bool, start: u32, tight: bool, marker: u8 },
    item,
    /// `info`'s first word is the language; empty for indented code.
    code_block: struct { fenced: bool, info: Span },
    html_block,
    front_matter,
    table,
    table_head,
    table_row,
    table_cell: Alignment,
    emphasis,
    strong,
    strikethrough,
    link: Link,
    image: Link,
};

/// An entity or numeric character reference's code points: `second` is 0
/// where it is one.
pub const Reference = struct { first: u21, second: u21 = 0 };

/// 8 bytes of span and 24 of kind (a `Node` of 20 and its tag): 32 bytes,
/// `align(4)`, on every target and in every build mode; the check below
/// fails the build where the compiler lays it out larger.
pub const Event = struct {
    /// What the event covers in the text: a container from its first marker
    /// to its last byte, a leaf's whole extent, a link from `[` to `)`, the
    /// two bytes of an escape, a break's line ending (with the spaces or
    /// backslash before it, and the indentation after it).
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        enter: Node,
        exit: Node,
        /// The span is the text, verbatim. A text event never crosses a
        /// line: a paragraph's lines arrive as text, break, text. In a code
        /// block, each line is one text event.
        text,
        /// Columns of a tab a container took part of, as spaces, before the
        /// code block or HTML block line that follows: the span is the tab.
        spaces: u8,
        /// `\*`: the span covers both bytes; the character is the second.
        escape,
        /// `&amp;`, `&#x41;`: its code points.
        reference: Reference,
        /// A code span's content after the spec's stripping, one piece per
        /// line it is on: the span is the whole code span, backticks
        /// included, the same for each piece, which a writer joins with a
        /// space (a line ending in a code span is a space).
        code: Span,
        /// Raw HTML, one piece per line: inline HTML's pieces share the
        /// span of the whole tag, which a writer joins with a line ending;
        /// an HTML block's lines each span themselves.
        html: Span,
        soft_break,
        hard_break,
        /// A thematic break.
        rule,
        /// A task list item's marker, done or not.
        task: bool,
    };

    comptime {
        if (@sizeOf(Event) != 32 or @sizeOf(Node) != 20 or @sizeOf(Link) != 16)
            @compileError("datapad: Event's layout moved; the 32-byte budget is every consumer's");
    }
};

test "an event is 32 bytes" {
    try std.testing.expectEqual(32, @sizeOf(Event));
}
