//! Emphasis and strong emphasis (CommonMark 0.31.2 §6.2 and its appendix,
//! "process emphasis"): runs of `*` and `_` that can open or close go on a
//! delimiter stack as the leaf is read; at a link's end and at the leaf's
//! end the stack above a bottom is matched, closers left to right, each
//! looking back for the nearest opener it may take.
//!
//! The look back stops at `openers_bottom`, kept per delimiter character,
//! whether the closer can also open, and the closer's run length mod 3:
//! where a closer found no opener, a later closer of the same key cannot
//! find one below that point either, so each opener is passed over at most
//! once per key and the matching is linear.
const std = @import("std");
const aegis = @import("aegis");
const chars = @import("../scan/chars.zig");
const items = @import("items.zig");

pub const none = std.math.maxInt(u32);

pub const Delimiter = struct {
    /// The run's item.
    item: u32,
    prev: u32,
    next: u32,
    char: u8,
    can_open: bool,
    can_close: bool,
    /// The run's length as read, which the rule of 3 counts.
    length: u32,
};

/// The stack: the delimiters still open to matching, linked both ways so
/// that a match can take out those between its two runs.
pub const Stack = struct {
    entries: []Delimiter,
    len: u32 = 0,
    top: u32 = none,

    pub fn push(s: *Stack, d: Delimiter) void {
        aegis.assert.invariant(s.len < s.entries.len, "a leaf's delimiters fit the memory sized for it");
        var entry = d;
        entry.prev = s.top;
        entry.next = none;
        s.entries[s.len] = entry;
        if (s.top != none) s.entries[s.top].next = s.len;
        s.top = s.len;
        s.len += 1;
    }

    fn remove(s: *Stack, at: u32) void {
        const e = s.entries[at];
        if (e.prev != none) s.entries[e.prev].next = e.next;
        if (e.next != none) s.entries[e.next].prev = e.prev else s.top = e.prev;
    }
};

pub const Flanking = struct { can_open: bool, can_close: bool };

fn isPunctuation(cp: u21) bool {
    return chars.isUnicodePunctuation(cp);
}

/// Whether the run `s[start..end]` of `char` can open and can close: its
/// flanking (§6.2), and for `_` the intraword rule.
pub fn classify(s: []const u8, start: usize, end: usize, char: u8) Flanking {
    const before = chars.before(s, start);
    const after = chars.after(s, end);
    const space_before = chars.isUnicodeWhitespace(before);
    const space_after = chars.isUnicodeWhitespace(after);
    const punct_before = isPunctuation(before);
    const punct_after = isPunctuation(after);
    const left = !space_after and (!punct_after or space_before or punct_before);
    const right = !space_before and (!punct_before or space_after or punct_after);
    // `*` and GFM's `~` by flanking alone; `_` not inside a word.
    if (char != '_') return .{ .can_open = left, .can_close = right };
    return .{
        .can_open = left and (!right or punct_before),
        .can_close = right and (!left or punct_after),
    };
}

/// One of the `openers_bottom` keys for a closer: six for each of `*`
/// and `_` (whether it can open, its length mod 3), four for `~` (whether
/// it can open, its length, one or two).
fn key(d: Delimiter) usize {
    if (d.char == '~') return 12 + @as(usize, @intFromBool(d.can_open)) * 2 + (d.length - 1);
    return @as(usize, @intFromBool(d.char == '_')) * 6 + @as(usize, @intFromBool(d.can_open)) * 3 + d.length % 3;
}

/// Whether `o` can open what the closer `c` closes: the same character;
/// for `~`, the same length (GFM's strikethrough); for `*` and `_`, not
/// both lengths' sum a multiple of 3 when either can both open and close,
/// unless both are (§6.2's rule of 3).
fn opens(o: Delimiter, c: Delimiter) bool {
    if (!o.can_open or o.char != c.char) return false;
    if (c.char == '~') return o.length == c.length;
    const both = o.can_close or c.can_open;
    return !(both and (o.length + c.length) % 3 == 0 and !(o.length % 3 == 0 and c.length % 3 == 0));
}

/// Whether the entry `at` lies above the entry `floor` (`none`: no floor).
/// Entries are pushed in the text's order, so their indices are its order:
/// a floor an earlier match took off the stack still marks its place, where
/// waiting to meet it again let every later look back run to the bottom
/// (cmark's issue #389).
fn above(at: u32, floor: u32) bool {
    return floor == none or at > floor;
}

