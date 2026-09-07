// SPDX-License-Identifier: BSL-1.0

//! The Vulkan past the door, declared here because the loader does not.
//!
//! `fluxion-vulkan` stops where the API begins: it gets you a library, an
//! instance, a device and the tables to reach them through, and the several
//! thousand commands past that are your binding's business. This file is what
//! "your binding" looks like when you write only the part you need - the
//! handles, structs and commands the three sample programs beside it use, and
//! nothing else.
//!
//! It is worth reading as an answer to "how much would I have to write?". The
//! answer, for a compute dispatch and a triangle, is this file: no code
//! generation, no headers, no build step. Every command table here loads
//! through `vk.load` exactly like the ones the library ships.
//!
//! Two ABI rules that bite if you transcribe Vulkan by hand:
//!
//!   * **Dispatchable handles are pointers; the rest are 64-bit integers.**
//!     `VkDevice`, `VkQueue` and `VkCommandBuffer` are opaque pointers, and
//!     `VkBuffer`, `VkImage`, `VkPipeline` and everything else are `uint64_t`
//!     on every platform, 32-bit ones included.
//!   * **Every command pointer needs `vk.call`**, not `.c` - see
//!     `types.call`.

const std = @import("std");
const vk = @import("fluxion_vulkan");

pub const Device = vk.Device;
pub const Queue = vk.Queue;

/// A non-dispatchable handle: 64 bits everywhere, and zero means none.
///
/// Each `Handle` call makes a distinct type, so a `Buffer` will not go where
/// an `Image` was meant - which matters more here than usual, because to the
/// C API they are the same integer.
fn Handle(comptime name: []const u8) type {
    return enum(u64) {
        none = 0,
        _,

        /// Only so that the type name is distinct. Never read.
        pub const tag = name;
    };
}

pub const Buffer = Handle("Buffer");
pub const Image = Handle("Image");
pub const ImageView = Handle("ImageView");
pub const DeviceMemory = Handle("DeviceMemory");
pub const ShaderModule = Handle("ShaderModule");
pub const DescriptorSetLayout = Handle("DescriptorSetLayout");
pub const DescriptorPool = Handle("DescriptorPool");
pub const DescriptorSet = Handle("DescriptorSet");
pub const PipelineLayout = Handle("PipelineLayout");
pub const Pipeline = Handle("Pipeline");
pub const PipelineCache = Handle("PipelineCache");
pub const CommandPool = Handle("CommandPool");
pub const Fence = Handle("Fence");
pub const RenderPass = Handle("RenderPass");
pub const Framebuffer = Handle("Framebuffer");

/// Dispatchable, so a pointer rather than an integer.
pub const CommandBuffer = *opaque {};

pub const DeviceSize = vk.types.DeviceSize;

// -------------------------------------------------------------------------
// Structure tags
// -------------------------------------------------------------------------

