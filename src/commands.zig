// SPDX-License-Identifier: BSL-1.0

//! The three tables the loader itself needs, one per scope.
//!
//! Ordinary structs of the kind `dispatch.load` fills in, with nothing
//! privileged about them. What is in them is the setup path and only that:
//!
//!   `Global`    what exists before there is an instance
//!   `Instance`  creating one, looking at the physical devices, opening one
//!   `Device`    the three commands that are about the device rather than
//!               about drawing with it
//!
//! `Device` is short on purpose: once there is a device the loader's job is
//! done, and the remaining several thousand commands are the API rather than
//! the loading of it. Declare the ones you use and hand them to
//! `dispatch.load` with the same device resolver:
//!
//! ```zig
//! const Draw = struct {
//!     cmdBindPipeline: *const fn (CommandBuffer, PipelineBindPoint, Pipeline) callconv(types.call) void,
//!     cmdDraw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(types.call) void,
//! };
//!
//! const draw = try dispatch.load(Draw, loader.deviceResolver(instance_cmds, device));
//! ```
//!
//! Commands that may not be there are declared optional, so a table loads on
//! an older loader or an older driver and says what it did not get rather than
//! failing.

const std = @import("std");
const testing = std.testing;

const dispatch = @import("dispatch.zig");
const types = @import("types.zig");

const AllocationCallbacks = types.AllocationCallbacks;
const Result = types.Result;

/// The commands that exist before there is an instance, resolved against a
/// null one.
///
/// Four of them, and only three are guaranteed: `vkEnumerateInstanceVersion`
/// arrived in Vulkan 1.1, so its absence is not a failure - it is the answer.
/// A loader without it is a 1.0 loader, which is what `Loader.apiVersion`
/// reports when the field is `null`.
pub const Global = struct {
    createInstance: *const fn (
        create_info: *const types.InstanceCreateInfo,
        allocation_callbacks: ?*const AllocationCallbacks,
        instance: *types.Instance,
    ) callconv(types.call) Result,

    /// Two calls: once with a null array to learn the count, once to fill it.
    /// `layer_name` asks what a particular layer adds on top; null asks what
    /// the implementation itself has.
    enumerateInstanceExtensionProperties: *const fn (
        layer_name: ?[*:0]const u8,
        count: *u32,
        properties: ?[*]types.ExtensionProperties,
    ) callconv(types.call) Result,

    enumerateInstanceLayerProperties: *const fn (
        count: *u32,
        properties: ?[*]types.LayerProperties,
    ) callconv(types.call) Result,

    /// Vulkan 1.1. Absent on a 1.0 loader, which is how you know it is one.
    enumerateInstanceVersion: ?*const fn (version: *u32) callconv(types.call) Result,
};

/// The commands that dispatch on an instance or a physical device.
///
/// Every one of these goes through the loader's trampoline, which reads the
/// first argument and picks a driver. That is unavoidable here - a physical
/// device query has to be answered by whichever driver owns the device - and
/// avoidable one level down, which is what `getDeviceProcAddr` is for.
pub const Instance = struct {
    destroyInstance: *const fn (
        instance: types.Instance,
        allocation_callbacks: ?*const AllocationCallbacks,
    ) callconv(types.call) void,

    /// Two calls, like the extension queries. Returns `.incomplete` when the
    /// array was too small, having filled as much of it as fits.
    enumeratePhysicalDevices: *const fn (
        instance: types.Instance,
        count: *u32,
        devices: ?[*]types.PhysicalDevice,
    ) callconv(types.call) Result,

    getPhysicalDeviceProperties: *const fn (
        physical_device: types.PhysicalDevice,
        properties: *types.PhysicalDeviceProperties,
    ) callconv(types.call) void,

    getPhysicalDeviceFeatures: *const fn (
        physical_device: types.PhysicalDevice,
        features: *types.PhysicalDeviceFeatures,
    ) callconv(types.call) void,

    getPhysicalDeviceMemoryProperties: *const fn (
        physical_device: types.PhysicalDevice,
        properties: *types.PhysicalDeviceMemoryProperties,
    ) callconv(types.call) void,

    getPhysicalDeviceQueueFamilyProperties: *const fn (
        physical_device: types.PhysicalDevice,
        count: *u32,
        properties: ?[*]types.QueueFamilyProperties,
    ) callconv(types.call) void,

    enumerateDeviceExtensionProperties: *const fn (
        physical_device: types.PhysicalDevice,
        layer_name: ?[*:0]const u8,
        count: *u32,
        properties: ?[*]types.ExtensionProperties,
    ) callconv(types.call) Result,

    createDevice: *const fn (
        physical_device: types.PhysicalDevice,
        create_info: *const types.DeviceCreateInfo,
        allocation_callbacks: ?*const AllocationCallbacks,
        device: *types.Device,
    ) callconv(types.call) Result,

    /// The reason a device table costs nothing to call through. Instance-level
    /// itself - it is asked of the instance, and answers about a device.
    getDeviceProcAddr: dispatch.PfnGetDeviceProcAddr,

    /// Core since Vulkan 1.1, an extension before that, and the door to every
    /// property the 1.0 struct has no room for. Optional because a 1.0 driver
    /// without the extension has neither name.
    getPhysicalDeviceProperties2: ?*const fn (
        physical_device: types.PhysicalDevice,
        properties: *types.PhysicalDeviceProperties2,
    ) callconv(types.call) void,

    /// The other name the same command answers to, on a driver old enough to
    /// have had it as `VK_KHR_get_physical_device_properties2`.
    pub const aliases = .{
        .getPhysicalDeviceProperties2 = .{"vkGetPhysicalDeviceProperties2KHR"},
    };

    /// Where device-level commands are resolved: straight into the driver that
    /// owns `device`, with no trampoline in front.
    ///
    /// Hand it to `dispatch.load` with a table of your own for the device
    /// commands this library does not declare, which is nearly all of them.
    pub fn deviceResolver(self: Instance, device: types.Device) dispatch.Resolver {
        return .{ .device = .{ .get = self.getDeviceProcAddr, .handle = device } };
    }

    /// The three device-level commands the loader needs.
    pub fn deviceCommands(self: Instance, device: types.Device) dispatch.Error!Device {
        return dispatch.load(Device, self.deviceResolver(device));
    }
};

