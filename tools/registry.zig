// SPDX-License-Identifier: BSL-1.0

//! The Vulkan registry, read into the shape the generator asks questions of.
//!
//! `vk.xml` is one document in six parts - platforms, tags, types, enums,
//! commands, and the features and extensions that say which of the rest belong
//! to which version. This reads all six, keeps them in the registry's own order
//! (which is what makes the output deterministic), and answers the questions
//! the generator has:
//!
//!   * what is this type, and what does it need?
//!   * which numbers does this enum have, given the versions and extensions
//!     that were asked for?
//!   * which feature introduced this command?
//!
//! Nothing here knows the name of any Vulkan type or command. What is wanted is
//! `wanted.zon`'s business; what exists is the registry's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const Node = xml.Node;

pub const Error = Allocator.Error || error{Registry};

/// Set by `fail`, so a caller can print what was wrong.
pub var last_error: []const u8 = "";

fn fail(arena: Allocator, comptime fmt: []const u8, args: anytype) error{Registry} {
    last_error = std.fmt.allocPrint(arena, fmt, args) catch "out of memory while reporting an error";
    return error.Registry;
}

// -------------------------------------------------------------------------
// Declarations: how the registry writes C
// -------------------------------------------------------------------------

/// One C declaration - a struct member, a command parameter, a return type -
/// taken apart. The registry writes these as mixed content and this is the
/// only place that reads it.
pub const Decl = struct {
    /// The registry's name, or empty for a bare type (a function's return).
    name: []const u8,
    /// The base type, as the registry spells it: `uint32_t`, `VkBuffer`, `char`.
    type_name: []const u8,
    /// Is the base type `const`? In `const char*` it is the `char`.
    const_base: bool,
    /// One entry per `*`, innermost first: is that pointer itself `const`?
    /// `const char* const*` is `{ true, false }`.
    const_levels: []const bool,
    /// `[2][3]` is `{ 2, 3 }`: the outermost dimension first.
    dims: []const Dim,
    /// A bit-field width, which this generator refuses.
    bit_width: ?[]const u8,
    /// `optional="true,false"`, one flag per pointer level from the outermost
    /// in, the last one being the value at the end of the chain.
    optional: []const bool,
    /// `len="count,null-terminated"`, one entry per pointer level from the
    /// outermost in.
    len: []const []const u8,
    /// `values="VK_STRUCTURE_TYPE_..."`: what a member has to be set to.
    values: ?[]const u8,
    comment: ?[]const u8,
    /// `noautovalidity="true"`: the validity language does not say this pointer
    /// has to be valid. On an array pointer that means which of several is used
    /// depends on something else - `VkWriteDescriptorSet` has three, and one is.
    no_auto_validity: bool = false,

    pub const Dim = union(enum) {
        number: usize,
        constant: []const u8,
    };

    pub fn pointerDepth(self: Decl) usize {
        return self.const_levels.len;
    }

    /// Whether the outermost thing - the pointer, or the value if there is no
    /// pointer - may be null or zero.
    ///
    /// The registry says so with `optional`, and also - for an array that only
    /// some of its siblings use - with `noautovalidity`, which is the one place
    /// it says "not always there" without saying "optional".
    pub fn isOptional(self: Decl) bool {
        if (self.optional.len > 0 and self.optional[0]) return true;
        return self.const_levels.len > 0 and self.no_auto_validity and self.len.len > 0;
    }

    /// The `len` entry for pointer level `k`, counted from the outermost.
    pub fn lenAt(self: Decl, k: usize) ?[]const u8 {
        return if (k < self.len.len) self.len[k] else null;
    }
};

fn splitList(arena: Allocator, text: []const u8, separator: u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, separator);
    while (it.next()) |part| try list.append(arena, std.mem.trim(u8, part, " \t\r\n"));
    return list.items;
}

