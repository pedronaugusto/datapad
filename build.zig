const std = @import("std");

/// What a project that depends on datapad builds: the `datapad` module, on
/// aegis and xenoglyph. The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = datapadModule(b, b, target, optimize);
}

fn datapadModule(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.addModule("datapad", .{ .root_source_file = p.path("src/datapad.zig"), .target = target, .optimize = optimize });
    addSourceImports(p, module, target, optimize);
    return module;
}

/// What datapad's sources import: aegis and xenoglyph.
fn addSourceImports(p: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    module.addImport("xenoglyph", p.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph"));
}

/// datapad's development: its tests and checks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("datapad", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    const test_module = b.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "shakedown", .module = shakedown.module("shakedown") }},
    });
    addSourceImports(p, test_module, target, optimize);
    const tests = b.addTest(.{ .name = "datapad-tests", .filters = filters, .root_module = test_module });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    b.getInstallStep().dependOn(&tests.step);
    // The release tier runs every property under Zig's fuzzer (each shakedown
    // property is a fuzz target) and the suite with safety on.
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
    });
}
