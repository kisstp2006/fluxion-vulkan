// SPDX-License-Identifier: BSL-1.0

//! The generator's model: what is wanted, and what it needs.
//!
//! `wanted.zon` says which commands, structs and enums; the registry says what
//! they are. This file is the join. It selects the features and extensions
//! whose enumerants count, classifies each wanted command by the handle it
//! dispatches on and checks that against the tier it was listed under, follows
//! every member type, alias and function pointer to the end, works out each
//! enum's numbers - base values, plus what the selected extensions add, aliases
//! resolved - and builds the Zig text of every type. `emit.zig` writes it out;
//! `genvk.zig` is the program.
//!
//! **There is no list of Vulkan things here.** Which commands, structs and enums
//! exist is data. What this file does know is the registry's own conventions,
//! because it has to read them: the `Vk` and `VK_` prefixes, the `sType` and
//! `pNext` members every struct starts with, `VkBool32` and `VkFlags64`, which
//! handles are dispatchable, which `optional` and `len` attributes make a
//! pointer nullable, and how an extension's `offset` becomes a number.
//!
//! It fails loudly on what it does not understand: a bit-field, a type whose
//! platform declaration `wanted.zon` does not supply, two names that come out
//! as the same Zig name, an extension a wanted command needs that is not
//! listed. A generator that guesses writes wrong ABI without saying so.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const xml = @import("xml.zig");
const reg = @import("registry.zig");
const names = @import("names.zig");
const Decl = reg.Decl;

// -------------------------------------------------------------------------
// The wanted list
// -------------------------------------------------------------------------

/// The shape of `wanted.zon`. See that file for what each field means.
pub const Wanted = struct {
    api: []const u8 = "vulkan",
    versions: []const []const u8,
    baseline: []const u8,
    extensions: []const []const u8,
    result: []const u8,
    dispatch: struct {
        instance: []const []const u8,
        device: []const []const u8,
        through_instance: []const []const u8 = &.{},
    },
    global: []const []const u8,
    instance: []const []const u8,
    device: []const []const u8,
    structs: []const []const u8 = &.{},
    enums: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},
    zero_defaults: []const []const u8 = &.{},
    rename: []const struct { from: []const u8, to: []const u8 } = &.{},
    platform_types: []const struct { name: []const u8, zig: []const u8, c: []const u8 } = &.{},
    methods: []const struct { type: []const u8, decls: []const []const u8 } = &.{},
};

pub const Error = Allocator.Error || error{Generate};

/// What was wrong, when `generate` returns `error.Generate`.
pub var last_error: []const u8 = "";

pub fn fail(arena: Allocator, comptime fmt: []const u8, args: anytype) error{Generate} {
    last_error = std.fmt.allocPrint(arena, fmt, args) catch "out of memory while reporting an error";
    return error.Generate;
}

/// The four files, and what is in them.
pub const Outputs = struct {
    types: []const u8,
    commands: []const u8,
    layout_zig: []const u8,
    layout_c: []const u8,
    summary: Summary,
};

pub const Summary = struct {
    header_version: []const u8 = "",
    global: usize = 0,
    instance: usize = 0,
    device: usize = 0,
    optional: usize = 0,
    structs: usize = 0,
    unions: usize = 0,
    enums: usize = 0,
    flags: usize = 0,
    handles: usize = 0,
    function_pointers: usize = 0,
    constants: usize = 0,
    aliases: usize = 0,
    enumerants: usize = 0,
    layout_rows: usize = 0,

    pub fn format(self: Summary, w: *Io.Writer) Io.Writer.Error!void {
        try w.print(
            "registry VK_HEADER_VERSION {s}\n" ++
                "  commands   {d} global, {d} instance, {d} device ({d} optional)\n" ++
                "  types      {d} structs, {d} unions, {d} enums, {d} flags, {d} handles, {d} function pointers, {d} aliases\n" ++
                "  numbers    {d} enumerants, {d} constants\n" ++
                "  oracle     {d} layout rows\n",
            .{
                self.header_version,    self.global,  self.instance,   self.device,    self.optional,
                self.structs,           self.unions,  self.enums,      self.flags,     self.handles,
                self.function_pointers, self.aliases, self.enumerants, self.constants, self.layout_rows,
            },
        );
    }
};

// -------------------------------------------------------------------------
// C, as far as Zig needs to know it
// -------------------------------------------------------------------------

