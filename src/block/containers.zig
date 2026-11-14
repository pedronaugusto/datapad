//! The block pass (CommonMark 0.31.2, appendix A's phase 1): the text read
//! once, a line at a time, into the block table. Each line first continues
//! the open containers it can (a block quote's `>`, an item's indentation),
//! then opens the blocks it starts, then goes to the open leaf, a lazy
//! paragraph, or a new paragraph. A paragraph's link reference definitions
//! go to the label table when it closes. The open blocks are an explicit
//! stack: nothing recurses.
const std = @import("std");
const aegis = @import("aegis");
const Span = @import("../Span.zig");
const Limits = @import("../Limits.zig");
const chars = @import("../scan/chars.zig");
const Block = @import("Block.zig");
const leaves = @import("leaves.zig");
const references = @import("references.zig");

const Allocator = std.mem.Allocator;
const Reference = references.Reference;

/// `parse`'s refusals, each a limit (`Limits`).
pub const Error = error{ OutOfMemory, InputTooLong, TooDeep, TooManyBlocks, TooManyReferences };

/// What the pass made, each slice the caller's to free with `deinit`.
pub const Tables = struct {
    blocks: []Block,
    lines: []Block.Line,
    /// Where each line of the text starts.
    line_starts: []u32,
    /// The definitions in document order, every one, a label given twice
    /// included.
    references: []Reference,
    /// The normalized labels, which `Reference.key` indexes.
    keys: []u8,
    /// The definitions links resolve to, ordered by key: the first of each
    /// label.
    labels: []u32,
    /// The most bytes a leaf's lines hold, a line feed counted after each.
    largest_leaf: u32,
    /// The steps the pass took: bytes read and blocks continued, opened and
    /// closed. Linear in the text, which the work-bound tests hold it to.
    work: u64,

    pub fn deinit(t: *Tables, gpa: Allocator) void {
        gpa.free(t.blocks);
        gpa.free(t.lines);
        gpa.free(t.line_starts);
        gpa.free(t.references);
        gpa.free(t.keys);
        gpa.free(t.labels);
        t.* = undefined;
    }
};

pub fn run(gpa: Allocator, text: []const u8, limits: Limits, diagnostics: ?*Limits.Diagnostic) Error!Tables {
    const len = std.math.cast(u32, text.len);
    if (len == null or Span.Offset.fromRaw(len orelse 0).compare(limits.input) == .gt) {
        if (diagnostics) |d| d.* = .{ .offset = limits.input, .limit = .input };
        return error.InputTooLong;
    }
    var p: Pass = .{ .gpa = gpa, .text = text, .limits = limits, .diagnostics = diagnostics };
    defer p.deinit();
    try p.stack.append(gpa, .{ .kind = .document, .block = std.math.maxInt(u32), .end_line = 0 });
    var start: usize = 0;
    while (start < text.len) {
        var end = start;
        while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
        try p.line_starts.append(gpa, @intCast(start));
        p.work += end - start + 1;
        try p.incorporate(@intCast(start), text[start..end]);
        p.line_number += 1;
        start = end;
        if (start < text.len) start += if (text[start] == '\r' and start + 1 < text.len and text[start + 1] == '\n') 2 else 1;
    }
    // An empty last line, where an offset at the text's end lies.
    if (text.len == 0 or text[text.len - 1] == '\n' or text[text.len - 1] == '\r') try p.line_starts.append(gpa, @intCast(text.len));
    while (p.stack.items.len > 1) try p.closeTip();
    return p.finish();
}

/// An open block's kind: a block table kind, or the document.
const Kind = enum {
    document,
    block_quote,
    list,
    item,
    paragraph,
    heading,
    thematic_break,
    code_block,
    html_block,

    fn record(k: Kind) Block.Kind {
        return switch (k) {
            .document => aegis.assert.never("the document has no record"),
            inline else => |tag| @field(Block.Kind, @tagName(tag)),
        };
    }

    fn container(k: Kind) bool {
        return k == .block_quote or k == .list or k == .item;
    }

    /// Whether a block of kind `k` may hold one of `child`.
    fn holds(k: Kind, child: Kind) bool {
        return switch (k) {
            .document, .block_quote, .item => child != .item,
            .list => child == .item,
            else => false,
        };
    }
};

