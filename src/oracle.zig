// SPDX-License-Identifier: BSL-1.0

//! Internal plumbing: the generated ABI, checked against the real headers.
//!
//! A wrong member order, a wrong `sType` or a wrong enum value is silent until a
//! driver crashes, so the generated declarations are not trusted: they are
//! measured. `gen/layout.c` is generated from the same wanted list as the Zig,
//! and includes the real `vulkan_core.h`; it makes one number of every struct
//! size, every alignment, every member offset, every enumerant and every
//! constant. `gen/layout.zig` is the same list, in the same order, with the
//! numbers *Zig* makes of the generated declarations. Three tests compare them:
//!
//!   * **the layout oracle**: `zig cc` compiles and runs `layout.c` for the
//!     machine the tests run on, and every struct's size, alignment and member
//!     offsets must be what `@sizeOf`, `@alignOf` and `@offsetOf` say;
//!   * **the enum oracle**: every enumerant, flag bit and API constant the Zig
//!     declares must be the number the header has;
//!   * **the layout oracle for other targets** - 32-bit x86, where `u64` is
//!     4-aligned, and 32- and 64-bit ARM Android - which runs nothing: the
//!     table is data in the object file, so `zig cc -S` writes the C side out
//!     and `zig build-obj -femit-asm` writes the Zig side, and the two are
//!     read back and compared.
//!
//! Each test skips, out loud, when `zig cc` or the Vulkan headers are not here:
//! the headers are not part of this repository, and a machine without them is
//! not a broken machine. `VULKAN_SDK` or `FLUXION_VK_INCLUDE` says where they
//! are, and `FLUXION_ZIG` which compiler to use; `zig build test` sets the
//! latter.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const layout = @import("gen/layout.zig");
const layout_c = @embedFile("gen/layout.c");

const Skip = error{SkipZigTest};

fn skip(comptime fmt: []const u8, args: anytype) Skip {
    std.debug.print("\n  skipped: " ++ fmt ++ "\n", args);
    return error.SkipZigTest;
}

/// An environment variable, or null.
fn env(name: []const u8) ?[]const u8 {
    const map = struct {
        var value: ?std.process.Environ.Map = null;
    };
    if (map.value == null) map.value = testing.environ.createMap(std.heap.page_allocator) catch return null;
    return map.value.?.get(name);
}

/// Where `vulkan/vulkan_core.h` is, or null.
fn findHeaders(io: std.Io) ?[]const u8 {
    if (env("FLUXION_VK_INCLUDE")) |dir| return dir;
    const sdk = env("VULKAN_SDK") orelse return null;
    const candidates = [_][]const u8{ "Include", "include", "x86_64/include" };
    for (candidates) |sub| {
        const dir = std.fs.path.join(std.heap.page_allocator, &.{ sdk, sub }) catch return null;
        const probe = std.fs.path.join(std.heap.page_allocator, &.{ dir, "vulkan", "vulkan_core.h" }) catch return null;
        std.Io.Dir.cwd().access(io, probe, .{}) catch continue;
        return dir;
    }
    return null;
}

fn zigExe() []const u8 {
    return env("FLUXION_ZIG") orelse "zig";
}

/// The target this test binary was built for, spelled as `-target` wants it.
/// C has to be compiled for the same machine the Zig is running on, or the two
/// tables measure different ABIs.
const native_target = std.fmt.comptimePrint("{s}-{s}-{s}", .{
    @tagName(builtin.cpu.arch),
    @tagName(builtin.os.tag),
    @tagName(builtin.abi),
});

// -------------------------------------------------------------------------
// Running things
// -------------------------------------------------------------------------

const Staged = struct {
    dir: testing.TmpDir,
    path: []const u8,
};

/// A scratch directory with `layout.c` in it.
fn stage(gpa: Allocator, io: std.Io) !Staged {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "layout.c", .data = layout_c });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    return .{ .dir = tmp, .path = try gpa.dupe(u8, buffer[0..n]) };
}

fn run(gpa: Allocator, io: std.Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv, .cwd = cwd });
}

fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

// -------------------------------------------------------------------------
// The table, from a running program
// -------------------------------------------------------------------------