/// Read a `<member>`, `<param>` or `<proto>`.
pub fn parseDecl(arena: Allocator, node: *const Node) Error!Decl {
    var type_name: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var comment: ?[]const u8 = null;
    var const_base = false;
    var const_levels: std.ArrayList(bool) = .empty;
    var suffix: std.ArrayList(u8) = .empty;

    const Stage = enum { before_type, after_type, after_name };
    var stage: Stage = .before_type;

    for (node.children) |child| switch (child) {
        .text => |text| switch (stage) {
            .before_type => {
                var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
                while (words.next()) |word| {
                    if (std.mem.eql(u8, word, "const")) const_base = true else if (!std.mem.eql(u8, word, "struct") and !std.mem.eql(u8, word, "union"))
                        return fail(arena, "unexpected '{s}' before a type in <{s}>", .{ word, node.tag });
                }
            },
            .after_type => {
                var i: usize = 0;
                while (i < text.len) {
                    switch (text[i]) {
                        ' ', '\t', '\r', '\n' => i += 1,
                        '*' => {
                            try const_levels.append(arena, false);
                            i += 1;
                        },
                        else => {
                            if (std.mem.startsWith(u8, text[i..], "const")) {
                                if (const_levels.items.len == 0)
                                    return fail(arena, "a 'const' after the type but before any '*' in <{s}>", .{node.tag});
                                const_levels.items[const_levels.items.len - 1] = true;
                                i += "const".len;
                            } else return fail(arena, "unexpected '{s}' after a type in <{s}>", .{ text[i..], node.tag });
                        },
                    }
                }
            },
            .after_name => try suffix.appendSlice(arena, text),
        },
        .element => |e| {
            if (std.mem.eql(u8, e.tag, "type")) {
                if (type_name != null) return fail(arena, "two <type> in one <{s}>", .{node.tag});
                type_name = try e.textContent(arena);
                stage = .after_type;
            } else if (std.mem.eql(u8, e.tag, "name")) {
                name = try e.textContent(arena);
                stage = .after_name;
            } else if (std.mem.eql(u8, e.tag, "enum")) {
                try suffix.appendSlice(arena, try e.textContent(arena));
            } else if (std.mem.eql(u8, e.tag, "comment")) {
                comment = std.mem.trim(u8, try e.textContent(arena), " \t\r\n");
            } else return fail(arena, "unexpected <{s}> inside <{s}>", .{ e.tag, node.tag });
        },
    };

    const dims_and_bits = try parseSuffix(arena, suffix.items);

    const optional = if (node.attr("optional")) |text| blk: {
        const words = try splitList(arena, text, ',');
        const flags = try arena.alloc(bool, words.len);
        for (words, 0..) |word, i| flags[i] = std.mem.eql(u8, word, "true");
        break :blk flags;
    } else &[_]bool{};

    return .{
        .name = name orelse "",
        .type_name = type_name orelse return fail(arena, "a <{s}> with no <type>", .{node.tag}),
        .const_base = const_base,
        .const_levels = const_levels.items,
        .dims = dims_and_bits.dims,
        .bit_width = dims_and_bits.bits,
        .optional = optional,
        .len = if (node.attr("len")) |text| try splitList(arena, text, ',') else &.{},
        .values = node.attr("values"),
        .comment = comment,
        .no_auto_validity = if (node.attr("noautovalidity")) |v| std.mem.eql(u8, v, "true") else false,
    };
}

const Suffix = struct { dims: []const Decl.Dim, bits: ?[]const u8 };

/// What follows a name: `[4]`, `[VK_UUID_SIZE]`, `[2][3]`, `:8`, or nothing.
fn parseSuffix(arena: Allocator, text: []const u8) Error!Suffix {
    var dims: std.ArrayList(Decl.Dim) = .empty;
    var bits: ?[]const u8 = null;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            ' ', '\t', '\r', '\n' => i += 1,
            '[' => {
                const end = std.mem.indexOfScalarPos(u8, text, i, ']') orelse
                    return fail(arena, "an unterminated array size in '{s}'", .{text});
                const inner = std.mem.trim(u8, text[i + 1 .. end], " ");
                if (std.fmt.parseInt(usize, inner, 10)) |n| {
                    try dims.append(arena, .{ .number = n });
                } else |_| {
                    for (inner) |c| switch (c) {
                        'A'...'Z', '0'...'9', '_' => {},
                        else => return fail(arena, "an array size this generator cannot read: '{s}'", .{inner}),
                    };
                    try dims.append(arena, .{ .constant = inner });
                }
                i = end + 1;
            },
            ':' => {
                bits = std.mem.trim(u8, text[i + 1 ..], " ");
                i = text.len;
            },
            else => return fail(arena, "unexpected '{s}' after a name", .{text[i..]}),
        }
    }
    return .{ .dims = dims.items, .bits = bits };
}