/// A block still open: on the stack from the document down to the tip.
const Open = struct {
    kind: Kind,
    /// Its record in the block table.
    block: u32,
    /// The last line any of it is on, passed to its parent when it closes.
    end_line: u32,
    /// The last line of its last closed child: a blank line after it, before
    /// the next child, makes a list loose (§5.3).
    last_child_end: ?u32 = null,
    has_children: bool = false,
    /// A list item: the columns past its container's content its own
    /// content starts at (the marker's indentation, its width and the
    /// spaces after it).
    content: u32 = 0,
    /// A list: whether ordered, and its delimiter or bullet.
    ordered: bool = false,
    marker: u8 = 0,
    /// A fenced code block: its fence, and the indentation its lines lose.
    fenced: bool = false,
    fence_char: u8 = 0,
    fence_len: usize = 0,
    fence_indent: u32 = 0,
    html: Block.HtmlKind = .literal(1),
};

const Continued = enum { matched, failed, line_done };
const Started = enum { none, container, leaf };

const Pass = struct {
    gpa: Allocator,
    text: []const u8,
    limits: Limits,
    diagnostics: ?*Limits.Diagnostic,
    blocks: std.ArrayList(Block) = .empty,
    lines: std.ArrayList(Block.Line) = .empty,
    line_starts: std.ArrayList(u32) = .empty,
    references: std.ArrayList(Reference) = .empty,
    keys: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Open) = .empty,
    /// A paragraph's lines joined by line feeds, and where each starts in it.
    joined: std.ArrayList(u8) = .empty,
    joined_lines: std.ArrayList(usize) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    /// The lines of the paragraph whose definitions are being read.
    paragraph: []const Block.Line = &.{},
    largest_leaf: u32 = 0,
    work: u64 = 0,

    // The line being read: where it starts in the text, its bytes without
    // the line ending, and the place reached in it (§2.2's columns).
    line_number: u32 = 0,
    line_start: u32 = 0,
    line: []const u8 = "",
    offset: u32 = 0,
    column: u32 = 0,
    /// The tab at `offset` is taken in part, its rest left as spaces.
    partial_tab: bool = false,
    next_nonspace: u32 = 0,
    next_nonspace_column: u32 = 0,
    indent: u32 = 0,
    blank: bool = false,
    /// The deepest open block this line continued, an index in `stack`.
    matched: usize = 0,
    /// Every block open when the line began continued or was closed.
    all_closed: bool = true,
    /// The line has nothing left for a leaf: a fence's opening line.
    consumed: bool = false,

    fn deinit(p: *Pass) void {
        const gpa = p.gpa;
        p.blocks.deinit(gpa);
        p.lines.deinit(gpa);
        p.line_starts.deinit(gpa);
        p.references.deinit(gpa);
        p.keys.deinit(gpa);
        p.stack.deinit(gpa);
        p.joined.deinit(gpa);
        p.joined_lines.deinit(gpa);
        p.scratch.deinit(gpa);
    }

    fn finish(p: *Pass) Error!Tables {
        const gpa = p.gpa;
        const labels = try gpa.alloc(u32, p.references.items.len);
        errdefer gpa.free(labels);
        for (labels, 0..) |*l, i| l.* = @intCast(i);
        std.sort.block(u32, labels, p, Pass.keyBefore);
        // The first definition of each label, the order kept.
        var kept: usize = 0;
        for (labels) |l| {
            if (kept != 0 and std.mem.eql(u8, p.keyOf(labels[kept - 1]), p.keyOf(l))) continue;
            labels[kept] = l;
            kept += 1;
        }
        const label_table = try gpa.realloc(labels, kept);
        errdefer gpa.free(label_table);
        const blocks = try p.blocks.toOwnedSlice(gpa);
        errdefer gpa.free(blocks);
        const lines = try p.lines.toOwnedSlice(gpa);
        errdefer gpa.free(lines);
        const line_starts = try p.line_starts.toOwnedSlice(gpa);
        errdefer gpa.free(line_starts);
        const refs = try p.references.toOwnedSlice(gpa);
        errdefer gpa.free(refs);
        const keys = try p.keys.toOwnedSlice(gpa);
        return .{ .blocks = blocks, .lines = lines, .line_starts = line_starts, .references = refs, .keys = keys, .labels = label_table, .largest_leaf = p.largest_leaf, .work = p.work };
    }

    fn keyOf(p: *const Pass, i: u32) []const u8 {
        const k = p.references.items[i].key;
        return p.keys.items[k.start..][0..k.len];
    }

    fn keyBefore(p: *Pass, a: u32, b: u32) bool {
        return switch (std.mem.order(u8, p.keyOf(a), p.keyOf(b))) {
            .lt => true,
            .gt => false,
            .eq => a < b,
        };
    }

    fn fail(p: *Pass, limit: Limits.Limit, at: u32, err: Error) Error {
        if (p.diagnostics) |d| d.* = .{ .offset = .fromRaw(at), .limit = limit };
        return err;
    }

    // Reading a line, as commonmark.js's parser does.

    fn findNextNonspace(p: *Pass) void {
        var i = p.offset;
        var cols = p.column;
        while (i < p.line.len) : (i += 1) {
            switch (p.line[i]) {
                ' ' => cols += 1,
                '\t' => cols += 4 - cols % 4,
                else => break,
            }
        }
        p.blank = i == p.line.len;
        p.next_nonspace = i;
        p.next_nonspace_column = cols;
        p.indent = cols - p.column;
    }

    fn advanceNextNonspace(p: *Pass) void {
        p.offset = p.next_nonspace;
        p.column = p.next_nonspace_column;
        p.partial_tab = false;
    }

    /// Past `count` characters, or with `columns` `count` columns, a tab
    /// counting to its stop and possibly taken in part.
    fn advanceOffset(p: *Pass, count: u32, columns: bool) void {
        var left = count;
        while (left > 0 and p.offset < p.line.len) {
            if (p.line[p.offset] == '\t') {
                const to_tab = 4 - p.column % 4;
                if (columns) {
                    p.partial_tab = to_tab > left;
                    const step = @min(to_tab, left);
                    p.column += step;
                    if (!p.partial_tab) p.offset += 1;
                    left -= step;
                } else {
                    p.partial_tab = false;
                    p.column += to_tab;
                    p.offset += 1;
                    left -= 1;
                }
            } else {
                p.partial_tab = false;
                p.offset += 1;
                p.column += 1;
                left -= 1;
            }
        }
    }

    fn toLineEnd(p: *Pass) void {
        p.offset = @intCast(p.line.len);
        p.partial_tab = false;
    }

    fn tip(p: *Pass) *Open {
        return &p.stack.items[p.stack.items.len - 1];
    }

    fn incorporate(p: *Pass, start: u32, line: []const u8) Error!void {
        p.line_start = start;
        p.line = line;
        p.offset = 0;
        p.column = 0;
        p.partial_tab = false;
        p.consumed = false;
        const old_tip = p.stack.items.len - 1;
        const raw_blank = leaves.isBlank(line);

        // The open blocks this line continues.
        var container: usize = 0;
        while (container < old_tip) {
            p.findNextNonspace();
            p.work += 1;
            switch (try p.continues(container + 1)) {
                .matched => container += 1,
                .failed => break,
                .line_done => return,
            }
        }
        p.all_closed = container == old_tip;
        p.matched = container;

        // The blocks it starts.
        var leaf = switch (p.stack.items[container].kind) {
            .code_block, .html_block => true,
            else => false,
        };
        while (!leaf) {
            p.findNextNonspace();
            switch (try p.starts(container)) {
                .container => container = p.stack.items.len - 1,
                .leaf => {
                    container = p.stack.items.len - 1;
                    leaf = true;
                },
                .none => {
                    p.advanceNextNonspace();
                    break;
                },
            }
        }

        // What is left of it.
        if (!p.all_closed and !p.blank and p.tip().kind == .paragraph) {
            try p.addLine();
        } else {
            try p.closeUnmatched();
            const kind = p.stack.items[container].kind;
            switch (kind) {
                .paragraph, .code_block, .html_block => if (!p.consumed) {
                    try p.addLine();
                    if (kind == .code_block and p.tip().fenced) p.touch();
                    if (kind == .html_block and p.tip().html.widen(u8) <= 5 and leaves.htmlEnd(p.tip().html, p.line[p.offset..])) {
                        p.touch();
                        try p.closeTip();
                    }
                },
                else => if (p.offset < p.line.len and !p.blank) {
                    try p.addChild(.paragraph, p.next_nonspace);
                    p.advanceNextNonspace();
                    try p.addLine();
                },
            }
        }
        if (!raw_blank) p.touch();
    }

    /// The line ends the open block at `i` or goes on in it.
    fn continues(p: *Pass, i: usize) Error!Continued {
        const open = &p.stack.items[i];
        switch (open.kind) {
            .document => aegis.assert.never("the document is never continued"),
            .block_quote => {
                if (p.indent >= 4 or p.next_nonspace >= p.line.len or p.line[p.next_nonspace] != '>') return .failed;
                p.advanceNextNonspace();
                p.advanceOffset(1, false);
                if (p.offset < p.line.len and chars.isSpaceOrTab(p.line[p.offset])) p.advanceOffset(1, true);
                return .matched;
            },
            .list => return .matched,
            .item => {
                if (p.blank) {
                    // An item may begin with one blank line, not two.
                    if (!open.has_children) return .failed;
                    p.advanceNextNonspace();
                    return .matched;
                }
                if (p.indent < open.content) return .failed;
                p.advanceOffset(open.content, true);
                return .matched;
            },
            .paragraph => return if (p.blank) .failed else .matched,
            .heading, .thematic_break => return .failed,
            .html_block => return if (p.blank and open.html.widen(u8) >= 6) .failed else .matched,
            .code_block => {
                if (open.fenced) {
                    if (p.indent < 4 and p.next_nonspace < p.line.len and p.line[p.next_nonspace] == open.fence_char and
                        leaves.fenceClose(p.line[p.next_nonspace..], open.fence_char, open.fence_len))
                    {
                        p.touch();
                        try p.closeTip();
                        return .line_done;
                    }
                    var n = open.fence_indent;
                    while (n > 0 and p.offset < p.line.len and chars.isSpaceOrTab(p.line[p.offset])) : (n -= 1) p.advanceOffset(1, true);
                    return .matched;
                }
                if (p.indent >= 4) {
                    p.advanceOffset(4, true);
                    return .matched;
                }
                if (p.blank) {
                    p.advanceNextNonspace();
                    return .matched;
                }
                return .failed;
            },
        }
    }

    /// The block the line starts at the place reached, inside the block at
    /// `container`, opened; in CommonMark's order of precedence.
    fn starts(p: *Pass, container: usize) Error!Started {
        const kind = p.stack.items[container].kind;
        const indented = p.indent >= 4;
        const at = p.next_nonspace;
        const rest = p.line[at..];
        if (!indented and rest.len > 0) {
            if (rest[0] == '>') {
                p.advanceNextNonspace();
                p.advanceOffset(1, false);
                if (p.offset < p.line.len and chars.isSpaceOrTab(p.line[p.offset])) p.advanceOffset(1, true);
                try p.closeUnmatched();
                try p.addChild(.block_quote, at);
                return .container;
            }
            if (leaves.atx(rest)) |h| {
                try p.closeUnmatched();
                try p.addChild(.heading, at);
                const b = p.record();
                b.data = .{ .heading = .{ .level = h.level, .setext = false } };
                try p.lines.append(p.gpa, .{ .start = p.line_start + at + @as(u32, @intCast(h.start)), .end = p.line_start + at + @as(u32, @intCast(h.end)) });
                b.line_count = 1;
                p.toLineEnd();
                return .leaf;
            }
            if (leaves.fenceOpen(rest)) |f| {
                try p.closeUnmatched();
                try p.addChild(.code_block, at);
                const o = p.tip();
                o.fenced = true;
                o.fence_char = f.char;
                o.fence_len = f.len;
                o.fence_indent = p.indent;
                p.record().data = .{ .code = .{ .fenced = true, .info = .init(p.line_start + at + @as(u32, @intCast(f.info_start)), p.line_start + at + @as(u32, @intCast(f.info_end))) } };
                p.toLineEnd();
                p.consumed = true;
                return .leaf;
            }
            if (rest[0] == '<') {
                const interrupting = kind == .paragraph or (!p.all_closed and !p.blank and p.tip().kind == .paragraph);
                if (leaves.htmlStart(rest, interrupting)) |html| {
                    try p.closeUnmatched();
                    try p.addChild(.html_block, p.offset);
                    p.tip().html = html;
                    p.record().data = .{ .html = html };
                    return .leaf;
                }
            }
            if (kind == .paragraph) if (leaves.setextUnderline(rest)) |level| {
                try p.closeUnmatched();
                try p.takeDefinitions(p.tip().block);
                const b = p.record();
                if (b.line_count != 0) {
                    b.span.start = .fromRaw(p.lines.items[b.first_line].start);
                    b.kind = .heading;
                    b.data = .{ .heading = .{ .level = level, .setext = true } };
                    p.tip().kind = .heading;
                    p.toLineEnd();
                    return .leaf;
                }
            };
            if (leaves.thematicBreak(rest)) {
                try p.closeUnmatched();
                try p.addChild(.thematic_break, at);
                p.toLineEnd();
                return .leaf;
            }
        }
        if (!indented or kind == .list) if (p.listMarker(kind)) |m| {
            try p.closeUnmatched();
            const t = p.tip();
            if (t.kind != .list or t.ordered != m.ordered or t.marker != m.char) {
                try p.addChild(.list, at);
                const o = p.tip();
                o.ordered = m.ordered;
                o.marker = m.char;
                p.record().data = .{ .list = .{ .ordered = m.ordered, .start = m.start, .tight = true, .marker = m.char } };
            }
            try p.addChild(.item, at);
            p.tip().content = m.content;
            return .container;
        };
        if (indented and p.tip().kind != .paragraph and !p.blank) {
            p.advanceOffset(4, true);
            try p.closeUnmatched();
            try p.addChild(.code_block, p.offset);
            p.record().data = .{ .code = .{ .fenced = false, .info = .init(p.line_start + p.offset, p.line_start + p.offset) } };
            return .leaf;
        }
        return .none;
    }

    const ListMarker = struct { ordered: bool, start: u32, char: u8, content: u32 };

    /// A list item's marker at the place reached (§5.2), read and passed
    /// with the spaces after it that its content's indentation takes.
    fn listMarker(p: *Pass, container: Kind) ?ListMarker {
        if (p.indent >= 4) return null;
        const rest = p.line[p.next_nonspace..];
        const m = leaves.listMarker(rest) orelse return null;
        // An item interrupting a paragraph starts at 1 and holds something.
        if (container == .paragraph and ((m.ordered and m.start != 1) or leaves.isBlank(rest[m.width..]))) return null;
        const marker_offset = p.indent;
        p.advanceNextNonspace();
        p.advanceOffset(@intCast(m.width), true);
        const spaces_column = p.column;
        const spaces_offset = p.offset;
        while (true) {
            p.advanceOffset(1, true);
            if (p.column - spaces_column >= 5 or p.offset >= p.line.len or !chars.isSpaceOrTab(p.line[p.offset])) break;
        }
        const blank_item = p.offset >= p.line.len;
        const spaces_after = p.column - spaces_column;
        var padding: u32 = @intCast(m.width + spaces_after);
        if (spaces_after >= 5 or spaces_after < 1 or blank_item) {
            // Content indented five columns or more is indented code
            // inside the item: the item's content starts one space after
            // the marker.
            padding = @intCast(m.width + 1);
            p.column = spaces_column;
            p.offset = spaces_offset;
            p.partial_tab = false;
            if (p.offset < p.line.len and chars.isSpaceOrTab(p.line[p.offset])) p.advanceOffset(1, true);
        }
        return .{ .ordered = m.ordered, .start = m.start, .char = m.char, .content = marker_offset + padding };
    }

    /// The record of the block at the tip.
    fn record(p: *Pass) *Block {
        return &p.blocks.items[p.tip().block];
    }

    /// Opens a block of `kind` at byte `at` of the line, closing the tip
    /// until it can hold one.
    fn addChild(p: *Pass, kind: Kind, at: u32) Error!void {
        while (!p.tip().kind.holds(kind)) try p.closeTip();
        const parent_index = p.stack.items.len - 1;
        const offset = p.line_start + at;
        const depth = parent_index;
        if (kind.container() and depth + 1 > p.limits.depth.widen(usize)) return p.fail(.depth, offset, error.TooDeep);
        const count = aegis.units.Count(Limits.Block, u32).fromRaw(@intCast(p.blocks.items.len));
        if (count.compare(p.limits.blocks) != .lt) return p.fail(.blocks, offset, error.TooManyBlocks);
        const parent = &p.stack.items[parent_index];
        // A blank line between two of a list's items, or between two
        // blocks an item holds, makes the list loose.
        if (parent.last_child_end) |end| if (end + 1 < p.line_number) switch (parent.kind) {
            .list => p.blocks.items[parent.block].data.list.tight = false,
            .item => p.blocks.items[p.stack.items[parent_index - 1].block].data.list.tight = false,
            else => {},
        };
        parent.has_children = true;
        p.work += 1;
        try p.blocks.append(p.gpa, .{
            .kind = kind.record(),
            .depth = @intCast(depth),
            .span = .init(offset, offset),
            .first_line = @intCast(p.lines.items.len),
        });
        try p.stack.append(p.gpa, .{ .kind = kind, .block = @intCast(p.blocks.items.len - 1), .end_line = p.line_number });
    }

    /// The rest of the line, from the place reached, to the leaf at the
    /// tip; a tab taken in part gives its rest as spaces.
    fn addLine(p: *Pass) Error!void {
        var start = p.offset;
        var spaces: u8 = 0;
        if (p.partial_tab) {
            start += 1;
            spaces = @intCast(4 - p.column % 4);
        }
        try p.lines.append(p.gpa, .{ .start = p.line_start + start, .end = p.line_start + @as(u32, @intCast(p.line.len)), .spaces = spaces });
        p.record().line_count += 1;
    }

    /// The line belongs to the tip, and so to every block open: its end is
    /// theirs, passed down to each as its child closes.
    fn touch(p: *Pass) void {
        const t = p.tip();
        if (t.kind == .document) return;
        t.end_line = p.line_number;
        p.blocks.items[t.block].span.end = .fromRaw(p.line_start + @as(u32, @intCast(p.line.len)));
    }

    fn closeUnmatched(p: *Pass) Error!void {
        if (p.all_closed) return;
        while (p.stack.items.len - 1 > p.matched) try p.closeTip();
        p.all_closed = true;
    }

    /// Closes the block at the tip: its last steps, then its end given to
    /// its parent.
    fn closeTip(p: *Pass) Error!void {
        const open = p.stack.pop() orelse aegis.assert.never("the document stays open");
        p.work += 1;
        var end = p.blocks.items[open.block].span.end;
        switch (open.kind) {
            .document => aegis.assert.never("the document stays open"),
            .paragraph => try p.closeParagraph(open),
            .code_block => if (!open.fenced) p.trimIndented(open),
            else => {},
        }
        // A paragraph of definitions alone has left the table; any other
        // leaf's span holds its lines, blank ones at its end included.
        if (open.block < p.blocks.items.len) {
            const b = &p.blocks.items[open.block];
            if (b.line_count != 0) {
                const last: Span.Offset = .fromRaw(p.lines.items[b.first_line + b.line_count - 1].end);
                if (last.compare(b.span.end) == .gt) b.span.end = last;
            }
            end = b.span.end;
            p.measure(b.*);
        }
        const parent = p.tip();
        parent.last_child_end = open.end_line;
        if (parent.kind == .document) return;
        parent.end_line = @max(parent.end_line, open.end_line);
        const own = &p.blocks.items[parent.block].span.end;
        if (end.compare(own.*) == .gt) own.* = end;
    }

    fn measure(p: *Pass, b: Block) void {
        if (b.line_count == 0) return;
        var size: u32 = 0;
        for (p.lines.items[b.first_line..][0..b.line_count]) |l| size += l.end - l.start + l.spaces + 1;
        p.largest_leaf = @max(p.largest_leaf, size);
    }

    /// A paragraph's definitions taken; a paragraph of nothing else is no
    /// block of the table, though a list's looseness counted it as one.
    fn closeParagraph(p: *Pass, open: Open) Error!void {
        try p.takeDefinitions(open.block);
        const b = &p.blocks.items[open.block];
        if (b.line_count == 0) {
            aegis.assert.invariant(open.block == p.blocks.items.len - 1, "a paragraph closes as the last block opened");
            p.lines.shrinkRetainingCapacity(b.first_line);
            p.blocks.shrinkRetainingCapacity(open.block);
            return;
        }
        const first = p.lines.items[b.first_line];
        b.span.start = .fromRaw(first.start - @intFromBool(first.spaces != 0));
    }

    /// Indented code's trailing blank lines are not its own (§4.4).
    fn trimIndented(p: *Pass, open: Open) void {
        const b = &p.blocks.items[open.block];
        while (b.line_count > 0 and leaves.isBlank(p.lines.items[b.first_line + b.line_count - 1].of(p.text))) b.line_count -= 1;
        aegis.assert.invariant(b.line_count > 0, "indented code begins with a line that is not blank");
        const first = p.lines.items[b.first_line];
        const last = p.lines.items[b.first_line + b.line_count - 1];
        b.span = .init(first.start - @intFromBool(first.spaces != 0), last.end);
    }

    /// The link reference definitions a paragraph begins with, into the
    /// label table, their lines taken from it.
    fn takeDefinitions(p: *Pass, block: u32) Error!void {
        const b = &p.blocks.items[block];
        if (b.line_count == 0) return;
        const lines = p.lines.items[b.first_line..][0..b.line_count];
        p.paragraph = lines;
        if (lines[0].spaces != 0 or lines[0].start >= p.text.len or p.text[lines[0].start] != '[') return;
        p.joined.clearRetainingCapacity();
        p.joined_lines.clearRetainingCapacity();
        for (lines, 0..) |l, i| {
            if (i != 0) try p.joined.append(p.gpa, '\n');
            try p.joined_lines.append(p.gpa, p.joined.items.len);
            try p.joined.appendNTimes(p.gpa, ' ', l.spaces);
            try p.joined.appendSlice(p.gpa, l.of(p.text));
        }
        p.work += p.joined.items.len;
        var at: usize = 0;
        var cursor: usize = 0;
        while (at < p.joined.items.len and p.joined.items[at] == '[') {
            const d = references.parse(p.joined.items[at..]) orelse break;
            if (!try p.define(d, at, &cursor)) break;
            at += d.len;
        }
        // `define` added references and keys, never lines: `b` still holds.
        if (at == 0) return;
        var taken: u32 = 0;
        while (taken < lines.len and p.joined_lines.items[taken] < at) taken += 1;
        b.first_line += taken;
        b.line_count -= taken;
    }

    /// A definition read at `at` in the joined lines, into the label
    /// table; false where its label normalizes to nothing.
    fn define(p: *Pass, d: references.Definition, at: usize, cursor: *usize) Error!bool {
        const key_start = p.keys.items.len;
        const label = p.joined.items[at + d.label.start .. at + d.label.end];
        var keys: std.Io.Writer.Allocating = .fromArrayList(p.gpa, &p.keys);
        defer p.keys = keys.toArrayList();
        references.normalize(label, &keys.writer, &p.scratch, p.gpa) catch return error.OutOfMemory;
        if (keys.writer.end == key_start) return false;
        p.work += d.len;
        const where = p.source(at, cursor);
        const count = aegis.units.Count(Limits.Reference, u32).fromRaw(@intCast(p.references.items.len));
        if (count.compare(p.limits.references) != .lt) return p.fail(.references, where, error.TooManyReferences);
        // In the text's order: the cursor only moves forward.
        const label_span = p.span(at, d.label, cursor);
        const destination = p.span(at, d.destination, cursor);
        const title: ?Span = if (d.title) |t| p.span(at, t, cursor) else null;
        try p.references.append(p.gpa, .{
            .label = label_span,
            .destination = destination,
            .title = title,
            .key = .{ .start = @intCast(key_start), .len = @intCast(keys.writer.end - key_start) },
        });
        return true;
    }

    fn span(p: *Pass, at: usize, r: references.Range, cursor: *usize) Span {
        const start = p.source(at + r.start, cursor);
        return .init(start, @max(start, p.source(at + r.end, cursor)));
    }

    /// The text's offset of joined offset `j`; `cursor`, the line last
    /// mapped, only moves forward.
    fn source(p: *Pass, j: usize, cursor: *usize) u32 {
        const begins = p.joined_lines.items;
        while (cursor.* + 1 < begins.len and begins[cursor.* + 1] <= j) cursor.* += 1;
        const l = p.paragraph[cursor.*];
        const into = j - begins[cursor.*];
        if (into < l.spaces) return l.start - 1;
        return l.start + @as(u32, @intCast(into - l.spaces));
    }
};
