// SPDX-License-Identifier: BSL-1.0

//! SPIR-V, assembled at compile time.
//!
//! The samples beside this file need shaders, and a shader is a SPIR-V module:
//! a header and a stream of words. Normally `glslc` produces one from GLSL and
//! the build embeds the result - but that is a toolchain to install and a
//! build step to explain, for two shaders that between them do a multiply and
//! a colour lookup.
//!
//! So they are assembled here instead, by `zig build`, out of the same
//! instructions `glslc` would have emitted. Nothing is read from disk and
//! nothing is generated ahead of time; `module` is a `[]const u32` known at
//! compile time.
//!
//! **How a module is laid out.** SPIR-V is strictly ordered: capabilities,
//! then the memory model, then entry points and execution modes, then
//! decorations, then every type, constant and global variable, and only then
//! the functions. Within all that, a result id must be defined before it is
//! used. `Module` keeps the sections apart and joins them at the end, so the
//! ordering is a property of the writing rather than something to remember.
//!
//! **How an instruction is laid out.** One word of `(word_count << 16) |
//! opcode`, then the operands. The count includes the opcode word itself,
//! which is the detail everybody gets wrong by one - so `op` computes it.

const std = @import("std");

/// `0x07230203`, which is how a reader knows the byte order it is holding.
pub const magic: u32 = 0x07230203;

/// SPIR-V 1.0, which every Vulkan 1.0 implementation accepts. Asking for more
/// buys nothing here.
pub const version: u32 = 0x0001_0000;

// -------------------------------------------------------------------------
// The enumerations these shaders use
// -------------------------------------------------------------------------

pub const Op = struct {
    pub const memory_model = 14;
    pub const entry_point = 15;
    pub const execution_mode = 16;
    pub const capability = 17;
    pub const type_void = 19;
    pub const type_int = 21;
    pub const type_float = 22;
    pub const type_vector = 23;
    pub const type_array = 28;
    pub const type_runtime_array = 29;
    pub const type_struct = 30;
    pub const type_pointer = 32;
    pub const type_function = 33;
    pub const constant = 43;
    pub const constant_composite = 44;
    pub const composite_construct = 80;
    pub const composite_extract = 81;
    pub const function = 54;
    pub const function_end = 56;
    pub const variable = 59;
    pub const load = 61;
    pub const store = 62;
    pub const access_chain = 65;
    pub const decorate = 71;
    pub const member_decorate = 72;
    pub const i_add = 128;
    pub const i_mul = 132;
    pub const label = 248;
    pub const @"return" = 253;
};

pub const Capability = struct {
    pub const shader = 1;
};

pub const AddressingModel = struct {
    pub const logical = 0;
};

pub const MemoryModel = struct {
    pub const glsl450 = 1;
};

pub const ExecutionModel = struct {
    pub const vertex = 0;
    pub const fragment = 4;
    pub const gl_compute = 5;
};

pub const ExecutionMode = struct {
    pub const origin_upper_left = 7;
    pub const local_size = 17;
};

pub const StorageClass = struct {
    pub const input = 1;
    /// Vulkan 1.0's way of reaching a storage buffer: `Uniform` storage with
    /// the struct decorated `BufferBlock`. The tidier `StorageBuffer` class
    /// needs SPIR-V 1.3 or an extension, and buys nothing here.
    pub const uniform = 2;
    pub const output = 3;
    pub const private = 6;
    pub const function = 7;
};

pub const Decoration = struct {
    pub const block = 2;
    pub const buffer_block = 3;
    pub const array_stride = 6;
    pub const builtin = 11;
    pub const location = 30;
    pub const binding = 33;
    pub const descriptor_set = 34;
    pub const offset = 35;
};

pub const BuiltIn = struct {
    pub const position = 0;
    pub const global_invocation_id = 28;
    pub const vertex_index = 42;
};

pub const FunctionControl = struct {
    pub const none = 0;
};

// -------------------------------------------------------------------------
// Assembling
// -------------------------------------------------------------------------

