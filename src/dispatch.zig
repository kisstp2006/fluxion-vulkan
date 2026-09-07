// SPDX-License-Identifier: CC0-1.0

//! A struct of function pointers, filled in by name.
//!
//! Vulkan hands out its commands one at a time, through a function that takes
//! a string. Everything else in this library is arranged around that, and this
//! module is the part that does it: you declare a struct whose fields are
//! named after the commands you want, and `load` fills it in.
//!
//! ```zig
//! const Draw = struct {
//!     cmdDraw: *const fn (cb: CommandBuffer, u32, u32, u32, u32) callconv(types.call) void,
//!     cmdDrawMeshTasksEXT: ?*const fn (cb: CommandBuffer, u32, u32, u32) callconv(types.call) void,
//! };
//!
//! const draw = try dispatch.load(Draw, .{ .device = .{ .get = get_proc, .handle = device } });
//! ```
//!
//! The field name is the command name with `vk` in front and the first letter
//! capitalised, so `cmdDraw` is `vkCmdDraw` and `createSwapchainKHR` is
//! `vkCreateSwapchainKHR`. Nothing is generated and nothing is registered: the
//! table is an ordinary struct, and the loading is a comptime walk over its
//! fields. A table of this library's declarations and a table of a full
//! binding's load exactly the same way.
//!
//! **The field's type says whether the command is required.** A plain function
//! pointer must be found or `load` fails. An optional one may be absent, and
//! is left `null` - which is how a command from a version or an extension you
//! did not get is meant to be handled, and why `commands.Global` can ask for
//! `vkEnumerateInstanceVersion` without refusing to run on a Vulkan 1.0
//! loader.
//!
//! **Three scopes, because Vulkan has three.** A command resolved against an
//! instance goes through the loader's trampoline, which looks at its first
//! argument and dispatches to the right driver. A command resolved against a
//! device skips that: the pointer belongs to one driver and needs no
//! indirection. On a machine with one GPU the difference is small; it is still
//! free, and `vkGetDeviceProcAddr` is the reason `commands.Instance` carries
//! it.

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");

// -------------------------------------------------------------------------
// The two functions everything comes from
// -------------------------------------------------------------------------

/// A command pointer of unknown shape, which is what both lookups return.
pub const PfnVoidFunction = *const fn () callconv(types.call) void;

/// The one symbol a loader needs out of the Vulkan library. Given a null
/// instance it answers the handful of commands that exist before there is one.
pub const PfnGetInstanceProcAddr = *const fn (
    instance: ?types.Instance,
    name: [*:0]const u8,
) callconv(types.call) ?PfnVoidFunction;

/// The same thing one level down, and the reason a device table costs nothing
/// to call through.
pub const PfnGetDeviceProcAddr = *const fn (
    device: ?types.Device,
    name: [*:0]const u8,
) callconv(types.call) ?PfnVoidFunction;

// -------------------------------------------------------------------------
// Scopes
// -------------------------------------------------------------------------

/// Which of Vulkan's three tiers a table belongs to.
pub const Scope = enum {
    /// Before there is an instance: creating one, and asking what is on offer.
    global,
    /// Dispatching on an instance or a physical device, through the loader's
    /// trampoline.
    instance,
    /// Dispatching on a device, a queue or a command buffer, straight into the
    /// driver.
    device,
};

/// Where a name is turned into a pointer.
///
/// ```zig
/// .{ .global = get_instance_proc_addr }
/// .{ .instance = .{ .get = get_instance_proc_addr, .handle = instance } }
/// .{ .device = .{ .get = get_device_proc_addr, .handle = device } }
/// ```
pub const Resolver = union(Scope) {
    global: PfnGetInstanceProcAddr,
    instance: struct { get: PfnGetInstanceProcAddr, handle: types.Instance },
    device: struct { get: PfnGetDeviceProcAddr, handle: types.Device },

    /// The pointer for one command, or `null` if this implementation has no
    /// such command.
    pub fn lookup(self: Resolver, name: [*:0]const u8) ?PfnVoidFunction {
        return switch (self) {
            .global => |get| get(null, name),
            .instance => |it| it.get(it.handle, name),
            .device => |it| it.get(it.handle, name),
        };
    }
};

// -------------------------------------------------------------------------
// Loading
// -------------------------------------------------------------------------

pub const Error = error{
    /// A command the table declared as required was not there. `Report.missing`
    /// names it.
    CommandNotFound,
};