/// The `sType` values these structs carry. Vulkan numbers them in declaration
/// order in the header, which is why they look arbitrary.
pub const S = struct {
    pub const submit_info: vk.types.StructureType = @enumFromInt(4);
    pub const memory_allocate_info: vk.types.StructureType = @enumFromInt(5);
    pub const fence_create_info: vk.types.StructureType = @enumFromInt(8);
    pub const buffer_create_info: vk.types.StructureType = @enumFromInt(12);
    pub const image_create_info: vk.types.StructureType = @enumFromInt(14);
    pub const image_view_create_info: vk.types.StructureType = @enumFromInt(15);
    pub const shader_module_create_info: vk.types.StructureType = @enumFromInt(16);
    pub const pipeline_shader_stage_create_info: vk.types.StructureType = @enumFromInt(18);
    pub const pipeline_vertex_input_state_create_info: vk.types.StructureType = @enumFromInt(19);
    pub const pipeline_input_assembly_state_create_info: vk.types.StructureType = @enumFromInt(20);
    pub const pipeline_viewport_state_create_info: vk.types.StructureType = @enumFromInt(22);
    pub const pipeline_rasterization_state_create_info: vk.types.StructureType = @enumFromInt(23);
    pub const pipeline_multisample_state_create_info: vk.types.StructureType = @enumFromInt(24);
    pub const pipeline_color_blend_state_create_info: vk.types.StructureType = @enumFromInt(26);
    pub const graphics_pipeline_create_info: vk.types.StructureType = @enumFromInt(28);
    pub const compute_pipeline_create_info: vk.types.StructureType = @enumFromInt(29);
    pub const pipeline_layout_create_info: vk.types.StructureType = @enumFromInt(30);
    pub const descriptor_set_layout_create_info: vk.types.StructureType = @enumFromInt(32);
    pub const descriptor_pool_create_info: vk.types.StructureType = @enumFromInt(33);
    pub const descriptor_set_allocate_info: vk.types.StructureType = @enumFromInt(34);
    pub const write_descriptor_set: vk.types.StructureType = @enumFromInt(35);
    pub const framebuffer_create_info: vk.types.StructureType = @enumFromInt(37);
    pub const render_pass_create_info: vk.types.StructureType = @enumFromInt(38);
    pub const command_pool_create_info: vk.types.StructureType = @enumFromInt(39);
    pub const command_buffer_allocate_info: vk.types.StructureType = @enumFromInt(40);
    pub const command_buffer_begin_info: vk.types.StructureType = @enumFromInt(42);
    pub const render_pass_begin_info: vk.types.StructureType = @enumFromInt(43);
};

// -------------------------------------------------------------------------
// Enumerations and flags
// -------------------------------------------------------------------------

pub const BufferUsageFlags = packed struct(u32) {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    uniform_texel_buffer: bool = false,
    storage_texel_buffer: bool = false,
    uniform_buffer: bool = false,
    storage_buffer: bool = false,
    index_buffer: bool = false,
    vertex_buffer: bool = false,
    indirect_buffer: bool = false,
    _reserved: u23 = 0,
};

pub const ImageUsageFlags = packed struct(u32) {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    transient_attachment: bool = false,
    input_attachment: bool = false,
    _reserved: u24 = 0,
};

pub const ShaderStageFlags = packed struct(u32) {
    vertex: bool = false,
    tessellation_control: bool = false,
    tessellation_evaluation: bool = false,
    geometry: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _reserved: u26 = 0,
};

pub const ColorComponentFlags = packed struct(u32) {
    r: bool = false,
    g: bool = false,
    b: bool = false,
    a: bool = false,
    _reserved: u28 = 0,

    pub const all: ColorComponentFlags = .{ .r = true, .g = true, .b = true, .a = true };
};

pub const ImageAspectFlags = packed struct(u32) {
    color: bool = false,
    depth: bool = false,
    stencil: bool = false,
    metadata: bool = false,
    _reserved: u28 = 0,
};

pub const CommandPoolCreateFlags = packed struct(u32) {
    transient: bool = false,
    reset_command_buffer: bool = false,
    _reserved: u30 = 0,
};

pub const CommandBufferUsageFlags = packed struct(u32) {
    one_time_submit: bool = false,
    render_pass_continue: bool = false,
    simultaneous_use: bool = false,
    _reserved: u29 = 0,
};

