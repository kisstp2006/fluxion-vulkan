// SPDX-License-Identifier: CC0-1.0

//! The slice of the Vulkan ABI a loader needs, and nothing beyond it.
//!
//! A loader has to speak enough Vulkan to open the door: name the handles, read
//! a result code, ask what layers and extensions are on offer, create an
//! instance, look at the physical devices, create a device. That is where these
//! declarations stop. Everything past the door belongs to whatever binding you
//! use, and `dispatch` loads a table of its declarations just as happily.
//!
//! Two conveniences the C headers do not have:
//!
//!   * every `s_type` field defaults to the right tag, so a create info is
//!     built by naming the fields you care about and nothing else;
//!   * every count-and-pointer pair has a setter that writes both, so the two
//!     cannot drift apart.
//!
//! Handles are distinct opaque pointer types, so a `Device` will not go where
//! an `Instance` was meant.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

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
pub const Instance = *opaque {};

/// A GPU the instance found. Neither created nor destroyed - it exists as
/// long as the instance does.
pub const PhysicalDevice = *opaque {};

/// An opened physical device, and the thing device-level commands dispatch on.
pub const Device = *opaque {};

/// A queue belonging to a device, taken out of it rather than created.
pub const Queue = *opaque {};

// -------------------------------------------------------------------------
// Scalars
// -------------------------------------------------------------------------

/// Vulkan's boolean: four bytes, `0` or `1`. `boolean` and `isTrue` convert.
pub const Bool32 = u32;

pub const vk_false: Bool32 = 0;
pub const vk_true: Bool32 = 1;

pub fn boolean(value: bool) Bool32 {
    return if (value) vk_true else vk_false;
}

pub fn isTrue(value: Bool32) bool {
    return value != vk_false;
}

/// A size or offset in device memory. Always 64 bits, on every platform.
pub const DeviceSize = u64;

/// The fixed widths the C headers spell as `VK_MAX_*`.
pub const max_extension_name_size = 256;
pub const max_description_size = 256;
pub const max_physical_device_name_size = 256;
pub const max_memory_types = 32;
pub const max_memory_heaps = 16;
pub const uuid_size = 16;

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
pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    event_set = 3,
    event_reset = 4,
    incomplete = 5,

    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    error_format_not_supported = -11,
    error_fragmented_pool = -12,
    error_unknown = -13,

    error_out_of_pool_memory = -1000069000,
    error_invalid_external_handle = -1000072003,
    error_fragmentation = -1000161000,
    error_invalid_opaque_capture_address = -1000257000,

    error_surface_lost_khr = -1000000000,
    error_native_window_in_use_khr = -1000000001,
    suboptimal_khr = 1000001003,
    error_out_of_date_khr = -1000001004,
    error_incompatible_display_khr = -1000003001,
    error_validation_failed_ext = -1000011001,

    _,

    /// Every failure a Vulkan command can report, as a Zig error.
    pub const Error = error{
        OutOfHostMemory,
        OutOfDeviceMemory,
        InitializationFailed,
        DeviceLost,
        MemoryMapFailed,
        LayerNotPresent,
        ExtensionNotPresent,
        FeatureNotPresent,
        IncompatibleDriver,
        TooManyObjects,
        FormatNotSupported,
        FragmentedPool,
        OutOfPoolMemory,
        InvalidExternalHandle,
        Fragmentation,
        InvalidOpaqueCaptureAddress,
        SurfaceLost,
        NativeWindowInUse,
        OutOfDate,
        IncompatibleDisplay,
        ValidationFailed,
        /// A negative code this library does not have a name for.
        Unknown,
    };

    /// Did the command succeed?
    pub fn succeeded(self: Result) bool {
        return @intFromEnum(self) >= 0;
    }

    /// Turn a failure into an error, and hand a success straight back.
    ///
    /// The result comes back rather than being swallowed, because the
    /// successes are not interchangeable: `incomplete` and `suboptimal_khr`
    /// are both success, and both mean you have something else to do.
    ///
    /// ```zig
    /// const result = try cmds.enumeratePhysicalDevices(instance, &n, buf).check();
    /// if (result == .incomplete) {} // there were more than `buf` could hold
    /// ```
    pub fn check(self: Result) Error!Result {
        return switch (self) {
            .error_out_of_host_memory => error.OutOfHostMemory,
            .error_out_of_device_memory => error.OutOfDeviceMemory,
            .error_initialization_failed => error.InitializationFailed,
            .error_device_lost => error.DeviceLost,
            .error_memory_map_failed => error.MemoryMapFailed,
            .error_layer_not_present => error.LayerNotPresent,
            .error_extension_not_present => error.ExtensionNotPresent,
            .error_feature_not_present => error.FeatureNotPresent,
            .error_incompatible_driver => error.IncompatibleDriver,
            .error_too_many_objects => error.TooManyObjects,
            .error_format_not_supported => error.FormatNotSupported,
            .error_fragmented_pool => error.FragmentedPool,
            .error_out_of_pool_memory => error.OutOfPoolMemory,
            .error_invalid_external_handle => error.InvalidExternalHandle,
            .error_fragmentation => error.Fragmentation,
            .error_invalid_opaque_capture_address => error.InvalidOpaqueCaptureAddress,
            .error_surface_lost_khr => error.SurfaceLost,
            .error_native_window_in_use_khr => error.NativeWindowInUse,
            .error_out_of_date_khr => error.OutOfDate,
            .error_incompatible_display_khr => error.IncompatibleDisplay,
            .error_validation_failed_ext => error.ValidationFailed,
            else => if (self.succeeded()) self else error.Unknown,
        };
    }
};