// -------------------------------------------------------------------------
// The registry
// -------------------------------------------------------------------------

pub const Category = enum {
    /// `typedef uint32_t VkBool32;`
    basetype,
    /// `VK_DEFINE_HANDLE(VkInstance)`.
    handle,
    /// `VkFormat`: the type is here, its numbers are in an `<enums>` block.
    enumeration,
    /// `VkQueueFlags`: the flags type, whose bits are an enumeration of its own.
    bitmask,
    funcpointer,
    structure,
    union_,
    /// Named by the registry, defined by somebody else's header: `HWND`, `Window`.
    external,
};

pub const TypeDef = struct {
    name: []const u8,
    category: Category,
    node: *Node,
    alias_of: ?[]const u8 = null,
    /// Where the registry lists it, for a deterministic output order.
    order: usize,

    /// A handle is dispatchable - a pointer - unless the registry defines it
    /// with `VK_DEFINE_NON_DISPATCHABLE_HANDLE`.
    pub fn isDispatchable(self: TypeDef, arena: Allocator) Allocator.Error!bool {
        std.debug.assert(self.category == .handle);
        const inner = try self.node.textContent(arena);
        return std.mem.indexOf(u8, inner, "VK_DEFINE_HANDLE") != null;
    }
};

/// One name and number of an enum. Aliases hold the name of what they alias
/// until `Registry.resolve` has all of them.
pub const EnumValue = struct {
    name: []const u8,
    value: union(enum) {
        number: i128,
        alias: []const u8,
    },
    /// A flag bit is a position rather than a value; the number is `1 << bit`.
    is_bit: bool = false,
    comment: ?[]const u8 = null,
};

pub const EnumBlock = struct {
    name: []const u8,
    is_bitmask: bool,
    /// 32 or 64: the width of the flags type, from `bitwidth`.
    bitwidth: u8,
    values: []const EnumValue,
};

pub const Constant = struct {
    name: []const u8,
    type_name: []const u8,
    value: []const u8,
};

pub const Command = struct {
    name: []const u8,
    node: ?*Node,
    alias_of: ?[]const u8,
};

/// An enumerant that a feature or an extension adds to somebody else's enum.
pub const Addition = struct {
    extends: []const u8,
    value: EnumValue,
    /// The feature or extension that adds it.
    provider: []const u8,
};

/// The part of a `<feature>` or `<extension>` that says what it brings.
pub const Require = struct {
    types: []const []const u8,
    commands: []const []const u8,
    constants: []const []const u8,
};

pub const Provider = struct {
    name: []const u8,
    is_extension: bool,
    /// What this depends on, as the registry writes it: names joined by `,`
    /// and `+`, with parentheses.
    depends: []const u8,
    platform: ?[]const u8,
    /// `instance` or `device` for an extension, from `type=`.
    kind: ?[]const u8,
    requires: []const Require,
    additions: []const Addition,
};

