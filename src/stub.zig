// SPDX-License-Identifier: CC0-1.0

//! Internal plumbing: a Vulkan that is not there.
//!
//! A loader can only be tested against something to load, and a real driver is
//! the one thing a test suite cannot assume. So this is an implementation of
//! the far side of `vkGetInstanceProcAddr`: an entry point that answers the
//! names in `commands`, backed by two invented GPUs, a layer, three instance
//! extensions and a swapchain. It follows the rules the real thing follows -
//! the two-call idiom, `.incomplete` on a short array, `vkGetDeviceProcAddr`
//! answering a different set of names - so the whole path from library to
//! device table runs in `zig build test` on a machine with no GPU at all.
//!
//! The knobs below turn it into the awkward cases: a Vulkan 1.0 loader, a
//! driver without `vkGetPhysicalDeviceProperties2` under its core name, an
//! instance that refuses to be created.
//!
//! Nothing here is exported from `root.zig`, and none of it is thread-safe.

const std = @import("std");
const testing = std.testing;

const commands = @import("commands.zig");
const dispatch = @import("dispatch.zig");
const enumerate = @import("enumerate.zig");
const types = @import("types.zig");
const version = @import("version.zig");

// -------------------------------------------------------------------------
// Knobs
// -------------------------------------------------------------------------

/// Hide `vkEnumerateInstanceVersion` and the core name of
/// `vkGetPhysicalDeviceProperties2`, leaving the extension name behind - which
/// is exactly what a Vulkan 1.0 loader with
/// `VK_KHR_get_physical_device_properties2` looks like.
pub var pretend_1_0 = false;

/// Hide `vkGetPhysicalDeviceProperties2` under both of its names.
pub var no_properties2 = false;

/// What the next `vkCreateInstance` returns instead of succeeding.
pub var instance_failure: ?types.Result = null;

pub fn reset() void {
    pretend_1_0 = false;
    no_properties2 = false;
    instance_failure = null;
}

// -------------------------------------------------------------------------
// What this Vulkan has
// -------------------------------------------------------------------------

pub const api_version = version.ApiVersion.init(1, 3, 280);

pub const layer_names = [_][]const u8{"VK_LAYER_KHRONOS_validation"};

pub const instance_extension_names = [_][]const u8{
    "VK_KHR_surface",
    "VK_KHR_win32_surface",
    "VK_EXT_debug_utils",
};

pub const device_extension_names = [_][]const u8{"VK_KHR_swapchain"};

/// The discrete card, and the software rasteriser behind it.
pub const device_names = [_][]const u8{
    "Fluxion Reference GPU",
    "Fluxion Software Rasteriser",
};

const layers = [_]types.LayerProperties{layerProperties(layer_names[0], "Khronos Validation Layer")};

const instance_extensions = blk: {
    var list: [instance_extension_names.len]types.ExtensionProperties = undefined;
    for (instance_extension_names, 0..) |name, i| list[i] = extensionProperties(name);
    break :blk list;
};

const device_extensions = [_]types.ExtensionProperties{extensionProperties(device_extension_names[0])};

/// The graphics family first, then a transfer-only one - which is what a
/// discrete card looks like, and what `enumerate.queueFamily` is for.
const discrete_families = [_]types.QueueFamilyProperties{
    family(.{ .graphics = true, .compute = true, .transfer = true, .sparse_binding = true }, 16),
    family(.{ .transfer = true, .sparse_binding = true }, 2),
};

const software_families = [_]types.QueueFamilyProperties{
    family(.{ .graphics = true, .compute = true, .transfer = true }, 1),
};

// -------------------------------------------------------------------------
// Handles
// -------------------------------------------------------------------------
//
// Never dereferenced by anything, on either side: to Vulkan a dispatchable
// handle is a pointer the driver understands and nobody else does.

pub fn theInstance() types.Instance {
    return @ptrFromInt(0xF10000);
}