// -------------------------------------------------------------------------
// Enumerations and flags
// -------------------------------------------------------------------------

/// The tag every Vulkan struct starts with, so that a driver walking a `next`
/// chain knows what it is looking at. Only the tags this library's own structs
/// use are named; the enum is open for the rest.
pub const StructureType = enum(i32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    physical_device_properties_2 = 1000059001,
    _,
};

/// What kind of hardware a physical device is. The usual reason to look:
/// preferring `discrete_gpu` over the integrated one sitting next to it.
pub const PhysicalDeviceType = enum(i32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    cpu = 4,
    _,

    /// A short name, for printing.
    pub fn label(self: PhysicalDeviceType) []const u8 {
        return switch (self) {
            .other => "other",
            .integrated_gpu => "integrated GPU",
            .discrete_gpu => "discrete GPU",
            .virtual_gpu => "virtual GPU",
            .cpu => "CPU",
            _ => "unrecognised",
        };
    }
};

/// What a queue family can be asked to do. A family almost always supports
/// more than one thing, and `transfer` is implied by `graphics` and `compute`
/// even when the bit is not set.
pub const QueueFlags = packed struct(u32) {
    graphics: bool = false,
    compute: bool = false,
    transfer: bool = false,
    sparse_binding: bool = false,
    protected: bool = false,
    video_decode_khr: bool = false,
    video_encode_khr: bool = false,
    _reserved: u25 = 0,

    /// Does this family support everything in `wanted`?
    pub fn contains(self: QueueFlags, wanted: QueueFlags) bool {
        const have: u32 = @bitCast(self);
        const need: u32 = @bitCast(wanted);
        return have & need == need;
    }
};

/// What a kind of device memory is good for. `device_local` is video memory;
/// `host_visible` can be mapped and written from the CPU; the two together are
/// the resizable BAR window, when there is one.
pub const MemoryPropertyFlags = packed struct(u32) {
    device_local: bool = false,
    host_visible: bool = false,
    host_coherent: bool = false,
    host_cached: bool = false,
    lazily_allocated: bool = false,
    protected: bool = false,
    _reserved: u26 = 0,

    pub fn contains(self: MemoryPropertyFlags, wanted: MemoryPropertyFlags) bool {
        const have: u32 = @bitCast(self);
        const need: u32 = @bitCast(wanted);
        return have & need == need;
    }
};

