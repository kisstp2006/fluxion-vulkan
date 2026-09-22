// SPDX-License-Identifier: BSL-1.0

//! The slice of the Vulkan ABI a loader needs, and nothing beyond it.
//!
//! A loader has to speak enough Vulkan to open the door: name the handles, read
//! a result code, ask what layers and extensions are on offer, create an
//! instance, look at the physical devices, create a device. That is where these
//! declarations stop. Everything past the door is `gen/types.zig`, which is the
//! same ABI generated from the registry - all of it a backend needs, a few
//! hundred structs - and `dispatch` loads a table of either one's declarations
//! just as happily.
//!
//! **These are the generated declarations, under the names this library has
//! always used.** Nothing here is a second copy of the ABI: a `types.Device` and
//! a `gen.types.Device` are the same type, so a table from `gen/commands.zig`
//! and a call through `commands.Device` take the same handles. What is written
//! by hand in this file is what the registry cannot say - the calling
//! convention, the documentation - and what is checked here is that the
//! generated declarations are the size the driver expects.
//!
//! Two conveniences the C headers do not have:
//!
//!   * every `s_type` field defaults to the right tag, so a create info is
//!     built by naming the fields you care about and nothing else;
//!   * every count-and-pointer pair has a setter that writes both, so the two
//!     cannot drift apart.
//!
//! Handles are distinct types, so a `Device` will not go where an `Instance`
//! was meant.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const gen = @import("gen/types.zig");

// -------------------------------------------------------------------------
// The calling convention
// -------------------------------------------------------------------------

/// How a Vulkan command is called, which is not the same everywhere.
///
/// The C headers spell this `VKAPI_CALL` and `VKAPI_PTR`. On most platforms it
/// expands to nothing and the ordinary C convention applies - but on two it
/// does not, and both are platforms Vulkan actually runs on:
///
///   * **Windows**: `__stdcall`. No difference on x86-64 and arm64; on 32-bit
///     x86 it decides who cleans the arguments off the stack, and getting it
///     wrong corrupts the stack on the first call and crashes later, somewhere
///     unrelated.
///   * **32-bit ARM Android**: `aapcs-vfp`, the hardfloat convention, whether
///     or not the application was built for it.
///
/// Every function pointer here is declared with it, and so should every command
/// table of your own be:
///
/// ```zig
/// const Draw = struct {
///     cmdDraw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(vk.call) void,
/// };
/// ```
///
/// On every platform but 32-bit Windows this is exactly `.c`, so the two are
/// interchangeable right up until somebody builds for one that is.
pub const call: std.builtin.CallingConvention = if (builtin.os.tag == .windows)
    .winapi
else if (builtin.abi.isAndroid() and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb))
    .{ .arm_aapcs_vfp = .{} }
else
    .c;

// -------------------------------------------------------------------------
// Handles
// -------------------------------------------------------------------------

/// The loader's own object: one per application, holding the driver list.
pub const Instance = gen.Instance;

/// A GPU the instance found. Neither created nor destroyed - it exists as
/// long as the instance does.
pub const PhysicalDevice = gen.PhysicalDevice;

/// An opened physical device, and the thing device-level commands dispatch on.
pub const Device = gen.Device;

/// A queue belonging to a device, taken out of it rather than created.
pub const Queue = gen.Queue;

// -------------------------------------------------------------------------
// Scalars
// -------------------------------------------------------------------------

/// Vulkan's boolean: four bytes, `0` or `1`. `boolean` and `isTrue` convert.
pub const Bool32 = gen.Bool32;

pub const vk_false: Bool32 = gen.vk_false;
pub const vk_true: Bool32 = gen.vk_true;

pub fn boolean(value: bool) Bool32 {
    return if (value) vk_true else vk_false;
}

pub fn isTrue(value: Bool32) bool {
    return value != vk_false;
}

/// A size or offset in device memory. Always 64 bits, on every platform.
pub const DeviceSize = gen.DeviceSize;

/// The fixed widths the C headers spell as `VK_MAX_*`.
pub const max_extension_name_size = gen.max_extension_name_size;
pub const max_description_size = gen.max_description_size;
pub const max_physical_device_name_size = gen.max_physical_device_name_size;
pub const max_memory_types = gen.max_memory_types;
pub const max_memory_heaps = gen.max_memory_heaps;
pub const uuid_size = gen.uuid_size;

