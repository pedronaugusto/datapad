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
            .tables = try containers.run(r.gpa, bytes, r.options.limits, r.options.diagnostics),
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

/// Where `offset` is: an offset at a line ending is on the line it ends.
pub fn lineOf(document: *const Document, offset: Span.Offset) Position {
    const starts = document.tables.line_starts;
    const at = offset.raw();
    // The last line starting at or before `at`.
    var low: usize = 0;
    var high: usize = starts.len;
    while (high - low > 1) {
        const mid = low + (high - low) / 2;
        if (starts[mid] <= at) low = mid else high = mid;
    }
    return .{ .line = @intCast(low + 1), .column = at - starts[low] + 1 };
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
