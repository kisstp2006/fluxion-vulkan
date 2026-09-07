// SPDX-License-Identifier: CC0-1.0

//! Fluxion Vulkan - finding Vulkan at run time, and turning its names into
//! function pointers.
//!
//! Six pieces:
//!
//!   `library`    finding and opening the platform's Vulkan library
//!   `dispatch`   a struct of function pointers, filled in by name
//!   `commands`   the three tables the loader itself needs
//!   `types`      the slice of the Vulkan ABI those tables speak
//!   `enumerate`  Vulkan's two-call idiom, done once
//!   `version`    the packed `u32` a Vulkan version travels in
//!
//! and `Loader`, which is the first five in the order you use them.
//!
//! Vulkan is never linked against. The library is found at run time and
//! `vkGetInstanceProcAddr` is the only symbol looked up by name; every other
//! command comes out of that one function, in three tiers - what exists before
//! there is an instance, what dispatches on an instance, and what dispatches
//! on a device without going through the loader's trampoline.
//!
//! `dispatch` loads any struct whose fields are named after commands, so the
//! tables in `commands` have no special status. A field's type says whether the
//! command is required: a plain function pointer must be found, an optional one
//! may be absent and is left `null`.
//!
//! The line this library draws is the door: a library, an entry point, a
//! version, the layers and extensions on offer, an instance, the physical
//! devices, a device, and the tables to reach them through. Past that is the
//! Vulkan API rather than the loading of it.
//!
//! Nothing here allocates unless it takes an `Allocator`, and everything that
//! allocates says who owns the result.

const std = @import("std");
const testing = std.testing;

pub const commands = @import("commands.zig");
pub const dispatch = @import("dispatch.zig");
pub const enumerate = @import("enumerate.zig");
pub const library = @import("library.zig");
pub const types = @import("types.zig");
pub const version = @import("version.zig");

/// The library, the entry point and the global commands, in one place. See
/// `Loader`.
pub const Loader = @import("Loader.zig");

/// An open handle on the platform's Vulkan library. See `library`.
pub const Library = library.Library;

// -------------------------------------------------------------------------
// Handles
// -------------------------------------------------------------------------

pub const Instance = types.Instance;
pub const PhysicalDevice = types.PhysicalDevice;
pub const Device = types.Device;
pub const Queue = types.Queue;

// -------------------------------------------------------------------------
// The command tables
// -------------------------------------------------------------------------

/// What exists before there is an instance. See `commands`.
pub const GlobalCommands = commands.Global;

/// What dispatches on an instance or a physical device. See `commands`.
pub const InstanceCommands = commands.Instance;

/// What dispatches on a device, with no trampoline. See `commands`.
pub const DeviceCommands = commands.Device;

/// Where a name becomes a pointer: one of Vulkan's three tiers. See `dispatch`.
pub const Resolver = dispatch.Resolver;

// -------------------------------------------------------------------------
// Versions
// -------------------------------------------------------------------------

/// A Vulkan version, unpacked. See `version`.
pub const ApiVersion = version.ApiVersion;

pub const v1_0 = version.v1_0;
pub const v1_1 = version.v1_1;
pub const v1_2 = version.v1_2;
pub const v1_3 = version.v1_3;
pub const v1_4 = version.v1_4;

// -------------------------------------------------------------------------
// The ABI
// -------------------------------------------------------------------------

/// How a Vulkan command is called - `__stdcall` on Windows, `aapcs-vfp` on
/// 32-bit ARM Android, and the ordinary C convention everywhere else. Declare
/// every command pointer of your own with it. See `types.call`.
pub const call = types.call;

/// What a Vulkan command returns, and `check` turns into an error. See `types`.
pub const Result = types.Result;

pub const ApplicationInfo = types.ApplicationInfo;
pub const InstanceCreateInfo = types.InstanceCreateInfo;
pub const DeviceCreateInfo = types.DeviceCreateInfo;
pub const DeviceQueueCreateInfo = types.DeviceQueueCreateInfo;
pub const AllocationCallbacks = types.AllocationCallbacks;