pub const SharingMode = enum(i32) { exclusive = 0, concurrent = 1, _ };
pub const DescriptorType = enum(i32) {
    storage_image = 3,
    uniform_buffer = 6,
    storage_buffer = 7,
    _,
};
pub const PipelineBindPoint = enum(i32) { graphics = 0, compute = 1, _ };
pub const CommandBufferLevel = enum(i32) { primary = 0, secondary = 1, _ };
pub const ImageType = enum(i32) { @"1d" = 0, @"2d" = 1, @"3d" = 2, _ };
pub const ImageViewType = enum(i32) { @"1d" = 0, @"2d" = 1, @"3d" = 2, _ };
pub const ImageTiling = enum(i32) { optimal = 0, linear = 1, _ };
pub const ImageLayout = enum(i32) {
    undefined = 0,
    general = 1,
    color_attachment_optimal = 2,
    transfer_src_optimal = 6,
    transfer_dst_optimal = 7,
    _,
};
pub const AttachmentLoadOp = enum(i32) { load = 0, clear = 1, dont_care = 2, _ };
pub const AttachmentStoreOp = enum(i32) { store = 0, dont_care = 1, _ };
/// `@"inline"` because Zig spells it as a keyword: the subpass's commands are
/// in this command buffer rather than in secondary ones.
pub const SubpassContents = enum(i32) { @"inline" = 0, secondary_command_buffers = 1, _ };
pub const PrimitiveTopology = enum(i32) { triangle_list = 3, _ };
pub const PolygonMode = enum(i32) { fill = 0, line = 1, point = 2, _ };
pub const FrontFace = enum(i32) { counter_clockwise = 0, clockwise = 1, _ };
pub const BlendFactor = enum(i32) { zero = 0, one = 1, _ };
pub const BlendOp = enum(i32) { add = 0, _ };
pub const LogicOp = enum(i32) { clear = 0, copy = 3, _ };

/// Only the formats these samples use. `r8g8b8a8_unorm` is the one to read
/// back on the CPU: four bytes per pixel, in the order they are written.
pub const Format = enum(i32) {
    undefined = 0,
    r8g8b8a8_unorm = 37,
    b8g8r8a8_unorm = 44,
    r32g32b32a32_sfloat = 109,
    _,
};

pub const SampleCountFlags = vk.types.SampleCountFlags;

// -------------------------------------------------------------------------
// Structs
// -------------------------------------------------------------------------

pub const Offset2D = extern struct { x: i32 = 0, y: i32 = 0 };
pub const Extent2D = extern struct { width: u32, height: u32 };
pub const Extent3D = vk.types.Extent3D;
pub const Rect2D = extern struct { offset: Offset2D = .{}, extent: Extent2D };

pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const MemoryRequirements = extern struct {
    size: DeviceSize,
    alignment: DeviceSize,
    /// One bit per index into `PhysicalDeviceMemoryProperties.memory_types`.
    memory_type_bits: u32,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: vk.types.StructureType = S.memory_allocate_info,
    next: ?*const anyopaque = null,
    allocation_size: DeviceSize,
    memory_type_index: u32,
};

pub const BufferCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.buffer_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    size: DeviceSize,
    usage: BufferUsageFlags,
    sharing_mode: SharingMode = .exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
};

pub const ImageCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.image_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    image_type: ImageType = .@"2d",
    format: Format,
    extent: Extent3D,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: SampleCountFlags = .{ .x1 = true },
    tiling: ImageTiling = .optimal,
    usage: ImageUsageFlags,
    sharing_mode: SharingMode = .exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    initial_layout: ImageLayout = .undefined,
};

pub const ComponentMapping = extern struct {
    r: i32 = 0,
    g: i32 = 0,
    b: i32 = 0,
    a: i32 = 0,
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: ImageAspectFlags = .{ .color = true },
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const ImageSubresourceLayers = extern struct {
    aspect_mask: ImageAspectFlags = .{ .color = true },
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.image_view_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    image: Image,
    view_type: ImageViewType = .@"2d",
    format: Format,
    components: ComponentMapping = .{},
    subresource_range: ImageSubresourceRange = .{},
};

pub const BufferImageCopy = extern struct {
    buffer_offset: DeviceSize = 0,
    /// Zero means tightly packed, which is what these samples want.
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    image_subresource: ImageSubresourceLayers = .{},
    image_offset: Offset3D = .{},
    image_extent: Extent3D,
};

pub const Offset3D = extern struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };

pub const ShaderModuleCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.shader_module_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    /// In bytes, though the code itself is words.
    code_size: usize,
    code: [*]const u32,
};

pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptor_type: DescriptorType,
    descriptor_count: u32 = 1,
    stage_flags: ShaderStageFlags,
    immutable_samplers: ?*const anyopaque = null,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.descriptor_set_layout_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    binding_count: u32,
    bindings: [*]const DescriptorSetLayoutBinding,
};

pub const DescriptorPoolSize = extern struct {
    type: DescriptorType,
    descriptor_count: u32,
};

pub const DescriptorPoolCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.descriptor_pool_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    max_sets: u32,
    pool_size_count: u32,
    pool_sizes: [*]const DescriptorPoolSize,
};

pub const DescriptorSetAllocateInfo = extern struct {
    s_type: vk.types.StructureType = S.descriptor_set_allocate_info,
    next: ?*const anyopaque = null,
    descriptor_pool: DescriptorPool,
    descriptor_set_count: u32,
    set_layouts: [*]const DescriptorSetLayout,
};

pub const DescriptorBufferInfo = extern struct {
    buffer: Buffer,
    offset: DeviceSize = 0,
    /// `whole_size` reaches to the end of the buffer.
    range: DeviceSize,

    pub const whole_size: DeviceSize = ~@as(DeviceSize, 0);
};

pub const WriteDescriptorSet = extern struct {
    s_type: vk.types.StructureType = S.write_descriptor_set,
    next: ?*const anyopaque = null,
    dst_set: DescriptorSet,
    dst_binding: u32,
    dst_array_element: u32 = 0,
    descriptor_count: u32 = 1,
    descriptor_type: DescriptorType,
    image_info: ?*const anyopaque = null,
    buffer_info: ?*const DescriptorBufferInfo = null,
    texel_buffer_view: ?*const anyopaque = null,
};

pub const PipelineLayoutCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.pipeline_layout_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    set_layout_count: u32 = 0,
    set_layouts: ?[*]const DescriptorSetLayout = null,
    push_constant_range_count: u32 = 0,
    push_constant_ranges: ?*const anyopaque = null,
};

pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.pipeline_shader_stage_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: ShaderStageFlags,
    module: ShaderModule,
    name: [*:0]const u8,
    specialization_info: ?*const anyopaque = null,
};

pub const ComputePipelineCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.compute_pipeline_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: PipelineShaderStageCreateInfo,
    layout: PipelineLayout,
    base_pipeline_handle: Pipeline = .none,
    base_pipeline_index: i32 = -1,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.command_pool_create_info,
    next: ?*const anyopaque = null,
    flags: CommandPoolCreateFlags = .{},
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: vk.types.StructureType = S.command_buffer_allocate_info,
    next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: CommandBufferLevel = .primary,
    command_buffer_count: u32,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: vk.types.StructureType = S.command_buffer_begin_info,
    next: ?*const anyopaque = null,
    flags: CommandBufferUsageFlags = .{},
    inheritance_info: ?*const anyopaque = null,
};

pub const SubmitInfo = extern struct {
    s_type: vk.types.StructureType = S.submit_info,
    next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?*const anyopaque = null,
    wait_dst_stage_mask: ?*const u32 = null,
    command_buffer_count: u32,
    command_buffers: [*]const CommandBuffer,
    signal_semaphore_count: u32 = 0,
    signal_semaphores: ?*const anyopaque = null,
};

pub const FenceCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.fence_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
};

// -------------------------------------------------------------------------
// Render pass and graphics pipeline
// -------------------------------------------------------------------------

pub const AttachmentDescription = extern struct {
    flags: u32 = 0,
    format: Format,
    samples: SampleCountFlags = .{ .x1 = true },
    load_op: AttachmentLoadOp,
    store_op: AttachmentStoreOp,
    stencil_load_op: AttachmentLoadOp = .dont_care,
    stencil_store_op: AttachmentStoreOp = .dont_care,
    initial_layout: ImageLayout = .undefined,
    final_layout: ImageLayout,
};