/// The table `layout.c` makes on this machine, computed once: the compile is
/// the slow part, and the two tests that use it read the same numbers.
fn hostTable() Skip![]const u64 {
    const cache = struct {
        var table: ?[]const u64 = null;
        var reason: ?[]const u8 = null;
    };
    if (cache.table) |t| return t;
    if (cache.reason) |r| return skip("{s}", .{r});

    const gpa = std.heap.page_allocator;
    const io = testing.io;

    const include = findHeaders(io) orelse {
        cache.reason = "no Vulkan headers here (set VULKAN_SDK or FLUXION_VK_INCLUDE) so there is nothing to measure against";
        return skip("{s}", .{cache.reason.?});
    };

    var staged = stage(gpa, io) catch |err| {
        cache.reason = "could not stage layout.c in a scratch directory";
        std.debug.print("  ({s})\n", .{@errorName(err)});
        return skip("{s}", .{cache.reason.?});
    };
    defer staged.dir.cleanup();

    const exe_name = if (builtin.os.tag == .windows) "layout.exe" else "layout";
    const include_flag = std.fmt.allocPrint(gpa, "-I{s}", .{include}) catch return skip("out of memory", .{});
    const compile = run(gpa, io, .{ .path = staged.path }, &.{ zigExe(), "cc", "-target", native_target, "-std=c11", "-DFLUXION_MAIN", include_flag, "layout.c", "-o", exe_name }) catch |err| {
        cache.reason = "`zig cc` could not be started (set FLUXION_ZIG to the zig executable)";
        std.debug.print("  ({s})\n", .{@errorName(err)});
        return skip("{s}", .{cache.reason.?});
    };
    if (!succeeded(compile.term)) {
        std.debug.print("\n{s}\n", .{compile.stderr});
        // The headers are here and layout.c does not compile against them: that
        // is a finding, not a missing tool.
        @panic("layout.c does not compile against the Vulkan headers");
    }

    const exe_path = std.fs.path.join(gpa, &.{ staged.path, exe_name }) catch return skip("out of memory", .{});
    const ran = run(gpa, io, .{ .path = staged.path }, &.{exe_path}) catch |err| {
        std.debug.print("  ({s})\n", .{@errorName(err)});
        @panic("the layout program compiled and could not be run");
    };
    if (!succeeded(ran.term)) @panic("the layout program crashed");

    var list: std.ArrayList(u64) = .empty;
    var lines = std.mem.tokenizeAny(u8, ran.stdout, "\r\n");
    while (lines.next()) |line| {
        list.append(gpa, std.fmt.parseInt(u64, line, 10) catch @panic("the layout program printed something that is not a number")) catch
            return skip("out of memory", .{});
    }
    cache.table = list.items;
    return list.items;
}

/// Compare Zig's numbers with C's for the rows `wanted` picks, and say what
/// disagreed. Returns how many rows it looked at.
fn compare(zig_values: []const u64, c_values: []const u64, comptime wanted: enum { structs, numbers, all }) !usize {
    try testing.expectEqual(layout.labels.len, c_values.len);
    try testing.expectEqual(layout.labels.len, zig_values.len);

    var checked: usize = 0;
    var bad: usize = 0;
    for (layout.labels, zig_values, c_values) |label, zig, c| {
        const is_struct = std.mem.startsWith(u8, label, "sizeof(") or std.mem.startsWith(u8, label, "alignof(") or
            std.mem.startsWith(u8, label, "offsetof(");
        switch (wanted) {
            .structs => if (!is_struct) continue,
            .numbers => if (is_struct) continue,
            .all => {},
        }
        checked += 1;
        if (zig != c) {
            bad += 1;
            if (bad <= 20) std.debug.print("  {s}: Zig says {d}, the header says {d}\n", .{ label, zig, c });
        }
    }
    if (bad > 0) std.debug.print("  {d} of {d} disagree\n", .{ bad, checked });
    try testing.expectEqual(@as(usize, 0), bad);
    return checked;
}

fn report(comptime fmt: []const u8, args: anytype) void {
    if (testing.environ.contains(testing.allocator, "FLUXION_VERBOSE") catch false) std.debug.print(fmt, args);
}

test "the layout oracle: every struct is the size and shape the C headers say" {
    const c_values = try hostTable();
    const checked = try compare(&layout.values, c_values, .structs);

    var structs: usize = 0;
    for (layout.labels) |label| {
        if (std.mem.startsWith(u8, label, "sizeof(")) structs += 1;
    }
    // Enough of them that this is not vacuous: the wanted list is a backend's
    // worth of Vulkan, and every struct and union of it is in the table.
    try testing.expect(structs >= 100);
    report("\n  layout oracle ({s}): {d} structs and unions, {d} sizes, alignments and offsets, all as the headers have them\n", .{ native_target, structs, checked });
}

