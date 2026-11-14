//! The block pass: the blocks a line starts (`leaves`), link reference
//! definitions (`references`), the container stack that reads the text into
//! the block table (`containers`), and the table's record (`Block`).
pub const Block = @import("block/Block.zig");
pub const leaves = @import("block/leaves.zig");
pub const references = @import("block/references.zig");
pub const containers = @import("block/containers.zig");

test {
    _ = leaves;
    _ = references;
    _ = containers;
}
