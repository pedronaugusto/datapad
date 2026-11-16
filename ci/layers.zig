//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{ "src/Span.zig", "src/Limits.zig", "src/Options.zig" } },
    .{ .name = "scan", .patterns = &.{ "src/scan/chars.zig", "src/scan/line.zig", "src/scan/entities.zig" } },
    .{ .name = "scan entry", .patterns = &.{"src/scan.zig"} },
    .{ .name = "blocks", .patterns = &.{ "src/block/front_matter.zig", "src/block/Block.zig", "src/block/leaves.zig", "src/block/references.zig", "src/block/containers.zig" } },
    .{ .name = "blocks entry", .patterns = &.{"src/block.zig"} },
    .{ .name = "document", .patterns = &.{"src/Document.zig"} },
    .{ .name = "event vocabulary", .patterns = &.{"src/event.zig"} },
    .{ .name = "inline parts", .patterns = &.{ "src/inline/items.zig", "src/inline/code.zig", "src/inline/html.zig", "src/inline/autolink.zig", "src/inline/reference.zig", "src/inline/extended.zig" } },
    .{ .name = "inline rules", .patterns = &.{ "src/inline/delimiters.zig", "src/inline/links.zig" } },
    .{ .name = "inlines", .patterns = &.{"src/inline/Leaf.zig"} },
    .{ .name = "inlines entry", .patterns = &.{"src/inline.zig"} },
    .{ .name = "events", .patterns = &.{"src/Events.zig"} },
    .{ .name = "writers", .patterns = &.{"src/html.zig"} },
    .{ .name = "public", .patterns = &.{"src/datapad.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{ "std", "aegis", "xenoglyph", "shakedown", "builtin" },
    },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

/// A family package is reached through its module name, never by a path into it.
pub const references: []const gantry.rules.ReferenceRule = &package_references;

/// Every production source, so a file added without a layer is refused.
pub const required = [_][]const u8{
    "src/Span.zig",
    "src/Limits.zig",
    "src/Options.zig",
    "src/scan/chars.zig",
    "src/scan/line.zig",
    "src/scan/entities.zig",
    "src/scan.zig",
    "src/block/front_matter.zig",
    "src/block/Block.zig",
    "src/block/leaves.zig",
    "src/block/references.zig",
    "src/block/containers.zig",
    "src/block.zig",
    "src/Document.zig",
    "src/event.zig",
    "src/inline/items.zig",
    "src/inline/code.zig",
    "src/inline/html.zig",
    "src/inline/autolink.zig",
    "src/inline/reference.zig",
    "src/inline/extended.zig",
    "src/inline/delimiters.zig",
    "src/inline/links.zig",
    "src/inline/Leaf.zig",
    "src/inline.zig",
    "src/Events.zig",
    "src/html.zig",
    "src/datapad.zig",
};