pub const ExtensionProperties = types.ExtensionProperties;
pub const LayerProperties = types.LayerProperties;
pub const PhysicalDeviceProperties = types.PhysicalDeviceProperties;
pub const PhysicalDeviceProperties2 = types.PhysicalDeviceProperties2;
pub const PhysicalDeviceFeatures = types.PhysicalDeviceFeatures;
pub const PhysicalDeviceMemoryProperties = types.PhysicalDeviceMemoryProperties;
pub const PhysicalDeviceType = types.PhysicalDeviceType;
pub const QueueFamilyProperties = types.QueueFamilyProperties;

pub const InstanceCreateFlags = types.InstanceCreateFlags;
pub const QueueFlags = types.QueueFlags;
pub const MemoryPropertyFlags = types.MemoryPropertyFlags;

// -------------------------------------------------------------------------
// Shorthands
// -------------------------------------------------------------------------

/// Fill in a table of command declarations. See `dispatch.load`.
///
/// ```zig
/// const draw = try vk.load(Draw, inst.deviceResolver(device));
/// ```
pub fn load(comptime Table: type, resolver: Resolver) dispatch.Error!Table {
    return dispatch.load(Table, resolver);
}

/// Shorthand for `enumerate.has`: is this extension in the list?
pub const has = enumerate.has;

/// Shorthand for `enumerate.firstMissing`: which required extension is not?
pub const firstMissing = enumerate.firstMissing;

/// Shorthand for `enumerate.supported`: which of the optional ones are?
pub const supported = enumerate.supported;

/// Shorthand for `enumerate.queueFamily`: the narrowest family that can do
/// the job.
pub const queueFamily = enumerate.queueFamily;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const stub = @import("stub.zig");

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = commands;
    _ = dispatch;
    _ = enumerate;
    _ = library;
    _ = types;
    _ = version;
    _ = Loader;
    _ = stub;
}

test "the whole path, against a Vulkan that is not there" {
    stub.reset();
    const gpa = testing.allocator;

    // --- the loader ------------------------------------------------------
    var loader = try Loader.adopt(stub.getInstanceProcAddr);
    defer loader.deinit();
    try testing.expect(try loader.supports(v1_1));

    // --- what is on offer ------------------------------------------------
    const installed = try loader.layers(gpa);
    defer gpa.free(installed);
    try testing.expect(enumerate.hasLayer(installed, "VK_LAYER_KHRONOS_validation"));

    const available = try loader.extensions(gpa, null);
    defer gpa.free(available);

    // Required: fail here, by name, rather than inside `vkCreateInstance`.
    const required = [_][*:0]const u8{"VK_KHR_surface"};
    try testing.expectEqual(@as(?[]const u8, null), firstMissing(available, &required));

    // Optional: take the ones that are there and leave the rest.
    const nice_to_have = [_][*:0]const u8{ "VK_EXT_debug_utils", "VK_KHR_portability_enumeration" };
    var wanted: [required.len + nice_to_have.len][*:0]const u8 = undefined;
    wanted[0] = required[0];
    const extras = supported(available, &nice_to_have, wanted[1..]);
    const enabled = wanted[0 .. 1 + extras.len];
    try testing.expectEqual(@as(usize, 2), enabled.len); // no portability here

    // --- the instance ----------------------------------------------------
    const app: ApplicationInfo = .{ .application_name = "fluxion", .api_version = v1_1.toInt() };
    var info: InstanceCreateInfo = .{ .application_info = &app };
    info.setExtensions(enabled);

    const instance = try loader.createInstance(&info, null);
    const inst = try loader.instanceCommands(instance);
    defer inst.destroyInstance(instance, null);

    // 1.1 loader or better, so the promoted command is under its core name.
    try testing.expect(inst.getPhysicalDeviceProperties2 != null);

    // --- picking a device ------------------------------------------------
    const gpus = try enumerate.physicalDevices(gpa, inst, instance);
    defer gpa.free(gpus);
    try testing.expectEqual(@as(usize, 2), gpus.len);

    var chosen: ?PhysicalDevice = null;
    var chosen_memory: types.DeviceSize = 0;
    for (gpus) |gpu| {
        var props: PhysicalDeviceProperties = undefined;
        inst.getPhysicalDeviceProperties(gpu, &props);
        if (props.device_type != .discrete_gpu) continue;

        var memory: PhysicalDeviceMemoryProperties = undefined;
        inst.getPhysicalDeviceMemoryProperties(gpu, &memory);
        chosen = gpu;
        chosen_memory = memory.deviceLocalBytes();
    }
    const gpu = chosen.?;
    try testing.expectEqual(@as(types.DeviceSize, 8 << 30), chosen_memory);

    // The software rasteriser cannot present, and the discrete card can.
    const device_extensions = try enumerate.deviceExtensions(gpa, inst, gpu, null);
    defer gpa.free(device_extensions);
    try testing.expect(has(device_extensions, "VK_KHR_swapchain"));

    // --- a queue family --------------------------------------------------
    const families = try enumerate.queueFamilies(gpa, inst, gpu);
    defer gpa.free(families);
    const graphics = queueFamily(families, .{ .graphics = true }).?;
    const transfer = queueFamily(families, .{ .transfer = true }).?;
    try testing.expectEqual(@as(u32, 0), graphics);
    try testing.expectEqual(@as(u32, 1), transfer); // the dedicated one

    // --- the device ------------------------------------------------------
    const priorities = [_]f32{1.0};
    const queues = [_]DeviceQueueCreateInfo{.queues(graphics, &priorities)};
    const swapchain = [_][*:0]const u8{"VK_KHR_swapchain"};

    var device_info: DeviceCreateInfo = .{};
    device_info.setQueues(&queues);
    device_info.setExtensions(&swapchain);

    var device: Device = undefined;
    _ = try inst.createDevice(gpu, &device_info, null, &device).check();

    // --- and the table that skips the trampoline -------------------------
    const dev = try inst.deviceCommands(device);
    defer dev.destroyDevice(device, null);

    var queue: Queue = undefined;
    dev.getDeviceQueue(device, graphics, 0, &queue);
    _ = try dev.deviceWaitIdle(device).check();
}