pub const Registry = struct {
    arena: Allocator,
    api: []const u8,
    header_version: []const u8,
    types: std.StringHashMapUnmanaged(*TypeDef),
    /// Every type in registry order.
    type_list: []const *TypeDef,
    enum_blocks: std.StringHashMapUnmanaged(*EnumBlock),
    constants: std.StringHashMapUnmanaged(Constant),
    commands: std.StringHashMapUnmanaged(*Command),
    command_list: []const *Command,
    /// Features first, then extensions, each in file order.
    providers: []const Provider,
    tags: []const []const u8,
    /// `win32` -> `VK_USE_PLATFORM_WIN32_KHR`.
    platforms: std.StringHashMapUnmanaged([]const u8),

    pub fn find(self: *const Registry, name: []const u8) ?*TypeDef {
        return self.types.get(name);
    }

    pub fn provider(self: *const Registry, name: []const u8) ?*const Provider {
        for (self.providers) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    /// Follow an alias to what it names.
    pub fn canonical(self: *const Registry, name: []const u8) []const u8 {
        var current = name;
        var guard: usize = 0;
        while (self.types.get(current)) |def| : (guard += 1) {
            if (def.alias_of) |target| current = target else break;
            if (guard > 16) break;
        }
        return current;
    }

    pub fn canonicalCommand(self: *const Registry, name: []const u8) []const u8 {
        var current = name;
        var guard: usize = 0;
        while (self.commands.get(current)) |cmd| : (guard += 1) {
            if (cmd.alias_of) |target| current = target else break;
            if (guard > 16) break;
        }
        return current;
    }

    /// Is `name` a vendor tag - `KHR`, `EXT`, `NV`?
    pub fn isTag(self: *const Registry, name: []const u8) bool {
        for (self.tags) |t| if (std.mem.eql(u8, t, name)) return true;
        return false;
    }
};

/// Does an `api="vulkan,vulkansc"` attribute include `api`? No attribute
/// means every API.
pub fn appliesTo(node: *const Node, api: []const u8) bool {
    const list = node.attr("api") orelse return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |item| if (std.mem.eql(u8, item, api)) return true;
    return false;
}

/// Read a number the way the registry writes them: decimal or hex, with or
/// without a `U`, `L`, `LL` or `ULL`.
pub fn parseNumber(text: []const u8) ?i128 {
    var trimmed = std.mem.trim(u8, text, " ");
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == 'U' or trimmed[trimmed.len - 1] == 'L' or
        trimmed[trimmed.len - 1] == 'u' or trimmed[trimmed.len - 1] == 'l'))
        trimmed = trimmed[0 .. trimmed.len - 1];
    return std.fmt.parseInt(i128, trimmed, 0) catch null;
}

pub fn load(arena: Allocator, root: *Node, api: []const u8) Error!Registry {
    if (!std.mem.eql(u8, root.tag, "registry")) return fail(arena, "the root element is <{s}>, not <registry>", .{root.tag});

    var types: std.StringHashMapUnmanaged(*TypeDef) = .empty;
    var type_list: std.ArrayList(*TypeDef) = .empty;
    var enum_blocks: std.StringHashMapUnmanaged(*EnumBlock) = .empty;
    var constants: std.StringHashMapUnmanaged(Constant) = .empty;
    var commands: std.StringHashMapUnmanaged(*Command) = .empty;
    var command_list: std.ArrayList(*Command) = .empty;
    var providers: std.ArrayList(Provider) = .empty;
    var extension_nodes: std.ArrayList(*Node) = .empty;
    var tags: std.ArrayList([]const u8) = .empty;
    var platforms: std.StringHashMapUnmanaged([]const u8) = .empty;
    var header_version: []const u8 = "";

    var top = root.elements();
    while (top.next()) |section| {
        if (std.mem.eql(u8, section.tag, "platforms")) {
            var it = section.elements();
            while (it.next()) |p| {
                const name = p.attr("name") orelse continue;
                try platforms.put(arena, name, p.attr("protect") orelse "");
            }
        } else if (std.mem.eql(u8, section.tag, "tags")) {
            var it = section.elements();
            while (it.next()) |t| if (t.attr("name")) |name| try tags.append(arena, name);
        } else if (std.mem.eql(u8, section.tag, "types")) {
            var it = section.elements();
            while (it.next()) |t| {
                if (!std.mem.eql(u8, t.tag, "type")) continue;
                if (!appliesTo(t, api)) continue;
                if (std.mem.eql(u8, t.attr("category") orelse "", "define")) {
                    if (header_version.len == 0) header_version = try readHeaderVersion(arena, t) orelse "";
                    continue;
                }
                const def = try readType(arena, t, type_list.items.len) orelse continue;
                if (types.get(def.name)) |_| return fail(arena, "the registry defines type {s} twice for api {s}", .{ def.name, api });
                try types.put(arena, def.name, def);
                try type_list.append(arena, def);
            }
        } else if (std.mem.eql(u8, section.tag, "enums")) {
            try readEnums(arena, section, api, &enum_blocks, &constants);
        } else if (std.mem.eql(u8, section.tag, "commands")) {
            var it = section.elements();
            while (it.next()) |c| {
                if (!std.mem.eql(u8, c.tag, "command") or !appliesTo(c, api)) continue;
                const cmd = try arena.create(Command);
                if (c.attr("alias")) |target| {
                    cmd.* = .{ .name = c.attr("name") orelse return fail(arena, "an alias <command> with no name", .{}), .node = null, .alias_of = target };
                } else {
                    const proto = c.child("proto") orelse return fail(arena, "a <command> with no <proto>", .{});
                    const name_node = proto.child("name") orelse return fail(arena, "a <proto> with no <name>", .{});
                    cmd.* = .{ .name = try name_node.textContent(arena), .node = c, .alias_of = null };
                }
                if (commands.get(cmd.name)) |_| return fail(arena, "the registry defines command {s} twice for api {s}", .{ cmd.name, api });
                try commands.put(arena, cmd.name, cmd);
                try command_list.append(arena, cmd);
            }
        } else if (std.mem.eql(u8, section.tag, "feature")) {
            if (!appliesTo(section, api)) continue;
            try providers.append(arena, try readProvider(arena, section, false, 0, api));
        } else if (std.mem.eql(u8, section.tag, "extensions")) {
            var it = section.elements();
            while (it.next()) |e| if (std.mem.eql(u8, e.tag, "extension")) try extension_nodes.append(arena, e);
        }
    }

    // Extensions come after features, in file order. One that is not supported
    // for this API (`supported="disabled"`, or for another API) is skipped: it
    // cannot be asked for, and its numbers must not leak into an enum.
    for (extension_nodes.items) |e| {
        const supported = e.attr("supported") orelse "";
        var ok = false;
        var it = std.mem.splitScalar(u8, supported, ',');
        while (it.next()) |item| if (std.mem.eql(u8, item, api)) {
            ok = true;
        };
        if (!ok) continue;
        const number_text = e.attr("number") orelse return fail(arena, "extension {s} has no number", .{e.attr("name") orelse "?"});
        const number = std.fmt.parseInt(u32, number_text, 10) catch return fail(arena, "extension {s} has a number that is not a number", .{e.attr("name").?});
        try providers.append(arena, try readProvider(arena, e, true, number, api));
    }

    return .{
        .arena = arena,
        .api = api,
        .header_version = header_version,
        .types = types,
        .type_list = type_list.items,
        .enum_blocks = enum_blocks,
        .constants = constants,
        .commands = commands,
        .command_list = command_list.items,
        .providers = providers.items,
        .tags = tags.items,
        .platforms = platforms,
    };
}