/// The Zig spelling of a C type the registry uses without defining: the
/// fixed-width integers, `float`, `char`. This is a fact about C and not about
/// Vulkan, which is why it lives here and not in the wanted list.
pub fn cPrimitive(name: []const u8) ?[]const u8 {
    const table = [_]struct { c: []const u8, zig: []const u8 }{
        .{ .c = "void", .zig = "void" },
        .{ .c = "char", .zig = "u8" },
        .{ .c = "float", .zig = "f32" },
        .{ .c = "double", .zig = "f64" },
        .{ .c = "int", .zig = "c_int" },
        .{ .c = "size_t", .zig = "usize" },
        .{ .c = "uint8_t", .zig = "u8" },
        .{ .c = "uint16_t", .zig = "u16" },
        .{ .c = "uint32_t", .zig = "u32" },
        .{ .c = "uint64_t", .zig = "u64" },
        .{ .c = "int8_t", .zig = "i8" },
        .{ .c = "int16_t", .zig = "i16" },
        .{ .c = "int32_t", .zig = "i32" },
        .{ .c = "int64_t", .zig = "i64" },
    };
    for (table) |entry| if (std.mem.eql(u8, entry.c, name)) return entry.zig;
    return null;
}

pub const Set = std.StringHashMapUnmanaged(void);

pub fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

// -------------------------------------------------------------------------
// The generator
// -------------------------------------------------------------------------

pub const Tier = enum { global, instance, device };

pub const Member = struct {
    decl: Decl,
    /// As it is written in Zig source: quoted if it has to be.
    zig_name: []const u8,
    /// The bare name, for `@offsetOf`.
    raw_name: []const u8,
};

pub const Param = Member;

pub const WantedCommand = struct {
    /// The registry's name.
    name: []const u8,
    field: []const u8,
    tier: Tier,
    required: bool,
    params: []const Param,
    /// The return type as a declaration with no name.
    ret: Decl,
    /// The other names it answers to, from registry aliases.
    aliases: []const []const u8,
    /// Where it comes from, for the doc comment.
    provenance: []const u8,
    order: usize,
};

pub const Entry = struct {
    reg_name: []const u8,
    zig_name: []const u8,
    number: i128,
    /// A member of the enum, or a field of the flags type - as opposed to a
    /// constant that names another one.
    primary: bool,
    /// For a primary of a flags type: its bit.
    bit: u8 = 0,
    /// For an alias: the primary it is another name for.
    target: ?usize = null,
    comment: ?[]const u8 = null,
};

pub const EnumInfo = struct {
    name: []const u8,
    is_flags: bool,
    bits: u8,
    entries: []Entry,
    /// The zero-valued enumerant, when there is one.
    zero_name: ?[]const u8,
};

