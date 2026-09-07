// SPDX-License-Identifier: CC0-1.0

//! Declaring your own commands. Run it with `zig build example-table`.
//!
//! `commands.Global`, `commands.Instance` and `commands.Device` have no
//! special status: they are structs of function pointers, and so is anything
//! you write. This file declares three tables of its own - one per scope - and
//! loads them through the same resolvers the shipped ones go through.
//!
//! Which is the whole point of loading by field name. A table can come from
//! this library, from a full Vulkan binding, or from four lines you wrote
//! because you needed four commands.

const std = @import("std");
const Io = std.Io;
const vk = @import("fluxion_vulkan");

/// Command pointers this file never calls, so the argument types are left as
/// `anyopaque` rather than transcribed. A real program would spell them out -
/// nothing here checks a signature against Vulkan's, and nothing can.
const Handle = *anyopaque;

/// Global scope: what exists before there is an instance.
const Global = struct {
    /// Required. Not being able to create an instance is not a Vulkan.
    createInstance: *const fn (
        create_info: *const vk.InstanceCreateInfo,
        allocation_callbacks: ?*const vk.AllocationCallbacks,
        instance: *vk.Instance,
    ) callconv(vk.call) vk.Result,

    /// Optional. Vulkan 1.1, so a 1.0 loader does not have it - and its
    /// absence is how you know that is what you are talking to.
    enumerateInstanceVersion: ?*const fn (version: *u32) callconv(vk.call) vk.Result,
};

/// Instance scope: through the loader's trampoline, which reads a command's
/// first argument and picks a driver.
const Instance = struct {
    destroyInstance: *const fn (vk.Instance, ?*const vk.AllocationCallbacks) callconv(vk.call) void,

    /// Core since Vulkan 1.1, and an extension before that. The same command
    /// under two names, and which one a driver answers to depends on how old
    /// it is.
    getPhysicalDeviceProperties2: ?*const fn (
        vk.PhysicalDevice,
        *vk.PhysicalDeviceProperties2,
    ) callconv(vk.call) void,

    /// A command from an extension almost nothing has, to show what an absent
    /// optional looks like next to a present one.
    getPhysicalDeviceSurfaceCapabilities2EXT: ?*const fn (
        vk.PhysicalDevice,
        Handle,
        Handle,
    ) callconv(vk.call) vk.Result,

    pub const aliases = .{
        .getPhysicalDeviceProperties2 = .{"vkGetPhysicalDeviceProperties2KHR"},
    };
};