/// What a memory heap is. `device_local` marks the one whose size is the
/// number people mean by "how much video memory".
pub const MemoryHeapFlags = packed struct(u32) {
    device_local: bool = false,
    multi_instance: bool = false,
    _reserved: u30 = 0,
};

/// How many samples an attachment can carry. Read it as a set: a format
/// supports several counts at once.
pub const SampleCountFlags = packed struct(u32) {
    x1: bool = false,
    x2: bool = false,
    x4: bool = false,
    x8: bool = false,
    x16: bool = false,
    x32: bool = false,
    x64: bool = false,
    _reserved: u25 = 0,
};

pub const InstanceCreateFlags = packed struct(u32) {
    /// Let drivers that implement only a portable subset of Vulkan be
    /// enumerated - MoltenVK on macOS being the one everybody meets. Without
    /// it, `vkCreateInstance` there fails with `error.IncompatibleDriver`.
    /// Requires the `VK_KHR_portability_enumeration` instance extension, which
    /// is why `Loader` turns both on together.
    enumerate_portability_khr: bool = false,
    _reserved: u31 = 0,
};

/// Reserved for future use, and required to be zero today.
pub const DeviceCreateFlags = u32;

/// The only bit today marks a queue as protected-capable.
pub const DeviceQueueCreateFlags = packed struct(u32) {
    protected: bool = false,
    _reserved: u31 = 0,
};

// -------------------------------------------------------------------------
// Allocation callbacks
// -------------------------------------------------------------------------

/// What the allocation is being asked to hold, which decides how long it lives.
pub const SystemAllocationScope = enum(i32) {
    command = 0,
    object = 1,
    cache = 2,
    device = 3,
    instance = 4,
    _,
};

pub const InternalAllocationType = enum(i32) {
    executable = 0,
    _,
};

pub const PfnAllocation = *const fn (
    user_data: ?*anyopaque,
    size: usize,
    alignment: usize,
    scope: SystemAllocationScope,
) callconv(call) ?*anyopaque;

pub const PfnReallocation = *const fn (
    user_data: ?*anyopaque,
    original: ?*anyopaque,
    size: usize,
    alignment: usize,
    scope: SystemAllocationScope,
) callconv(call) ?*anyopaque;

pub const PfnFree = *const fn (
    user_data: ?*anyopaque,
    memory: ?*anyopaque,
) callconv(call) void;

pub const PfnInternalAllocationNotification = *const fn (
    user_data: ?*anyopaque,
    size: usize,
    allocation_type: InternalAllocationType,
    scope: SystemAllocationScope,
) callconv(call) void;

pub const PfnInternalFreeNotification = *const fn (
    user_data: ?*anyopaque,
    size: usize,
    allocation_type: InternalAllocationType,
    scope: SystemAllocationScope,
) callconv(call) void;

/// Host memory allocation, handed over to you.
///
/// This is for the driver's own bookkeeping on the CPU, not for device memory.
/// Passing `null` instead - which every command in this library lets you do -
/// leaves the driver to use the system allocator, and that is the right answer
/// until a profiler says otherwise.
pub const AllocationCallbacks = extern struct {
    user_data: ?*anyopaque = null,
    allocation: PfnAllocation,
    reallocation: PfnReallocation,
    free: PfnFree,
    internal_allocation: ?PfnInternalAllocationNotification = null,
    internal_free: ?PfnInternalFreeNotification = null,
};

// -------------------------------------------------------------------------
// Layers and extensions
// -------------------------------------------------------------------------

/// One entry of what `vkEnumerateInstanceExtensionProperties` and its device
/// counterpart return.
pub const ExtensionProperties = extern struct {
    extension_name: [max_extension_name_size]u8,
    spec_version: u32,

    /// The name, without the zero padding behind it.
    pub fn name(self: *const ExtensionProperties) []const u8 {
        return cstr(&self.extension_name);
    }
};

