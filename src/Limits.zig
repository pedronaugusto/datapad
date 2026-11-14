//! The bounds on every dimension a document controls. `parse` checks each
//! as the block pass meets it, with a named error; `Events.next` checks
//! `expansion`, which only resolving inlines can know.
const aegis = @import("aegis");
const Span = @import("Span.zig");

/// The domains a count of blocks and of references belongs to.
pub const Block = struct {};
pub const Reference = struct {};

/// Which limit a refusal met.
pub const Limit = enum { input, depth, blocks, references, expansion };

/// Where a refusal met its limit: the offset in the text (for `input`, the
/// limit itself), and which.
pub const Diagnostic = struct {
    offset: Span.Offset = .fromRaw(0),
    limit: Limit = .input,
};

/// The longest text accepted.
input: Span.Offset = .literal("16MiB"),
/// How deep containers (block quotes, lists, list items) may nest.
depth: aegis.int.Ranged(u16, 1, 1024) = .literal(128),
/// Blocks one document may hold.
blocks: aegis.units.Count(Block, u32) = .fromRaw(1 << 20),
/// Link reference definitions one document may hold.
references: aegis.units.Count(Reference, u32) = .fromRaw(1 << 16),
/// Bytes reference links may reproduce in the output (a definition's
/// destination and title, counted at each use): a small definition used a
/// million times is Markdown's billion laughs.
expansion: Span.Offset = .literal("64MiB"),