/// The bytes of a fixed-width `char[N]` field, up to the terminator.
///
/// Vulkan writes names into arrays of a fixed width and pads the rest with
/// zeroes, so the array is almost never the string.
pub fn cstr(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}

// -------------------------------------------------------------------------
// Result codes
// -------------------------------------------------------------------------

/// What a Vulkan command returns. Negative is a failure, zero is success, and
/// positive is success with something worth knowing - `incomplete` means the
/// array you offered was too small, `suboptimal_khr` means the swapchain still
/// works but no longer fits the window.
///
/// The enum is open: a driver or an extension may return a code this library
/// has never heard of, and `check` turns any unknown failure into
/// `error.Unknown` rather than pretending it did not happen.
///
/// `Error` and `check` are generated with it: every negative code in the
/// registry is an error of the same name, without its `VK_ERROR_` and its tag.
pub const Result = gen.Result;

// -------------------------------------------------------------------------
// Enumerations and flags
// -------------------------------------------------------------------------

/// The tag every Vulkan struct starts with, so that a driver walking a `next`
/// chain knows what it is looking at.
pub const StructureType = gen.StructureType;

/// What kind of hardware a physical device is. The usual reason to look:
/// preferring `discrete_gpu` over the integrated one sitting next to it.
pub const PhysicalDeviceType = gen.PhysicalDeviceType;

/// What a queue family can be asked to do. A family almost always supports
/// more than one thing, and `transfer` is implied by `graphics` and `compute`
/// even when the bit is not set.
pub const QueueFlags = gen.QueueFlags;

/// What a kind of device memory is good for. `device_local` is video memory;
/// `host_visible` can be mapped and written from the CPU; the two together are
/// the resizable BAR window, when there is one.
pub const MemoryPropertyFlags = gen.MemoryPropertyFlags;

/// What a memory heap is. `device_local` marks the one whose size is the
/// number people mean by "how much video memory".
pub const MemoryHeapFlags = gen.MemoryHeapFlags;

/// How many samples an attachment can carry. Read it as a set: a format
/// supports several counts at once.
pub const SampleCountFlags = gen.SampleCountFlags;

/// `enumerate_portability_khr` lets drivers that implement only a portable
/// subset of Vulkan be enumerated - MoltenVK on macOS being the one everybody
/// meets. Without it, `vkCreateInstance` there fails with
/// `error.IncompatibleDriver`. Requires the `VK_KHR_portability_enumeration`
/// instance extension, which is why `Loader` turns both on together.
pub const InstanceCreateFlags = gen.InstanceCreateFlags;

/// Reserved for future use, and required to be zero today.
pub const DeviceCreateFlags = gen.DeviceCreateFlags;

/// The only bit today marks a queue as protected-capable.
pub const DeviceQueueCreateFlags = gen.DeviceQueueCreateFlags;

// -------------------------------------------------------------------------
// Allocation callbacks
// -------------------------------------------------------------------------

/// What the allocation is being asked to hold, which decides how long it lives.
pub const SystemAllocationScope = gen.SystemAllocationScope;

pub const InternalAllocationType = gen.InternalAllocationType;

pub const PfnAllocation = gen.PfnAllocationFunction;
pub const PfnReallocation = gen.PfnReallocationFunction;
pub const PfnFree = gen.PfnFreeFunction;
pub const PfnInternalAllocationNotification = gen.PfnInternalAllocationNotification;
pub const PfnInternalFreeNotification = gen.PfnInternalFreeNotification;

/// Host memory allocation, handed over to you.
///
/// This is for the driver's own bookkeeping on the CPU, not for device memory.
/// Passing `null` instead - which every command in this library lets you do -
/// leaves the driver to use the system allocator, and that is the right answer
/// until a profiler says otherwise.
pub const AllocationCallbacks = gen.AllocationCallbacks;

// -------------------------------------------------------------------------
// Layers and extensions
// -------------------------------------------------------------------------

/// One entry of what `vkEnumerateInstanceExtensionProperties` and its device
/// counterpart return. `name()` is the name without the zero padding.
pub const ExtensionProperties = gen.ExtensionProperties;

