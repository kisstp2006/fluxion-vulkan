// SPDX-License-Identifier: BSL-1.0

//! The ABI generator: Vulkan's registry in, this library's declarations out.
//!
//!     zig build gen -Dvk-xml=<path to vk.xml>
//!
//! reads `vk.xml` and `tools/wanted.zon` and writes four files into `src/gen/`:
//!
//!   `types.zig`     handles, enums, flags, structs, function pointer types
//!   `commands.zig`  the three command tables - global, instance, device
//!   `layout.zig`    what Zig makes of every struct, and every enumerant's number
//!   `layout.c`      what the C headers make of the same, to be compared with it
//!
//! **What is generated is chosen by data, not by code.** `wanted.zon` lists the
//! commands by tier, the extra structs and enums, and the extensions whose
//! enumerants count; nothing in this directory contains the name of a Vulkan
//! command, struct or enum. The generator resolves what the wanted things need,
//! follows member types, aliases and function pointers to the end, and writes
//! them in the registry's own order - so the same registry and the same wanted
//! list give the same bytes, every time.
//!
//! It fails loudly on what it does not understand: a bit-field, a type whose
//! platform declaration `wanted.zon` does not supply, two names that come out as
//! the same Zig name, an extension a wanted command needs that is not listed. A
//! generator that guesses writes wrong ABI without saying so.
//!
//!     genvk <vk.xml> <wanted.zon> <out dir>            write the files
//!     genvk <vk.xml> <wanted.zon> <out dir> --check    exit 1 if they differ

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const xml = @import("xml.zig");
pub const registry = @import("registry.zig");
pub const names = @import("names.zig");
pub const gen = @import("gen.zig");
pub const emit = @import("emit.zig");

pub const Outputs = gen.Outputs;
pub const Wanted = gen.Wanted;

/// The file names, in the order they are written.
pub const files = [_][]const u8{ "types.zig", "commands.zig", "layout.zig", "layout.c" };

/// What `generate` says when it fails.
pub fn lastError() []const u8 {
    return gen.last_error;
}

/// Everything, from the registry's text and the wanted list's.
pub fn generate(arena: Allocator, registry_xml: []const u8, wanted_source: [:0]const u8) gen.Error!Outputs {
    var diagnostic: xml.Diagnostic = .{};
    const root = xml.parse(arena, registry_xml, &diagnostic) catch |err| switch (err) {
        error.Syntax => return gen.fail(arena, "vk.xml, {f}", .{diagnostic}),
        else => |e| return e,
    };

    var zon_diagnostic: std.zon.parse.Diagnostics = .{};
    const wanted = std.zon.parse.fromSliceAlloc(gen.Wanted, arena, wanted_source, &zon_diagnostic, .{}) catch |err| switch (err) {
        error.ParseZon => return gen.fail(arena, "wanted.zon: {f}", .{zon_diagnostic}),
        else => |e| return e,
    };

    const reg = registry.load(arena, root, wanted.api) catch |err| switch (err) {
        error.Registry => return gen.fail(arena, "vk.xml: {s}", .{registry.last_error}),
        else => |e| return e,
    };

    // The generated files say which registry they came from, and a registry that
    // does not say is one whose output nobody could trace.
    if (reg.header_version.len == 0) return gen.fail(arena, "vk.xml does not say its VK_HEADER_VERSION", .{});

    var g = try gen.Generator.init(arena, reg, wanted);
    try g.select();
    try g.addCommands(wanted.global, .global);
    try g.addCommands(wanted.instance, .instance);
    try g.addCommands(wanted.device, .device);
    for (wanted.structs) |name| try g.need(name);
    for (wanted.enums) |name| try g.need(name);
    for (wanted.constants) |name| try g.useConstant(name);
    try g.closure();

    var rows: std.ArrayList(emit.Row) = .empty;
    const types = try emit.types(&g, &rows);
    const commands = try emit.commands(&g);
    g.summary.layout_rows = rows.items.len;
    g.summary.header_version = reg.header_version;

    return .{
        .types = try formatted(arena, types, "types.zig"),
        .commands = try formatted(arena, commands, "commands.zig"),
        .layout_zig = try formatted(arena, try emit.layoutZig(&g, rows.items), "layout.zig"),
        .layout_c = try emit.layoutC(&g, rows.items),
        .summary = g.summary,
    };
}