/// What a load found, for the times when the error alone is not enough.
pub const Report = struct {
    /// How many commands were resolved.
    found: usize = 0,
    /// How many optional commands the implementation did not have. On a
    /// Vulkan 1.0 loader this is how the missing 1.1 commands show up.
    absent: usize = 0,
    /// The first required command that was not found, if any. Loading stops
    /// there, so `found` and `absent` count what came before it rather than
    /// the whole table - `names(Table).len` is the total, and it is known at
    /// compile time.
    missing: ?[:0]const u8 = null,
};

/// Fill in `Table` by looking up each of its fields.
///
/// Fails on the first required command that is not there. When you want to
/// know which one, or how many optional commands were absent, use `loadReport`.
pub fn load(comptime Table: type, resolver: Resolver) Error!Table {
    var report: Report = .{};
    return loadReport(Table, resolver, &report);
}

/// `load`, writing down what it found on the way.
///
/// The report is filled in whether the load succeeds or not, so on
/// `error.CommandNotFound` it names the command that was missing:
///
/// ```zig
/// var report: dispatch.Report = .{};
/// const table = dispatch.loadReport(Commands, resolver, &report) catch {
///     std.log.err("this driver has no {s}", .{report.missing.?});
///     return error.DriverTooOld;
/// };
/// ```
pub fn loadReport(comptime Table: type, resolver: Resolver, report: *Report) Error!Table {
    comptime validate(Table);

    report.* = .{};
    var table: Table = undefined;

    inline for (@typeInfo(Table).@"struct".fields) |field| {
        const name = comptime commandName(field.name);
        const found = for (comptime aliasesFor(Table, field.name)) |candidate| {
            if (resolver.lookup(candidate.ptr)) |pointer| break pointer;
        } else null;

        if (found) |pointer| {
            @field(table, field.name) = @ptrCast(pointer);
            report.found += 1;
        } else if (@typeInfo(field.type) == .optional) {
            @field(table, field.name) = null;
            report.absent += 1;
        } else {
            if (report.missing == null) report.missing = name;
            return error.CommandNotFound;
        }
    }

    return table;
}

/// The Vulkan name a field resolves to: `vk`, then the field name with its
/// first letter capitalised.
pub fn commandName(comptime field_name: []const u8) [:0]const u8 {
    comptime {
        if (field_name.len == 0) @compileError("a command table field needs a name");
        const spelled = "vk" ++
            [_]u8{std.ascii.toUpper(field_name[0])} ++
            field_name[1..] ++
            [_]u8{0};
        return spelled[0 .. spelled.len - 1 :0];
    }
}

/// Every command a table asks for, in field order. For printing what a table
/// wants without loading it.
pub fn names(comptime Table: type) []const [:0]const u8 {
    comptime {
        validate(Table);
        var list: []const [:0]const u8 = &.{};
        for (@typeInfo(Table).@"struct".fields) |field| {
            list = list ++ [_][:0]const u8{commandName(field.name)};
        }
        return list;
    }
}

/// Is every required command in `Table` present? For checking a driver before
/// committing to it.
pub fn available(comptime Table: type, resolver: Resolver) bool {
    _ = load(Table, resolver) catch return false;
    return true;
}

// -------------------------------------------------------------------------
// Aliases
// -------------------------------------------------------------------------

/// A table may declare other names to try when the derived one is not there:
///
/// ```zig
/// const Commands = struct {
///     getPhysicalDeviceProperties2: ?*const fn (...) callconv(types.call) void,
///
///     /// Core in 1.1, and an extension before that.
///     pub const aliases = .{
///         .getPhysicalDeviceProperties2 = .{"vkGetPhysicalDeviceProperties2KHR"},
///     };
/// };
/// ```
///
/// Which is what a promoted extension looks like: the same command under two
/// names, and which one a driver answers to depends on how old it is. The
/// derived name is always tried first.
fn aliasesFor(comptime Table: type, comptime field_name: []const u8) []const [:0]const u8 {
    comptime {
        const derived = [_][:0]const u8{commandName(field_name)};
        if (!@hasDecl(Table, "aliases")) return &derived;
        if (!@hasField(@TypeOf(Table.aliases), field_name)) return &derived;

        var list: []const [:0]const u8 = &derived;
        for (@field(Table.aliases, field_name)) |alias| list = list ++ [_][:0]const u8{alias};
        return list;
    }
}