pub const AttachmentReference = extern struct {
    attachment: u32,
    layout: ImageLayout,
};

pub const SubpassDescription = extern struct {
    flags: u32 = 0,
    pipeline_bind_point: PipelineBindPoint = .graphics,
    input_attachment_count: u32 = 0,
    input_attachments: ?*const AttachmentReference = null,
    color_attachment_count: u32 = 0,
    color_attachments: ?[*]const AttachmentReference = null,
    resolve_attachments: ?*const AttachmentReference = null,
    depth_stencil_attachment: ?*const AttachmentReference = null,
    preserve_attachment_count: u32 = 0,
    preserve_attachments: ?*const u32 = null,
};

pub const RenderPassCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.render_pass_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    attachment_count: u32,
    attachments: [*]const AttachmentDescription,
    subpass_count: u32,
    subpasses: [*]const SubpassDescription,
    dependency_count: u32 = 0,
    dependencies: ?*const anyopaque = null,
};

pub const FramebufferCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.framebuffer_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    render_pass: RenderPass,
    attachment_count: u32,
    attachments: [*]const ImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

/// One clear value, as a union of the three ways to spell it. Vulkan reads the
/// member that matches the attachment's format.
pub const ClearValue = extern union {
    color_f32: [4]f32,
    color_u32: [4]u32,
    depth_stencil: extern struct { depth: f32, stencil: u32 },
};

pub const RenderPassBeginInfo = extern struct {
    s_type: vk.types.StructureType = S.render_pass_begin_info,
    next: ?*const anyopaque = null,
    render_pass: RenderPass,
    framebuffer: Framebuffer,
    render_area: Rect2D,
    clear_value_count: u32 = 0,
    clear_values: ?[*]const ClearValue = null,
};

pub const PipelineVertexInputStateCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.pipeline_vertex_input_state_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    /// Zero of each: these samples put the vertices in the shader.
    vertex_binding_description_count: u32 = 0,
    vertex_binding_descriptions: ?*const anyopaque = null,
    vertex_attribute_description_count: u32 = 0,
    vertex_attribute_descriptions: ?*const anyopaque = null,
};

pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.pipeline_input_assembly_state_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    topology: PrimitiveTopology = .triangle_list,
    primitive_restart_enable: vk.types.Bool32 = vk.types.vk_false,
};

pub const PipelineViewportStateCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.pipeline_viewport_state_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    viewport_count: u32 = 1,
    viewports: ?[*]const Viewport = null,
    scissor_count: u32 = 1,
    scissors: ?[*]const Rect2D = null,
};

pub const PipelineRasterizationStateCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.pipeline_rasterization_state_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    depth_clamp_enable: vk.types.Bool32 = vk.types.vk_false,
    rasterizer_discard_enable: vk.types.Bool32 = vk.types.vk_false,
    polygon_mode: PolygonMode = .fill,
    /// No culling, so the triangle shows whichever way it is wound.
    cull_mode: u32 = 0,
    front_face: FrontFace = .counter_clockwise,
    depth_bias_enable: vk.types.Bool32 = vk.types.vk_false,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    line_width: f32 = 1,
};

pub const PipelineMultisampleStateCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.pipeline_multisample_state_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    rasterization_samples: SampleCountFlags = .{ .x1 = true },
    sample_shading_enable: vk.types.Bool32 = vk.types.vk_false,
    min_sample_shading: f32 = 0,
    sample_mask: ?*const u32 = null,
    alpha_to_coverage_enable: vk.types.Bool32 = vk.types.vk_false,
    alpha_to_one_enable: vk.types.Bool32 = vk.types.vk_false,
};

pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: vk.types.Bool32 = vk.types.vk_false,
    src_color_blend_factor: BlendFactor = .one,
    dst_color_blend_factor: BlendFactor = .zero,
    color_blend_op: BlendOp = .add,
    src_alpha_blend_factor: BlendFactor = .one,
    dst_alpha_blend_factor: BlendFactor = .zero,
    alpha_blend_op: BlendOp = .add,
    color_write_mask: ColorComponentFlags = ColorComponentFlags.all,
};