/// One entry of what `vkEnumerateInstanceLayerProperties` returns.
pub const LayerProperties = extern struct {
    layer_name: [max_extension_name_size]u8,
    /// The Vulkan version the layer was written against.
    spec_version: u32,
    /// The layer's own version.
    implementation_version: u32,
    description: [max_description_size]u8,

    pub fn name(self: *const LayerProperties) []const u8 {
        return cstr(&self.layer_name);
    }

    pub fn describe(self: *const LayerProperties) []const u8 {
        return cstr(&self.description);
    }
};

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
pub const ApplicationInfo = extern struct {
    s_type: StructureType = .application_info,
    next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    /// A packed version - see `version.ApiVersion`. Zero means 1.0.
    api_version: u32 = 0,
};

pub const InstanceCreateInfo = extern struct {
    s_type: StructureType = .instance_create_info,
    next: ?*const anyopaque = null,
    flags: InstanceCreateFlags = .{},
    application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,

    /// Set the pointer and the count from one slice, so the two cannot
    /// disagree.
    pub fn setLayers(self: *InstanceCreateInfo, names: []const [*:0]const u8) void {
        self.enabled_layer_count = @intCast(names.len);
        self.enabled_layer_names = names.ptr;
    }

    pub fn setExtensions(self: *InstanceCreateInfo, names: []const [*:0]const u8) void {
        self.enabled_extension_count = @intCast(names.len);
        self.enabled_extension_names = names.ptr;
    }
};

// -------------------------------------------------------------------------
// Looking at a physical device
// -------------------------------------------------------------------------

pub const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

/// What one family of queues can do, and how many queues are in it.
///
/// A family's index is its position in the array the driver fills in, which is
/// why `queueFamilies` hands back the whole slice rather than one entry.
pub const QueueFamilyProperties = extern struct {
    queue_flags: QueueFlags,
    queue_count: u32,
    /// How many bits of a timestamp query are meaningful. `0` means the family
    /// cannot timestamp at all.
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const MemoryType = extern struct {
    property_flags: MemoryPropertyFlags,
    heap_index: u32,
};

pub const MemoryHeap = extern struct {
    size: DeviceSize,
    flags: MemoryHeapFlags,
};

/// Every kind of memory a device has, and the heaps they come out of.
///
/// Both arrays are fixed-width and mostly empty; read them through `types` and
/// `heaps` rather than to the end.
pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [max_memory_types]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [max_memory_heaps]MemoryHeap,

    pub fn types(self: *const PhysicalDeviceMemoryProperties) []const MemoryType {
        return self.memory_types[0..self.memory_type_count];
    }

    pub fn heaps(self: *const PhysicalDeviceMemoryProperties) []const MemoryHeap {
        return self.memory_heaps[0..self.memory_heap_count];
    }

    /// The size of the largest device-local heap: the number people mean when
    /// they ask how much video memory a card has.
    pub fn deviceLocalBytes(self: *const PhysicalDeviceMemoryProperties) DeviceSize {
        var largest: DeviceSize = 0;
        for (self.heaps()) |heap| {
            if (heap.flags.device_local and heap.size > largest) largest = heap.size;
        }
        return largest;
    }
};