fn readHeaderVersion(arena: Allocator, node: *const Node) Error!?[]const u8 {
    const text = try node.textContent(arena);
    const marker = "#define VK_HEADER_VERSION ";
    const at = std.mem.indexOf(u8, text, marker) orelse return null;
    const rest = text[at + marker.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;
    return rest[0..end];
}

fn readType(arena: Allocator, t: *Node, order: usize) Error!?*TypeDef {
    const category_text = t.attr("category");
    const def = try arena.create(TypeDef);

    if (category_text == null) {
        // `<type requires="X11/Xlib.h" name="Display"/>`, or one of the plain C
        // types the registry names so that other types can refer to them.
        const name = t.attr("name") orelse return null;
        def.* = .{ .name = name, .category = .external, .node = t, .order = order };
        return def;
    }
    const category = category_text.?;

    if (std.mem.eql(u8, category, "include")) return null;

    if (std.mem.eql(u8, category, "basetype")) {
        const name_node = t.child("name") orelse return null;
        def.* = .{ .name = try name_node.textContent(arena), .category = if (t.child("type") != null) .basetype else .external, .node = t, .order = order };
        return def;
    }

    const name = if (t.attr("name")) |n| n else if (t.child("name")) |n| try n.textContent(arena) else if (t.child("proto")) |p| blk: {
        const n = p.child("name") orelse return fail(arena, "a funcpointer with no name", .{});
        break :blk try n.textContent(arena);
    } else return fail(arena, "a <type category=\"{s}\"> with no name", .{category});

    const cat: Category = if (std.mem.eql(u8, category, "handle"))
        .handle
    else if (std.mem.eql(u8, category, "enum"))
        .enumeration
    else if (std.mem.eql(u8, category, "bitmask"))
        .bitmask
    else if (std.mem.eql(u8, category, "funcpointer"))
        .funcpointer
    else if (std.mem.eql(u8, category, "struct"))
        .structure
    else if (std.mem.eql(u8, category, "union"))
        .union_
    else
        return fail(arena, "type {s} has a category this generator does not know: {s}", .{ name, category });

    def.* = .{ .name = name, .category = cat, .node = t, .alias_of = t.attr("alias"), .order = order };
    return def;
}

fn readEnums(
    arena: Allocator,
    section: *Node,
    api: []const u8,
    blocks: *std.StringHashMapUnmanaged(*EnumBlock),
    constants: *std.StringHashMapUnmanaged(Constant),
) Error!void {
    const name = section.attr("name") orelse return;
    const kind = section.attr("type") orelse return;

    if (std.mem.eql(u8, kind, "constants")) {
        var it = section.elements();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.tag, "enum") or !appliesTo(e, api)) continue;
            const const_name = e.attr("name") orelse continue;
            // An alias of another constant carries no value of its own.
            const value = e.attr("value") orelse continue;
            try constants.put(arena, const_name, .{ .name = const_name, .type_name = e.attr("type") orelse "uint32_t", .value = value });
        }
        return;
    }

    const is_bitmask = std.mem.eql(u8, kind, "bitmask");
    if (!is_bitmask and !std.mem.eql(u8, kind, "enum")) return;

    var values: std.ArrayList(EnumValue) = .empty;
    var it = section.elements();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.tag, "enum") or !appliesTo(e, api)) continue;
        try values.append(arena, try readEnumValue(arena, e, null));
    }

    const block = try arena.create(EnumBlock);
    block.* = .{
        .name = name,
        .is_bitmask = is_bitmask,
        .bitwidth = if (section.attr("bitwidth")) |w| std.fmt.parseInt(u8, w, 10) catch return fail(arena, "enum {s} has a bitwidth that is not a number", .{name}) else 32,
        .values = values.items,
    };
    if (blocks.get(name)) |_| return fail(arena, "the registry has two <enums> blocks named {s}", .{name});
    try blocks.put(arena, name, block);
}