/// Zig source, parsed and written out again the way `zig fmt` writes it.
///
/// Two things at once. What the generator writes is what `zig fmt --check`
/// accepts, whatever the emitter's own spacing was; and it is *parsed*, so a
/// generator that writes something that is not Zig fails here, by file and
/// line, rather than in whoever compiles it next.
fn formatted(arena: Allocator, source: []const u8, name: []const u8) gen.Error![]const u8 {
    const terminated = try arena.dupeZ(u8, source);
    const tree = try std.zig.Ast.parse(arena, terminated, .zig);
    if (tree.errors.len > 0) {
        const first = tree.errors[0];
        const location = tree.tokenLocation(0, first.token);
        var message: Io.Writer.Allocating = .init(arena);
        tree.renderError(first, &message.writer) catch return error.OutOfMemory;
        return gen.fail(arena, "the generator wrote {s} that is not Zig, at line {d}: {s}", .{ name, location.line + 1, message.written() });
    }
    return tree.renderAlloc(arena);
}

/// The bytes of one of the four files by name.
pub fn contentsOf(outputs: Outputs, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "types.zig")) return outputs.types;
    if (std.mem.eql(u8, name, "commands.zig")) return outputs.commands;
    if (std.mem.eql(u8, name, "layout.zig")) return outputs.layout_zig;
    if (std.mem.eql(u8, name, "layout.c")) return outputs.layout_c;
    return null;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: genvk <vk.xml> <wanted.zon> <out dir> [--check]\n", .{});
        std.process.exit(2);
    }
    const check = args.len > 4 and std.mem.eql(u8, args[4], "--check");

    const cwd = Io.Dir.cwd();
    const registry_xml = cwd.readFileAlloc(io, args[1], arena, .limited(256 << 20)) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ args[1], @errorName(err) });
        std.process.exit(2);
    };
    const wanted_source = cwd.readFileAllocOptions(io, args[2], arena, .limited(16 << 20), .of(u8), 0) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ args[2], @errorName(err) });
        std.process.exit(2);
    };

    const outputs = generate(arena, registry_xml, wanted_source) catch |err| switch (err) {
        error.Generate => {
            std.debug.print("genvk: {s}\n", .{lastError()});
            std.process.exit(1);
        },
        else => |e| return e,
    };

    var stderr_buffer: [1024]u8 = undefined;
    var stderr: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    defer stderr.interface.flush() catch {};

    if (check) {
        var differs = false;
        for (files) |name| {
            const path = try std.fs.path.join(arena, &.{ args[3], name });
            const on_disk = cwd.readFileAlloc(io, path, arena, .limited(256 << 20)) catch |err| {
                try stderr.interface.print("genvk: cannot read {s}: {s}\n", .{ path, @errorName(err) });
                differs = true;
                continue;
            };
            if (!std.mem.eql(u8, on_disk, contentsOf(outputs, name).?)) {
                try stderr.interface.print("genvk: {s} is not what the generator writes\n", .{path});
                differs = true;
            }
        }
        if (differs) {
            try stderr.interface.flush();
            std.process.exit(1);
        }
        try stderr.interface.print("genvk: {s} is up to date\n{f}", .{ args[3], outputs.summary });
        return;
    }

    try cwd.createDirPath(io, args[3]);
    for (files) |name| {
        const path = try std.fs.path.join(arena, &.{ args[3], name });
        try cwd.writeFile(io, .{ .sub_path = path, .data = contentsOf(outputs, name).? });
        try stderr.interface.print("genvk: wrote {s} ({d} bytes)\n", .{ path, contentsOf(outputs, name).?.len });
    }
    try stderr.interface.print("{f}", .{outputs.summary});
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = xml;
    _ = registry;
    _ = names;
}

test "the committed files are what the generator writes, byte for byte" {
    // Needs the registry, which is not in this repository: `zig build test
    // -Dvk-xml=<path>` passes it. Without it the test says so and skips.
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const xml_path = env.get("FLUXION_VK_XML") orelse {
        std.debug.print("\n  skipped: no registry to regenerate from (pass -Dvk-xml=<path to vk.xml>)\n", .{});
        return error.SkipZigTest;
    };

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    const registry_xml = try cwd.readFileAlloc(io, xml_path, arena, .limited(256 << 20));
    const wanted_source = try cwd.readFileAllocOptions(io, "tools/wanted.zon", arena, .limited(16 << 20), .of(u8), 0);

    const first = generate(arena, registry_xml, wanted_source) catch |err| {
        std.debug.print("\n  genvk: {s}\n", .{lastError()});
        return err;
    };
    // Twice, from scratch: nothing may depend on which run this is.
    const second = try generate(arena, registry_xml, wanted_source);

    for (files) |name| {
        const expected = contentsOf(first, name).?;
        try testing.expectEqualStrings(expected, contentsOf(second, name).?);

        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "src/gen/{s}", .{name});
        const on_disk = try cwd.readFileAlloc(io, path, arena, .limited(256 << 20));
        if (!std.mem.eql(u8, on_disk, expected)) {
            std.debug.print("\n  {s} is not what the generator writes: run `zig build gen -Dvk-xml=...`\n", .{path});
            return error.TestExpectedEqual;
        }
    }
}

