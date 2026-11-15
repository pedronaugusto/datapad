//! What the inline pass reads a leaf into: a list of items in text order,
//! each a run of the leaf's joined text and what it is. Emphasis is found
//! only once the leaf is read, by matching delimiter runs already listed,
//! so the list is linked both ways: a match takes characters off two runs
//! and puts an opening item after the one and a closing item before the
//! other, where an array would shift everything after.
const std = @import("std");
const aegis = @import("aegis");

pub const none = std.math.maxInt(u32);

pub const Kind = enum(u8) {
    /// Text, verbatim.
    text,
    /// `\` and the ASCII punctuation character it escapes.
    escape,
    /// An entity or numeric reference: `a` and `b` are its code points.
    reference,
    /// A code span, backticks included: `a` and `b` bound its content
    /// after stripping.
    code,
    /// Raw inline HTML.
    html,
    /// A line ending, with the spaces before it and after it.
    soft_break,
    /// A line ending after two spaces or a backslash, with them and the
    /// spaces after it.
    hard_break,
    /// A run of `*`, `_` or `~` (`a` is the character), the characters no
    /// match took: text.
    delimiter,
    /// A `[` or `![` no link took: text.
    bracket,
    /// Emphasis's and strong emphasis's delimiters: `a` is the item that
    /// closes or opens it.
    emphasis_open,
    emphasis_close,
    strong_open,
    strong_close,
    /// GFM's strikethrough's delimiters, as emphasis's.
    strike_open,
    strike_close,
    /// A link's or an image's opening and closing syntax: `a` is its
    /// record.
    link_open,
    link_close,
};

pub const Item = struct {
    start: u32,
    end: u32,
    prev: u32 = none,
    next: u32 = none,
    a: u32 = 0,
    b: u32 = 0,
    kind: Kind,

    /// Characters that read as text when nothing else took them.
    pub fn textual(item: Item) bool {
        return switch (item.kind) {
            .text, .delimiter, .bracket => true,
            else => false,
        };
    }
};

/// The items, in memory the caller sized for the leaf.
pub const List = struct {
    items: []Item,
    len: u32 = 0,
    head: u32 = none,
    tail: u32 = none,

    fn add(l: *List, item: Item) u32 {
        aegis.assert.invariant(l.len < l.items.len, "a leaf's items fit the memory sized for it");
        const at = l.len;
        l.items[at] = item;
        l.len += 1;
        return at;
    }

    /// An item after the last.
    pub fn append(l: *List, item: Item) u32 {
        const at = l.add(item);
        l.items[at].prev = l.tail;
        l.items[at].next = none;
        if (l.tail == none) l.head = at else l.items[l.tail].next = at;
        l.tail = at;
        return at;
    }

    /// An item right after `after`.
    pub fn insertAfter(l: *List, after: u32, item: Item) u32 {
        const at = l.add(item);
        const next = l.items[after].next;
        l.items[at].prev = after;
        l.items[at].next = next;
        l.items[after].next = at;
        if (next == none) l.tail = at else l.items[next].prev = at;
        return at;
    }

    /// An item right before `before`.
    pub fn insertBefore(l: *List, before: u32, item: Item) u32 {
        const at = l.add(item);
        const prev = l.items[before].prev;
        l.items[at].prev = prev;
        l.items[at].next = before;
        l.items[before].prev = at;
        if (prev == none) l.head = at else l.items[prev].next = at;
        return at;
    }
};

test "items go in at either end and between" {
    var memory: [4]Item = undefined;
    var l: List = .{ .items = &memory };
    const b = l.append(.{ .start = 1, .end = 2, .kind = .text });
    const d = l.append(.{ .start = 3, .end = 4, .kind = .text });
    _ = l.insertAfter(b, .{ .start = 2, .end = 3, .kind = .emphasis_open });
    _ = l.insertBefore(b, .{ .start = 0, .end = 1, .kind = .bracket });
    var starts: [4]u32 = undefined;
    var i: usize = 0;
    var at = l.head;
    while (at != none) : (at = l.items[at].next) {
        starts[i] = l.items[at].start;
        i += 1;
    }
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, &starts);
    try std.testing.expectEqual(d, l.tail);
}