/// One `<enum>`. `extension_number` is the extension it sits in, when there is
/// one; an `extnumber=` on the element itself wins over it.
fn readEnumValue(arena: Allocator, e: *const Node, extension_number: ?u32) Error!EnumValue {
    const name = e.attr("name") orelse return fail(arena, "an <enum> with no name", .{});
    const comment = e.attr("comment");

    if (e.attr("alias")) |target| return .{ .name = name, .value = .{ .alias = target }, .comment = comment };

    if (e.attr("bitpos")) |text| {
        const bit = std.fmt.parseInt(u8, text, 10) catch return fail(arena, "enum {s} has a bitpos that is not a number", .{name});
        return .{ .name = name, .value = .{ .number = @as(i128, 1) << @intCast(bit) }, .is_bit = true, .comment = comment };
    }
    if (e.attr("value")) |text| {
        const number = parseNumber(text) orelse
            // A string, like an extension's name: not an enumerant.
            return fail(arena, "enum {s} has a value this generator cannot read: '{s}'", .{ name, text });
        return .{ .name = name, .value = .{ .number = number }, .comment = comment };
    }
    if (e.attr("offset")) |text| {
        const offset = std.fmt.parseInt(i128, text, 10) catch return fail(arena, "enum {s} has an offset that is not a number", .{name});
        const number: i128 = if (e.attr("extnumber")) |n|
            std.fmt.parseInt(i128, n, 10) catch return fail(arena, "enum {s} has an extnumber that is not a number", .{name})
        else if (extension_number) |n|
            n
        else
            return fail(arena, "enum {s} has an offset but no extension number to count from", .{name});
        var value: i128 = 1_000_000_000 + (number - 1) * 1000 + offset;
        if (e.attr("dir")) |dir| {
            if (!std.mem.eql(u8, dir, "-")) return fail(arena, "enum {s} has a dir this generator does not know: {s}", .{ name, dir });
            value = -value;
        }
        return .{ .name = name, .value = .{ .number = value }, .comment = comment };
    }
    return fail(arena, "enum {s} has no value, bitpos, offset or alias", .{name});
}

