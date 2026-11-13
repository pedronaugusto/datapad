//! Reading the text a character at a time: CommonMark's character classes,
//! columns with tab stops, and the HTML5 named character references.
pub const chars = @import("scan/chars.zig");
pub const line = @import("scan/line.zig");
pub const entities = @import("scan/entities.zig");

test {
    _ = chars;
    _ = line;
    _ = entities;
}