test "the failures are the ones Vulkan reports" {
    stub.reset();
    defer stub.reset();
    const gpa = testing.allocator;

    var loader = try Loader.adopt(stub.getInstanceProcAddr);
    defer loader.deinit();

    // An extension that is not installed, refused by name.
    {
        const missing = [_][*:0]const u8{"VK_KHR_xlib_surface"};
        var info: InstanceCreateInfo = .{};
        info.setExtensions(&missing);
        try testing.expectError(error.ExtensionNotPresent, loader.createInstance(&info, null));

        // Which is what asking first would have told you, and sooner.
        const available = try loader.extensions(gpa, null);
        defer gpa.free(available);
        try testing.expectEqualStrings(
            "VK_KHR_xlib_surface",
            firstMissing(available, &missing).?,
        );
    }

    // A layer that is not installed.
    {
        const missing = [_][*:0]const u8{"VK_LAYER_fluxion_invented"};
        var info: InstanceCreateInfo = .{};
        info.setLayers(&missing);
        try testing.expectError(error.LayerNotPresent, loader.createInstance(&info, null));
    }

    // And a driver simply saying no.
    {
        stub.instance_failure = .error_incompatible_driver;
        const info: InstanceCreateInfo = .{};
        try testing.expectError(error.IncompatibleDriver, loader.createInstance(&info, null));
    }
}

test "an older Vulkan, and the same code on it" {
    stub.reset();
    stub.pretend_1_0 = true;
    defer stub.reset();

    var loader = try Loader.adopt(stub.getInstanceProcAddr);
    defer loader.deinit();

    // A 1.0 loader: the version command is not there, which is the answer.
    try testing.expectEqual(v1_0, try loader.apiVersion());

    const info: InstanceCreateInfo = .{};
    const instance = try loader.createInstance(&info, null);

    // The instance table still loads. `vkGetPhysicalDeviceProperties2` is gone
    // under its core name and found under the extension it was promoted from,
    // which is the whole point of the alias.
    var report: dispatch.Report = .{};
    const inst = try dispatch.loadReport(
        InstanceCommands,
        loader.instanceResolver(instance),
        &report,
    );
    defer inst.destroyInstance(instance, null);

    try testing.expect(inst.getPhysicalDeviceProperties2 != null);
    try testing.expectEqual(@as(usize, 0), report.absent);
    try testing.expectEqual(comptime dispatch.names(InstanceCommands).len, report.found);
}