/// One entry of what `vkEnumerateInstanceLayerProperties` returns. `name()` and
/// `describe()` read the two fixed-width strings.
pub const LayerProperties = gen.LayerProperties;

// -------------------------------------------------------------------------
// Creating an instance
// -------------------------------------------------------------------------

/// What the application calls itself, and which Vulkan version it was written
/// against.
///
/// `api_version` is the only field that changes behaviour: it is a promise
/// about which version's rules you expect, and the loader refuses an instance
/// if no driver can keep it. The names and versions are for tools - though
/// drivers do genuinely read them, to apply per-application workarounds.
/// `api_version` is a packed version - see `version.ApiVersion` - and zero
/// means 1.0.
pub const ApplicationInfo = gen.ApplicationInfo;

/// `setLayers` and `setExtensions` write a count and a pointer from one slice.
pub const InstanceCreateInfo = gen.InstanceCreateInfo;

// -------------------------------------------------------------------------
// Looking at a physical device
// -------------------------------------------------------------------------

pub const Extent3D = gen.Extent3D;

/// What one family of queues can do, and how many queues are in it.
///
/// A family's index is its position in the array the driver fills in, which is
/// why `queueFamilies` hands back the whole slice rather than one entry.
pub const QueueFamilyProperties = gen.QueueFamilyProperties;

pub const MemoryType = gen.MemoryType;

pub const MemoryHeap = gen.MemoryHeap;

/// Every kind of memory a device has, and the heaps they come out of. Both
/// arrays are fixed-width and mostly empty; read them through `types()` and
/// `heaps()` rather than to the end.
pub const PhysicalDeviceMemoryProperties = gen.PhysicalDeviceMemoryProperties;

/// The hard numbers: how large a texture may be, how many descriptors a stage
/// may see, how finely a viewport is subdivided. None of it is a preference -
/// exceeding any of it is undefined behaviour.
pub const PhysicalDeviceLimits = gen.PhysicalDeviceLimits;

/// Which forms of sparse residency the device implements the standard layout
/// for. Rarely read, and part of `PhysicalDeviceProperties` whether or not
/// anyone wants it.
pub const PhysicalDeviceSparseProperties = gen.PhysicalDeviceSparseProperties;

/// Who a physical device is, and what it will put up with.
///
/// The driver writes the whole struct into memory this library hands over, so
/// this declaration has to be exactly the size the driver expects - which is
/// what the size test at the bottom of this file, and the layout oracle, are
/// for.
pub const PhysicalDeviceProperties = gen.PhysicalDeviceProperties;

/// The same properties, with a `next` chain hanging off them.
///
/// This is the door to everything the 1.0 struct has no room for: the driver's
/// name and its conformance version, subgroup sizes, descriptor indexing
/// limits, ray tracing shader group alignment. Point `next` at whatever struct
/// an extension defines, and the driver fills that in too. The command is core
/// since Vulkan 1.1 and an extension before it, which is why
/// `commands.Instance` lists it as optional and gives it an alias.
pub const PhysicalDeviceProperties2 = gen.PhysicalDeviceProperties2;

/// The Vulkan 1.0 optional features, each either present or not.
///
/// Read it with `getPhysicalDeviceFeatures` to see what a device offers, then
/// hand a copy - with everything you do not need turned off - to
/// `DeviceCreateInfo.enabled_features`. Asking for a feature the device does
/// not have fails device creation; leaving one off costs nothing.
pub const PhysicalDeviceFeatures = gen.PhysicalDeviceFeatures;

// -------------------------------------------------------------------------
// Creating a device
// -------------------------------------------------------------------------

/// How many queues to take out of one family, and how much each of them
/// matters relative to the others.
///
/// `priorities.len` is the queue count, so build one with `queues` and the two
/// cannot disagree.
pub const DeviceQueueCreateInfo = gen.DeviceQueueCreateInfo;