/// Device scope: resolved through `vkGetDeviceProcAddr`, so each pointer
/// belongs to one driver and there is no trampoline in front of it.
const Device = struct {
    deviceWaitIdle: *const fn (vk.Device) callconv(vk.call) vk.Result,
    destroyDevice: *const fn (vk.Device, ?*const vk.AllocationCallbacks) callconv(vk.call) void,

    /// The commands a renderer actually spends its time in.
    cmdDraw: ?*const fn (Handle, u32, u32, u32, u32) callconv(vk.call) void,
    cmdDrawIndexed: ?*const fn (Handle, u32, u32, u32, i32, u32) callconv(vk.call) void,
    cmdDrawMeshTasksEXT: ?*const fn (Handle, u32, u32, u32) callconv(vk.call) void,

    /// Core since 1.3, `VK_KHR_dynamic_rendering` before that - so on a driver
    /// that is neither, this is the alias earning its keep.
    cmdBeginRendering: ?*const fn (Handle, Handle) callconv(vk.call) void,

    pub const aliases = .{
        .cmdBeginRendering = .{"vkCmdBeginRenderingKHR"},
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // What a table asks for is known at compile time, whether or not anything
    // is ever loaded into it.
    try out.writeAll("--- what these tables want ---\n");
    try printWanted(out, "Global", Global);
    try printWanted(out, "Instance", Instance);
    try printWanted(out, "Device", Device);

    var loader = vk.Loader.init() catch |err| switch (err) {
        error.NotFound, error.NotSupported => {
            try out.writeAll(
                \\
                \\No Vulkan on this machine, so there is nothing to load them
                \\from. The names above needed no driver to work out.
                \\
            );
            return;
        },
        else => return err,
    };
    defer loader.deinit();

    // --- global ----------------------------------------------------------
    try out.writeAll("\n--- loaded ---\n");
    var report: vk.dispatch.Report = .{};
    const global = try vk.dispatch.loadReport(
        Global,
        .{ .global = loader.getInstanceProcAddr },
        &report,
    );
    try printReport(out, "Global", Global, report);

    // The optional command, used exactly as its type says to.
    if (global.enumerateInstanceVersion) |query| {
        var value: u32 = 0;
        _ = try query(&value).check();
        try out.print("  loader is Vulkan {f}\n", .{vk.ApiVersion.fromInt(value)});
    } else {
        try out.writeAll("  loader is Vulkan 1.0 (no vkEnumerateInstanceVersion)\n");
    }

    // --- instance --------------------------------------------------------
    // The version asked for here decides which core commands can be loaded
    // later: `vkGetDeviceProcAddr` answers for the version the application
    // asked for, not the one the device happens to support. Ask for 1.0 and
    // `vkCmdBeginRendering` comes back null on a 1.4 driver, which looks
    // exactly like a driver that does not have it.
    //
    // Asking for more than the loader has fails instance creation outright,
    // so the request is the lower of the two.
    const asked_for = (try loader.apiVersion()).min(vk.v1_3);
    const app: vk.ApplicationInfo = .{
        .application_name = "table",
        .api_version = asked_for.toInt(),
    };
    const create_info: vk.InstanceCreateInfo = .{ .application_info = &app };

    var instance: vk.Instance = undefined;
    _ = try global.createInstance(&create_info, null, &instance).check();
    try out.print("  asked for Vulkan {f}\n", .{asked_for});

    const inst = try vk.dispatch.loadReport(
        Instance,
        loader.instanceResolver(instance),
        &report,
    );
    defer inst.destroyInstance(instance, null);
    try printReport(out, "Instance", Instance, report);

    // --- device ----------------------------------------------------------
    // Getting one needs the shipped instance table, which has the commands
    // this file did not bother to declare.
    const shipped = try loader.instanceCommands(instance);
    const gpus = try vk.enumerate.physicalDevices(gpa, shipped, instance);
    if (gpus.len == 0) {
        try out.writeAll("\nNo devices, so no device table.\n");
        return;
    }

    const gpu = gpus[0];
    const families = try vk.enumerate.queueFamilies(gpa, shipped, gpu);
    const family = vk.queueFamily(families, .{}) orelse {
        try out.writeAll("\nA device with no queue families, which should not happen.\n");
        return;
    };

    const priorities = [_]f32{1.0};
    const queue_infos = [_]vk.DeviceQueueCreateInfo{.queues(family, &priorities)};
    var device_info: vk.DeviceCreateInfo = .{};
    device_info.setQueues(&queue_infos);

    var device: vk.Device = undefined;
    _ = try shipped.createDevice(gpu, &device_info, null, &device).check();

    const dev = try vk.dispatch.loadReport(
        Device,
        shipped.deviceResolver(device),
        &report,
    );
    defer dev.destroyDevice(device, null);
    try printReport(out, "Device", Device, report);

    _ = try dev.deviceWaitIdle(device).check();

    // A required command that this Vulkan does not have is an error naming it,
    // rather than a table with a null in the middle of it.
    const Impossible = struct {
        cmdDrawMeshTasksAndSingHKR: *const fn () callconv(vk.call) void,
    };
    var failed: vk.dispatch.Report = .{};
    if (vk.dispatch.loadReport(Impossible, shipped.deviceResolver(device), &failed)) |_| {
        try out.writeAll("\nsomehow loaded a command that does not exist\n");
    } else |err| {
        try out.print("\n{t}: {s}\n", .{ err, failed.missing.? });
    }
}

fn printWanted(out: *Io.Writer, label: []const u8, comptime Table: type) !void {
    const names = comptime vk.dispatch.names(Table);
    try out.print("{s} ({d})\n", .{ label, names.len });
    inline for (names, @typeInfo(Table).@"struct".fields) |name, field| {
        try out.print("  {s:<48} {s}\n", .{
            name,
            if (@typeInfo(field.type) == .optional) "optional" else "required",
        });
    }
}

fn printReport(
    out: *Io.Writer,
    label: []const u8,
    comptime Table: type,
    report: vk.dispatch.Report,
) !void {
    try out.print("{s:<9} {d} of {d} found, {d} absent\n", .{
        label,
        report.found,
        comptime vk.dispatch.names(Table).len,
        report.absent,
    });
}
