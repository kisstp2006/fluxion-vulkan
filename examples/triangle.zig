// SPDX-License-Identifier: BSL-1.0

//! Hello triangle. Run it with `zig build example-triangle`.
//!
//! The sample every graphics API opens with: three vertices, one for each
//! primary colour, interpolated across the face. The whole graphics pipeline
//! is here - render pass, framebuffer, vertex and fragment shaders, viewport,
//! rasteriser, blending - and the only thing missing is the window.
//!
//! **It renders to an image rather than a screen**, which is what makes it a
//! sample that can be checked rather than looked at. There is no surface, no
//! swapchain, no windowing library and no platform code: it draws into a
//! `VkImage`, copies that to a buffer the CPU can read, and then *verifies the
//! pixels* - the corners must be the clear colour, the centre must be lit, and
//! the three corners of the triangle must be reddish, greenish and blueish in
//! the right places. It exits non-zero if any of that is wrong.
//!
//! It also writes `triangle.ppm` beside itself, which any image viewer opens.
//!
//! The shaders, assembled into SPIR-V at compile time by `spirv.zig`:
//!
//! ```glsl
//! // vertex
//! #version 450
//! layout(location = 0) out vec3 tint;
//! vec2 corners[3] = vec2[](vec2(0.0, -0.7), vec2(0.7, 0.7), vec2(-0.7, 0.7));
//! vec3 tints[3]   = vec3[](vec3(1,0,0), vec3(0,1,0), vec3(0,0,1));
//! void main() {
//!     gl_Position = vec4(corners[gl_VertexIndex], 0.0, 1.0);
//!     tint = tints[gl_VertexIndex];
//! }
//!
//! // fragment
//! #version 450
//! layout(location = 0) in vec3 tint;
//! layout(location = 0) out vec4 target;
//! void main() { target = vec4(tint, 1.0); }
//! ```

const std = @import("std");
const Io = std.Io;
const vk = @import("fluxion_vulkan");
const gpu = @import("beyond.zig");
const spirv = @import("spirv.zig");

const width = 256;
const height = 256;
const format: gpu.Format = .r8g8b8a8_unorm;

/// What the render pass clears to before anything is drawn: a dark blue, so
/// that "cleared" and "drawn" are never in doubt.
const clear_colour = [4]f32{ 0.04, 0.05, 0.12, 1.0 };