test "the enum oracle: every enumerant, flag bit and constant is the header's number" {
    const c_values = try hostTable();
    const checked = try compare(&layout.values, c_values, .numbers);
    try testing.expect(checked >= 500);
    report("\n  enum oracle ({s}): {d} enumerants, flag bits and constants, all as the headers have them\n", .{ native_target, checked });
}

// -------------------------------------------------------------------------
// The table, from assembly
// -------------------------------------------------------------------------

/// The numbers in one symbol's data, read out of compiler-written assembly.
///
/// Both compilers are LLVM, so both write the same vocabulary: a label, then
/// `.quad` on most targets, `.xword` on arm64 and `.long` pairs on 32-bit ARM,
/// until the `.size`. Everything is little-endian on the targets this checks.
fn readTable(gpa: Allocator, assembly: []const u8, symbol: []const u8) ![]u64 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);

    var inside = false;
    var lines = std.mem.splitScalar(u8, assembly, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!inside) {
            // `fluxion_layout:` from C, `.Lprobe.fluxion_layout:` from Zig.
            if (line.len > 0 and line[line.len - 1] == ':' and std.mem.endsWith(u8, line[0 .. line.len - 1], symbol) and
                (line.len - 1 == symbol.len or line[line.len - 2 - symbol.len] == '.'))
                inside = true;
            continue;
        }
        if (line.len == 0 or line[0] != '.') {
            if (line.len > 0 and line[line.len - 1] == ':') break; // the next symbol
            continue;
        }
        if (std.mem.startsWith(u8, line, ".size")) break;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const directive = tokens.next().?;
        const width: usize = if (eq(directive, ".quad") or eq(directive, ".xword") or eq(directive, ".8byte") or eq(directive, ".dword"))
            8
        else if (eq(directive, ".long") or eq(directive, ".word") or eq(directive, ".4byte") or eq(directive, ".int"))
            4
        else if (eq(directive, ".zero") or eq(directive, ".space")) {
            const n = std.fmt.parseInt(usize, tokens.next() orelse return error.BadAssembly, 10) catch return error.BadAssembly;
            try bytes.appendNTimes(gpa, 0, n);
            continue;
        } else continue; // `.p2align`, `.type`, and other things that are not data

        var text = tokens.next() orelse return error.BadAssembly;
        // A trailing comment on the same token, as in `350#`.
        if (std.mem.indexOfAny(u8, text, "#@/")) |at| text = text[0..at];
        const value: u64 = if (text.len > 0 and text[0] == '-')
            @bitCast(std.fmt.parseInt(i64, text, 0) catch return error.BadAssembly)
        else
            std.fmt.parseInt(u64, text, 0) catch return error.BadAssembly;
        var i: usize = 0;
        while (i < width) : (i += 1) try bytes.append(gpa, @truncate(value >> @intCast(8 * i)));
    }
    if (!inside) return error.BadAssembly;
    if (bytes.items.len % 8 != 0) return error.BadAssembly;

    const table = try gpa.alloc(u64, bytes.items.len / 8);
    for (table, 0..) |*slot, i| slot.* = std.mem.readInt(u64, bytes.items[i * 8 ..][0..8], .little);
    return table;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "a table is read back out of assembly, whatever the target writes it as" {
    const gpa = testing.allocator;

    const x86 =
        \\fluxion_layout:
        \\    .quad 350                             # 0x15e
        \\    .quad -1
        \\    .quad 0
        \\    .size fluxion_layout, 24
    ;
    const table = try readTable(gpa, x86, "fluxion_layout");
    defer gpa.free(table);
    try testing.expectEqualSlices(u64, &.{ 350, std.math.maxInt(u64), 0 }, table);

    // 32-bit ARM writes a 64-bit number as two 32-bit words, low first.
    const arm =
        \\.Lprobe.fluxion_layout:
        \\    .long 350
        \\    .long 0
        \\    .long 4294967295
        \\    .long 1
        \\    .zero 8
        \\    .size .Lprobe.fluxion_layout, 24
    ;
    const arm_table = try readTable(gpa, arm, "fluxion_layout");
    defer gpa.free(arm_table);
    try testing.expectEqualSlices(u64, &.{ 350, 0x1_FFFF_FFFF, 0 }, arm_table);

    try testing.expectError(error.BadAssembly, readTable(gpa, "nothing here", "fluxion_layout"));
}