pub const PipelineColorBlendStateCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.pipeline_color_blend_state_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    logic_op_enable: vk.types.Bool32 = vk.types.vk_false,
    logic_op: LogicOp = .copy,
    attachment_count: u32,
    attachments: [*]const PipelineColorBlendAttachmentState,
    blend_constants: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const GraphicsPipelineCreateInfo = extern struct {
    s_type: vk.types.StructureType = S.graphics_pipeline_create_info,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage_count: u32,
    stages: [*]const PipelineShaderStageCreateInfo,
    vertex_input_state: *const PipelineVertexInputStateCreateInfo,
    input_assembly_state: *const PipelineInputAssemblyStateCreateInfo,
    tessellation_state: ?*const anyopaque = null,
    viewport_state: *const PipelineViewportStateCreateInfo,
    rasterization_state: *const PipelineRasterizationStateCreateInfo,
    multisample_state: *const PipelineMultisampleStateCreateInfo,
    depth_stencil_state: ?*const anyopaque = null,
    color_blend_state: *const PipelineColorBlendStateCreateInfo,
    dynamic_state: ?*const anyopaque = null,
    layout: PipelineLayout,
    render_pass: RenderPass,
    subpass: u32 = 0,
    base_pipeline_handle: Pipeline = .none,
    base_pipeline_index: i32 = -1,
};

// -------------------------------------------------------------------------
// Synchronisation
// -------------------------------------------------------------------------
//
// Commands in one command buffer are allowed to overlap: nothing stops the
// copy at the end of `triangle.zig` from reading the image while the
// rasteriser is still writing it. A barrier is what says otherwise.

pub const PipelineStageFlags = packed struct(u32) {
    top_of_pipe: bool = false,
    draw_indirect: bool = false,
    vertex_input: bool = false,
    vertex_shader: bool = false,
    tessellation_control_shader: bool = false,
    tessellation_evaluation_shader: bool = false,
    geometry_shader: bool = false,
    fragment_shader: bool = false,
    early_fragment_tests: bool = false,
    late_fragment_tests: bool = false,
    color_attachment_output: bool = false,
    compute_shader: bool = false,
    transfer: bool = false,
    bottom_of_pipe: bool = false,
    host: bool = false,
    all_graphics: bool = false,
    all_commands: bool = false,
    _reserved: u15 = 0,
};

pub const AccessFlags = packed struct(u32) {
    indirect_command_read: bool = false,
    index_read: bool = false,
    vertex_attribute_read: bool = false,
    uniform_read: bool = false,
    input_attachment_read: bool = false,
    shader_read: bool = false,
    shader_write: bool = false,
    color_attachment_read: bool = false,
    color_attachment_write: bool = false,
    depth_stencil_attachment_read: bool = false,
    depth_stencil_attachment_write: bool = false,
    transfer_read: bool = false,
    transfer_write: bool = false,
    host_read: bool = false,
    host_write: bool = false,
    memory_read: bool = false,
    memory_write: bool = false,
    _reserved: u15 = 0,
};

/// Ownership stays where it is unless a barrier says otherwise, and this is
/// how it says so.
pub const queue_family_ignored: u32 = ~@as(u32, 0);

pub const MemoryBarrier = extern struct {
    s_type: vk.types.StructureType = @enumFromInt(46),
    next: ?*const anyopaque = null,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
};

pub const ImageMemoryBarrier = extern struct {
    s_type: vk.types.StructureType = @enumFromInt(45),
    next: ?*const anyopaque = null,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
    old_layout: ImageLayout,
    new_layout: ImageLayout,
    src_queue_family_index: u32 = queue_family_ignored,
    dst_queue_family_index: u32 = queue_family_ignored,
    image: Image,
    subresource_range: ImageSubresourceRange = .{},
};

