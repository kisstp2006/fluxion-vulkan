// SPDX-License-Identifier: BSL-1.0

//! Internal plumbing: the generated ABI, on hardware.
//!
//! The layout oracle proves the structs are the size the headers say, and the
//! enum oracle that the numbers are. Neither proves that a driver *accepts*
//! them: that the members are in an order it reads, that the tables load, that
//! a pipeline built out of two dozen generated structs is a pipeline. This does.
//!
//! It is a small renderer, written only against `gen.types` and `gen.commands`
//! - the generated declarations, and nothing hand-written but the loader:
//!
//!   * an instance with `VK_LAYER_KHRONOS_validation` when it is installed, and
//!     a debug messenger that counts what the layer says;
//!   * a device and a queue; a host-visible buffer, written and read back;
//!   * an image, a view, a sampler, a render pass, a framebuffer, a descriptor
//!     set layout, pool and set, a pipeline layout with a push constant;
//!   * a **graphics pipeline** from two SPIR-V modules (`testdata/`, compiled
//!     from the GLSL beside them with `glslc`), a command buffer that draws a
//!     triangle into 64x64 and copies it out, a fence, a submit;
//!   * and then the pixels: the centre is the triangle's colour, the corners are
//!     the clear colour.
//!
//! **Any validation error or warning fails the test.** The layer is the
//! second opinion on every struct here, and a wrong `sType` or a missing
//! barrier is exactly what it reports.
//!
//! Everything is named as it would be in a backend, and labelled through
//! `VK_EXT_debug_utils`, so that if the layer does speak up it names the object.
//! Without a Vulkan library, a device, a graphics queue, or the layer, the test
//! says what is missing and skips - except that a missing *layer* only skips the
//! second opinion, not the drawing.

const std = @import("std");
const testing = std.testing;

const vk = @import("root.zig");
const t = vk.gen.types;
const c = vk.gen.commands;

const width = 64;
const height = 64;
const format: t.Format = .r8g8b8a8_unorm;

const clear_colour = [4]f32{ 0, 0, 1, 1 }; // blue
const triangle_colour = [4]f32{ 0, 1, 0, 1 }; // green

const vertex_spv = @embedFile("testdata/triangle.vert.spv");
const fragment_spv = @embedFile("testdata/triangle.frag.spv");

/// What the validation layer said.
const Messages = struct {
    var errors: usize = 0;
    var warnings: usize = 0;
    var info: usize = 0;
    var verbose: usize = 0;
    /// Of any severity, the ones the layer itself sent - as opposed to the
    /// loader's account of which drivers and layers it found. Today that is one
    /// line of information, the layer announcing that it is active.
    var validation: usize = 0;

    fn reset() void {
        errors = 0;
        warnings = 0;
        info = 0;
        verbose = 0;
        validation = 0;
    }

    fn callback(
        severity: t.DebugUtilsMessageSeverityFlagsEXT,
        kind: t.DebugUtilsMessageTypeFlagsEXT,
        data: *const t.DebugUtilsMessengerCallbackDataEXT,
        _: ?*anyopaque,
    ) callconv(vk.call) t.Bool32 {
        const text: [*:0]const u8 = data.message orelse "(no message)";
        if (kind.validation) validation += 1;
        if (severity.@"error") {
            errors += 1;
            std.debug.print("\n  validation ERROR: {s}\n", .{text});
        } else if (severity.warning) {
            warnings += 1;
            std.debug.print("\n  validation WARNING: {s}\n", .{text});
        } else if (severity.info) {
            info += 1;
        } else {
            verbose += 1;
        }
        return t.vk_false;
    }
};

/// `FLUXION_VERBOSE=1` makes the test say what it found: which device, which
/// layer, how many messages.
fn wantsReport() bool {
    return testing.environ.contains(testing.allocator, "FLUXION_VERBOSE") catch false;
}

fn skip(comptime fmt: []const u8, args: anytype) error{SkipZigTest} {
    std.debug.print("\n  skipped: " ++ fmt ++ "\n", args);
    return error.SkipZigTest;
}