/// The commands that are about the device rather than about drawing with it.
///
/// Loaded through `vkGetDeviceProcAddr`, so each pointer belongs to one driver
/// and there is no trampoline in front of it.
pub const Device = struct {
    destroyDevice: *const fn (
        device: types.Device,
        allocation_callbacks: ?*const AllocationCallbacks,
    ) callconv(types.call) void,

    /// A queue is taken out of a device, not created: the index is into the
    /// queues asked for in `DeviceQueueCreateInfo`, not into the family.
    getDeviceQueue: *const fn (
        device: types.Device,
        queue_family_index: u32,
        queue_index: u32,
        queue: *types.Queue,
    ) callconv(types.call) void,

    /// Blocks until the device has finished everything. The one thing to call
    /// before tearing anything down.
    deviceWaitIdle: *const fn (device: types.Device) callconv(types.call) Result,
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the tables ask for the commands they are named after" {
    const global = comptime dispatch.names(Global);
    try testing.expectEqual(@as(usize, 4), global.len);
    try testing.expectEqualStrings("vkCreateInstance", global[0]);
    try testing.expectEqualStrings("vkEnumerateInstanceExtensionProperties", global[1]);
    try testing.expectEqualStrings("vkEnumerateInstanceLayerProperties", global[2]);
    try testing.expectEqualStrings("vkEnumerateInstanceVersion", global[3]);

    const device = comptime dispatch.names(Device);
    try testing.expectEqual(@as(usize, 3), device.len);
    try testing.expectEqualStrings("vkDestroyDevice", device[0]);
    try testing.expectEqualStrings("vkGetDeviceQueue", device[1]);
    try testing.expectEqualStrings("vkDeviceWaitIdle", device[2]);

    const instance = comptime dispatch.names(Instance);
    try testing.expectEqualStrings("vkDestroyInstance", instance[0]);
    try testing.expectEqualStrings("vkGetDeviceProcAddr", instance[instance.len - 2]);
    try testing.expectEqualStrings("vkGetPhysicalDeviceProperties2", instance[instance.len - 1]);
}

test "what may be absent is declared optional, and nothing else is" {
    // The rule the tables are built on: a command that a supported loader or
    // driver might not have is optional, so its absence is an answer rather
    // than a failure. Everything else is required, and a Vulkan that does not
    // have it is not a Vulkan.
    const optional = struct {
        fn count(comptime Table: type) usize {
            var n = 0;
            for (@typeInfo(Table).@"struct".fields) |field| {
                if (@typeInfo(field.type) == .optional) n += 1;
            }
            return n;
        }
    }.count;

    // `vkEnumerateInstanceVersion`, which arrived in 1.1.
    try testing.expectEqual(@as(usize, 1), comptime optional(Global));
    // `vkGetPhysicalDeviceProperties2`, core in 1.1 and an extension before.
    try testing.expectEqual(@as(usize, 1), comptime optional(Instance));
    // Nothing here postdates Vulkan 1.0.
    try testing.expectEqual(@as(usize, 0), comptime optional(Device));
}