/// The hard numbers: how large a texture may be, how many descriptors a stage
/// may see, how finely a viewport is subdivided. None of it is a preference -
/// exceeding any of it is undefined behaviour.
pub const PhysicalDeviceLimits = extern struct {
    max_image_dimension_1d: u32,
    max_image_dimension_2d: u32,
    max_image_dimension_3d: u32,
    max_image_dimension_cube: u32,
    max_image_array_layers: u32,
    max_texel_buffer_elements: u32,
    max_uniform_buffer_range: u32,
    max_storage_buffer_range: u32,
    max_push_constants_size: u32,
    max_memory_allocation_count: u32,
    max_sampler_allocation_count: u32,
    buffer_image_granularity: DeviceSize,
    sparse_address_space_size: DeviceSize,
    max_bound_descriptor_sets: u32,
    max_per_stage_descriptor_samplers: u32,
    max_per_stage_descriptor_uniform_buffers: u32,
    max_per_stage_descriptor_storage_buffers: u32,
    max_per_stage_descriptor_sampled_images: u32,
    max_per_stage_descriptor_storage_images: u32,
    max_per_stage_descriptor_input_attachments: u32,
    max_per_stage_resources: u32,
    max_descriptor_set_samplers: u32,
    max_descriptor_set_uniform_buffers: u32,
    max_descriptor_set_uniform_buffers_dynamic: u32,
    max_descriptor_set_storage_buffers: u32,
    max_descriptor_set_storage_buffers_dynamic: u32,
    max_descriptor_set_sampled_images: u32,
    max_descriptor_set_storage_images: u32,
    max_descriptor_set_input_attachments: u32,
    max_vertex_input_attributes: u32,
    max_vertex_input_bindings: u32,
    max_vertex_input_attribute_offset: u32,
    max_vertex_input_binding_stride: u32,
    max_vertex_output_components: u32,
    max_tessellation_generation_level: u32,
    max_tessellation_patch_size: u32,
    max_tessellation_control_per_vertex_input_components: u32,
    max_tessellation_control_per_vertex_output_components: u32,
    max_tessellation_control_per_patch_output_components: u32,
    max_tessellation_control_total_output_components: u32,
    max_tessellation_evaluation_input_components: u32,
    max_tessellation_evaluation_output_components: u32,
    max_geometry_shader_invocations: u32,
    max_geometry_input_components: u32,
    max_geometry_output_components: u32,
    max_geometry_output_vertices: u32,
    max_geometry_total_output_components: u32,
    max_fragment_input_components: u32,
    max_fragment_output_attachments: u32,
    max_fragment_dual_src_attachments: u32,
    max_fragment_combined_output_resources: u32,
    max_compute_shared_memory_size: u32,
    max_compute_work_group_count: [3]u32,
    max_compute_work_group_invocations: u32,
    max_compute_work_group_size: [3]u32,
    sub_pixel_precision_bits: u32,
    sub_texel_precision_bits: u32,
    mipmap_precision_bits: u32,
    max_draw_indexed_index_value: u32,
    max_draw_indirect_count: u32,
    max_sampler_lod_bias: f32,
    max_sampler_anisotropy: f32,
    max_viewports: u32,
    max_viewport_dimensions: [2]u32,
    viewport_bounds_range: [2]f32,
    viewport_sub_pixel_bits: u32,
    min_memory_map_alignment: usize,
    min_texel_buffer_offset_alignment: DeviceSize,
    min_uniform_buffer_offset_alignment: DeviceSize,
    min_storage_buffer_offset_alignment: DeviceSize,
    min_texel_offset: i32,
    max_texel_offset: u32,
    min_texel_gather_offset: i32,
    max_texel_gather_offset: u32,
    min_interpolation_offset: f32,
    max_interpolation_offset: f32,
    sub_pixel_interpolation_offset_bits: u32,
    max_framebuffer_width: u32,
    max_framebuffer_height: u32,
    max_framebuffer_layers: u32,
    framebuffer_color_sample_counts: SampleCountFlags,
    framebuffer_depth_sample_counts: SampleCountFlags,
    framebuffer_stencil_sample_counts: SampleCountFlags,
    framebuffer_no_attachments_sample_counts: SampleCountFlags,
    max_color_attachments: u32,
    sampled_image_color_sample_counts: SampleCountFlags,
    sampled_image_integer_sample_counts: SampleCountFlags,
    sampled_image_depth_sample_counts: SampleCountFlags,
    sampled_image_stencil_sample_counts: SampleCountFlags,
    storage_image_sample_counts: SampleCountFlags,
    max_sample_mask_words: u32,
    timestamp_compute_and_graphics: Bool32,
    timestamp_period: f32,
    max_clip_distances: u32,
    max_cull_distances: u32,
    max_combined_clip_and_cull_distances: u32,
    discrete_queue_priorities: u32,
    point_size_range: [2]f32,
    line_width_range: [2]f32,
    point_size_granularity: f32,
    line_width_granularity: f32,
    strict_lines: Bool32,
    standard_sample_locations: Bool32,
    optimal_buffer_copy_offset_alignment: DeviceSize,
    optimal_buffer_copy_row_pitch_alignment: DeviceSize,
    non_coherent_atom_size: DeviceSize,
};

