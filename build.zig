// SPDX-License-Identifier: BSL-1.0

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

    // fluxion-dyn: finding a shared library at run time and filling a struct
    // of function pointers, which is the general form of what `library` does.
    const dyn = b.dependency("fluxion_dyn", .{
        .target = target,
        .optimize = optimize,
    });

    // The importable module. Consumers do:
    //   const vk = @import("fluxion_vulkan");
    const mod = b.addModule("fluxion_vulkan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_dyn", .module = dyn.module("fluxion_dyn") },
        },
    });

    // The generator: `tools/genvk.zig` reads the registry and `tools/wanted.zon`
    // and writes `src/gen/`. It runs on the machine building, whatever the
    // target is, and it is not part of `zig build` or `zig build test`: what it
    // writes is committed, so nobody who only uses this library needs `vk.xml`.
    const genvk_mod = b.createModule(.{
        .root_source_file = b.path("tools/genvk.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    });
    const genvk = b.addExecutable(.{ .name = "genvk", .root_module = genvk_mod });

    // zig build gen -Dvk-xml=<path>: regenerate. zig build gen-check: say whether
    // what is committed is what the generator writes now.
    const vk_xml = b.option([]const u8, "vk-xml", "Path to the Vulkan registry, vk.xml, for `zig build gen`");
    const gen_step = b.step("gen", "Regenerate src/gen from vk.xml and tools/wanted.zon (needs -Dvk-xml=<path>)");
    const gen_check_step = b.step("gen-check", "Fail if src/gen is not what the generator writes from vk.xml (needs -Dvk-xml=<path>)");
    if (vk_xml) |xml_path| {
        const write = b.addRunArtifact(genvk);
        write.addArgs(&.{ xml_path, "tools/wanted.zon", "src/gen" });
        write.setCwd(b.path("."));
        gen_step.dependOn(&write.step);

        const check = b.addRunArtifact(genvk);
        check.addArgs(&.{ xml_path, "tools/wanted.zon", "src/gen", "--check" });
        check.setCwd(b.path("."));
        gen_check_step.dependOn(&check.step);
    } else {
        const missing = "the generator needs the registry: pass -Dvk-xml=<path to vk.xml>";
        gen_step.dependOn(&b.addFail(missing).step);
        gen_check_step.dependOn(&b.addFail(missing).step);
    }

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-vulkan-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    // The layout oracle compiles C with this compiler, and writes its scratch
    // files under the cache directory of wherever it is run from.
    run_tests.setEnvironmentVariable("FLUXION_ZIG", b.graph.zig_exe);
    run_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // The generator's own tests: the XML reader, the names, and - when it is
    // given the registry - that what is committed is what it writes.
    const tool_tests = b.addTest(.{ .name = "genvk-tests", .root_module = genvk_mod });
    const run_tool_tests = b.addRunArtifact(tool_tests);
    run_tool_tests.setCwd(b.path("."));
    if (vk_xml) |xml_path| run_tool_tests.setEnvironmentVariable("FLUXION_VK_XML", xml_path);
    test_step.dependOn(&run_tool_tests.step);

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
