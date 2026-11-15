//! A record of the block table: one block of the document, in document
//! order (a container before what it holds), with its nesting depth, its
//! span, and for a leaf its content lines (container markers and
//! indentation taken off).
const aegis = @import("aegis");
const Span = @import("../Span.zig");

pub const Kind = enum(u8) {
    block_quote,
    list,
    item,
    paragraph,
    heading,
    thematic_break,
    code_block,
    html_block,
    /// GFM's table: its lines are its header row, its delimiter row and its
    /// body rows.
    table,
};

/// A heading's level, `#` to `######`.
pub const Level = aegis.int.Ranged(u8, 1, 6);
/// Which of CommonMark's seven kinds of HTML block (§4.6).
pub const HtmlKind = aegis.int.Ranged(u8, 1, 7);

kind: Kind,
/// How many containers (block quotes, lists, list items) hold it.
depth: u16,
/// From its first marker to its last byte: a block quote's first `>`, a
/// list's or an item's first marker, a fence, a heading's `#`, a
/// paragraph's first character; its last line's end, line ending left out.
span: Span,
/// Its content lines, `lines[first_line..][0..line_count]` of the document.
first_line: u32 = 0,
line_count: u32 = 0,
data: Data = .none,

pub const Data = union(enum) {
    none,
    heading: struct { level: Level, setext: bool },
    /// `start` is an ordered list's first number; `marker` its delimiter
    /// (`.` or `)`) or a bullet list's bullet (`-`, `+`, `*`).
    list: struct { ordered: bool, start: u32, tight: bool, marker: u8 },
    /// `info` is a fenced block's info string, trimmed: empty where it has
    /// none, and for an indented block.
    code: struct { fenced: bool, info: Span },
    html: HtmlKind,
    /// A table's columns: its delimiter row's cells.
    table: u32,
};

/// A content line: where its content lies, and how many columns of a tab a
/// container took part of come before it, as spaces (§2.2): the tab is the
/// byte before `start`.
pub const Line = struct {
    start: u32,
    end: u32,
    spaces: u8 = 0,

    pub fn of(l: Line, text: []const u8) []const u8 {
        return text[l.start..l.end];
    }
};