/// The targets whose layout differs from this machine's in a way that matters:
/// 32-bit x86, where `u64` is only 4-aligned; 32-bit ARM, where it is 8-aligned
/// but pointers are not; 64-bit ARM; and x86-64 Android.
const cross_targets = [_][]const u8{
    "x86-linux-gnu",
    "arm-linux-androideabi",
    "aarch64-linux-android",
    "x86_64-linux-android",
};

test "the layout oracle for other targets: 32-bit x86, 32- and 64-bit Android" {
    const gpa = std.heap.page_allocator;
    const io = testing.io;

    const include = findHeaders(io) orelse
        return skip("no Vulkan headers here (set VULKAN_SDK or FLUXION_VK_INCLUDE) so there is nothing to measure against", .{});
    // The Zig side is compiled from `src/layout_probe.zig`, relative to where
    // the tests run: the package root, under `zig build test`.
    std.Io.Dir.cwd().access(io, "src/layout_probe.zig", .{}) catch
        return skip("src/layout_probe.zig is not reachable from here, so the Zig side cannot be built for another target", .{});

    var staged = stage(gpa, io) catch return skip("could not stage layout.c in a scratch directory", .{});
    defer staged.dir.cleanup();
    const include_flag = std.fmt.allocPrint(gpa, "-I{s}", .{include}) catch return skip("out of memory", .{});

    var checked_total: usize = 0;
    for (cross_targets) |target| {
        // C first: what the headers make of everything, as assembly.
        const c_path = try std.fs.path.join(gpa, &.{ staged.path, try std.fmt.allocPrint(gpa, "c-{s}.s", .{target}) });
        const compile_c = run(gpa, io, .{ .path = staged.path }, &.{ zigExe(), "cc", "-target", target, "-std=c11", include_flag, "-S", "layout.c", "-o", c_path }) catch
            return skip("`zig cc` could not be started (set FLUXION_ZIG)", .{});
        if (!succeeded(compile_c.term)) {
            // A target the headers or the compiler do not support here is not
            // a failure of the ABI; a target they do support that then
            // disagrees is.
            std.debug.print("\n  {s}: zig cc could not compile layout.c for it:\n{s}\n", .{ target, compile_c.stderr });
            return error.LayoutDoesNotCompile;
        }

        // Then Zig: the same table, from the generated declarations, as data.
        const zig_path = try std.fs.path.join(gpa, &.{ staged.path, try std.fmt.allocPrint(gpa, "zig-{s}.s", .{target}) });
        const emit_flag = try std.fmt.allocPrint(gpa, "-femit-asm={s}", .{zig_path});
        const compile_zig = try run(gpa, io, .inherit, &.{
            zigExe(), "build-obj",    "src/layout_probe.zig", "-target", target,
            "-O",     "ReleaseSmall", "-fllvm",               emit_flag, "-fno-emit-bin",
        });
        if (!succeeded(compile_zig.term)) {
            std.debug.print("\n  {s}: the generated declarations do not compile for it:\n{s}\n", .{ target, compile_zig.stderr });
            return error.GeneratedDoesNotCompile;
        }

        const c_asm = try staged.dir.dir.readFileAlloc(io, std.fs.path.basename(c_path), gpa, .limited(64 << 20));
        const zig_asm = try staged.dir.dir.readFileAlloc(io, std.fs.path.basename(zig_path), gpa, .limited(64 << 20));
        const c_values = try readTable(gpa, c_asm, "fluxion_layout");
        const zig_values = try readTable(gpa, zig_asm, "fluxion_layout");

        std.debug.print("", .{});
        testing.expectEqual(layout.labels.len, c_values.len) catch |err| {
            std.debug.print("  {s}: the C table has {d} rows, expected {d}\n", .{ target, c_values.len, layout.labels.len });
            return err;
        };
        _ = compare(zig_values, c_values, .all) catch |err| {
            std.debug.print("  ({s})\n", .{target});
            return err;
        };
        checked_total += c_values.len;
        report("\n  layout oracle ({s}): {d} rows, all as the headers have them\n", .{ target, c_values.len });
    }
    try testing.expect(checked_total > 0);
}