const Pixel = extern struct { r: u8, g: u8, b: u8, a: u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // --- a device that can draw ------------------------------------------
    var loader = vk.Loader.init() catch |err| switch (err) {
        error.NotFound, error.NotSupported => {
            try out.writeAll("No Vulkan on this machine, so nothing to draw with.\n");
            return;
        },
        else => return err,
    };
    defer loader.deinit();

    const info: vk.InstanceCreateInfo = .{};
    const instance = try loader.createInstance(&info, null);
    const inst = try loader.instanceCommands(instance);
    defer inst.destroyInstance(instance, null);

    const gpus = try vk.enumerate.physicalDevices(gpa, inst, instance);
    if (gpus.len == 0) {
        try out.writeAll("A Vulkan loader, but no devices behind it.\n");
        return;
    }

    var chosen = gpus[0];
    for (gpus) |candidate| {
        var props: vk.PhysicalDeviceProperties = undefined;
        inst.getPhysicalDeviceProperties(candidate, &props);
        if (props.device_type == .discrete_gpu) {
            chosen = candidate;
            break;
        }
    }

    var props: vk.PhysicalDeviceProperties = undefined;
    inst.getPhysicalDeviceProperties(chosen, &props);

    var memory_props: vk.PhysicalDeviceMemoryProperties = undefined;
    inst.getPhysicalDeviceMemoryProperties(chosen, &memory_props);

    const families = try vk.enumerate.queueFamilies(gpa, inst, chosen);
    const family = vk.queueFamily(families, .{ .graphics = true }) orelse {
        try out.print("{s} has no graphics queue.\n", .{props.name()});
        return;
    };

    const priorities = [_]f32{1.0};
    const queue_infos = [_]vk.DeviceQueueCreateInfo{.queues(family, &priorities)};
    var device_info: vk.DeviceCreateInfo = .{};
    device_info.setQueues(&queue_infos);

    var device: vk.Device = undefined;
    _ = try inst.createDevice(chosen, &device_info, null, &device).check();

    const core = try inst.deviceCommands(device);
    defer core.destroyDevice(device, null);

    const dev = try vk.load(gpu.Commands, inst.deviceResolver(device));

    var queue: vk.Queue = undefined;
    core.getDeviceQueue(device, family, 0, &queue);

    try out.print("{s}, graphics queue family {d}\n", .{ props.name(), family });

    // --- the image drawn into --------------------------------------------
    var image: gpu.Image = .none;
    const image_info: gpu.ImageCreateInfo = .{
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .usage = .{ .color_attachment = true, .transfer_src = true },
    };
    _ = try dev.createImage(device, &image_info, null, &image).check();
    defer dev.destroyImage(device, image, null);

    var image_requirements: gpu.MemoryRequirements = undefined;
    dev.getImageMemoryRequirements(device, image, &image_requirements);

    // Device-local: the rasteriser writes it, and only the copy reads it.
    const image_type = gpu.memoryType(&memory_props, image_requirements.memory_type_bits, .{
        .device_local = true,
    }) orelse gpu.memoryType(&memory_props, image_requirements.memory_type_bits, .{}).?;

    var image_memory: gpu.DeviceMemory = .none;
    _ = try dev.allocateMemory(device, &.{
        .allocation_size = image_requirements.size,
        .memory_type_index = image_type,
    }, null, &image_memory).check();
    defer dev.freeMemory(device, image_memory, null);
    _ = try dev.bindImageMemory(device, image, image_memory, 0).check();

    var view: gpu.ImageView = .none;
    _ = try dev.createImageView(device, &.{
        .image = image,
        .format = format,
    }, null, &view).check();
    defer dev.destroyImageView(device, view, null);

    // --- the buffer read back --------------------------------------------
    const pixel_bytes: gpu.DeviceSize = width * height * @sizeOf(Pixel);

    var readback: gpu.Buffer = .none;
    _ = try dev.createBuffer(device, &.{
        .size = pixel_bytes,
        .usage = .{ .transfer_dst = true },
    }, null, &readback).check();
    defer dev.destroyBuffer(device, readback, null);

    var buffer_requirements: gpu.MemoryRequirements = undefined;
    dev.getBufferMemoryRequirements(device, readback, &buffer_requirements);

    const buffer_type = gpu.memoryType(&memory_props, buffer_requirements.memory_type_bits, .{
        .host_visible = true,
        .host_coherent = true,
    }) orelse {
        try out.writeAll("No memory the CPU can read this back through.\n");
        return;
    };

    var buffer_memory: gpu.DeviceMemory = .none;
    _ = try dev.allocateMemory(device, &.{
        .allocation_size = buffer_requirements.size,
        .memory_type_index = buffer_type,
    }, null, &buffer_memory).check();
    defer dev.freeMemory(device, buffer_memory, null);
    _ = try dev.bindBufferMemory(device, readback, buffer_memory, 0).check();

    // --- the render pass -------------------------------------------------
    // One attachment, cleared on the way in and kept on the way out, ending in
    // the layout the copy wants - so no separate transition is needed for it.
    const attachments = [_]gpu.AttachmentDescription{.{
        .format = format,
        .load_op = .clear,
        .store_op = .store,
        .final_layout = .transfer_src_optimal,
    }};
    const colour_refs = [_]gpu.AttachmentReference{.{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    }};
    const subpasses = [_]gpu.SubpassDescription{.{
        .color_attachment_count = colour_refs.len,
        .color_attachments = &colour_refs,
    }};

    var render_pass: gpu.RenderPass = .none;
    _ = try dev.createRenderPass(device, &.{
        .attachment_count = attachments.len,
        .attachments = &attachments,
        .subpass_count = subpasses.len,
        .subpasses = &subpasses,
    }, null, &render_pass).check();
    defer dev.destroyRenderPass(device, render_pass, null);

    const views = [_]gpu.ImageView{view};
    var framebuffer: gpu.Framebuffer = .none;
    _ = try dev.createFramebuffer(device, &.{
        .render_pass = render_pass,
        .attachment_count = views.len,
        .attachments = &views,
        .width = width,
        .height = height,
    }, null, &framebuffer).check();
    defer dev.destroyFramebuffer(device, framebuffer, null);

    // --- the shaders -----------------------------------------------------
    const vertex_code = comptime vertexShader();
    const fragment_code = comptime fragmentShader();

    var vertex_module: gpu.ShaderModule = .none;
    _ = try dev.createShaderModule(device, &.{
        .code_size = vertex_code.len * @sizeOf(u32),
        .code = vertex_code.ptr,
    }, null, &vertex_module).check();
    defer dev.destroyShaderModule(device, vertex_module, null);

    var fragment_module: gpu.ShaderModule = .none;
    _ = try dev.createShaderModule(device, &.{
        .code_size = fragment_code.len * @sizeOf(u32),
        .code = fragment_code.ptr,
    }, null, &fragment_module).check();
    defer dev.destroyShaderModule(device, fragment_module, null);

    try out.print("shaders   {d} + {d} words of SPIR-V, assembled at compile time\n", .{
        vertex_code.len,
        fragment_code.len,
    });

    // --- the pipeline ----------------------------------------------------
    // Nothing is bound to it: the vertices are in the vertex shader, so the
    // layout is empty and the vertex input state is empty too.
    var pipeline_layout: gpu.PipelineLayout = .none;
    _ = try dev.createPipelineLayout(device, &.{}, null, &pipeline_layout).check();
    defer dev.destroyPipelineLayout(device, pipeline_layout, null);

    const stages = [_]gpu.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = vertex_module, .name = "main" },
        .{ .stage = .{ .fragment = true }, .module = fragment_module, .name = "main" },
    };

    const vertex_input: gpu.PipelineVertexInputStateCreateInfo = .{};
    const input_assembly: gpu.PipelineInputAssemblyStateCreateInfo = .{};

    const viewports = [_]gpu.Viewport{.{ .width = width, .height = height }};
    const scissors = [_]gpu.Rect2D{.{ .extent = .{ .width = width, .height = height } }};
    const viewport_state: gpu.PipelineViewportStateCreateInfo = .{
        .viewports = &viewports,
        .scissors = &scissors,
    };

    const rasterization: gpu.PipelineRasterizationStateCreateInfo = .{};
    const multisample: gpu.PipelineMultisampleStateCreateInfo = .{};

    const blend_attachments = [_]gpu.PipelineColorBlendAttachmentState{.{}};
    const blend: gpu.PipelineColorBlendStateCreateInfo = .{
        .attachment_count = blend_attachments.len,
        .attachments = &blend_attachments,
    };

    const pipeline_infos = [_]gpu.GraphicsPipelineCreateInfo{.{
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
    }};

    var pipeline: gpu.Pipeline = .none;
    _ = try dev.createGraphicsPipelines(
        device,
        .none,
        pipeline_infos.len,
        &pipeline_infos,
        null,
        @ptrCast(&pipeline),
    ).check();
    defer dev.destroyPipeline(device, pipeline, null);

    // --- drawing ---------------------------------------------------------
    var command_pool: gpu.CommandPool = .none;
    _ = try dev.createCommandPool(device, &.{ .queue_family_index = family }, null, &command_pool).check();
    defer dev.destroyCommandPool(device, command_pool, null);

    var cmd: gpu.CommandBuffer = undefined;
    _ = try dev.allocateCommandBuffers(device, &.{
        .command_pool = command_pool,
        .command_buffer_count = 1,
    }, @ptrCast(&cmd)).check();

    _ = try dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } }).check();

    const clears = [_]gpu.ClearValue{.{ .color_f32 = clear_colour }};
    dev.cmdBeginRenderPass(cmd, &.{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = .{ .extent = .{ .width = width, .height = height } },
        .clear_value_count = clears.len,
        .clear_values = &clears,
    }, .@"inline");

    dev.cmdBindPipeline(cmd, .graphics, pipeline);
    // Three vertices, one instance, and no buffers: `gl_VertexIndex` is all
    // the vertex shader needs.
    dev.cmdDraw(cmd, 3, 1, 0, 0);

    dev.cmdEndRenderPass(cmd);

    // The render pass moved the image to `transfer_src_optimal`, but nothing
    // yet says the writes have landed before the copy reads them. Commands in
    // one buffer may overlap; this is what stops them.
    const before_copy = [_]gpu.ImageMemoryBarrier{.{
        .src_access_mask = .{ .color_attachment_write = true },
        .dst_access_mask = .{ .transfer_read = true },
        .old_layout = .transfer_src_optimal,
        .new_layout = .transfer_src_optimal,
        .image = image,
    }};
    dev.cmdPipelineBarrier(
        cmd,
        .{ .color_attachment_output = true },
        .{ .transfer = true },
        0,
        0,
        null,
        0,
        null,
        before_copy.len,
        &before_copy,
    );

    const regions = [_]gpu.BufferImageCopy{.{
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    }};
    dev.cmdCopyImageToBuffer(cmd, image, .transfer_src_optimal, readback, regions.len, &regions);

    // And the same again for the host: mapped memory is not guaranteed to
    // show the copy without a barrier that names `host_read`.
    const before_read = [_]gpu.MemoryBarrier{.{
        .src_access_mask = .{ .transfer_write = true },
        .dst_access_mask = .{ .host_read = true },
    }};
    dev.cmdPipelineBarrier(
        cmd,
        .{ .transfer = true },
        .{ .host = true },
        0,
        before_read.len,
        &before_read,
        0,
        null,
        0,
        null,
    );

    _ = try dev.endCommandBuffer(cmd).check();

    var fence: gpu.Fence = .none;
    _ = try dev.createFence(device, &.{}, null, &fence).check();
    defer dev.destroyFence(device, fence, null);

    const command_buffers = [_]gpu.CommandBuffer{cmd};
    const submits = [_]gpu.SubmitInfo{.{
        .command_buffer_count = command_buffers.len,
        .command_buffers = &command_buffers,
    }};
    _ = try dev.queueSubmit(queue, submits.len, &submits, fence).check();

    const fences = [_]gpu.Fence{fence};
    _ = try dev.waitForFences(device, fences.len, &fences, vk.types.vk_true, gpu.forever).check();

    try out.print("drew      3 vertices into {d}x{d}\n", .{ width, height });

    // --- reading the pixels back -----------------------------------------
    const pixels = try gpa.alloc(Pixel, width * height);
    {
        var mapped: ?*anyopaque = null;
        _ = try dev.mapMemory(device, buffer_memory, 0, pixel_bytes, 0, &mapped).check();
        defer dev.unmapMemory(device, buffer_memory);
        const source: [*]const Pixel = @ptrCast(@alignCast(mapped.?));
        @memcpy(pixels, source[0 .. width * height]);
    }

    _ = try core.deviceWaitIdle(device).check();

    // --- and checking them -----------------------------------------------
    var failures: usize = 0;
    try out.writeAll("\nchecks\n");

    // The clear colour, as the eight-bit values it lands on.
    const cleared: Pixel = .{
        .r = quantise(clear_colour[0]),
        .g = quantise(clear_colour[1]),
        .b = quantise(clear_colour[2]),
        .a = 255,
    };

    // Corners: outside a triangle that reaches 0.7 of the way out, so all four
    // must still be exactly the clear colour.
    for ([_][2]usize{
        .{ 1, 1 },
        .{ width - 2, 1 },
        .{ 1, height - 2 },
        .{ width - 2, height - 2 },
    }) |corner| {
        const p = at(pixels, corner[0], corner[1]);
        failures += try expect(out, "corner is untouched", near(p, cleared, 2));
    }

    // The centre is inside the triangle, and nowhere near the clear colour.
    const centre = at(pixels, width / 2, height / 2);
    failures += try expect(out, "centre is drawn", !near(centre, cleared, 8));

    // Each corner of the triangle leans towards its own vertex colour. The
    // vertices are at the top middle (red), bottom right (green) and bottom
    // left (blue) - Vulkan's Y axis points down, so -0.7 is the top.
    const top = at(pixels, width / 2, height * 22 / 100);
    failures += try expect(out, "top vertex is reddest", top.r > top.g and top.r > top.b);

    const bottom_right = at(pixels, width * 76 / 100, height * 78 / 100);
    failures += try expect(
        out,
        "bottom right is greenest",
        bottom_right.g > bottom_right.r and bottom_right.g > bottom_right.b,
    );

    const bottom_left = at(pixels, width * 24 / 100, height * 78 / 100);
    failures += try expect(
        out,
        "bottom left is bluest",
        bottom_left.b > bottom_left.r and bottom_left.b > bottom_left.g,
    );

    // Interpolation: halfway between two vertices both should show, so the
    // centre is a mix rather than any one primary.
    failures += try expect(
        out,
        "the face is interpolated",
        centre.r > 20 and centre.g > 20 and centre.b > 20,
    );

    // Every pixel is opaque, since the fragment shader writes alpha 1.
    var transparent: usize = 0;
    for (pixels) |p| {
        if (p.a != 255) transparent += 1;
    }
    failures += try expect(out, "every pixel is opaque", transparent == 0);

    // --- and out it goes -------------------------------------------------
    const path = "triangle.ppm";
    try writePpm(init.io, path, pixels);
    try out.print("\nwrote     {s} ({d}x{d})\n", .{ path, width, height });

    if (failures != 0) {
        try out.print("\n{d} check(s) failed.\n", .{failures});
        try out.flush();
        return error.WrongPicture;
    }
}