/// One instruction: the opcode with its word count in front, then operands.
pub fn op(comptime opcode: u16, comptime operands: []const u32) []const u32 {
    comptime {
        const count: u32 = @intCast(operands.len + 1);
        return [_]u32{(count << 16) | opcode} ++ operands;
    }
}

/// Several word runs, joined. For an operand list built out of pieces of
/// different kinds - an `OpEntryPoint`'s model, name and interface list.
pub fn cat(comptime parts: []const []const u32) []const u32 {
    comptime {
        var all: []const u32 = &.{};
        for (parts) |part| all = all ++ part;
        return all;
    }
}

/// A literal string, as SPIR-V stores one: the bytes, then a terminator, then
/// zero padding out to a whole number of words.
pub fn string(comptime text: []const u8) []const u32 {
    comptime {
        const padded = ((text.len + 4) / 4) * 4;
        var bytes: [padded]u8 = @splat(0);
        @memcpy(bytes[0..text.len], text);

        var words: [padded / 4]u32 = undefined;
        for (&words, 0..) |*word, i| {
            word.* = @as(u32, bytes[i * 4]) |
                @as(u32, bytes[i * 4 + 1]) << 8 |
                @as(u32, bytes[i * 4 + 2]) << 16 |
                @as(u32, bytes[i * 4 + 3]) << 24;
        }
        const frozen = words;
        return &frozen;
    }
}

/// The sections of a module, kept apart so that the order they must appear in
/// is not something the caller has to remember.
pub const Module = struct {
    capabilities: []const u32 = &.{},
    memory_model: []const u32 = &.{},
    entry_points: []const u32 = &.{},
    execution_modes: []const u32 = &.{},
    decorations: []const u32 = &.{},
    /// Types, constants and global variables, in definition order.
    globals: []const u32 = &.{},
    functions: []const u32 = &.{},
    /// One past the largest result id used.
    bound: u32,

    /// The finished module, header and all.
    pub fn words(comptime self: Module) []const u32 {
        comptime {
            const header = [_]u32{
                magic,
                version,
                0, // generator: none of the registered ones
                self.bound,
                0, // schema: reserved
            };
            return &header ++
                self.capabilities ++
                self.memory_model ++
                self.entry_points ++
                self.execution_modes ++
                self.decorations ++
                self.globals ++
                self.functions;
        }
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "an instruction carries its own length" {
    // OpCapability Shader: one word of opcode, one operand.
    const cap = comptime op(Op.capability, &.{Capability.shader});
    try testing.expectEqual(@as(usize, 2), cap.len);
    try testing.expectEqual(@as(u32, (2 << 16) | 17), cap[0]);
    try testing.expectEqual(@as(u32, 1), cap[1]);

    // OpReturn: no operands at all, and still one word.
    const ret = comptime op(Op.@"return", &.{});
    try testing.expectEqual(@as(usize, 1), ret.len);
    try testing.expectEqual(@as(u32, (1 << 16) | 253), ret[0]);
}

test "a literal string is padded to whole words" {
    // "main" is four bytes, and the terminator makes five - so two words, the
    // second of which is entirely padding.
    const name = comptime string("main");
    try testing.expectEqual(@as(usize, 2), name.len);
    try testing.expectEqual(@as(u32, 0x6E69616D), name[0]); // 'n','i','a','m'
    try testing.expectEqual(@as(u32, 0), name[1]);

    // Three bytes plus a terminator is exactly one word, with no padding.
    const three = comptime string("abc");
    try testing.expectEqual(@as(usize, 1), three.len);
    try testing.expectEqual(@as(u32, 0x00636261), three[0]);

    // And the empty string is still one word of terminator.
    try testing.expectEqual(@as(usize, 1), comptime string("").len);
}

test "a module starts with the header a reader looks for" {
    const m: Module = .{
        .capabilities = comptime op(Op.capability, &.{Capability.shader}),
        .bound = 3,
    };
    const words = comptime m.words();

    try testing.expectEqual(magic, words[0]);
    try testing.expectEqual(version, words[1]);
    try testing.expectEqual(@as(u32, 3), words[3]); // bound
    try testing.expectEqual(@as(usize, 7), words.len); // header plus one instruction
}