/// Which forms of sparse residency the device implements the standard layout
/// for. Rarely read, and part of `PhysicalDeviceProperties` whether or not
/// anyone wants it.
pub const PhysicalDeviceSparseProperties = extern struct {
    residency_standard_2d_block_shape: Bool32,
    residency_standard_2d_multisample_block_shape: Bool32,
    residency_standard_3d_block_shape: Bool32,
    residency_aligned_mip_size: Bool32,
    residency_non_resident_strict: Bool32,
};

/// Who a physical device is, and what it will put up with.
///
/// The driver writes the whole struct into memory this library hands over, so
/// this declaration has to be exactly the size the driver expects - which is
/// what the size test at the bottom of this file is for. Everything device
/// selection reads sits before `limits`, at the top.
pub const PhysicalDeviceProperties = extern struct {
    /// The highest Vulkan version this device supports. Not the loader's
    /// version, and not the version you asked for.
    api_version: u32,
    /// The driver's own version, packed however the vendor felt like.
    driver_version: u32,
    /// The PCI vendor id: `0x10DE` NVIDIA, `0x1002` AMD, `0x8086` Intel.
    vendor_id: u32,
    device_id: u32,
    device_type: PhysicalDeviceType,
    device_name: [max_physical_device_name_size]u8,
    /// Stable across runs and driver updates: the key a pipeline cache is
    /// filed under, so a cache from another machine is never fed to this one.
    pipeline_cache_uuid: [uuid_size]u8,
    limits: PhysicalDeviceLimits,
    sparse_properties: PhysicalDeviceSparseProperties,

    pub fn name(self: *const PhysicalDeviceProperties) []const u8 {
        return cstr(&self.device_name);
    }
};

/// The same properties, with a `next` chain hanging off them.
///
/// This is the door to everything the 1.0 struct has no room for: the driver's
/// name and its conformance version, subgroup sizes, descriptor indexing
/// limits, ray tracing shader group alignment. Point `next` at whatever struct
/// an extension defines, and the driver fills that in too. The command is core
/// since Vulkan 1.1 and an extension before it, which is why
/// `commands.Instance` lists it as optional and gives it an alias.
pub const PhysicalDeviceProperties2 = extern struct {
    s_type: StructureType = .physical_device_properties_2,
    next: ?*anyopaque = null,
    properties: PhysicalDeviceProperties,
};