// -------------------------------------------------------------------------
// The commands
// -------------------------------------------------------------------------

const Result = vk.Result;
const Callbacks = ?*const vk.AllocationCallbacks;

/// Everything the samples call, on top of what `vk.DeviceCommands` already
/// has. Loaded through the same device resolver, so none of it goes through
/// the loader's trampoline either.
pub const Commands = struct {
    // Memory and buffers.
    createBuffer: *const fn (Device, *const BufferCreateInfo, Callbacks, *Buffer) callconv(vk.call) Result,
    destroyBuffer: *const fn (Device, Buffer, Callbacks) callconv(vk.call) void,
    getBufferMemoryRequirements: *const fn (Device, Buffer, *MemoryRequirements) callconv(vk.call) void,
    allocateMemory: *const fn (Device, *const MemoryAllocateInfo, Callbacks, *DeviceMemory) callconv(vk.call) Result,
    freeMemory: *const fn (Device, DeviceMemory, Callbacks) callconv(vk.call) void,
    bindBufferMemory: *const fn (Device, Buffer, DeviceMemory, DeviceSize) callconv(vk.call) Result,
    mapMemory: *const fn (Device, DeviceMemory, DeviceSize, DeviceSize, u32, *?*anyopaque) callconv(vk.call) Result,
    unmapMemory: *const fn (Device, DeviceMemory) callconv(vk.call) void,

    // Images.
    createImage: *const fn (Device, *const ImageCreateInfo, Callbacks, *Image) callconv(vk.call) Result,
    destroyImage: *const fn (Device, Image, Callbacks) callconv(vk.call) void,
    getImageMemoryRequirements: *const fn (Device, Image, *MemoryRequirements) callconv(vk.call) void,
    bindImageMemory: *const fn (Device, Image, DeviceMemory, DeviceSize) callconv(vk.call) Result,
    createImageView: *const fn (Device, *const ImageViewCreateInfo, Callbacks, *ImageView) callconv(vk.call) Result,
    destroyImageView: *const fn (Device, ImageView, Callbacks) callconv(vk.call) void,

    // Shaders and pipelines.
    createShaderModule: *const fn (Device, *const ShaderModuleCreateInfo, Callbacks, *ShaderModule) callconv(vk.call) Result,
    destroyShaderModule: *const fn (Device, ShaderModule, Callbacks) callconv(vk.call) void,
    createDescriptorSetLayout: *const fn (Device, *const DescriptorSetLayoutCreateInfo, Callbacks, *DescriptorSetLayout) callconv(vk.call) Result,
    destroyDescriptorSetLayout: *const fn (Device, DescriptorSetLayout, Callbacks) callconv(vk.call) void,
    createPipelineLayout: *const fn (Device, *const PipelineLayoutCreateInfo, Callbacks, *PipelineLayout) callconv(vk.call) Result,
    destroyPipelineLayout: *const fn (Device, PipelineLayout, Callbacks) callconv(vk.call) void,
    createComputePipelines: *const fn (Device, PipelineCache, u32, [*]const ComputePipelineCreateInfo, Callbacks, [*]Pipeline) callconv(vk.call) Result,
    createGraphicsPipelines: *const fn (Device, PipelineCache, u32, [*]const GraphicsPipelineCreateInfo, Callbacks, [*]Pipeline) callconv(vk.call) Result,
    destroyPipeline: *const fn (Device, Pipeline, Callbacks) callconv(vk.call) void,

    // Descriptors.
    createDescriptorPool: *const fn (Device, *const DescriptorPoolCreateInfo, Callbacks, *DescriptorPool) callconv(vk.call) Result,
    destroyDescriptorPool: *const fn (Device, DescriptorPool, Callbacks) callconv(vk.call) void,
    allocateDescriptorSets: *const fn (Device, *const DescriptorSetAllocateInfo, [*]DescriptorSet) callconv(vk.call) Result,
    updateDescriptorSets: *const fn (Device, u32, ?[*]const WriteDescriptorSet, u32, ?*const anyopaque) callconv(vk.call) void,

    // Render passes.
    createRenderPass: *const fn (Device, *const RenderPassCreateInfo, Callbacks, *RenderPass) callconv(vk.call) Result,
    destroyRenderPass: *const fn (Device, RenderPass, Callbacks) callconv(vk.call) void,
    createFramebuffer: *const fn (Device, *const FramebufferCreateInfo, Callbacks, *Framebuffer) callconv(vk.call) Result,
    destroyFramebuffer: *const fn (Device, Framebuffer, Callbacks) callconv(vk.call) void,

    // Command buffers.
    createCommandPool: *const fn (Device, *const CommandPoolCreateInfo, Callbacks, *CommandPool) callconv(vk.call) Result,
    destroyCommandPool: *const fn (Device, CommandPool, Callbacks) callconv(vk.call) void,
    allocateCommandBuffers: *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(vk.call) Result,
    beginCommandBuffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(vk.call) Result,
    endCommandBuffer: *const fn (CommandBuffer) callconv(vk.call) Result,

    // Recording.
    cmdBindPipeline: *const fn (CommandBuffer, PipelineBindPoint, Pipeline) callconv(vk.call) void,
    cmdBindDescriptorSets: *const fn (CommandBuffer, PipelineBindPoint, PipelineLayout, u32, u32, [*]const DescriptorSet, u32, ?*const u32) callconv(vk.call) void,
    cmdDispatch: *const fn (CommandBuffer, u32, u32, u32) callconv(vk.call) void,
    cmdBeginRenderPass: *const fn (CommandBuffer, *const RenderPassBeginInfo, SubpassContents) callconv(vk.call) void,
    cmdEndRenderPass: *const fn (CommandBuffer) callconv(vk.call) void,
    cmdDraw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(vk.call) void,
    cmdCopyImageToBuffer: *const fn (CommandBuffer, Image, ImageLayout, Buffer, u32, [*]const BufferImageCopy) callconv(vk.call) void,
    cmdPipelineBarrier: *const fn (
        CommandBuffer,
        PipelineStageFlags,
        PipelineStageFlags,
        u32, // dependency flags
        u32,
        ?[*]const MemoryBarrier,
        u32,
        ?*const anyopaque, // buffer barriers, unused here
        u32,
        ?[*]const ImageMemoryBarrier,
    ) callconv(vk.call) void,

    // Submission.
    queueSubmit: *const fn (Queue, u32, [*]const SubmitInfo, Fence) callconv(vk.call) Result,
    createFence: *const fn (Device, *const FenceCreateInfo, Callbacks, *Fence) callconv(vk.call) Result,
    destroyFence: *const fn (Device, Fence, Callbacks) callconv(vk.call) void,
    waitForFences: *const fn (Device, u32, [*]const Fence, vk.types.Bool32, u64) callconv(vk.call) Result,
};

// -------------------------------------------------------------------------
// Small helpers the samples share
// -------------------------------------------------------------------------

/// The index of a memory type that satisfies `allowed` and has every property
/// in `wanted`.
///
/// `allowed` is `MemoryRequirements.memory_type_bits` - one bit per type, and
/// the driver decides which of them a given buffer or image can live in. The
/// first match is the conventional choice: Vulkan requires drivers to list the
/// more desirable types first.
pub fn memoryType(
    properties: *const vk.PhysicalDeviceMemoryProperties,
    allowed: u32,
    wanted: vk.MemoryPropertyFlags,
) ?u32 {
    for (properties.types(), 0..) |kind, index| {
        if (allowed & (@as(u32, 1) << @intCast(index)) == 0) continue;
        if (!kind.property_flags.contains(wanted)) continue;
        return @intCast(index);
    }
    return null;
}

/// Wait for a fence with no timeout, in the two-argument form the samples
/// want.
pub const forever: u64 = ~@as(u64, 0);