pub fn theDevice() types.Device {
    return @ptrFromInt(0xDE0000);
}

pub fn physicalDevice(index: usize) types.PhysicalDevice {
    return @ptrFromInt(0xB0000 + (index + 1) * 0x100);
}

fn indexOf(handle: types.PhysicalDevice) usize {
    return (@intFromPtr(handle) - 0xB0000) / 0x100 - 1;
}

// -------------------------------------------------------------------------
// The entry points
// -------------------------------------------------------------------------

/// The one symbol a real Vulkan library exports, and the shape of everything
/// this file does: a string in, a command pointer or null out.
pub const getInstanceProcAddr: dispatch.PfnGetInstanceProcAddr = &instanceProcAddr;

fn instanceProcAddr(
    instance: ?types.Instance,
    name: [*:0]const u8,
) callconv(types.call) ?dispatch.PfnVoidFunction {
    _ = instance;
    const wanted = std.mem.span(name);
    const is = struct {
        fn it(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.it;

    // Global: answered whether or not an instance was passed.
    if (is(wanted, "vkCreateInstance")) return @ptrCast(&createInstance);
    if (is(wanted, "vkEnumerateInstanceExtensionProperties"))
        return @ptrCast(&enumerateInstanceExtensionProperties);
    if (is(wanted, "vkEnumerateInstanceLayerProperties"))
        return @ptrCast(&enumerateInstanceLayerProperties);
    if (is(wanted, "vkEnumerateInstanceVersion"))
        return if (pretend_1_0) null else @ptrCast(&enumerateInstanceVersion);

    // Instance level.
    if (is(wanted, "vkDestroyInstance")) return @ptrCast(&destroyInstance);
    if (is(wanted, "vkEnumeratePhysicalDevices")) return @ptrCast(&enumeratePhysicalDevices);
    if (is(wanted, "vkGetPhysicalDeviceProperties")) return @ptrCast(&getPhysicalDeviceProperties);
    if (is(wanted, "vkGetPhysicalDeviceFeatures")) return @ptrCast(&getPhysicalDeviceFeatures);
    if (is(wanted, "vkGetPhysicalDeviceMemoryProperties"))
        return @ptrCast(&getPhysicalDeviceMemoryProperties);
    if (is(wanted, "vkGetPhysicalDeviceQueueFamilyProperties"))
        return @ptrCast(&getPhysicalDeviceQueueFamilyProperties);
    if (is(wanted, "vkEnumerateDeviceExtensionProperties"))
        return @ptrCast(&enumerateDeviceExtensionProperties);
    if (is(wanted, "vkCreateDevice")) return @ptrCast(&createDevice);
    if (is(wanted, "vkGetDeviceProcAddr")) return @ptrCast(&deviceProcAddr);

    // Core in 1.1, an extension before it, and absent from neither name only
    // when the knobs say so.
    if (is(wanted, "vkGetPhysicalDeviceProperties2"))
        return if (pretend_1_0 or no_properties2) null else @ptrCast(&getPhysicalDeviceProperties2);
    if (is(wanted, "vkGetPhysicalDeviceProperties2KHR"))
        return if (no_properties2) null else @ptrCast(&getPhysicalDeviceProperties2);

    // A real loader also answers device-level names here, through a
    // trampoline. This one does too, so that the difference between the two
    // tables is about where the pointer comes from and not about what exists.
    return deviceProcAddr(null, name);
}

fn deviceProcAddr(
    device: ?types.Device,
    name: [*:0]const u8,
) callconv(types.call) ?dispatch.PfnVoidFunction {
    _ = device;
    const wanted = std.mem.span(name);
    if (std.mem.eql(u8, wanted, "vkDestroyDevice")) return @ptrCast(&destroyDevice);
    if (std.mem.eql(u8, wanted, "vkGetDeviceQueue")) return @ptrCast(&getDeviceQueue);
    if (std.mem.eql(u8, wanted, "vkDeviceWaitIdle")) return @ptrCast(&deviceWaitIdle);
    return null;
}

// -------------------------------------------------------------------------
// Global commands
// -------------------------------------------------------------------------

fn createInstance(
    create_info: *const types.InstanceCreateInfo,
    allocation_callbacks: ?*const types.AllocationCallbacks,
    instance: *types.Instance,
) callconv(types.call) types.Result {
    _ = allocation_callbacks;
    if (instance_failure) |failure| return failure;

    // Refuse what is not installed, by the same codes the real thing uses.
    for (0..create_info.enabled_layer_count) |i| {
        const wanted = std.mem.span(create_info.enabled_layer_names.?[i]);
        if (!enumerate.hasLayer(&layers, wanted)) return .error_layer_not_present;
    }
    for (0..create_info.enabled_extension_count) |i| {
        const wanted = std.mem.span(create_info.enabled_extension_names.?[i]);
        if (!enumerate.has(&instance_extensions, wanted)) return .error_extension_not_present;
    }

    instance.* = theInstance();
    return .success;
}

fn enumerateInstanceExtensionProperties(
    layer_name: ?[*:0]const u8,
    count: *u32,
    properties: ?[*]types.ExtensionProperties,
) callconv(types.call) types.Result {
    // A layer's extensions are its own, and this one adds none.
    if (layer_name) |name| {
        if (!enumerate.hasLayer(&layers, std.mem.span(name))) return .error_layer_not_present;
        return fill(types.ExtensionProperties, &.{}, count, properties);
    }
    return fill(types.ExtensionProperties, &instance_extensions, count, properties);
}

fn enumerateInstanceLayerProperties(
    count: *u32,
    properties: ?[*]types.LayerProperties,
) callconv(types.call) types.Result {
    return fill(types.LayerProperties, &layers, count, properties);
}

fn enumerateInstanceVersion(value: *u32) callconv(types.call) types.Result {
    value.* = api_version.toInt();
    return .success;
}

// -------------------------------------------------------------------------
// Instance commands
// -------------------------------------------------------------------------

fn destroyInstance(
    instance: types.Instance,
    allocation_callbacks: ?*const types.AllocationCallbacks,
) callconv(types.call) void {
    _ = instance;
    _ = allocation_callbacks;
}

fn enumeratePhysicalDevices(
    instance: types.Instance,
    count: *u32,
    devices: ?[*]types.PhysicalDevice,
) callconv(types.call) types.Result {
    _ = instance;
    var handles: [device_names.len]types.PhysicalDevice = undefined;
    for (0..device_names.len) |i| handles[i] = physicalDevice(i);
    return fill(types.PhysicalDevice, &handles, count, devices);
}

fn getPhysicalDeviceProperties(
    physical_device: types.PhysicalDevice,
    properties: *types.PhysicalDeviceProperties,
) callconv(types.call) void {
    const index = indexOf(physical_device);
    properties.* = std.mem.zeroes(types.PhysicalDeviceProperties);

    const name = device_names[index];
    @memcpy(properties.device_name[0..name.len], name);
    properties.device_type = if (index == 0) .discrete_gpu else .cpu;
    properties.api_version = if (index == 0) api_version.toInt() else version.v1_1.toInt();
    properties.driver_version = version.ApiVersion.init(2, 0, 294).toInt();
    properties.vendor_id = if (index == 0) version.Driver.amd else 0;
    properties.device_id = @intCast(0x7000 + index);
    properties.limits.max_image_dimension_2d = if (index == 0) 16384 else 4096;
}

fn getPhysicalDeviceProperties2(
    physical_device: types.PhysicalDevice,
    properties: *types.PhysicalDeviceProperties2,
) callconv(types.call) void {
    getPhysicalDeviceProperties(physical_device, &properties.properties);
}

fn getPhysicalDeviceFeatures(
    physical_device: types.PhysicalDevice,
    features: *types.PhysicalDeviceFeatures,
) callconv(types.call) void {
    features.* = .{};
    features.geometry_shader = types.boolean(indexOf(physical_device) == 0);
    features.sampler_anisotropy = types.vk_true;
}

fn getPhysicalDeviceMemoryProperties(
    physical_device: types.PhysicalDevice,
    properties: *types.PhysicalDeviceMemoryProperties,
) callconv(types.call) void {
    const index = indexOf(physical_device);
    properties.* = std.mem.zeroes(types.PhysicalDeviceMemoryProperties);

    if (index == 0) {
        properties.memory_heap_count = 2;
        properties.memory_heaps[0] = .{ .size = 8 << 30, .flags = .{ .device_local = true } };
        properties.memory_heaps[1] = .{ .size = 32 << 30, .flags = .{} };
        properties.memory_type_count = 2;
        properties.memory_types[0] = .{ .property_flags = .{ .device_local = true }, .heap_index = 0 };
        properties.memory_types[1] = .{
            .property_flags = .{ .host_visible = true, .host_coherent = true },
            .heap_index = 1,
        };
    } else {
        // No device-local heap at all: everything a software rasteriser has is
        // system memory.
        properties.memory_heap_count = 1;
        properties.memory_heaps[0] = .{ .size = 32 << 30, .flags = .{} };
        properties.memory_type_count = 1;
        properties.memory_types[0] = .{
            .property_flags = .{ .host_visible = true, .host_coherent = true },
            .heap_index = 0,
        };
    }
}

fn getPhysicalDeviceQueueFamilyProperties(
    physical_device: types.PhysicalDevice,
    count: *u32,
    properties: ?[*]types.QueueFamilyProperties,
) callconv(types.call) void {
    const families = familiesOf(physical_device);
    if (properties == null) {
        count.* = @intCast(families.len);
        return;
    }
    const n = @min(count.*, families.len);
    @memcpy(properties.?[0..n], families[0..n]);
    count.* = @intCast(n);
}

fn enumerateDeviceExtensionProperties(
    physical_device: types.PhysicalDevice,
    layer_name: ?[*:0]const u8,
    count: *u32,
    properties: ?[*]types.ExtensionProperties,
) callconv(types.call) types.Result {
    _ = layer_name;
    // Only the discrete card can present.
    const available: []const types.ExtensionProperties =
        if (indexOf(physical_device) == 0) &device_extensions else &.{};
    return fill(types.ExtensionProperties, available, count, properties);
}

fn createDevice(
    physical_device: types.PhysicalDevice,
    create_info: *const types.DeviceCreateInfo,
    allocation_callbacks: ?*const types.AllocationCallbacks,
    device: *types.Device,
) callconv(types.call) types.Result {
    _ = allocation_callbacks;

    const available: []const types.ExtensionProperties =
        if (indexOf(physical_device) == 0) &device_extensions else &.{};
    for (0..create_info.enabled_extension_count) |i| {
        const wanted = std.mem.span(create_info.enabled_extension_names.?[i]);
        if (!enumerate.has(available, wanted)) return .error_extension_not_present;
    }

    const families = familiesOf(physical_device);
    for (0..create_info.queue_create_info_count) |i| {
        const wanted = create_info.queue_create_infos.?[i];
        if (wanted.queue_family_index >= families.len) return .error_initialization_failed;
        if (wanted.queue_count > families[wanted.queue_family_index].queue_count)
            return .error_initialization_failed;
    }

    if (create_info.enabled_features) |features| {
        if (types.isTrue(features.geometry_shader) and indexOf(physical_device) != 0)
            return .error_feature_not_present;
    }

    device.* = theDevice();
    return .success;
}

// -------------------------------------------------------------------------
// Device commands
// -------------------------------------------------------------------------

fn destroyDevice(
    device: types.Device,
    allocation_callbacks: ?*const types.AllocationCallbacks,
) callconv(types.call) void {
    _ = device;
    _ = allocation_callbacks;
}

fn getDeviceQueue(
    device: types.Device,
    queue_family_index: u32,
    queue_index: u32,
    queue: *types.Queue,
) callconv(types.call) void {
    _ = device;
    queue.* = @ptrFromInt(0xA0000 + (queue_family_index + 1) * 0x100 + queue_index);
}

fn deviceWaitIdle(device: types.Device) callconv(types.call) types.Result {
    _ = device;
    return .success;
}

// -------------------------------------------------------------------------
// Odds and ends
// -------------------------------------------------------------------------

/// The two-call idiom from the other side: the count when there is nowhere to
/// write, as much as fits when there is, and `.incomplete` when that was not
/// all of it.
fn fill(comptime T: type, source: []const T, count: *u32, into: ?[*]T) types.Result {
    if (into == null) {
        count.* = @intCast(source.len);
        return .success;
    }
    const n = @min(count.*, source.len);
    @memcpy(into.?[0..n], source[0..n]);
    count.* = @intCast(n);
    return if (n < source.len) .incomplete else .success;
}

fn familiesOf(physical_device: types.PhysicalDevice) []const types.QueueFamilyProperties {
    return if (indexOf(physical_device) == 0) &discrete_families else &software_families;
}

fn family(flags: types.QueueFlags, count: u32) types.QueueFamilyProperties {
    return .{
        .queue_flags = flags,
        .queue_count = count,
        .timestamp_valid_bits = 64,
        .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
    };
}

fn extensionProperties(comptime name: []const u8) types.ExtensionProperties {
    comptime {
        var props: types.ExtensionProperties = .{ .extension_name = @splat(0), .spec_version = 1 };
        @memcpy(props.extension_name[0..name.len], name);
        return props;
    }
}

fn layerProperties(comptime name: []const u8, comptime description: []const u8) types.LayerProperties {
    comptime {
        var props: types.LayerProperties = .{
            .layer_name = @splat(0),
            .spec_version = api_version.toInt(),
            .implementation_version = 1,
            .description = @splat(0),
        };
        @memcpy(props.layer_name[0..name.len], name);
        @memcpy(props.description[0..description.len], description);
        return props;
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the stub answers the names the tables ask for" {
    reset();

    // Everything `commands` declares, resolved through the entry point - which
    // is the only claim this file has to being a Vulkan at all.
    inline for (comptime dispatch.names(commands.Global)) |name| {
        try testing.expect(instanceProcAddr(null, name.ptr) != null);
    }
    inline for (comptime dispatch.names(commands.Instance)) |name| {
        try testing.expect(instanceProcAddr(theInstance(), name.ptr) != null);
    }
    inline for (comptime dispatch.names(commands.Device)) |name| {
        try testing.expect(deviceProcAddr(theDevice(), name.ptr) != null);
    }

    // And nothing else.
    try testing.expect(instanceProcAddr(null, "vkCreateBuffer") == null);
    try testing.expect(deviceProcAddr(theDevice(), "vkCreateInstance") == null);
}

test "the knobs make the awkward cases" {
    reset();
    defer reset();

    pretend_1_0 = true;
    try testing.expect(instanceProcAddr(null, "vkEnumerateInstanceVersion") == null);
    // The core name is gone, and the extension it was promoted from is not.
    try testing.expect(instanceProcAddr(null, "vkGetPhysicalDeviceProperties2") == null);
    try testing.expect(instanceProcAddr(null, "vkGetPhysicalDeviceProperties2KHR") != null);

    no_properties2 = true;
    try testing.expect(instanceProcAddr(null, "vkGetPhysicalDeviceProperties2KHR") == null);
}

test "the physical device handles come apart again" {
    for (0..device_names.len) |i| {
        try testing.expectEqual(i, indexOf(physicalDevice(i)));
    }
    try testing.expect(physicalDevice(0) != physicalDevice(1));
}