/// The Vulkan 1.0 optional features, each either present or not.
///
/// Read it with `getPhysicalDeviceFeatures` to see what a device offers, then
/// hand a copy - with everything you do not need turned off - to
/// `DeviceCreateInfo.enabled_features`. Asking for a feature the device does
/// not have fails device creation; leaving one off costs nothing.
pub const PhysicalDeviceFeatures = extern struct {
    robust_buffer_access: Bool32 = vk_false,
    full_draw_index_uint32: Bool32 = vk_false,
    image_cube_array: Bool32 = vk_false,
    independent_blend: Bool32 = vk_false,
    geometry_shader: Bool32 = vk_false,
    tessellation_shader: Bool32 = vk_false,
    sample_rate_shading: Bool32 = vk_false,
    dual_src_blend: Bool32 = vk_false,
    logic_op: Bool32 = vk_false,
    multi_draw_indirect: Bool32 = vk_false,
    draw_indirect_first_instance: Bool32 = vk_false,
    depth_clamp: Bool32 = vk_false,
    depth_bias_clamp: Bool32 = vk_false,
    fill_mode_non_solid: Bool32 = vk_false,
    depth_bounds: Bool32 = vk_false,
    wide_lines: Bool32 = vk_false,
    large_points: Bool32 = vk_false,
    alpha_to_one: Bool32 = vk_false,
    multi_viewport: Bool32 = vk_false,
    sampler_anisotropy: Bool32 = vk_false,
    texture_compression_etc2: Bool32 = vk_false,
    texture_compression_astc_ldr: Bool32 = vk_false,
    texture_compression_bc: Bool32 = vk_false,
    occlusion_query_precise: Bool32 = vk_false,
    pipeline_statistics_query: Bool32 = vk_false,
    vertex_pipeline_stores_and_atomics: Bool32 = vk_false,
    fragment_stores_and_atomics: Bool32 = vk_false,
    shader_tessellation_and_geometry_point_size: Bool32 = vk_false,
    shader_image_gather_extended: Bool32 = vk_false,
    shader_storage_image_extended_formats: Bool32 = vk_false,
    shader_storage_image_multisample: Bool32 = vk_false,
    shader_storage_image_read_without_format: Bool32 = vk_false,
    shader_storage_image_write_without_format: Bool32 = vk_false,
    shader_uniform_buffer_array_dynamic_indexing: Bool32 = vk_false,
    shader_sampled_image_array_dynamic_indexing: Bool32 = vk_false,
    shader_storage_buffer_array_dynamic_indexing: Bool32 = vk_false,
    shader_storage_image_array_dynamic_indexing: Bool32 = vk_false,
    shader_clip_distance: Bool32 = vk_false,
    shader_cull_distance: Bool32 = vk_false,
    shader_float64: Bool32 = vk_false,
    shader_int64: Bool32 = vk_false,
    shader_int16: Bool32 = vk_false,
    shader_resource_residency: Bool32 = vk_false,
    shader_resource_min_lod: Bool32 = vk_false,
    sparse_binding: Bool32 = vk_false,
    sparse_residency_buffer: Bool32 = vk_false,
    sparse_residency_image_2d: Bool32 = vk_false,
    sparse_residency_image_3d: Bool32 = vk_false,
    sparse_residency_2_samples: Bool32 = vk_false,
    sparse_residency_4_samples: Bool32 = vk_false,
    sparse_residency_8_samples: Bool32 = vk_false,
    sparse_residency_16_samples: Bool32 = vk_false,
    sparse_residency_aliased: Bool32 = vk_false,
    variable_multisample_rate: Bool32 = vk_false,
    inherited_queries: Bool32 = vk_false,
};

// -------------------------------------------------------------------------
// Creating a device
// -------------------------------------------------------------------------

/// How many queues to take out of one family, and how much each of them
/// matters relative to the others.
///
/// `priorities.len` is the queue count, so build one with `queues` and the two
/// cannot disagree.
pub const DeviceQueueCreateInfo = extern struct {
    s_type: StructureType = .device_queue_create_info,
    next: ?*const anyopaque = null,
    flags: DeviceQueueCreateFlags = .{},
    queue_family_index: u32,
    queue_count: u32,
    /// Each between 0.0 and 1.0. A hint, and drivers are free to ignore it.
    queue_priorities: [*]const f32,

    /// One queue per entry in `priorities`.
    ///
    /// ```zig
    /// const one = [_]f32{1.0};
    /// const queue_info: vk.DeviceQueueCreateInfo = .queues(family, &one);
    /// ```
    pub fn queues(family_index: u32, priorities: []const f32) DeviceQueueCreateInfo {
        return .{
            .queue_family_index = family_index,
            .queue_count = @intCast(priorities.len),
            .queue_priorities = priorities.ptr,
        };
    }
};

pub const DeviceCreateInfo = extern struct {
    s_type: StructureType = .device_create_info,
    next: ?*const anyopaque = null,
    flags: DeviceCreateFlags = 0,
    queue_create_info_count: u32 = 0,
    queue_create_infos: ?[*]const DeviceQueueCreateInfo = null,
    /// Ignored since Vulkan 1.1: device layers no longer exist, and the
    /// instance's layers cover the device too.
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
    enabled_features: ?*const PhysicalDeviceFeatures = null,

    pub fn setQueues(self: *DeviceCreateInfo, infos: []const DeviceQueueCreateInfo) void {
        self.queue_create_info_count = @intCast(infos.len);
        self.queue_create_infos = infos.ptr;
    }

    pub fn setExtensions(self: *DeviceCreateInfo, names: []const [*:0]const u8) void {
        self.enabled_extension_count = @intCast(names.len);
        self.enabled_extension_names = names.ptr;
    }
};

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
