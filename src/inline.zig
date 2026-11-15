//! The inline pass: a leaf's text read into items (`items`) by its
//! constructs (`code`, `html`, `autolink`, `reference`), emphasis matched
//! (`delimiters`), links made (`links`), and the whole of one leaf
//! (`Leaf`), which `Events` gives out.
pub const items = @import("inline/items.zig");
pub const code = @import("inline/code.zig");
pub const html = @import("inline/html.zig");
pub const autolink = @import("inline/autolink.zig");
pub const reference = @import("inline/reference.zig");
pub const delimiters = @import("inline/delimiters.zig");
pub const links = @import("inline/links.zig");
pub const Leaf = @import("inline/Leaf.zig");

test {
    _ = items;
    _ = code;
    _ = html;
    _ = autolink;
    _ = reference;
    _ = delimiters;
    _ = links;
    _ = Leaf;
}