// -------------------------------------------------------------------------
// Looking at the result
// -------------------------------------------------------------------------

fn at(pixels: []const Pixel, x: usize, y: usize) Pixel {
    return pixels[y * width + x];
}

/// A float colour as the byte an 8-bit unorm target rounds it to.
fn quantise(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

fn near(a: Pixel, b: Pixel, slack: u8) bool {
    return diff(a.r, b.r) <= slack and diff(a.g, b.g) <= slack and diff(a.b, b.b) <= slack;
}

fn diff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

fn expect(out: *Io.Writer, what: []const u8, ok: bool) !usize {
    try out.print("  {s:<28} {s}\n", .{ what, if (ok) "ok" else "FAILED" });
    return @intFromBool(!ok);
}

/// Binary PPM: a three-line header and then RGB triples. The plainest format
/// an image viewer will open, and one nothing needs a library to write.
fn writePpm(io: Io, path: []const u8, pixels: []const Pixel) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;

    try w.print("P6\n{d} {d}\n255\n", .{ width, height });
    for (pixels) |p| try w.writeAll(&.{ p.r, p.g, p.b });
    try w.flush();
}

// -------------------------------------------------------------------------
// The shaders
// -------------------------------------------------------------------------

/// A `f32` as the word SPIR-V stores it in.
fn f32Bits(comptime value: f32) u32 {
    return @bitCast(value);
}