fn readProvider(arena: Allocator, node: *Node, is_extension: bool, number: u32, api: []const u8) Error!Provider {
    const name = node.attr("name") orelse return fail(arena, "a feature or extension with no name", .{});
    var requires: std.ArrayList(Require) = .empty;
    var additions: std.ArrayList(Addition) = .empty;

    var it = node.elements();
    while (it.next()) |block| {
        if (!std.mem.eql(u8, block.tag, "require") or !appliesTo(block, api)) continue;

        var types: std.ArrayList([]const u8) = .empty;
        var cmds: std.ArrayList([]const u8) = .empty;
        var consts: std.ArrayList([]const u8) = .empty;

        var items = block.elements();
        while (items.next()) |item| {
            if (!appliesTo(item, api)) continue;
            if (std.mem.eql(u8, item.tag, "type")) {
                if (item.attr("name")) |n| try types.append(arena, n);
            } else if (std.mem.eql(u8, item.tag, "command")) {
                if (item.attr("name")) |n| try cmds.append(arena, n);
            } else if (std.mem.eql(u8, item.tag, "enum")) {
                if (item.attr("extends")) |extends| {
                    const value = readEnumValue(arena, item, if (is_extension) number else null) catch |err| switch (err) {
                        error.Registry => return fail(arena, "in {s}: {s}", .{ name, last_error }),
                        else => return err,
                    };
                    try additions.append(arena, .{ .extends = extends, .value = value, .provider = name });
                } else if (item.attr("name")) |n| {
                    try consts.append(arena, n);
                }
            }
        }
        try requires.append(arena, .{ .types = types.items, .commands = cmds.items, .constants = consts.items });
    }

    return .{
        .name = name,
        .is_extension = is_extension,
        .depends = node.attr("depends") orelse "",
        .platform = node.attr("platform"),
        .kind = node.attr("type"),
        .requires = requires.items,
        .additions = additions.items,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a declaration is taken apart" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try xml.parse(arena,
        \\<r>
        \\<member optional="true" len="count,null-terminated">const <type>char</type>* const*      <name>ppNames</name><comment> Names </comment></member>
        \\<member len="null-terminated"><type>char</type> <name>layerName</name>[<enum>VK_MAX_EXTENSION_NAME_SIZE</enum>]</member>
        \\<member><type>float</type> <name>m</name>[3][4]</member>
        \\<member><type>uint32_t</type> <name>flags</name>:8</member>
        \\</r>
    , null);
    var it = root.elements();

    const names = try parseDecl(arena, it.next().?);
    try testing.expectEqualStrings("ppNames", names.name);
    try testing.expectEqualStrings("char", names.type_name);
    try testing.expect(names.const_base);
    try testing.expectEqualSlices(bool, &.{ true, false }, names.const_levels);
    try testing.expect(names.isOptional());
    try testing.expectEqualStrings("count", names.lenAt(0).?);
    try testing.expectEqualStrings("null-terminated", names.lenAt(1).?);
    try testing.expectEqualStrings("Names", names.comment.?);

    const array = try parseDecl(arena, it.next().?);
    try testing.expectEqual(@as(usize, 1), array.dims.len);
    try testing.expectEqualStrings("VK_MAX_EXTENSION_NAME_SIZE", array.dims[0].constant);

    const matrix = try parseDecl(arena, it.next().?);
    try testing.expectEqual(@as(usize, 3), matrix.dims[0].number);
    try testing.expectEqual(@as(usize, 4), matrix.dims[1].number);

    const bits = try parseDecl(arena, it.next().?);
    try testing.expectEqualStrings("8", bits.bit_width.?);
}

test "numbers are read the way the registry writes them" {
    try testing.expectEqual(@as(?i128, 5), parseNumber("5"));
    try testing.expectEqual(@as(?i128, -1), parseNumber("-1"));
    try testing.expectEqual(@as(?i128, 0x7FFFFFFF), parseNumber("0x7FFFFFFF"));
    try testing.expectEqual(@as(?i128, 0x100000000), parseNumber("0x0000000100000000ULL"));
    try testing.expectEqual(@as(?i128, null), parseNumber("\"VK_KHR_surface\""));
}
