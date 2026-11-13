//! datapad: CommonMark and GitHub Flavored Markdown. A pull parser whose
//! every event, and every part of one, carries its exact byte span, and an
//! HTML writer that gives CommonMark's reference output. See README.md and
//! docs/design.md. Being built: its vocabulary and character scanning so far.
pub const Span = @import("Span.zig");
pub const Limits = @import("Limits.zig");
pub const Options = @import("Options.zig");
pub const Extensions = Options.Extensions;

test {
    _ = Span;
    _ = Limits;
    _ = Options;
    _ = @import("scan.zig");
}