/// The vertex shader from the top of this file.
///
/// Longer than the compute one for one reason: the two constant arrays. A
/// shading language writes `vec2 corners[3] = vec2[](...)` and SPIR-V makes
/// you build the type, the three composites, the array composite, and a
/// variable to index it through - because only a pointer can be indexed by a
/// value that is not known until the shader runs.
fn vertexShader() []const u32 {
    @setEvalBranchQuota(20_000);

    const op = spirv.op;
    const Op = spirv.Op;
    const Class = spirv.StorageClass;
    const Dec = spirv.Decoration;

    const void_t = 1;
    const fn_t = 2;
    const float_t = 3;
    const v2_t = 4;
    const v3_t = 5;
    const v4_t = 6;
    const uint_t = 7;
    const int_t = 8;
    const per_vertex_t = 9; // struct { vec4 gl_Position; }
    const ptr_out_per_vertex = 10;
    const out_vertex = 11;
    const uint_3 = 12;
    const arr2_t = 13; // vec2[3]
    const arr3_t = 14; // vec3[3]
    const ptr_priv_arr2 = 15;
    const ptr_priv_arr3 = 16;
    const f_0 = 17;
    const f_1 = 18;
    const f_pos = 19; //  0.7
    const f_neg = 20; // -0.7
    const corner_0 = 21;
    const corner_1 = 22;
    const corner_2 = 23;
    const corners = 24;
    const tint_0 = 25;
    const tint_1 = 26;
    const tint_2 = 27;
    const tints = 28;
    const var_corners = 29;
    const var_tints = 30;
    const ptr_in_int = 31;
    const vertex_index = 32;
    const ptr_priv_v2 = 33;
    const ptr_priv_v3 = 34;
    const ptr_out_v3 = 35;
    const out_tint = 36;
    const ptr_out_v4 = 37;
    const int_0 = 38;
    const main_fn = 39;
    const entry_block = 40;
    const index = 41;
    const corner_ptr = 42;
    const corner = 43;
    const corner_x = 44;
    const corner_y = 45;
    const position = 46;
    const position_ptr = 47;
    const tint_ptr = 48;
    const tint = 49;

    const module: spirv.Module = .{
        .bound = 50,

        .capabilities = op(Op.capability, &.{spirv.Capability.shader}),

        .memory_model = op(Op.memory_model, &.{
            spirv.AddressingModel.logical,
            spirv.MemoryModel.glsl450,
        }),

        // Every Input and Output the entry point touches. `Private` variables
        // are not listed - SPIR-V 1.0 asks only for the interface.
        .entry_points = op(Op.entry_point, spirv.cat(&.{
            &.{ spirv.ExecutionModel.vertex, main_fn },
            spirv.string("main"),
            &.{ out_vertex, vertex_index, out_tint },
        })),

        .decorations = // gl_PerVertex, and its one member
        op(Op.member_decorate, &.{
            per_vertex_t,
            0,
            Dec.builtin,
            spirv.BuiltIn.position,
        }) ++
            op(Op.decorate, &.{ per_vertex_t, Dec.block }) ++
            // The vertex number the hardware hands in...
            op(Op.decorate, &.{ vertex_index, Dec.builtin, spirv.BuiltIn.vertex_index }) ++
            // ...and the colour handed on to the fragment shader.
            op(Op.decorate, &.{ out_tint, Dec.location, 0 }),

        .globals = op(Op.type_void, &.{void_t}) ++
            op(Op.type_function, &.{ fn_t, void_t }) ++
            op(Op.type_float, &.{ float_t, 32 }) ++
            op(Op.type_vector, &.{ v2_t, float_t, 2 }) ++
            op(Op.type_vector, &.{ v3_t, float_t, 3 }) ++
            op(Op.type_vector, &.{ v4_t, float_t, 4 }) ++
            op(Op.type_int, &.{ uint_t, 32, 0 }) ++
            op(Op.type_int, &.{ int_t, 32, 1 }) ++
            op(Op.type_struct, &.{ per_vertex_t, v4_t }) ++
            op(Op.type_pointer, &.{ ptr_out_per_vertex, Class.output, per_vertex_t }) ++
            op(Op.variable, &.{ ptr_out_per_vertex, out_vertex, Class.output }) ++
            op(Op.constant, &.{ uint_t, uint_3, 3 }) ++
            op(Op.type_array, &.{ arr2_t, v2_t, uint_3 }) ++
            op(Op.type_array, &.{ arr3_t, v3_t, uint_3 }) ++
            op(Op.type_pointer, &.{ ptr_priv_arr2, Class.private, arr2_t }) ++
            op(Op.type_pointer, &.{ ptr_priv_arr3, Class.private, arr3_t }) ++
            op(Op.constant, &.{ float_t, f_0, f32Bits(0.0) }) ++
            op(Op.constant, &.{ float_t, f_1, f32Bits(1.0) }) ++
            op(Op.constant, &.{ float_t, f_pos, f32Bits(0.7) }) ++
            op(Op.constant, &.{ float_t, f_neg, f32Bits(-0.7) }) ++
            // The three corners. Vulkan's clip space has Y pointing down, so
            // the negative one is the top of the picture.
            op(Op.constant_composite, &.{ v2_t, corner_0, f_0, f_neg }) ++
            op(Op.constant_composite, &.{ v2_t, corner_1, f_pos, f_pos }) ++
            op(Op.constant_composite, &.{ v2_t, corner_2, f_neg, f_pos }) ++
            op(Op.constant_composite, &.{ arr2_t, corners, corner_0, corner_1, corner_2 }) ++
            // Red, green, blue.
            op(Op.constant_composite, &.{ v3_t, tint_0, f_1, f_0, f_0 }) ++
            op(Op.constant_composite, &.{ v3_t, tint_1, f_0, f_1, f_0 }) ++
            op(Op.constant_composite, &.{ v3_t, tint_2, f_0, f_0, f_1 }) ++
            op(Op.constant_composite, &.{ arr3_t, tints, tint_0, tint_1, tint_2 }) ++
            // A constant cannot be indexed by a runtime value, so each array
            // goes into a variable that starts out holding it.
            op(Op.variable, &.{ ptr_priv_arr2, var_corners, Class.private, corners }) ++
            op(Op.variable, &.{ ptr_priv_arr3, var_tints, Class.private, tints }) ++
            op(Op.type_pointer, &.{ ptr_in_int, Class.input, int_t }) ++
            op(Op.variable, &.{ ptr_in_int, vertex_index, Class.input }) ++
            op(Op.type_pointer, &.{ ptr_priv_v2, Class.private, v2_t }) ++
            op(Op.type_pointer, &.{ ptr_priv_v3, Class.private, v3_t }) ++
            op(Op.type_pointer, &.{ ptr_out_v3, Class.output, v3_t }) ++
            op(Op.variable, &.{ ptr_out_v3, out_tint, Class.output }) ++
            op(Op.type_pointer, &.{ ptr_out_v4, Class.output, v4_t }) ++
            op(Op.constant, &.{ int_t, int_0, 0 }),

        .functions = op(Op.function, &.{
            void_t,
            main_fn,
            spirv.FunctionControl.none,
            fn_t,
        }) ++
            op(Op.label, &.{entry_block}) ++
            op(Op.load, &.{ int_t, index, vertex_index }) ++
            // gl_Position = vec4(corners[gl_VertexIndex], 0.0, 1.0);
            op(Op.access_chain, &.{ ptr_priv_v2, corner_ptr, var_corners, index }) ++
            op(Op.load, &.{ v2_t, corner, corner_ptr }) ++
            op(Op.composite_extract, &.{ float_t, corner_x, corner, 0 }) ++
            op(Op.composite_extract, &.{ float_t, corner_y, corner, 1 }) ++
            op(Op.composite_construct, &.{ v4_t, position, corner_x, corner_y, f_0, f_1 }) ++
            op(Op.access_chain, &.{ ptr_out_v4, position_ptr, out_vertex, int_0 }) ++
            op(Op.store, &.{ position_ptr, position }) ++
            // tint = tints[gl_VertexIndex];
            op(Op.access_chain, &.{ ptr_priv_v3, tint_ptr, var_tints, index }) ++
            op(Op.load, &.{ v3_t, tint, tint_ptr }) ++
            op(Op.store, &.{ out_tint, tint }) ++
            op(Op.@"return", &.{}) ++
            op(Op.function_end, &.{}),
    };

    return module.words();
}