/// `setQueues` and `setExtensions` write a count and a pointer from one slice.
pub const DeviceCreateInfo = gen.DeviceCreateInfo;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// What the structs holding a `u64` or a `size_t` come to, which is not one
/// number: three C ABIs are in play across the platforms Vulkan runs on.
const abi = struct {
    limits: usize,
    properties: usize,
    limits_offset: usize,
    memory: usize,

    /// 64-bit everything: every desktop, and arm64 Android.
    const wide: @This() = .{ .limits = 504, .properties = 824, .limits_offset = 296, .memory = 520 };
    /// 32-bit pointers, but `u64` still aligned to eight - armv7 Android, and
    /// 32-bit Windows.
    const narrow: @This() = .{ .limits = 496, .properties = 816, .limits_offset = 296, .memory = 520 };
    /// 32-bit pointers and `u64` aligned to four, which is i386 System V and
    /// nothing else.
    const packed_u64: @This() = .{ .limits = 488, .properties = 800, .limits_offset = 292, .memory = 456 };

    const expected: @This() = if (@sizeOf(usize) == 8)
        wide
    else if (@alignOf(u64) == 8)
        narrow
    else
        packed_u64;
};

test "the structs the driver writes into are the size it expects" {
    // Each of these is filled in by the driver, into memory this library hands
    // over. A declaration one field short is a buffer overflow that no test of
    // behaviour would catch, so the sizes are pinned rather than trusted.
    //
    // The ones built from `u32` alone come to the same number everywhere.
    try testing.expectEqual(@as(usize, 260), @sizeOf(ExtensionProperties));
    try testing.expectEqual(@as(usize, 520), @sizeOf(LayerProperties));
    try testing.expectEqual(@as(usize, 24), @sizeOf(QueueFamilyProperties));
    try testing.expectEqual(@as(usize, 220), @sizeOf(PhysicalDeviceFeatures));
    try testing.expectEqual(@as(usize, 20), @sizeOf(PhysicalDeviceSparseProperties));

    // The ones with a `VkDeviceSize` or a `size_t` in them do not.
    try testing.expectEqual(abi.expected.limits, @sizeOf(PhysicalDeviceLimits));
    try testing.expectEqual(abi.expected.properties, @sizeOf(PhysicalDeviceProperties));
    try testing.expectEqual(abi.expected.memory, @sizeOf(PhysicalDeviceMemoryProperties));
    try testing.expectEqual(
        abi.expected.limits_offset,
        @offsetOf(PhysicalDeviceProperties, "limits"),
    );

    // Everything device selection reads is `u32` or a byte array, so it sits
    // at the same offset on every platform - which is why a wrong `limits` is
    // still a wrong size and not a wrong device name.
    try testing.expectEqual(@as(usize, 16), @offsetOf(PhysicalDeviceProperties, "device_type"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(PhysicalDeviceProperties, "device_name"));
    try testing.expectEqual(@as(usize, 276), @offsetOf(PhysicalDeviceProperties, "pipeline_cache_uuid"));
    try testing.expectEqual(@as(usize, 260), @offsetOf(PhysicalDeviceMemoryProperties, "memory_heap_count"));
}

test "the calling convention is the one VKAPI_CALL expands to" {
    const Tag = std.meta.Tag(std.builtin.CallingConvention);
    const ours: Tag = std.meta.activeTag(call);
    const plain: Tag = std.meta.activeTag(std.builtin.CallingConvention.c);

    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) {
        // The one platform where this is not decoration. `__stdcall` has the
        // callee clean the arguments off the stack and `__cdecl` has the
        // caller do it; picking the wrong one leaves the stack pointer wrong
        // after every call, and the crash lands somewhere unrelated.
        try testing.expectEqual(Tag.x86_stdcall, ours);
        try testing.expect(ours != plain);
    } else if (builtin.abi.isAndroid() and
        (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb))
    {
        // Vulkan on 32-bit ARM Android passes floats in VFP registers whatever
        // the application was built for.
        try testing.expectEqual(Tag.arm_aapcs_vfp, ours);
    } else {
        // Everywhere else `VKAPI_CALL` is empty, and 64-bit Windows has only
        // one convention for `.winapi` to mean.
        try testing.expectEqual(plain, ours);
    }
}

test "result codes divide into failures and successes" {
    try testing.expect(Result.success.succeeded());
    try testing.expect(Result.incomplete.succeeded());
    try testing.expect(Result.suboptimal_khr.succeeded());
    try testing.expect(!Result.error_device_lost.succeeded());

    // A success comes back rather than being thrown away: `incomplete` is not
    // a failure, but it is not nothing either.
    try testing.expectEqual(Result.incomplete, try Result.incomplete.check());
    try testing.expectError(error.DeviceLost, Result.error_device_lost.check());
    try testing.expectError(error.OutOfHostMemory, Result.error_out_of_host_memory.check());
    try testing.expectError(error.OutOfDate, Result.error_out_of_date_khr.check());

    // A code from an extension this library has never heard of.
    const invented: Result = @enumFromInt(-1000999999);
    try testing.expectError(error.Unknown, invented.check());
    const invented_ok: Result = @enumFromInt(1000999999);
    try testing.expectEqual(invented_ok, try invented_ok.check());
}