/// Matches the delimiters above `bottom` (an entry, or `none` for the
/// whole stack), puts emphasis items into `list` for each match, and
/// takes every delimiter above `bottom` off the stack: what no match took
/// stays in its run's item as text.
pub fn process(stack: *Stack, list: *items.List, bottom: u32, work: *u64) void {
    var openers_bottom: [16]u32 = @splat(bottom);
    // The first delimiter above the bottom.
    if (stack.top == none or stack.top == bottom) return;
    var closer = stack.top;
    while (stack.entries[closer].prev != bottom) : (work.* += 1) closer = stack.entries[closer].prev;
    while (closer != none) {
        work.* += 1;
        const c = stack.entries[closer];
        if (!c.can_close) {
            closer = c.next;
            continue;
        }
        const k = key(c);
        var opener = c.prev;
        var found = false;
        while (opener != none and above(opener, bottom) and above(opener, openers_bottom[k])) {
            work.* += 1;
            const o = stack.entries[opener];
            if (opens(o, c)) {
                found = true;
                break;
            }
            opener = o.prev;
        }
        if (found) {
            closer = match(stack, list, opener, closer);
        } else {
            openers_bottom[k] = c.prev;
            const next = c.next;
            if (!c.can_open) stack.remove(closer);
            closer = next;
        }
    }
    // Everything above the bottom is done with.
    while (stack.top != bottom and stack.top != none) : (work.* += 1) stack.remove(stack.top);
}

/// Takes one or two characters off the opener's run and the closer's,
/// puts the emphasis between them, and takes the delimiters between them
/// off the stack. Returns the closer to go on with: the same one while it
/// has characters left, else the next.
fn match(stack: *Stack, list: *items.List, opener: u32, closer: u32) u32 {
    const open_item = stack.entries[opener].item;
    const close_item = stack.entries[closer].item;
    const o = list.items[open_item];
    const c = list.items[close_item];
    // A strikethrough takes its runs whole; emphasis two characters when
    // both runs have them, else one.
    const strike = stack.entries[closer].char == '~';
    const use: u32 = if (strike) c.end - c.start else if (o.end - o.start >= 2 and c.end - c.start >= 2) 2 else 1;
    const kinds: [2]items.Kind = if (strike) .{ .strike_open, .strike_close } else if (use == 2) .{ .strong_open, .strong_close } else .{ .emphasis_open, .emphasis_close };
    list.items[open_item].end -= use;
    const opened_at = list.items[open_item].end;
    const opening = list.insertAfter(open_item, .{ .start = opened_at, .end = opened_at + use, .kind = kinds[0] });
    const closed_at = list.items[close_item].start;
    list.items[close_item].start += use;
    const closing = list.insertBefore(close_item, .{ .start = closed_at, .end = closed_at + use, .kind = kinds[1] });
    list.items[opening].a = closing;
    list.items[closing].a = opening;
    // The delimiters between the two can no longer match anything.
    var between = stack.entries[closer].prev;
    while (between != opener) {
        const prev = stack.entries[between].prev;
        stack.remove(between);
        between = prev;
    }
    const opener_item = list.items[open_item];
    if (opener_item.end == opener_item.start) stack.remove(opener);
    const closer_item = list.items[close_item];
    if (closer_item.end == closer_item.start) {
        const next = stack.entries[closer].next;
        stack.remove(closer);
        return next;
    }
    return closer;
}

const testing = std.testing;

test "flanking as §6.2 reads it" {
    const Case = struct { []const u8, usize, usize, bool, bool };
    const cases = [_]Case{
        .{ "***abc", 0, 3, true, false },
        .{ "abc***", 3, 6, false, true },
        .{ "abc***def", 3, 6, true, true },
        .{ "abc *** def", 4, 7, false, false },
        .{ "\"abc\"***", 5, 8, false, true },
        .{ " _\"abc\"", 1, 2, true, false },
    };
    for (cases) |c| {
        const f = classify(c[0], c[1], c[2], c[0][c[1]]);
        try testing.expectEqual(c[3], f.can_open);
        try testing.expectEqual(c[4], f.can_close);
    }
    // `_` inside a word neither opens nor closes.
    const intraword = classify("foo_bar_", 3, 4, '_');
    try testing.expect(!intraword.can_open and !intraword.can_close);
}