/// The fragment shader: take the interpolated colour and add an alpha of one.
fn fragmentShader() []const u32 {
    @setEvalBranchQuota(20_000);

    const op = spirv.op;
    const Op = spirv.Op;
    const Class = spirv.StorageClass;
    const Dec = spirv.Decoration;

    const void_t = 1;
    const fn_t = 2;
    const float_t = 3;
    const v3_t = 4;
    const v4_t = 5;
    const ptr_in_v3 = 6;
    const in_tint = 7;
    const ptr_out_v4 = 8;
    const out_target = 9;
    const f_1 = 10;
    const main_fn = 11;
    const entry_block = 12;
    const tint = 13;
    const r = 14;
    const g = 15;
    const b = 16;
    const result = 17;

    const module: spirv.Module = .{
        .bound = 18,

        .capabilities = op(Op.capability, &.{spirv.Capability.shader}),

        .memory_model = op(Op.memory_model, &.{
            spirv.AddressingModel.logical,
            spirv.MemoryModel.glsl450,
        }),

        .entry_points = op(Op.entry_point, spirv.cat(&.{
            &.{ spirv.ExecutionModel.fragment, main_fn },
            spirv.string("main"),
            &.{ in_tint, out_target },
        })),

        // Vulkan requires this one: the origin is the top left corner.
        .execution_modes = op(Op.execution_mode, &.{
            main_fn,
            spirv.ExecutionMode.origin_upper_left,
        }),

        .decorations = op(Op.decorate, &.{ in_tint, Dec.location, 0 }) ++
            op(Op.decorate, &.{ out_target, Dec.location, 0 }),

        .globals = op(Op.type_void, &.{void_t}) ++
            op(Op.type_function, &.{ fn_t, void_t }) ++
            op(Op.type_float, &.{ float_t, 32 }) ++
            op(Op.type_vector, &.{ v3_t, float_t, 3 }) ++
            op(Op.type_vector, &.{ v4_t, float_t, 4 }) ++
            op(Op.type_pointer, &.{ ptr_in_v3, Class.input, v3_t }) ++
            op(Op.variable, &.{ ptr_in_v3, in_tint, Class.input }) ++
            op(Op.type_pointer, &.{ ptr_out_v4, Class.output, v4_t }) ++
            op(Op.variable, &.{ ptr_out_v4, out_target, Class.output }) ++
            op(Op.constant, &.{ float_t, f_1, f32Bits(1.0) }),

        .functions = op(Op.function, &.{
            void_t,
            main_fn,
            spirv.FunctionControl.none,
            fn_t,
        }) ++
            op(Op.label, &.{entry_block}) ++
            op(Op.load, &.{ v3_t, tint, in_tint }) ++
            op(Op.composite_extract, &.{ float_t, r, tint, 0 }) ++
            op(Op.composite_extract, &.{ float_t, g, tint, 1 }) ++
            op(Op.composite_extract, &.{ float_t, b, tint, 2 }) ++
            op(Op.composite_construct, &.{ v4_t, result, r, g, b, f_1 }) ++
            op(Op.store, &.{ out_target, result }) ++
            op(Op.@"return", &.{}) ++
            op(Op.function_end, &.{}),
    };

    return module.words();
}