// -------------------------------------------------------------------------
// Checking a table
// -------------------------------------------------------------------------

/// Every field must be a function pointer, or an optional one. Anything else
/// is a mistake worth catching at compile time rather than a pointer cast that
/// happens to go through.
fn validate(comptime Table: type) void {
    comptime {
        const info = @typeInfo(Table);
        if (info != .@"struct") @compileError(
            "a command table must be a struct, not " ++ @typeName(Table),
        );

        for (info.@"struct".fields) |field| {
            const inner = switch (@typeInfo(field.type)) {
                .optional => |opt| opt.child,
                else => field.type,
            };
            const bad = switch (@typeInfo(inner)) {
                .pointer => |ptr| ptr.size != .one or @typeInfo(ptr.child) != .@"fn",
                else => true,
            };
            if (bad) @compileError(
                "field '" ++ field.name ++ "' of " ++ @typeName(Table) ++
                    " is " ++ @typeName(field.type) ++ ", but a command table holds " ++
                    "function pointers - '*const fn (...) callconv(types.call) T' when the command " ++
                    "is required, '?*const fn (...) callconv(types.call) T' when it may be absent",
            );
        }
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A Vulkan that is not there: a `vkGetInstanceProcAddr` answering a fixed set
/// of names, so the loading path can be tested without a driver.
const Fake = struct {
    var absent: []const []const u8 = &.{};

    const known = [_][]const u8{
        "vkCreateInstance",
        "vkDestroyInstance",
        "vkEnumerateInstanceVersion",
        "vkGetPhysicalDeviceProperties2KHR",
    };

    fn nothing() callconv(types.call) void {}

    fn getProcAddr(instance: ?types.Instance, name: [*:0]const u8) callconv(types.call) ?PfnVoidFunction {
        _ = instance;
        const wanted = std.mem.span(name);
        for (absent) |gone| if (std.mem.eql(u8, gone, wanted)) return null;
        for (known) |candidate| if (std.mem.eql(u8, candidate, wanted)) return &nothing;
        return null;
    }

    fn resolver() Resolver {
        absent = &.{};
        return .{ .global = &getProcAddr };
    }

    fn without(gone: []const []const u8) Resolver {
        absent = gone;
        return .{ .global = &getProcAddr };
    }
};

const Two = struct {
    createInstance: *const fn () callconv(types.call) void,
    destroyInstance: *const fn () callconv(types.call) void,
};

test "a field name is a command name" {
    try testing.expectEqualStrings("vkCreateInstance", comptime commandName("createInstance"));
    try testing.expectEqualStrings("vkCmdDraw", comptime commandName("cmdDraw"));
    // An extension suffix is already capitalised, and stays that way.
    try testing.expectEqualStrings(
        "vkCreateSwapchainKHR",
        comptime commandName("createSwapchainKHR"),
    );
    // The result is zero-terminated, because that is what Vulkan takes.
    const name = comptime commandName("deviceWaitIdle");
    try testing.expectEqual(@as(u8, 0), name.ptr[name.len]);

    // And a table can say what it wants without being loaded.
    const wanted = comptime names(Two);
    try testing.expectEqual(@as(usize, 2), wanted.len);
    try testing.expectEqualStrings("vkCreateInstance", wanted[0]);
    try testing.expectEqualStrings("vkDestroyInstance", wanted[1]);
}

test "a table is filled in by name" {
    const table = try load(Two, Fake.resolver());
    try testing.expectEqual(@as(?*const anyopaque, @ptrCast(&Fake.nothing)), @as(
        ?*const anyopaque,
        @ptrCast(table.createInstance),
    ));

    var report: Report = .{};
    _ = try loadReport(Two, Fake.resolver(), &report);
    try testing.expectEqual(@as(usize, 2), report.found);
    try testing.expectEqual(@as(usize, 0), report.absent);
    try testing.expectEqual(@as(?[:0]const u8, null), report.missing);
}

test "the field's type decides whether absence is a failure" {
    const Mixed = struct {
        createInstance: *const fn () callconv(types.call) void,
        /// Vulkan 1.1. A 1.0 loader does not have it, and that is not an error.
        enumerateInstanceVersion: ?*const fn () callconv(types.call) void,
    };

    // Present: both filled in.
    {
        var report: Report = .{};
        const table = try loadReport(Mixed, Fake.resolver(), &report);
        try testing.expect(table.enumerateInstanceVersion != null);
        try testing.expectEqual(@as(usize, 2), report.found);
        try testing.expectEqual(@as(usize, 0), report.absent);
    }

    // Absent and optional: null, counted, and the load still succeeds. This is
    // exactly what a Vulkan 1.0 loader looks like.
    {
        var report: Report = .{};
        const table = try loadReport(Mixed, Fake.without(&.{"vkEnumerateInstanceVersion"}), &report);
        try testing.expectEqual(@as(usize, 1), report.found);
        try testing.expectEqual(@as(usize, 1), report.absent);
        try testing.expectEqual(@as(usize, 2), comptime names(Mixed).len);
        try testing.expectEqual(@as(?*const fn () callconv(types.call) void, null), table.enumerateInstanceVersion);
    }

    // Absent and required: an error, and the report says which command.
    {
        var report: Report = .{};
        try testing.expectError(
            error.CommandNotFound,
            loadReport(Mixed, Fake.without(&.{"vkCreateInstance"}), &report),
        );
        try testing.expectEqualStrings("vkCreateInstance", report.missing.?);
        // Loading stopped there, so nothing behind it was even looked at.
        try testing.expectEqual(@as(usize, 0), report.found);
    }

    // And the same question, asked without caring about the answer's detail.
    try testing.expect(available(Two, Fake.resolver()));
    try testing.expect(!available(Two, Fake.without(&.{"vkDestroyInstance"})));
}

test "aliases catch a promoted extension" {
    // The 1.1 name is not there, but the extension the command was promoted
    // from is - which is what an older driver looks like.
    const Promoted = struct {
        getPhysicalDeviceProperties2: ?*const fn () callconv(types.call) void,

        pub const aliases = .{
            .getPhysicalDeviceProperties2 = .{"vkGetPhysicalDeviceProperties2KHR"},
        };
    };

    var report: Report = .{};
    const table = try loadReport(Promoted, Fake.resolver(), &report);
    try testing.expect(table.getPhysicalDeviceProperties2 != null);
    try testing.expectEqual(@as(usize, 1), report.found);

    // Without either name it is absent, not found under some third spelling.
    const gone = Fake.without(&.{ "vkGetPhysicalDeviceProperties2", "vkGetPhysicalDeviceProperties2KHR" });
    const empty = try loadReport(Promoted, gone, &report);
    try testing.expectEqual(@as(usize, 1), report.absent);
    try testing.expectEqual(@as(?*const fn () callconv(types.call) void, null), empty.getPhysicalDeviceProperties2);
}

test "an empty table loads to an empty table" {
    // Not useful, but it should not be a special case either.
    var report: Report = .{};
    _ = try loadReport(struct {}, Fake.resolver(), &report);
    try testing.expectEqual(@as(usize, 0), report.found);
    try testing.expectEqual(@as(usize, 0), report.absent);
    try testing.expectEqual(@as(?[:0]const u8, null), report.missing);
}

test "the three scopes reach three different lookups" {
    // Each scope passes a different handle to a different function, and the
    // only way to tell from outside is to watch what arrives.
    const Watch = struct {
        var saw_instance: ?types.Instance = null;
        var saw_device: ?types.Device = null;

        fn nothing() callconv(types.call) void {}

        fn instanceProc(instance: ?types.Instance, name: [*:0]const u8) callconv(types.call) ?PfnVoidFunction {
            _ = name;
            saw_instance = instance;
            return &nothing;
        }

        fn deviceProc(device: ?types.Device, name: [*:0]const u8) callconv(types.call) ?PfnVoidFunction {
            _ = name;
            saw_device = device;
            return &nothing;
        }
    };

    const One = struct { deviceWaitIdle: *const fn () callconv(types.call) void };
    const instance: types.Instance = @ptrFromInt(0x1000);
    const device: types.Device = @ptrFromInt(0x2000);

    _ = try load(One, .{ .global = &Watch.instanceProc });
    try testing.expectEqual(@as(?types.Instance, null), Watch.saw_instance);

    _ = try load(One, .{ .instance = .{ .get = &Watch.instanceProc, .handle = instance } });
    try testing.expectEqual(instance, Watch.saw_instance.?);

    _ = try load(One, .{ .device = .{ .get = &Watch.deviceProc, .handle = device } });
    try testing.expectEqual(device, Watch.saw_device.?);
}
