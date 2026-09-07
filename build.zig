// SPDX-License-Identifier: CC0-1.0

const std = @import("std");

/// The examples, each a program in `examples/` that runs on its own.
///
/// `zig build example` runs the tour; `zig build example-<name>` runs one of
/// the others; `zig build examples` builds all of them without running any,
/// which is what a cross-compiled check wants.
const examples = [_]struct {
    name: []const u8,
    description: []const u8,
}{
    .{ .name = "demo", .description = "the whole library, on whatever this machine has" },
    .{ .name = "headless", .description = "the smallest complete Vulkan program" },
    .{ .name = "devices", .description = "weighing the GPUs and picking one" },
    .{ .name = "table", .description = "declaring and loading your own commands" },
    .{ .name = "adopt", .description = "a Vulkan somebody else already loaded" },
    .{ .name = "compute", .description = "numbers in, shader, numbers out - and checked" },
    .{ .name = "triangle", .description = "hello triangle, rendered offscreen and checked" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable module. Consumers do:
    //   const vk = @import("fluxion_vulkan");
    const mod = b.addModule("fluxion_vulkan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-vulkan-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build example, zig build example-<name>, zig build examples
    const all_examples = b.step("examples", "Build every example without running one");

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_vulkan", .module = mod }},
        });
        const exe = b.addExecutable(.{
            .name = b.fmt("fluxion-vulkan-{s}", .{example.name}),
            .root_module = example_mod,
        });
        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
        // Installed rather than merely compiled, so `zig build examples`
        // leaves five programs in `zig-out/bin` to run by hand.
        all_examples.dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());

        const step = b.step(
            b.fmt("example-{s}", .{example.name}),
            b.fmt("Build and run the {s} example: {s}", .{ example.name, example.description }),
        );
        step.dependOn(&run.step);

        // The tour is what a bare `zig build example` runs.
        if (std.mem.eql(u8, example.name, "demo")) {
            const default = b.step("example", "Build and run the demo tour");
            default.dependOn(&run.step);
        }
    }

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-vulkan",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
