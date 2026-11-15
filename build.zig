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
    // The CommonMark spec, read by the spec runner as it is (testdata/commonmark).
    test_module.addAnonymousImport("commonmark_spec", .{ .root_source_file = p.path("testdata/commonmark/spec.txt") });
    test_module.addAnonymousImport("gfm_spec", .{ .root_source_file = p.path("testdata/gfm/spec.txt") });
    const tests = b.addTest(.{ .name = "datapad-tests", .filters = filters, .root_module = test_module });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);

    // The entity table's generator, on the build host: `entities` writes
    // src/scan/entities.zig from WHATWG's entities.json, and the tests fail
    // unless writing it again gives the same bytes.
    const generator = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{ .root_source_file = p.path("tools/generate.zig"), .target = b.graph.host, .optimize = .safe }),
    });
    const write = b.addRunArtifact(generator);
    write.setCwd(p.path("."));
    write.addArgs(&.{ "testdata/whatwg/entities.json", "src/scan/entities.zig" });
    write.has_side_effects = true;
    b.step("entities", "Write src/scan/entities.zig from testdata/whatwg/entities.json").dependOn(&write.step);
    const compare = b.addRunArtifact(generator);
    compare.setCwd(p.path("."));
    compare.addArgs(&.{ "testdata/whatwg/entities.json", "src/scan/entities.zig", "--check" });
    compare.has_side_effects = true;
    test_step.dependOn(&compare.step);
    check.dependOn(&generator.step);
    b.getInstallStep().dependOn(&tests.step);
    // The release tier runs every property under Zig's fuzzer (each shakedown
    // property is a fuzz target) and the suite with safety on.
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
    });
}
