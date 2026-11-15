//! datapad: CommonMark and GitHub Flavored Markdown. A pull parser whose
//! every event, and every part of one, carries its exact byte span, and an
//! HTML writer that gives CommonMark's reference output. See README.md and
//! docs/design.md. Being built: its vocabulary, character scanning, the
//! block pass and the events with CommonMark's inlines so far.
pub const Span = @import("Span.zig");
pub const Limits = @import("Limits.zig");
pub const Options = @import("Options.zig");
pub const Extensions = Options.Extensions;
pub const Document = @import("Document.zig");
pub const Events = @import("Events.zig");
pub const Event = Events.Event;
pub const Node = Events.Node;
pub const Link = Events.Link;
pub const html = @import("html.zig");

test {
    _ = Span;
    _ = Limits;
    _ = Options;
    _ = @import("scan.zig");
    _ = Document;
    _ = Events;
    _ = html;
}
