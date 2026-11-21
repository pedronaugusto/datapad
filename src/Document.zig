//! A parsed document: the text it borrows and the block pass's tables, the
//! block table (every block in document order), the content lines of its
//! leaves, the line table and the label table of link reference
//! definitions.
const Document = @This();
const std = @import("std");
const aegis = @import("aegis");
const Span = @import("Span.zig");
const Limits = @import("Limits.zig");
const Extensions = @import("Options.zig").Extensions;
const pass = @import("block.zig");
const containers = pass.containers;
const references = pass.references;

pub const Block = pass.Block;
pub const Reference = references.Reference;

gpa: std.mem.Allocator,
source: []const u8,
tables: containers.Tables,
/// The syntax it was parsed with, which the inline pass and the writer read too.
extensions: Extensions,
/// The limits it was parsed under: `Events` checks `expansion`.
limits: Limits,
/// Where `parse`, and `Events.next` at the expansion limit, say which
/// limit a refusal met.
diagnostics: ?*Limits.Diagnostic,

pub const Options = struct {
    extensions: Extensions = .gfm,
    limits: Limits = .{},
    /// Filled where `parse` refuses on a limit.
    diagnostics: ?*Limits.Diagnostic = null,
};

/// Every refusal is a limit, named: Markdown has no invalid document.
pub const ParseError = containers.Error;

/// Runs the block pass. Borrows `text` until `deinit`.
pub fn parse(gpa: std.mem.Allocator, input: aegis.input.Untrusted([]const u8), options: Options) ParseError!Document {
    return input.parse(Run{ .gpa = gpa, .options = options }, Run.read);
}

const Run = struct {
    gpa: std.mem.Allocator,
    options: Options,

    fn read(r: Run, bytes: []const u8) ParseError!Document {
        return .{
            .gpa = r.gpa,
            .source = bytes,
            .tables = try containers.run(r.gpa, bytes, r.options.extensions, r.options.limits, r.options.diagnostics),
            .extensions = r.options.extensions,
            .limits = r.options.limits,
            .diagnostics = r.options.diagnostics,
        };
    }
};

pub fn deinit(document: *Document) void {
    document.tables.deinit(document.gpa);
    document.* = undefined;
}

pub fn text(document: *const Document) []const u8 {
    return document.source;
}

/// Every block, a container before what it holds.
pub fn blocks(document: *const Document) []const Block {
    return document.tables.blocks;
}

/// A leaf's content lines.
pub fn lines(document: *const Document, block: Block) []const Block.Line {
    return document.tables.lines[block.first_line..][0..block.line_count];
}

/// A line and a column, both from 1, the column in bytes.
pub const Position = struct { line: u32, column: u32 };

/// Where `offset` is: an offset at a line ending is on the line it ends. A column is a
/// u32 as the offset is: the one offset with none is u32's last on the text's first line.
pub fn lineOf(document: *const Document, offset: Span.Offset) Position {
    const starts = document.tables.line_starts;
    // The last line starting at or before `offset`.
    var low: usize = 0;
    var high: usize = starts.len;
    while (high - low > 1) {
        const mid = low + (high - low) / 2;
        if (Span.Offset.fromRaw(starts[mid]).compare(offset) != .gt) low = mid else high = mid;
    }
    const into = offset.sub(.fromRaw(starts[low])) catch aegis.assert.never("the line found starts at or before the offset");
    const column = into.add(.fromRaw(1)) catch aegis.assert.never("a column within u32: no offset is u32's last on the text's first line");
    return .{ .line = @intCast(low + 1), .column = column.raw() };
}

/// Every definition in document order, a label given twice included.
pub fn definitions(document: *const Document) []const Reference {
    return document.tables.references;
}

/// A definition's normalized label.
pub fn keyOf(document: *const Document, reference: Reference) []const u8 {
    return document.tables.keys[reference.key.start..][0..reference.key.len];
}

/// The definition a link with the normalized label `normalized` resolves
/// to: the first of that label.
pub fn find(document: *const Document, normalized: []const u8) ?Reference {
    const labels = document.tables.labels;
    var low: usize = 0;
    var high: usize = labels.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const r = document.tables.references[labels[mid]];
        switch (std.mem.order(u8, document.keyOf(r), normalized)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return r,
        }
    }
    return null;
}

/// A label as links are matched by it (CommonMark §6.3): whitespace runs
/// collapsed and trimmed, then Unicode case folded. `scratch` is reused.
pub fn normalizeLabel(gpa: std.mem.Allocator, label: []const u8, w: *std.Io.Writer, scratch: *std.ArrayList(u8)) (std.Io.Writer.Error || error{OutOfMemory})!void {
    return references.normalize(label, w, scratch, gpa);
}

/// Front matter: its language, its whole span (fences included) and its
/// body's, from its first line's start to its last line's end.
pub const FrontMatter = struct {
    format: Format,
    span: Span,
    body: Span,

    /// YAML between `---` lines, or TOML between `+++` lines.
    pub const Format = pass.front_matter.Format;
};

/// The front matter the text starts with, where `Extensions.front_matter`
/// read it.
pub fn frontMatter(document: *const Document) ?FrontMatter {
    const all = document.blocks();
    if (all.len == 0 or all[0].kind != .front_matter) return null;
    const b = all[0];
    const body_lines = document.lines(b);
    // An empty body lies at the closing line's start: the opening line's end, its line ending passed.
    const body: Span = if (body_lines.len == 0) empty: {
        const at = document.tables.line_starts[1];
        break :empty .init(at, at);
    } else .init(body_lines[0].start, body_lines[body_lines.len - 1].end);
    return .{ .format = b.data.front_matter, .span = b.span, .body = body };
}

/// What the block pass measured.
pub const Stats = struct {
    /// The most bytes a leaf's lines hold, a line feed counted after each:
    /// what the inline pass's scratch is sized by.
    largest_leaf: u32,
    /// The steps the pass took, bytes read and blocks continued, opened and
    /// closed: linear in the text.
    work: u64,
};

pub fn stats(document: *const Document) Stats {
    return .{ .largest_leaf = document.tables.largest_leaf, .work = document.tables.work };
}

test {
    _ = pass;
}