/// A registry small enough to read, with one struct that needs an extension's
/// tag and one command that uses it. The struct's members are in two halves so
/// that a test can put a bit-field between them.
const fragment_head =
    \\<registry>
    \\  <tags><tag name="KHR"/></tags>
    \\  <types>
    \\    <type category="define">#define <name>VK_HEADER_VERSION</name> 1</type>
    \\    <type category="basetype">typedef <type>uint32_t</type> <name>VkBool32</name>;</type>
    \\    <type category="handle"><type>VK_DEFINE_HANDLE</type>(<name>VkInstance</name>)</type>
    \\    <type category="enum" name="VkStructureType"/>
    \\    <type category="struct" name="VkThing">
    \\      <member values="VK_STRUCTURE_TYPE_THING"><type>VkStructureType</type> <name>sType</name></member>
    \\      <member optional="true">const <type>void</type>* <name>pNext</name></member>
;

const fragment_bit_field =
    \\      <member><type>uint32_t</type> <name>bits</name>:8</member>
;

const fragment_tail =
    \\    </type>
    \\  </types>
    \\  <enums name="VkStructureType" type="enum"><enum value="0" name="VK_STRUCTURE_TYPE_OTHER"/></enums>
    \\  <commands>
    \\    <command><proto><type>void</type> <name>vkUseThing</name></proto>
    \\      <param><type>VkInstance</type> <name>instance</name></param>
    \\      <param>const <type>VkThing</type>* <name>pThing</name></param>
    \\    </command>
    \\  </commands>
    \\  <feature api="vulkan" name="VK_VERSION_1_0" number="1.0"><require><command name="vkUseThing"/></require></feature>
    \\  <extensions>
    \\    <extension name="VK_KHR_thing" number="1" supported="vulkan">
    \\      <require><enum offset="0" extends="VkStructureType" name="VK_STRUCTURE_TYPE_THING"/></require>
    \\    </extension>
    \\  </extensions>
    \\</registry>
;

const fragment = fragment_head ++ "\n" ++ fragment_tail;
const fragment_with_bit_field = fragment_head ++ "\n" ++ fragment_bit_field ++ "\n" ++ fragment_tail;

fn wantedFor(comptime extensions: []const u8, comptime global: []const u8, comptime instance: []const u8) [:0]const u8 {
    return ".{ .versions = .{\"VK_VERSION_1_0\"}, .baseline = \"VK_VERSION_1_0\", .extensions = .{" ++ extensions ++
        "}, .result = \"VkResult\", .dispatch = .{ .instance = .{\"VkInstance\"}, .device = .{} }, .global = .{" ++
        global ++ "}, .instance = .{" ++ instance ++ "}, .device = .{} }";
}

test "what a wanted list leaves out is refused by name, and told where to go" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A struct whose sType comes from an extension that is not listed: the
    // generator stops and says which tag it could not find.
    try testing.expectError(error.Generate, generate(arena, fragment, wantedFor("", "", "\"vkUseThing\"")));
    try testing.expect(std.mem.indexOf(u8, lastError(), "VK_STRUCTURE_TYPE_THING") != null);
    try testing.expect(std.mem.indexOf(u8, lastError(), "comes from") != null or std.mem.indexOf(u8, lastError(), ".extensions") != null);

    // With the extension listed the same list works.
    const outputs = try generate(arena, fragment, wantedFor("\"VK_KHR_thing\"", "", "\"vkUseThing\""));
    try testing.expect(std.mem.indexOf(u8, outputs.types, "s_type: StructureType = .thing,") != null);
    try testing.expect(std.mem.indexOf(u8, outputs.commands, "useThing: *const fn (") != null);

    // A command in the wrong tier is refused, and told where it belongs.
    try testing.expectError(error.Generate, generate(arena, fragment, wantedFor("\"VK_KHR_thing\"", "\"vkUseThing\"", "")));
    try testing.expect(std.mem.indexOf(u8, lastError(), "move it to .instance") != null);

    // A command the registry does not have.
    try testing.expectError(error.Generate, generate(arena, fragment, wantedFor("", "", "\"vkNoSuchThing\"")));
    try testing.expect(std.mem.indexOf(u8, lastError(), "vkNoSuchThing") != null);

    // A bit-field is refused loudly, with the member named: `VkThing.bits`.
    try testing.expectError(error.Generate, generate(arena, fragment_with_bit_field, wantedFor("\"VK_KHR_thing\"", "", "\"vkUseThing\"")));
    try testing.expect(std.mem.indexOf(u8, lastError(), "VkThing.bits is a bit-field") != null);
}
