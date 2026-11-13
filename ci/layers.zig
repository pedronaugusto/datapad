//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{ "src/Span.zig", "src/Limits.zig", "src/Options.zig" } },
    .{ .name = "scan", .patterns = &.{ "src/scan/chars.zig", "src/scan/line.zig", "src/scan/entities.zig" } },
    .{ .name = "scan entry", .patterns = &.{"src/scan.zig"} },
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
    "src/datapad.zig",
};