pub const Generator = struct {
    arena: Allocator,
    r: reg.Registry,
    w: Wanted,

    /// Features and extensions whose enumerants count.
    selected: Set = .empty,
    /// The features that make up the baseline: what a command has to be in to
    /// be required rather than optional.
    baseline: Set = .empty,

    /// Types some wanted thing needs, by canonical registry name.
    needed: Set = .empty,
    pending: std.ArrayList([]const u8) = .empty,
    /// API constants some array size or the wanted list names.
    used_constants: Set = .empty,
    /// `VkSampleCountFlagBits` names used as a type: they get an alias.
    bits_referenced: Set = .empty,
    /// The `...Flags` typedef for each `...FlagBits` enum.
    bits_to_flags: std.StringHashMapUnmanaged([]const u8) = .empty,

    members_cache: std.StringHashMapUnmanaged([]const Member) = .empty,
    enum_cache: std.StringHashMapUnmanaged(*EnumInfo) = .empty,
    renames: std.StringHashMapUnmanaged([]const u8) = .empty,
    platform_types: std.StringHashMapUnmanaged([]const u8) = .empty,

    commands: std.ArrayList(WantedCommand) = .empty,
    summary: Summary = .{},

    pub fn init(arena: Allocator, r: reg.Registry, w: Wanted) Error!Generator {
        var g: Generator = .{ .arena = arena, .r = r, .w = w };
        for (w.rename) |item| try g.renames.put(arena, item.from, item.to);
        for (w.platform_types) |item| try g.platform_types.put(arena, item.name, item.zig);

        // Which FlagBits belongs to which Flags: the typedef says so.
        for (r.type_list) |def| {
            if (def.category != .bitmask or def.alias_of != null) continue;
            const bits = def.node.attr("requires") orelse def.node.attr("bitvalues") orelse continue;
            try g.bits_to_flags.put(arena, bits, def.name);
        }
        return g;
    }

    // ---------------------------------------------------------------------
    // Selecting features and extensions
    // ---------------------------------------------------------------------

    pub fn addFeature(g: *Generator, name: []const u8, set: *Set) Error!void {
        const p = g.r.provider(name) orelse
            return fail(g.arena, "wanted.zon names {s}, which is not a feature of the {s} registry", .{ name, g.w.api });
        if (p.is_extension) return fail(g.arena, "{s} is an extension; list it under .extensions", .{name});
        if (set.contains(name)) return;
        try set.put(g.arena, name, {});

        // `depends` is a small expression: names joined by `,` and `+`, with
        // parentheses. Which of the names are features is all that matters.
        var it = std.mem.tokenizeAny(u8, p.depends, ",+() ");
        while (it.next()) |token| {
            if (g.r.provider(token)) |dep| {
                if (!dep.is_extension) try g.addFeature(token, set);
            }
        }
    }

    pub fn select(g: *Generator) Error!void {
        for (g.w.versions) |v| try g.addFeature(v, &g.selected);
        try g.addFeature(g.w.baseline, &g.baseline);
        for (g.w.extensions) |name| {
            const p = g.r.provider(name) orelse
                return fail(g.arena, "wanted.zon names extension {s}, which is not in the {s} registry or is not supported by it", .{ name, g.w.api });
            if (!p.is_extension) return fail(g.arena, "{s} is a feature; list it under .versions", .{name});
            try g.selected.put(g.arena, name, {});
        }
    }

    pub fn isSelected(g: *const Generator, provider: []const u8) bool {
        return g.selected.contains(provider);
    }

    // ---------------------------------------------------------------------
    // Names
    // ---------------------------------------------------------------------

    pub fn zigTypeName(g: *Generator, reg_name: []const u8) Error![]const u8 {
        if (g.renames.get(reg_name)) |to| return to;
        if (std.mem.startsWith(u8, reg_name, "PFN_vk")) return names.pfnTypeName(g.arena, reg_name);
        return names.typeName(reg_name);
    }

    pub fn id(g: *Generator, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(g.arena, "{f}", .{std.zig.fmtIdP(name)});
    }

    // ---------------------------------------------------------------------
    // The wanted commands
    // ---------------------------------------------------------------------

    pub fn providerList(g: *Generator, canonical_name: []const u8) Error![]const u8 {
        // Which features and extensions bring a command: under its own name and
        // under every alias, since the registry lists a promoted command in both
        // places, spelled differently.
        var out: std.ArrayList(u8) = .empty;
        var seen: Set = .empty;
        var lowest_version: ?[]const u8 = null;
        for (g.r.providers) |p| {
            var found = false;
            for (p.requires) |req| for (req.commands) |c| {
                if (std.mem.eql(u8, g.r.canonicalCommand(c), canonical_name)) found = true;
            };
            if (!found) continue;

            // `VK_GRAPHICS_VERSION_1_1` and `VK_VERSION_1_1` are both "Vulkan
            // 1.1", and only the lowest is worth saying.
            if (!p.is_extension) {
                const at = std.mem.indexOf(u8, p.name, "VERSION_") orelse continue;
                const text = try std.fmt.allocPrint(g.arena, "Vulkan {s}", .{try replaceChar(g.arena, p.name[at + "VERSION_".len ..], '_', '.')});
                if (lowest_version == null or std.mem.lessThan(u8, text, lowest_version.?)) lowest_version = text;
                continue;
            }
            if (seen.contains(p.name)) continue;
            try seen.put(g.arena, p.name, {});
            if (out.items.len > 0) try out.appendSlice(g.arena, ", ");
            try out.appendSlice(g.arena, p.name);
        }
        if (lowest_version) |v| {
            const joined = try std.fmt.allocPrint(g.arena, "{s}{s}{s}", .{ v, if (out.items.len > 0) ", " else "", out.items });
            return joined;
        }
        return out.items;
    }

    pub fn isProvidedBy(g: *Generator, canonical_name: []const u8, set: *const Set) bool {
        for (g.r.providers) |p| {
            if (!set.contains(p.name)) continue;
            for (p.requires) |req| for (req.commands) |c| {
                if (std.mem.eql(u8, g.r.canonicalCommand(c), canonical_name)) return true;
            };
        }
        return false;
    }

    pub fn addCommands(g: *Generator, list: []const []const u8, tier: Tier) Error!void {
        for (list) |wanted_name| {
            const canon = g.r.canonicalCommand(wanted_name);
            const cmd = g.r.commands.get(canon) orelse
                return fail(g.arena, "wanted.zon lists {s}, which is not a command of the {s} registry", .{ wanted_name, g.w.api });
            const node = cmd.node orelse return fail(g.arena, "{s} is an alias of {s}, which has no definition", .{ wanted_name, canon });

            for (g.commands.items) |existing| {
                if (std.mem.eql(u8, existing.name, canon))
                    return fail(g.arena, "{s} is listed twice in wanted.zon (as {s} and as {s})", .{ canon, @tagName(existing.tier), @tagName(tier) });
            }

            // Which extensions the command comes from must be among those whose
            // enumerants were asked for: otherwise its structs would be missing
            // their `sType` values, and that is a worse error to meet later.
            if (!g.isProvidedBy(canon, &g.selected)) {
                return fail(g.arena, "{s} comes from {s}, which wanted.zon does not list: add it to .extensions (or its version to .versions)", .{ canon, try g.providerList(canon) });
            }

            var params: std.ArrayList(Param) = .empty;
            var it = node.elements();
            while (it.next()) |child| {
                if (!std.mem.eql(u8, child.tag, "param") or !reg.appliesTo(child, g.w.api)) continue;
                const decl = try g.parseDecl(child);
                const raw = try g.paramName(decl);
                try params.append(g.arena, .{ .decl = decl, .zig_name = try g.id(raw), .raw_name = raw });
            }
            const proto = node.child("proto") orelse return fail(g.arena, "{s} has no <proto>", .{canon});
            const ret = try g.parseDecl(proto);

            // Dispatch: a command is called through whichever handle is its
            // first argument, and which table it belongs in follows.
            try g.checkTier(canon, tier, params.items);

            var aliases: std.ArrayList([]const u8) = .empty;
            for (g.r.command_list) |other| {
                if (other.alias_of) |target| {
                    if (std.mem.eql(u8, g.r.canonicalCommand(target), canon)) try aliases.append(g.arena, other.name);
                }
            }

            for (params.items) |p| try g.need(p.decl.type_name);
            try g.need(ret.type_name);

            try g.commands.append(g.arena, .{
                .name = canon,
                .field = try names.commandField(g.arena, canon),
                .tier = tier,
                .required = g.isProvidedBy(canon, &g.baseline),
                .params = params.items,
                .ret = ret,
                .aliases = aliases.items,
                .provenance = try g.providerList(canon),
                .order = commandOrder(g.r, canon),
            });
        }
    }

    pub fn commandOrder(r: reg.Registry, name: []const u8) usize {
        for (r.command_list, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return i;
        return r.command_list.len;
    }

    pub fn checkTier(g: *Generator, name: []const u8, tier: Tier, params: []const Param) Error!void {
        const first: ?[]const u8 = if (params.len > 0) g.r.canonical(params[0].decl.type_name) else null;
        const on_instance = first != null and params[0].decl.pointerDepth() == 0 and contains(g.w.dispatch.instance, first.?);
        const on_device = first != null and params[0].decl.pointerDepth() == 0 and contains(g.w.dispatch.device, first.?);
        const first_optional = params.len > 0 and params[0].decl.isOptional();

        switch (tier) {
            .global => if ((on_instance or on_device) and !first_optional)
                return fail(g.arena, "{s} dispatches on {s}, so it cannot be a global command: move it to .{s}", .{ name, first.?, if (on_instance) "instance" else "device" }),
            .instance => {
                if (on_device and !contains(g.w.dispatch.through_instance, name))
                    return fail(g.arena, "{s} dispatches on the device handle {s}: move it to .device (or, if the loader asks the instance for it, to .dispatch.through_instance)", .{ name, first.? });
                if (!on_instance and !on_device)
                    return fail(g.arena, "{s} does not dispatch on an instance or a physical device: move it to .global", .{name});
            },
            .device => if (!on_device)
                return fail(g.arena, "{s} does not dispatch on a device, a queue or a command buffer: it belongs in .{s}", .{ name, if (on_instance) "instance" else "global" }),
        }
    }

    // ---------------------------------------------------------------------
    // Declarations
    // ---------------------------------------------------------------------

    pub fn parseDecl(g: *Generator, node: *const xml.Node) Error!Decl {
        return reg.parseDecl(g.arena, node) catch |err| switch (err) {
            error.Registry => return fail(g.arena, "{s}", .{reg.last_error}),
            else => |e| return e,
        };
    }

    pub fn isFunctionPointer(g: *Generator, type_name: []const u8) bool {
        const def = g.r.find(g.r.canonical(type_name)) orelse return false;
        return def.category == .funcpointer;
    }

    pub fn paramName(g: *Generator, decl: Decl) Error![]const u8 {
        return names.memberName(g.arena, decl.name, decl.pointerDepth(), g.isFunctionPointer(decl.type_name));
    }

    // ---------------------------------------------------------------------
    // What the wanted things need
    // ---------------------------------------------------------------------

    /// Ask for a type, and everything it needs in turn.
    pub fn need(g: *Generator, type_name: []const u8) Error!void {
        if (cPrimitive(type_name) != null) return;
        const canon = g.r.canonical(type_name);
        if (cPrimitive(canon) != null) return;
        const def = g.r.find(canon) orelse
            return fail(g.arena, "the registry has no type {s}", .{canon});

        // A reference to a FlagBits enum is a reference to its flags type, and
        // the enum's own name becomes an alias of it.
        if (def.category == .enumeration) {
            if (g.bits_to_flags.get(canon)) |flags| {
                try g.bits_referenced.put(g.arena, canon, {});
                return g.need(flags);
            }
        }

        if (g.needed.contains(canon)) return;
        try g.needed.put(g.arena, canon, {});
        try g.pending.append(g.arena, canon);
    }

    pub fn closure(g: *Generator) Error!void {
        while (g.pending.pop()) |name| {
            const def = g.r.find(name).?;
            switch (def.category) {
                .basetype => {
                    const inner = def.node.child("type") orelse continue;
                    const inner_name = try inner.textContent(g.arena);
                    try g.need(inner_name);
                },
                .handle, .enumeration => {},
                // A flags type needs nothing else: its bits are numbers, read
                // through `enumInfo` when the type is written.
                .bitmask => {},
                .funcpointer => {
                    const proto = def.node.child("proto").?;
                    try g.need((try g.parseDecl(proto)).type_name);
                    var it = def.node.elements();
                    while (it.next()) |child| {
                        if (!std.mem.eql(u8, child.tag, "param")) continue;
                        try g.need((try g.parseDecl(child)).type_name);
                    }
                },
                .structure, .union_ => {
                    for (try g.members(def)) |m| {
                        if (m.decl.bit_width != null)
                            return fail(g.arena, "{s}.{s} is a bit-field, which this generator refuses: no Zig type has a C bit-field's layout on every target", .{ def.name, m.decl.name });
                        try g.need(m.decl.type_name);
                        for (m.decl.dims) |dim| switch (dim) {
                            .constant => |c| try g.useConstant(c),
                            .number => {},
                        };
                    }
                },
                .external => {
                    if (!g.platform_types.contains(def.name))
                        return fail(g.arena, "the registry uses {s}, which is defined by a platform's own header; wanted.zon has to say what it is under .platform_types", .{def.name});
                },
            }
        }
    }

    pub fn useConstant(g: *Generator, name: []const u8) Error!void {
        if (!g.r.constants.contains(name))
            return fail(g.arena, "the registry has no API constant {s}", .{name});
        try g.used_constants.put(g.arena, name, {});
    }

    pub fn members(g: *Generator, def: *const reg.TypeDef) Error![]const Member {
        if (g.members_cache.get(def.name)) |cached| return cached;
        var list: std.ArrayList(Member) = .empty;
        var it = def.node.elements();
        while (it.next()) |child| {
            if (!std.mem.eql(u8, child.tag, "member") or !reg.appliesTo(child, g.w.api)) continue;
            const decl = try g.parseDecl(child);
            const raw = try g.paramName(decl);
            try list.append(g.arena, .{ .decl = decl, .zig_name = try g.id(raw), .raw_name = raw });
        }
        try g.members_cache.put(g.arena, def.name, list.items);
        return list.items;
    }

    // ---------------------------------------------------------------------
    // Enumerations
    // ---------------------------------------------------------------------

    /// Everything about an enum's numbers, resolved: the registry's block, plus
    /// what the selected features and extensions add to it.
    pub fn enumInfo(g: *Generator, name: []const u8) Error!*EnumInfo {
        if (g.enum_cache.get(name)) |cached| return cached;

        const block = g.r.enum_blocks.get(name);
        const flags_name = g.bits_to_flags.get(name);
        const is_flags = (block != null and block.?.is_bitmask) or flags_name != null;

        var bits: u8 = if (block) |b| b.bitwidth else 32;
        if (flags_name) |f| {
            const def = g.r.find(f).?;
            if (def.node.child("type")) |t| {
                if (std.mem.eql(u8, try t.textContent(g.arena), "VkFlags64")) bits = 64;
            }
        }

        // Every value the registry gives this enum, selected or not, so that an
        // alias can be resolved wherever its target sits.
        var everything: std.StringHashMapUnmanaged(reg.EnumValue) = .empty;
        if (block) |b| for (b.values) |v| try everything.put(g.arena, v.name, v);
        for (g.r.providers) |p| for (p.additions) |a| {
            if (std.mem.eql(u8, g.r.canonical(a.extends), name)) try everything.put(g.arena, a.value.name, a.value);
        };

        // What is actually wanted, in registry order.
        var wanted: std.ArrayList(reg.EnumValue) = .empty;
        if (block) |b| try wanted.appendSlice(g.arena, b.values);
        for (g.r.providers) |p| {
            if (!g.isSelected(p.name)) continue;
            for (p.additions) |a| {
                if (std.mem.eql(u8, g.r.canonical(a.extends), name)) try wanted.append(g.arena, a.value);
            }
        }

        var entries: std.ArrayList(Entry) = .empty;
        var seen: std.StringHashMapUnmanaged(i128) = .empty;
        var is_alias: std.StringHashMapUnmanaged(bool) = .empty;
        for (wanted.items) |v| {
            const number = try g.resolveEnumValue(name, v, &everything);
            if (seen.get(v.name)) |previous| {
                if (previous != number) return fail(g.arena, "{s}: {s} has two different values ({d} and {d})", .{ name, v.name, previous, number });
                continue;
            }
            try seen.put(g.arena, v.name, number);
            try is_alias.put(g.arena, v.name, v.value == .alias);

            var zig_name = try names.enumerantName(g.arena, name, v.name, is_flags, g.r.tags);
            if (zig_name.len == 0) return fail(g.arena, "{s}: the name of {s} comes out empty", .{ name, v.name });
            if (is_flags and zig_name[0] >= '0' and zig_name[0] <= '9') zig_name = try std.fmt.allocPrint(g.arena, "x{s}", .{zig_name});

            // The registry sometimes has `X_BIT` and `X` for one value, and
            // they come out as one name. The second says nothing new.
            var duplicate = false;
            for (entries.items) |earlier| {
                if (std.mem.eql(u8, earlier.zig_name, zig_name) and earlier.number == number) duplicate = true;
            }
            if (duplicate) continue;
            try entries.append(g.arena, .{ .reg_name = v.name, .zig_name = zig_name, .number = number, .primary = false, .comment = v.comment });
        }

        // Who is the member and who is a constant that names it. Among the
        // entries with one value the registry's own name wins over an alias,
        // then the one that came first. Flags have room for one bit each; a
        // value that is not one bit (`0`, `ALL_GRAPHICS`) is always a constant.
        const items = entries.items;
        for (items, 0..) |*e, i| {
            const single_bit = is_flags and e.number > 0 and (e.number & (e.number - 1)) == 0;
            if (is_flags and !single_bit) continue;
            var best = i;
            for (items, 0..) |other, j| {
                if (other.number != e.number) continue;
                const other_alias = is_alias.get(other.reg_name).?;
                const best_alias = is_alias.get(items[best].reg_name).?;
                if (best_alias and !other_alias) best = j;
            }
            // The first of the equally good ones.
            for (items, 0..) |other, j| {
                if (other.number == e.number and is_alias.get(other.reg_name).? == is_alias.get(items[best].reg_name).?) {
                    best = j;
                    break;
                }
            }
            if (best == i) {
                e.primary = true;
                if (is_flags) e.bit = @intCast(@ctz(@as(u128, @intCast(e.number))));
            }
        }
        for (items) |*e| {
            if (e.primary) continue;
            for (items, 0..) |other, j| {
                if (other.primary and other.number == e.number) {
                    e.target = j;
                    break;
                }
            }
        }

        // Two names that end up the same Zig name are a bug in the rules, not
        // something to paper over.
        var used: Set = .empty;
        for (items) |e| {
            if (used.contains(e.zig_name))
                return fail(g.arena, "{s}: two enumerants are both called '{s}' in Zig (one is {s})", .{ name, e.zig_name, e.reg_name });
            try used.put(g.arena, e.zig_name, {});
        }

        var zero_name: ?[]const u8 = null;
        for (items) |e| if (e.number == 0 and e.primary) {
            zero_name = e.zig_name;
        };

        const info = try g.arena.create(EnumInfo);
        info.* = .{ .name = name, .is_flags = is_flags, .bits = bits, .entries = items, .zero_name = zero_name };
        try g.enum_cache.put(g.arena, name, info);
        return info;
    }

    pub fn resolveEnumValue(g: *Generator, enum_name: []const u8, v: reg.EnumValue, everything: *const std.StringHashMapUnmanaged(reg.EnumValue)) Error!i128 {
        var current = v;
        var guard: usize = 0;
        while (true) : (guard += 1) {
            switch (current.value) {
                .number => |n| return n,
                .alias => |target| {
                    current = everything.get(target) orelse
                        return fail(g.arena, "{s}: {s} is an alias of {s}, which the registry does not define for this enum", .{ enum_name, v.name, target });
                },
            }
            if (guard > 16) return fail(g.arena, "{s}: a chain of aliases starting at {s} does not end", .{ enum_name, v.name });
        }
    }

    // ---------------------------------------------------------------------
    // Types, as Zig text
    // ---------------------------------------------------------------------

    pub const Base = struct {
        text: []const u8,
        /// A dispatchable handle, a function pointer: something whose value
        /// can be null on its own.
        nullable: bool = false,
        /// `anyopaque`: only ever pointed at, never a `[*]`.
        is_opaque: bool = false,
        is_u8: bool = false,
    };

    pub fn baseType(g: *Generator, prefix: []const u8, type_name: []const u8) Error!Base {
        if (cPrimitive(type_name)) |zig| {
            return .{ .text = zig, .is_u8 = std.mem.eql(u8, zig, "u8") };
        }
        const canon = g.r.canonical(type_name);
        if (cPrimitive(canon)) |zig| return .{ .text = zig, .is_u8 = std.mem.eql(u8, zig, "u8") };
        const def = g.r.find(canon) orelse return fail(g.arena, "the registry has no type {s}", .{canon});

        switch (def.category) {
            .external => {
                const zig = g.platform_types.get(def.name) orelse
                    return fail(g.arena, "no .platform_types entry for {s}", .{def.name});
                return .{
                    .text = zig,
                    .nullable = std.mem.startsWith(u8, zig, "*") or std.mem.startsWith(u8, zig, "[*"),
                    .is_opaque = std.mem.eql(u8, zig, "anyopaque"),
                };
            },
            .handle => {
                return .{
                    .text = try std.fmt.allocPrint(g.arena, "{s}{s}", .{ prefix, try g.zigTypeName(canon) }),
                    .nullable = try def.isDispatchable(g.arena),
                };
            },
            .funcpointer => return .{
                .text = try std.fmt.allocPrint(g.arena, "{s}{s}", .{ prefix, try g.zigTypeName(canon) }),
                .nullable = true,
            },
            .enumeration => {
                // A FlagBits enum is spelled as the flags type it belongs to.
                const target = g.bits_to_flags.get(canon) orelse canon;
                return .{ .text = try std.fmt.allocPrint(g.arena, "{s}{s}", .{ prefix, try g.zigTypeName(target) }) };
            },
            else => return .{ .text = try std.fmt.allocPrint(g.arena, "{s}{s}", .{ prefix, try g.zigTypeName(canon) }) },
        }
    }

    pub const Mode = enum { member, param, ret };

    /// The Zig type of a declaration.
    ///
    /// Pointers first, from the innermost out, then array dimensions: the C
    /// declarator `const char* names[3]` is an array of three pointers.
    pub fn declType(g: *Generator, prefix: []const u8, decl: Decl, siblings: []const Decl, mode: Mode) Error![]const u8 {
        const base = try g.baseType(prefix, decl.type_name);
        const depth = decl.pointerDepth();
        var text: []const u8 = if (std.mem.eql(u8, base.text, "void") and depth > 0) "anyopaque" else base.text;
        const opaque_base = base.is_opaque or (std.mem.eql(u8, base.text, "void") and depth > 0);

        var i: usize = 0;
        while (i < depth) : (i += 1) {
            const k = depth - 1 - i; // counted from the outermost, like `len` and `optional`
            const pointee_const = if (i == 0) decl.const_base else decl.const_levels[i - 1];
            const len = decl.lenAt(k);

            const kind: []const u8 = if (i == 0 and opaque_base)
                "*"
            else if (len != null and std.mem.eql(u8, len.?, "null-terminated") and i == 0 and base.is_u8)
                "[*:0]"
            else if (len != null)
                "[*]"
            else
                "*";

            // The pointer may be null when the registry says so, or - for the
            // outermost one - when its length is a count that may be zero.
            var optional_here = if (k == 0) decl.isOptional() else k < decl.optional.len and decl.optional[k];
            if (!optional_here and k == 0 and mode != .ret) {
                if (len) |l| {
                    for (siblings) |s| {
                        if (std.mem.eql(u8, s.name, l) and s.isOptional()) optional_here = true;
                    }
                }
            }
            if (mode == .ret) optional_here = true;

            text = try std.fmt.allocPrint(g.arena, "{s}{s}{s}{s}", .{
                if (optional_here) "?" else "",
                kind,
                if (pointee_const) "const " else "",
                text,
            });
        }

        if (depth == 0 and base.nullable and (decl.isOptional() or mode == .ret)) {
            text = try std.fmt.allocPrint(g.arena, "?{s}", .{text});
        }

        // An array parameter is a pointer to the array in C: `const float c[4]`
        // is `const float*`. Zig says so with a pointer to an array.
        if (mode == .param and decl.dims.len > 0) {
            var inner = text;
            var d = decl.dims.len;
            while (d > 0) : (d -= 1) {
                inner = try std.fmt.allocPrint(g.arena, "[{s}]{s}", .{ try g.dimText(prefix, decl.dims[d - 1]), inner });
            }
            return std.fmt.allocPrint(g.arena, "*{s}{s}", .{ if (decl.const_base and depth == 0) "const " else "", inner });
        }

        var d = decl.dims.len;
        while (d > 0) : (d -= 1) {
            text = try std.fmt.allocPrint(g.arena, "[{s}]{s}", .{ try g.dimText(prefix, decl.dims[d - 1]), text });
        }
        return text;
    }

    pub fn dimText(g: *Generator, prefix: []const u8, dim: Decl.Dim) Error![]const u8 {
        switch (dim) {
            .number => |n| return std.fmt.allocPrint(g.arena, "{d}", .{n}),
            .constant => |c| {
                try g.useConstant(c);
                return std.fmt.allocPrint(g.arena, "{s}{s}", .{ prefix, try g.constantZigName(c) });
            },
        }
    }

    pub fn constantZigName(g: *Generator, reg_name: []const u8) Error![]const u8 {
        if (g.renames.get(reg_name)) |to| return to;
        return g.id(try names.constantName(g.arena, reg_name));
    }

    /// What a member is set to when nobody says.
    ///
    /// `sType` is its tag, always. A member the registry marks `optional` - zero
    /// or null is allowed - defaults to that, and so does every member of a
    /// struct that is a set of switches (all `VkBool32`) or that
    /// `zero_defaults` names. Members a caller must decide - a size, a usage, a
    /// format - have no default, and leaving one out is a compile error.
    pub fn memberDefault(g: *Generator, def: *const reg.TypeDef, m: Member, siblings: []const Decl, all_zero: bool, text: []const u8) Error!?[]const u8 {
        const decl = m.decl;
        if (def.category == .union_) return null;

        if (std.mem.eql(u8, decl.name, "sType")) {
            const value = decl.values orelse return null;
            const first = value[0 .. std.mem.indexOfScalar(u8, value, ',') orelse value.len];
            const info = try g.enumInfo(g.r.canonical(decl.type_name));
            for (info.entries) |e| {
                if (std.mem.eql(u8, e.reg_name, first)) {
                    return try std.fmt.allocPrint(g.arena, ".{s}", .{try g.id(info.entries[e.target orelse indexOf(info.entries, e.reg_name)].zig_name)});
                }
            }
            return fail(g.arena, "{s} is tagged {s}, which comes from an extension wanted.zon does not list: add the extension that defines it to .extensions", .{ def.name, first });
        }

        const returned_only = def.node.attr("returnedonly") != null and std.mem.eql(u8, def.node.attr("returnedonly").?, "true");
        if (returned_only and !std.mem.eql(u8, decl.name, "pNext")) return null;
        if (decl.dims.len > 0) return null;

        const optional_here = blk: {
            if (decl.isOptional()) break :blk true;
            if (decl.pointerDepth() > 0) {
                if (decl.lenAt(0)) |l| for (siblings) |s| {
                    if (std.mem.eql(u8, s.name, l) and s.isOptional()) break :blk true;
                };
            }
            break :blk false;
        };
        if (!optional_here and !all_zero) return null;

        // Only what the type can hold.
        if (decl.pointerDepth() > 0) return if (text.len > 0 and text[0] == '?') "null" else null;

        const canon = g.r.canonical(decl.type_name);
        if (cPrimitive(canon)) |zig| {
            if (std.mem.eql(u8, zig, "void")) return null;
            return "0";
        }
        const type_def = g.r.find(canon) orelse return null;
        switch (type_def.category) {
            .basetype => return "0",
            .handle => {
                if (try type_def.isDispatchable(g.arena)) return if (text.len > 0 and text[0] == '?') "null" else null;
                return ".none";
            },
            .enumeration => {
                if (g.bits_to_flags.get(canon)) |flags| {
                    return if (try g.flagsIsPacked(flags)) ".{}" else "0";
                }
                const info = try g.enumInfo(canon);
                if (info.zero_name) |z| return try std.fmt.allocPrint(g.arena, ".{s}", .{try g.id(z)});
                return "@enumFromInt(0)";
            },
            .bitmask => return if (try g.flagsIsPacked(canon)) ".{}" else "0",
            .funcpointer => return if (text.len > 0 and text[0] == '?') "null" else null,
            else => return null,
        }
    }

    pub fn indexOf(entries: []const Entry, reg_name: []const u8) usize {
        for (entries, 0..) |e, i| if (std.mem.eql(u8, e.reg_name, reg_name)) return i;
        unreachable;
    }

    /// A flags typedef is a packed struct of its bits when the registry says
    /// which bits there are, and a bare integer when it does not (reserved).
    pub fn flagsIsPacked(g: *Generator, flags_name: []const u8) Error!bool {
        const def = g.r.find(g.r.canonical(flags_name)) orelse return false;
        return def.node.attr("requires") != null or def.node.attr("bitvalues") != null;
    }
};

pub fn replaceChar(arena: Allocator, text: []const u8, from: u8, to: u8) Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, text);
    for (out) |*c| if (c.* == from) {
        c.* = to;
    };
    return out;
}