/// The index of a memory type that `allowed` (a `MemoryRequirements` bit mask)
/// permits and that has every property in `wanted`.
fn memoryType(props: *const t.PhysicalDeviceMemoryProperties, allowed: u32, wanted: t.MemoryPropertyFlags) ?u32 {
    for (props.types(), 0..) |kind, index| {
        if (allowed & (@as(u32, 1) << @intCast(index)) == 0) continue;
        if (kind.property_flags.contains(wanted)) return @intCast(index);
    }
    return null;
}

/// SPIR-V arrives as bytes, and a `VkShaderModuleCreateInfo` wants words that
/// are aligned as such.
fn words(comptime bytes: []const u8) [bytes.len / 4]u32 {
    var out: [bytes.len / 4]u32 = undefined;
    @memcpy(std.mem.sliceAsBytes(&out), bytes);
    return out;
}

test "the generated ABI on a real driver: a triangle, drawn, read back, and validated" {
    const gpa = testing.allocator;
    Messages.reset();

    // --- the loader, and what it has ---------------------------------------
    var loader = vk.Loader.init() catch return skip("no Vulkan library on this machine", .{});
    defer loader.deinit();

    const layers = try loader.layers(gpa);
    defer gpa.free(layers);
    const have_validation = vk.enumerate.hasLayer(layers, "VK_LAYER_KHRONOS_validation");

    const instance_extensions = try loader.extensions(gpa, null);
    defer gpa.free(instance_extensions);
    const have_utils = vk.has(instance_extensions, "VK_EXT_debug_utils");

    // The generated table of what exists before there is an instance loads out
    // of the real loader, and answers the same question the hand-written one does.
    const global = try vk.load(c.Global, .{ .global = loader.getInstanceProcAddr });
    try testing.expect(global.createInstance == loader.global.createInstance);

    // --- an instance, with the layer and a messenger if they are here ------
    const layer_names = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    const extension_names = [_][*:0]const u8{"VK_EXT_debug_utils"};

    const messenger_info: t.DebugUtilsMessengerCreateInfoEXT = .{
        .message_severity = .{ .verbose = true, .info = true, .warning = true, .@"error" = true },
        .message_type = .{ .general = true, .validation = true, .performance = true },
        .user_callback = &Messages.callback,
    };

    // Vulkan 1.0 is the baseline, so that is what is asked for: everything
    // below runs on it, and the layer checks it against the 1.0 rules.
    const app: t.ApplicationInfo = .{ .application_name = "fluxion-vulkan", .api_version = vk.v1_0.toInt() };
    var instance_info: t.InstanceCreateInfo = .{ .application_info = &app };
    if (have_validation) instance_info.setLayers(&layer_names);
    if (have_utils) {
        instance_info.setExtensions(&extension_names);
        // Chained, so that the messenger is there while the instance is made.
        instance_info.next = &messenger_info;
    }

    const instance = loader.createInstance(&instance_info, null) catch |err|
        return skip("no instance could be created ({s})", .{@errorName(err)});
    const inst = try vk.load(c.Instance, loader.instanceResolver(instance));
    defer inst.destroyInstance(instance, null);

    var messenger: t.DebugUtilsMessengerEXT = .none;
    if (have_utils) {
        _ = try inst.createDebugUtilsMessengerEXT.?(instance, &messenger_info, null, &messenger).check();
    }
    defer if (messenger != .none) inst.destroyDebugUtilsMessengerEXT.?(instance, messenger, null);

    // --- a device ----------------------------------------------------------
    const gpus = try vk.enumerate.physicalDevices(gpa, inst, instance);
    defer gpa.free(gpus);
    if (gpus.len == 0) return skip("a Vulkan loader, but no device behind it", .{});

    var chosen = gpus[0];
    for (gpus) |candidate| {
        var candidate_props: t.PhysicalDeviceProperties = undefined;
        inst.getPhysicalDeviceProperties(candidate, &candidate_props);
        if (candidate_props.device_type == .discrete_gpu) {
            chosen = candidate;
            break;
        }
    }
    var props: t.PhysicalDeviceProperties = undefined;
    inst.getPhysicalDeviceProperties(chosen, &props);
    var memory: t.PhysicalDeviceMemoryProperties = undefined;
    inst.getPhysicalDeviceMemoryProperties(chosen, &memory);

    const families = try vk.enumerate.queueFamilies(gpa, inst, chosen);
    defer gpa.free(families);
    const family = vk.queueFamily(families, .{ .graphics = true }) orelse
        return skip("{s} has no graphics queue", .{props.name()});

    const priorities = [_]f32{1.0};
    const queue_infos = [_]t.DeviceQueueCreateInfo{.queues(family, &priorities)};
    var device_info: t.DeviceCreateInfo = .{};
    device_info.setQueues(&queue_infos);

    var device: t.Device = undefined;
    _ = try inst.createDevice(chosen, &device_info, null, &device).check();
    const dev = try vk.load(c.Device, vk.deviceResolver(inst, device));
    defer dev.destroyDevice(device, null);

    var queue: t.Queue = undefined;
    dev.getDeviceQueue(device, family, 0, &queue);

    // Every object gets a name, so that the layer can say which one it means.
    const Namer = struct {
        dev: c.Device,
        device: t.Device,
        fn name(self: @This(), object_type: t.ObjectType, handle: u64, label: [*:0]const u8) void {
            const set = self.dev.setDebugUtilsObjectNameEXT orelse return;
            const object_name: t.DebugUtilsObjectNameInfoEXT = .{ .object_type = object_type, .object_handle = handle, .object_name = label };
            _ = set(self.device, &object_name);
        }
    };
    const namer: Namer = .{ .dev = dev, .device = device };

    // --- a host-visible buffer: write, read back ----------------------------
    var scratch: t.Buffer = .none;
    const scratch_info: t.BufferCreateInfo = .{
        .size = 256,
        .usage = .{ .transfer_src = true, .transfer_dst = true },
        .sharing_mode = .exclusive,
    };
    _ = try dev.createBuffer(device, &scratch_info, null, &scratch).check();
    defer dev.destroyBuffer(device, scratch, null);
    namer.name(.buffer, @intFromEnum(scratch), "scratch buffer");

    var scratch_requirements: t.MemoryRequirements = undefined;
    dev.getBufferMemoryRequirements(device, scratch, &scratch_requirements);
    const host_type = memoryType(&memory, scratch_requirements.memory_type_bits, .{ .host_visible = true, .host_coherent = true }) orelse
        return skip("{s} has no host-visible coherent memory", .{props.name()});

    var scratch_memory: t.DeviceMemory = .none;
    const scratch_allocate: t.MemoryAllocateInfo = .{ .allocation_size = scratch_requirements.size, .memory_type_index = host_type };
    _ = try dev.allocateMemory(device, &scratch_allocate, null, &scratch_memory).check();
    defer dev.freeMemory(device, scratch_memory, null);
    _ = try dev.bindBufferMemory(device, scratch, scratch_memory, 0).check();

    {
        var mapped: ?*anyopaque = null;
        _ = try dev.mapMemory(device, scratch_memory, 0, t.whole_size, .{}, &mapped).check();
        const bytes: [*]u8 = @ptrCast(mapped.?);
        for (0..256) |i| bytes[i] = @truncate(i *% 7 +% 3);

        // Coherent memory needs neither call, and the calls are still legal:
        // this is what a backend does for memory that may not be.
        const range: t.MappedMemoryRange = .{ .memory = scratch_memory, .offset = 0, .size = t.whole_size };
        _ = try dev.flushMappedMemoryRanges(device, 1, @ptrCast(&range)).check();
        _ = try dev.invalidateMappedMemoryRanges(device, 1, @ptrCast(&range)).check();
        for (0..256) |i| try testing.expectEqual(@as(u8, @truncate(i *% 7 +% 3)), bytes[i]);
        dev.unmapMemory(device, scratch_memory);
    }

    // --- the colour, in a uniform buffer ----------------------------------
    var uniform: t.Buffer = .none;
    const uniform_info: t.BufferCreateInfo = .{ .size = 16, .usage = .{ .uniform_buffer = true }, .sharing_mode = .exclusive };
    _ = try dev.createBuffer(device, &uniform_info, null, &uniform).check();
    defer dev.destroyBuffer(device, uniform, null);
    namer.name(.buffer, @intFromEnum(uniform), "triangle colour");

    var uniform_requirements: t.MemoryRequirements = undefined;
    dev.getBufferMemoryRequirements(device, uniform, &uniform_requirements);
    var uniform_memory: t.DeviceMemory = .none;
    const uniform_allocate: t.MemoryAllocateInfo = .{
        .allocation_size = uniform_requirements.size,
        .memory_type_index = memoryType(&memory, uniform_requirements.memory_type_bits, .{ .host_visible = true, .host_coherent = true }).?,
    };
    _ = try dev.allocateMemory(device, &uniform_allocate, null, &uniform_memory).check();
    defer dev.freeMemory(device, uniform_memory, null);
    _ = try dev.bindBufferMemory(device, uniform, uniform_memory, 0).check();
    {
        var mapped: ?*anyopaque = null;
        _ = try dev.mapMemory(device, uniform_memory, 0, 16, .{}, &mapped).check();
        @memcpy(@as([*]u8, @ptrCast(mapped.?))[0..16], std.mem.sliceAsBytes(&triangle_colour));
        dev.unmapMemory(device, uniform_memory);
    }

    // --- the image drawn into, its view, and a sampler ---------------------
    var image: t.Image = .none;
    const image_info: t.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .x1 = true },
        .tiling = .optimal,
        .usage = .{ .color_attachment = true, .transfer_src = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    _ = try dev.createImage(device, &image_info, null, &image).check();
    defer dev.destroyImage(device, image, null);
    namer.name(.image, @intFromEnum(image), "render target");

    var image_requirements: t.MemoryRequirements = undefined;
    dev.getImageMemoryRequirements(device, image, &image_requirements);
    var image_memory: t.DeviceMemory = .none;
    const image_allocate: t.MemoryAllocateInfo = .{
        .allocation_size = image_requirements.size,
        .memory_type_index = memoryType(&memory, image_requirements.memory_type_bits, .{ .device_local = true }) orelse
            memoryType(&memory, image_requirements.memory_type_bits, .{}).?,
    };
    _ = try dev.allocateMemory(device, &image_allocate, null, &image_memory).check();
    defer dev.freeMemory(device, image_memory, null);
    _ = try dev.bindImageMemory(device, image, image_memory, 0).check();

    const colour_range: t.ImageSubresourceRange = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };
    var view: t.ImageView = .none;
    const view_info: t.ImageViewCreateInfo = .{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = colour_range,
    };
    _ = try dev.createImageView(device, &view_info, null, &view).check();
    defer dev.destroyImageView(device, view, null);

    var sampler: t.Sampler = .none;
    const sampler_info: t.SamplerCreateInfo = .{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = t.vk_false,
        .max_anisotropy = 1,
        .compare_enable = t.vk_false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = t.lod_clamp_none,
        .border_color = .float_opaque_black,
        .unnormalized_coordinates = t.vk_false,
    };
    _ = try dev.createSampler(device, &sampler_info, null, &sampler).check();
    defer dev.destroySampler(device, sampler, null);

    // --- a render pass and a framebuffer -----------------------------------
    const attachment: t.AttachmentDescription = .{
        .format = format,
        .samples = .{ .x1 = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .color_attachment_optimal,
    };
    const colour_reference: t.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass: t.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .color_attachments = @ptrCast(&colour_reference),
    };
    const pass_info: t.RenderPassCreateInfo = .{
        .attachment_count = 1,
        .attachments = @ptrCast(&attachment),
        .subpass_count = 1,
        .subpasses = @ptrCast(&subpass),
    };
    var render_pass: t.RenderPass = .none;
    _ = try dev.createRenderPass(device, &pass_info, null, &render_pass).check();
    defer dev.destroyRenderPass(device, render_pass, null);

    var framebuffer: t.Framebuffer = .none;
    const framebuffer_info: t.FramebufferCreateInfo = .{
        .render_pass = render_pass,
        .attachment_count = 1,
        .attachments = @ptrCast(&view),
        .width = width,
        .height = height,
        .layers = 1,
    };
    _ = try dev.createFramebuffer(device, &framebuffer_info, null, &framebuffer).check();
    defer dev.destroyFramebuffer(device, framebuffer, null);

    // --- descriptors and the pipeline layout -------------------------------
    var set_layout: t.DescriptorSetLayout = .none;
    const binding: t.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment = true },
    };
    const set_layout_info: t.DescriptorSetLayoutCreateInfo = .{ .binding_count = 1, .bindings = @ptrCast(&binding) };
    _ = try dev.createDescriptorSetLayout(device, &set_layout_info, null, &set_layout).check();
    defer dev.destroyDescriptorSetLayout(device, set_layout, null);

    var pool: t.DescriptorPool = .none;
    const pool_size: t.DescriptorPoolSize = .{ .type = .uniform_buffer, .descriptor_count = 1 };
    const pool_info: t.DescriptorPoolCreateInfo = .{ .max_sets = 1, .pool_size_count = 1, .pool_sizes = @ptrCast(&pool_size) };
    _ = try dev.createDescriptorPool(device, &pool_info, null, &pool).check();
    defer dev.destroyDescriptorPool(device, pool, null);

    var descriptor_set: t.DescriptorSet = .none;
    const allocate_set: t.DescriptorSetAllocateInfo = .{ .descriptor_pool = pool, .descriptor_set_count = 1, .set_layouts = @ptrCast(&set_layout) };
    _ = try dev.allocateDescriptorSets(device, &allocate_set, @ptrCast(&descriptor_set)).check();

    const buffer_info: t.DescriptorBufferInfo = .{ .buffer = uniform, .offset = 0, .range = 16 };
    const write: t.WriteDescriptorSet = .{
        .dst_set = descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .uniform_buffer,
        .buffer_info = @ptrCast(&buffer_info),
    };
    dev.updateDescriptorSets(device, 1, @ptrCast(&write), 0, null);

    var pipeline_layout: t.PipelineLayout = .none;
    const push_range: t.PushConstantRange = .{ .stage_flags = .{ .vertex = true }, .offset = 0, .size = @sizeOf(f32) };
    const layout_info: t.PipelineLayoutCreateInfo = .{
        .set_layout_count = 1,
        .set_layouts = @ptrCast(&set_layout),
        .push_constant_range_count = 1,
        .push_constant_ranges = @ptrCast(&push_range),
    };
    _ = try dev.createPipelineLayout(device, &layout_info, null, &pipeline_layout).check();
    defer dev.destroyPipelineLayout(device, pipeline_layout, null);

    // --- shaders and the graphics pipeline ---------------------------------
    const vertex_words = comptime words(vertex_spv);
    const fragment_words = comptime words(fragment_spv);
    var vertex_module: t.ShaderModule = .none;
    var fragment_module: t.ShaderModule = .none;
    _ = try dev.createShaderModule(device, &.{ .code_size = vertex_spv.len, .code = &vertex_words }, null, &vertex_module).check();
    defer dev.destroyShaderModule(device, vertex_module, null);
    _ = try dev.createShaderModule(device, &.{ .code_size = fragment_spv.len, .code = &fragment_words }, null, &fragment_module).check();
    defer dev.destroyShaderModule(device, fragment_module, null);

    const stages = [_]t.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = vertex_module, .name = "main" },
        .{ .stage = .{ .fragment = true }, .module = fragment_module, .name = "main" },
    };
    const vertex_input: t.PipelineVertexInputStateCreateInfo = .{};
    const input_assembly: t.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_list, .primitive_restart_enable = t.vk_false };
    const viewport: t.Viewport = .{ .x = 0, .y = 0, .width = width, .height = height, .min_depth = 0, .max_depth = 1 };
    const scissor: t.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
    const viewport_state: t.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .viewports = @ptrCast(&viewport),
        .scissor_count = 1,
        .scissors = @ptrCast(&scissor),
    };
    const rasterization: t.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = t.vk_false,
        .rasterizer_discard_enable = t.vk_false,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .counter_clockwise,
        .depth_bias_enable = t.vk_false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const multisample: t.PipelineMultisampleStateCreateInfo = .{
        .rasterization_samples = .{ .x1 = true },
        .sample_shading_enable = t.vk_false,
        .min_sample_shading = 0,
        .alpha_to_coverage_enable = t.vk_false,
        .alpha_to_one_enable = t.vk_false,
    };
    const blend_attachment: t.PipelineColorBlendAttachmentState = .{
        .blend_enable = t.vk_false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
    };
    const blend: t.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = t.vk_false,
        .logic_op = .copy,
        .attachment_count = 1,
        .attachments = @ptrCast(&blend_attachment),
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const pipeline_info: t.GraphicsPipelineCreateInfo = .{
        .stage_count = stages.len,
        .stages = &stages,
        .vertex_input_state = &vertex_input,
        .input_assembly_state = &input_assembly,
        .viewport_state = &viewport_state,
        .rasterization_state = &rasterization,
        .multisample_state = &multisample,
        .color_blend_state = &blend,
        .layout = pipeline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    var pipeline: t.Pipeline = .none;
    _ = try dev.createGraphicsPipelines(device, .none, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline)).check();
    defer dev.destroyPipeline(device, pipeline, null);
    namer.name(.pipeline, @intFromEnum(pipeline), "triangle pipeline");

    // --- the buffer the picture is copied into -----------------------------
    const readback_size: t.DeviceSize = width * height * 4;
    var readback: t.Buffer = .none;
    const readback_info: t.BufferCreateInfo = .{ .size = readback_size, .usage = .{ .transfer_dst = true }, .sharing_mode = .exclusive };
    _ = try dev.createBuffer(device, &readback_info, null, &readback).check();
    defer dev.destroyBuffer(device, readback, null);
    var readback_requirements: t.MemoryRequirements = undefined;
    dev.getBufferMemoryRequirements(device, readback, &readback_requirements);
    var readback_memory: t.DeviceMemory = .none;
    const readback_allocate: t.MemoryAllocateInfo = .{
        .allocation_size = readback_requirements.size,
        .memory_type_index = memoryType(&memory, readback_requirements.memory_type_bits, .{ .host_visible = true, .host_coherent = true }).?,
    };
    _ = try dev.allocateMemory(device, &readback_allocate, null, &readback_memory).check();
    defer dev.freeMemory(device, readback_memory, null);
    _ = try dev.bindBufferMemory(device, readback, readback_memory, 0).check();

    // --- record ------------------------------------------------------------
    var command_pool: t.CommandPool = .none;
    const command_pool_info: t.CommandPoolCreateInfo = .{ .flags = .{ .transient = true }, .queue_family_index = family };
    _ = try dev.createCommandPool(device, &command_pool_info, null, &command_pool).check();
    defer dev.destroyCommandPool(device, command_pool, null);

    var cmd: t.CommandBuffer = undefined;
    const cmd_allocate: t.CommandBufferAllocateInfo = .{ .command_pool = command_pool, .level = .primary, .command_buffer_count = 1 };
    _ = try dev.allocateCommandBuffers(device, &cmd_allocate, @ptrCast(&cmd)).check();

    const begin: t.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit = true } };
    _ = try dev.beginCommandBuffer(cmd, &begin).check();

    const label: t.DebugUtilsLabelEXT = .{ .label_name = "draw the triangle", .color = .{ 0, 1, 0, 1 } };
    if (dev.cmdBeginDebugUtilsLabelEXT) |begin_label| begin_label(cmd, &label);

    const clear: t.ClearValue = .{ .color = .{ .float32 = clear_colour } };
    const pass_begin: t.RenderPassBeginInfo = .{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = scissor,
        .clear_value_count = 1,
        .clear_values = @ptrCast(&clear),
    };
    dev.cmdBeginRenderPass(cmd, &pass_begin, .@"inline");
    dev.cmdBindPipeline(cmd, .graphics, pipeline);
    dev.cmdBindDescriptorSets(cmd, .graphics, pipeline_layout, 0, 1, @ptrCast(&descriptor_set), 0, null);
    const scale: f32 = 1.0;
    dev.cmdPushConstants(cmd, pipeline_layout, .{ .vertex = true }, 0, @sizeOf(f32), &scale);
    dev.cmdDraw(cmd, 3, 1, 0, 0);
    dev.cmdEndRenderPass(cmd);

    // The render pass left the image where the rasteriser writes it. What
    // copies it out has to wait for those writes, and needs it laid out for
    // reading.
    const to_transfer: t.ImageMemoryBarrier = .{
        .src_access_mask = .{ .color_attachment_write = true },
        .dst_access_mask = .{ .transfer_read = true },
        .old_layout = .color_attachment_optimal,
        .new_layout = .transfer_src_optimal,
        .src_queue_family_index = t.queue_family_ignored,
        .dst_queue_family_index = t.queue_family_ignored,
        .image = image,
        .subresource_range = colour_range,
    };
    dev.cmdPipelineBarrier(cmd, .{ .color_attachment_output = true }, .{ .transfer = true }, .{}, 0, null, 0, null, 1, @ptrCast(&to_transfer));

    const copy: t.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    dev.cmdCopyImageToBuffer(cmd, image, .transfer_src_optimal, readback, 1, @ptrCast(&copy));

    // And the host reads what the copy wrote.
    const to_host: t.BufferMemoryBarrier = .{
        .src_access_mask = .{ .transfer_write = true },
        .dst_access_mask = .{ .host_read = true },
        .src_queue_family_index = t.queue_family_ignored,
        .dst_queue_family_index = t.queue_family_ignored,
        .buffer = readback,
        .offset = 0,
        .size = t.whole_size,
    };
    dev.cmdPipelineBarrier(cmd, .{ .transfer = true }, .{ .host = true }, .{}, 0, null, 1, @ptrCast(&to_host), 0, null);

    if (dev.cmdEndDebugUtilsLabelEXT) |end_label| end_label(cmd);
    _ = try dev.endCommandBuffer(cmd).check();

    // --- submit, and wait ---------------------------------------------------
    var fence: t.Fence = .none;
    _ = try dev.createFence(device, &.{}, null, &fence).check();
    defer dev.destroyFence(device, fence, null);

    const submit: t.SubmitInfo = .{ .command_buffer_count = 1, .command_buffers = @ptrCast(&cmd) };
    _ = try dev.queueSubmit(queue, 1, @ptrCast(&submit), fence).check();
    const waited = try dev.waitForFences(device, 1, @ptrCast(&fence), t.vk_true, 10_000_000_000).check();
    try testing.expectEqual(t.Result.success, waited);
    _ = try dev.queueWaitIdle(queue).check();

    // --- the pixels ---------------------------------------------------------
    var pixels: [*]const [4]u8 = undefined;
    {
        var mapped: ?*anyopaque = null;
        _ = try dev.mapMemory(device, readback_memory, 0, readback_size, .{}, &mapped).check();
        pixels = @ptrCast(@alignCast(mapped.?));
    }
    defer dev.unmapMemory(device, readback_memory);

    const green = [4]u8{ 0, 255, 0, 255 };
    const blue = [4]u8{ 0, 0, 255, 255 };
    try testing.expectEqual(green, pixels[(height / 2) * width + width / 2]); // the centre is the triangle
    try testing.expectEqual(blue, pixels[0]); // the corners are not
    try testing.expectEqual(blue, pixels[width - 1]);
    try testing.expectEqual(blue, pixels[(height - 1) * width]);
    try testing.expectEqual(blue, pixels[height * width - 1]);

    // A dozen more, so that "the centre is green" is not one lucky pixel: every
    // pixel is one of the two colours, and a good part of them are the triangle.
    var lit: usize = 0;
    for (0..width * height) |i| {
        const pixel = pixels[i];
        try testing.expect(std.mem.eql(u8, &pixel, &green) or std.mem.eql(u8, &pixel, &blue));
        if (std.mem.eql(u8, &pixel, &green)) lit += 1;
    }
    try testing.expect(lit > width * height / 4);
    try testing.expect(lit < width * height / 2);

    // --- what the layer thought ---------------------------------------------
    _ = try dev.deviceWaitIdle(device).check();
    if (have_validation and have_utils) {
        try testing.expectEqual(@as(usize, 0), Messages.errors);
        try testing.expectEqual(@as(usize, 0), Messages.warnings);
    }

    if (wantsReport()) {
        std.debug.print(
            "\n  real driver: {s} ({s}), Vulkan {f}, validation layer {s}: {d} errors, {d} warnings ({d} messages from the layer, {d} more info and {d} verbose from the loader); triangle {d} of {d} pixels\n",
            .{
                props.name(),
                props.device_type.label(),
                vk.ApiVersion.fromInt(props.api_version),
                if (have_validation and have_utils) "on" else "NOT INSTALLED",
                Messages.errors,
                Messages.warnings,
                Messages.validation,
                Messages.info - @min(Messages.info, Messages.validation),
                Messages.verbose,
                lit,
                width * height,
            },
        );
    }
}