test "names come out of their padding" {
    var props: ExtensionProperties = .{ .extension_name = @splat(0), .spec_version = 1 };
    @memcpy(props.extension_name[0.."VK_KHR_surface".len], "VK_KHR_surface");
    try testing.expectEqualStrings("VK_KHR_surface", props.name());

    // A name that fills the array leaves no room for a terminator.
    var full: ExtensionProperties = .{ .extension_name = @splat('x'), .spec_version = 1 };
    try testing.expectEqual(@as(usize, max_extension_name_size), full.name().len);
    full.extension_name[0] = 0;
    try testing.expectEqualStrings("", full.name());
}

test "flags are sets, not integers" {
    const family: QueueFlags = .{ .graphics = true, .compute = true, .transfer = true };
    try testing.expect(family.contains(.{ .graphics = true }));
    try testing.expect(family.contains(.{ .graphics = true, .compute = true }));
    try testing.expect(!family.contains(.{ .sparse_binding = true }));

    // And the bit positions are the ones the headers use.
    try testing.expectEqual(@as(u32, 0x1), @as(u32, @bitCast(QueueFlags{ .graphics = true })));
    try testing.expectEqual(@as(u32, 0x2), @as(u32, @bitCast(QueueFlags{ .compute = true })));
    try testing.expectEqual(@as(u32, 0x8), @as(u32, @bitCast(QueueFlags{ .sparse_binding = true })));
    try testing.expectEqual(
        @as(u32, 0x1),
        @as(u32, @bitCast(MemoryPropertyFlags{ .device_local = true })),
    );
    try testing.expectEqual(@as(u32, 0x10), @as(u32, @bitCast(SampleCountFlags{ .x16 = true })));
    try testing.expectEqual(
        @as(u32, 0x1),
        @as(u32, @bitCast(InstanceCreateFlags{ .enumerate_portability_khr = true })),
    );
}

test "create infos tag themselves" {
    // The one field nobody should have to remember.
    const app: ApplicationInfo = .{ .application_name = "demo" };
    try testing.expectEqual(StructureType.application_info, app.s_type);

    var info: InstanceCreateInfo = .{ .application_info = &app };
    try testing.expectEqual(StructureType.instance_create_info, info.s_type);

    // And the count follows the pointer, because both come from one slice.
    const wanted = [_][*:0]const u8{ "VK_KHR_surface", "VK_EXT_debug_utils" };
    info.setExtensions(&wanted);
    try testing.expectEqual(@as(u32, 2), info.enabled_extension_count);
    try testing.expectEqualStrings("VK_KHR_surface", std.mem.span(info.enabled_extension_names.?[0]));

    const priorities = [_]f32{ 1.0, 0.5 };
    const queue: DeviceQueueCreateInfo = .queues(3, &priorities);
    try testing.expectEqual(@as(u32, 3), queue.queue_family_index);
    try testing.expectEqual(@as(u32, 2), queue.queue_count);
    try testing.expectEqual(StructureType.device_queue_create_info, queue.s_type);
}

test "the largest device-local heap is the video memory" {
    var props: PhysicalDeviceMemoryProperties = std.mem.zeroes(PhysicalDeviceMemoryProperties);
    props.memory_heap_count = 3;
    props.memory_heaps[0] = .{ .size = 8 << 30, .flags = .{ .device_local = true } };
    props.memory_heaps[1] = .{ .size = 32 << 30, .flags = .{} }; // system memory
    props.memory_heaps[2] = .{ .size = 256 << 20, .flags = .{ .device_local = true } };

    try testing.expectEqual(@as(DeviceSize, 8 << 30), props.deviceLocalBytes());
    try testing.expectEqual(@as(usize, 3), props.heaps().len);
    try testing.expectEqual(@as(usize, 0), props.types().len);
}