test "a driver without the optional command loads anyway" {
    stub.reset();
    stub.no_properties2 = true;
    defer stub.reset();

    var loader = try Loader.adopt(stub.getInstanceProcAddr);
    defer loader.deinit();

    const info: InstanceCreateInfo = .{};
    const instance = try loader.createInstance(&info, null);

    var report: dispatch.Report = .{};
    const inst = try dispatch.loadReport(
        InstanceCommands,
        loader.instanceResolver(instance),
        &report,
    );
    defer inst.destroyInstance(instance, null);

    // Absent under both names, so the field is null and the load succeeded.
    try testing.expectEqual(@as(usize, 1), report.absent);
    try testing.expect(inst.getPhysicalDeviceProperties2 == null);
    try testing.expectEqual(@as(?[:0]const u8, null), report.missing);

    // Everything that does not depend on it still works.
    var props: PhysicalDeviceProperties = undefined;
    inst.getPhysicalDeviceProperties(stub.physicalDevice(0), &props);
    try testing.expectEqualStrings("Fluxion Reference GPU", props.name());
}

test "a table of your own, loaded the same way" {
    stub.reset();

    var loader = try Loader.adopt(stub.getInstanceProcAddr);
    defer loader.deinit();

    const info: InstanceCreateInfo = .{};
    const instance = try loader.createInstance(&info, null);
    const inst = try loader.instanceCommands(instance);
    defer inst.destroyInstance(instance, null);

    var device: Device = undefined;
    const priorities = [_]f32{1.0};
    const queues = [_]DeviceQueueCreateInfo{.queues(0, &priorities)};
    var device_info: DeviceCreateInfo = .{};
    device_info.setQueues(&queues);
    _ = try inst.createDevice(stub.physicalDevice(0), &device_info, null, &device).check();

    // Nothing about `commands.Device` is privileged: a struct declared here
    // loads through the same resolver, and gets the same pointers.
    const Mine = struct {
        deviceWaitIdle: *const fn (Device) callconv(types.call) Result,
        cmdDrawIndexed: ?*const fn (u32, u32, u32, i32, u32) callconv(types.call) void,
    };

    const mine = try load(Mine, inst.deviceResolver(device));
    const theirs = try inst.deviceCommands(device);
    defer theirs.destroyDevice(device, null);

    try testing.expectEqual(
        @as(*const anyopaque, @ptrCast(theirs.deviceWaitIdle)),
        @as(*const anyopaque, @ptrCast(mine.deviceWaitIdle)),
    );
    // And a command this Vulkan does not have is absent, not a failure.
    try testing.expect(mine.cmdDrawIndexed == null);
}

test "the real Vulkan, when this machine has one" {
    var loader = Loader.init() catch return error.SkipZigTest;
    defer loader.deinit();
    const gpa = testing.allocator;

    const info: InstanceCreateInfo = .{};
    const instance = loader.createInstance(&info, null) catch return error.SkipZigTest;
    const inst = try loader.instanceCommands(instance);
    defer inst.destroyInstance(instance, null);

    const gpus = try enumerate.physicalDevices(gpa, inst, instance);
    defer gpa.free(gpus);

    for (gpus) |gpu| {
        var props: PhysicalDeviceProperties = undefined;
        inst.getPhysicalDeviceProperties(gpu, &props);

        // A device has a name, a version, and at least one queue family that
        // can do something. Anything else is this machine's business.
        try testing.expect(props.name().len > 0);
        try testing.expect(ApiVersion.fromInt(props.api_version).atLeast(v1_0));

        const families = try enumerate.queueFamilies(gpa, inst, gpu);
        defer gpa.free(families);
        try testing.expect(families.len > 0);

        const anything: u32 = @bitCast(families[0].queue_flags);
        try testing.expect(anything != 0);
    }
}
