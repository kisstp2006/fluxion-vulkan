// SPDX-License-Identifier: CC0-1.0

//! GPU compute, end to end. Run it with `zig build example-compute`.
//!
//! The sample every API has: put numbers in a buffer, run a shader over them,
//! read the answers back and check them. No window, no swapchain, no display -
//! it runs over SSH and on a headless server.
//!
//! What it does is deliberately checkable. Element `i` starts as `i`, and the
//! shader replaces it with `i * 2 + i`, so the answer is `3i` and a wrong
//! answer is obvious rather than plausible. The program compares all 1024 of
//! them and exits non-zero if any disagrees.
//!
//! The shader is this, and it is assembled into SPIR-V at compile time by
//! `spirv.zig` rather than compiled by `glslc`:
//!
//! ```glsl
//! #version 450
//! layout(local_size_x = 64) in;
//! layout(std430, set = 0, binding = 0) buffer Data { uint values[]; };
//! void main() {
//!     uint i = gl_GlobalInvocationID.x;
//!     values[i] = values[i] * 2 + i;
//! }
//! ```

const std = @import("std");
const Io = std.Io;
const vk = @import("fluxion_vulkan");
const gpu = @import("beyond.zig");
const spirv = @import("spirv.zig");

/// How many numbers to push through. A multiple of the workgroup size, so
/// there is no partial group to guard against in the shader.
const count = 1024;
const local_size = 64;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // --- a device that can compute ---------------------------------------
    var loader = vk.Loader.init() catch |err| switch (err) {
        error.NotFound, error.NotSupported => {
            try out.writeAll("No Vulkan on this machine, so nothing to compute with.\n");
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

    // Prefer a discrete card, since this is the kind of work one is for.
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
    const family = vk.queueFamily(families, .{ .compute = true }) orelse {
        try out.print("{s} has no compute queue.\n", .{props.name()});
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

    // The commands this file needs, declared in `beyond.zig` and loaded
    // through the same device resolver - so they skip the loader's trampoline
    // exactly like the three the library ships.
    const dev = try vk.load(gpu.Commands, inst.deviceResolver(device));

    var queue: vk.Queue = undefined;
    core.getDeviceQueue(device, family, 0, &queue);

    try out.print("{s}, compute queue family {d}\n", .{ props.name(), family });

    // --- a buffer both sides can see -------------------------------------
    // Host-visible and host-coherent, so the numbers can be written and read
    // without staging or explicit flushes. A real workload would stage into
    // device-local memory; this one is 4 KiB and the point is elsewhere.
    const bytes: gpu.DeviceSize = count * @sizeOf(u32);

    var buffer: gpu.Buffer = .none;
    const buffer_info: gpu.BufferCreateInfo = .{
        .size = bytes,
        .usage = .{ .storage_buffer = true },
    };
    _ = try dev.createBuffer(device, &buffer_info, null, &buffer).check();
    defer dev.destroyBuffer(device, buffer, null);

    var requirements: gpu.MemoryRequirements = undefined;
    dev.getBufferMemoryRequirements(device, buffer, &requirements);

    const type_index = gpu.memoryType(&memory_props, requirements.memory_type_bits, .{
        .host_visible = true,
        .host_coherent = true,
    }) orelse {
        try out.writeAll("No memory this buffer can live in that the CPU can also see.\n");
        return;
    };

    var memory: gpu.DeviceMemory = .none;
    const allocate_info: gpu.MemoryAllocateInfo = .{
        .allocation_size = requirements.size,
        .memory_type_index = type_index,
    };
    _ = try dev.allocateMemory(device, &allocate_info, null, &memory).check();
    defer dev.freeMemory(device, memory, null);

    _ = try dev.bindBufferMemory(device, buffer, memory, 0).check();

    // --- the numbers going in --------------------------------------------
    {
        var mapped: ?*anyopaque = null;
        _ = try dev.mapMemory(device, memory, 0, bytes, 0, &mapped).check();
        defer dev.unmapMemory(device, memory);

        const values: [*]u32 = @ptrCast(@alignCast(mapped.?));
        for (0..count) |i| values[i] = @intCast(i);
    }

    // --- the shader ------------------------------------------------------
    const code = comptime shader();
    var module: gpu.ShaderModule = .none;
    const module_info: gpu.ShaderModuleCreateInfo = .{
        .code_size = code.len * @sizeOf(u32),
        .code = code.ptr,
    };
    _ = try dev.createShaderModule(device, &module_info, null, &module).check();
    defer dev.destroyShaderModule(device, module, null);

    try out.print("shader    {d} words of SPIR-V, assembled at compile time\n", .{code.len});

    // --- what the shader can see -----------------------------------------
    const bindings = [_]gpu.DescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .stage_flags = .{ .compute = true },
    }};
    var set_layout: gpu.DescriptorSetLayout = .none;
    const layout_info: gpu.DescriptorSetLayoutCreateInfo = .{
        .binding_count = bindings.len,
        .bindings = &bindings,
    };
    _ = try dev.createDescriptorSetLayout(device, &layout_info, null, &set_layout).check();
    defer dev.destroyDescriptorSetLayout(device, set_layout, null);

    const set_layouts = [_]gpu.DescriptorSetLayout{set_layout};
    var pipeline_layout: gpu.PipelineLayout = .none;
    const pipeline_layout_info: gpu.PipelineLayoutCreateInfo = .{
        .set_layout_count = set_layouts.len,
        .set_layouts = &set_layouts,
    };
    _ = try dev.createPipelineLayout(device, &pipeline_layout_info, null, &pipeline_layout).check();
    defer dev.destroyPipelineLayout(device, pipeline_layout, null);

    const pool_sizes = [_]gpu.DescriptorPoolSize{.{ .type = .storage_buffer, .descriptor_count = 1 }};
    var pool: gpu.DescriptorPool = .none;
    const pool_info: gpu.DescriptorPoolCreateInfo = .{
        .max_sets = 1,
        .pool_size_count = pool_sizes.len,
        .pool_sizes = &pool_sizes,
    };
    _ = try dev.createDescriptorPool(device, &pool_info, null, &pool).check();
    defer dev.destroyDescriptorPool(device, pool, null);

    var set: gpu.DescriptorSet = .none;
    const set_info: gpu.DescriptorSetAllocateInfo = .{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .set_layouts = &set_layouts,
    };
    _ = try dev.allocateDescriptorSets(device, &set_info, @ptrCast(&set)).check();

    const buffer_binding: gpu.DescriptorBufferInfo = .{
        .buffer = buffer,
        .range = gpu.DescriptorBufferInfo.whole_size,
    };
    const writes = [_]gpu.WriteDescriptorSet{.{
        .dst_set = set,
        .dst_binding = 0,
        .descriptor_type = .storage_buffer,
        .buffer_info = &buffer_binding,
    }};
    dev.updateDescriptorSets(device, writes.len, &writes, 0, null);

    // --- the pipeline ----------------------------------------------------
    var pipeline: gpu.Pipeline = .none;
    const pipeline_infos = [_]gpu.ComputePipelineCreateInfo{.{
        .stage = .{
            .stage = .{ .compute = true },
            .module = module,
            .name = "main",
        },
        .layout = pipeline_layout,
    }};
    _ = try dev.createComputePipelines(
        device,
        .none,
        pipeline_infos.len,
        &pipeline_infos,
        null,
        @ptrCast(&pipeline),
    ).check();
    defer dev.destroyPipeline(device, pipeline, null);

    // --- recording and submitting ----------------------------------------
    var command_pool: gpu.CommandPool = .none;
    const command_pool_info: gpu.CommandPoolCreateInfo = .{ .queue_family_index = family };
    _ = try dev.createCommandPool(device, &command_pool_info, null, &command_pool).check();
    defer dev.destroyCommandPool(device, command_pool, null);

    var cmd: gpu.CommandBuffer = undefined;
    const cmd_info: gpu.CommandBufferAllocateInfo = .{
        .command_pool = command_pool,
        .command_buffer_count = 1,
    };
    _ = try dev.allocateCommandBuffers(device, &cmd_info, @ptrCast(&cmd)).check();

    const begin: gpu.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit = true } };
    _ = try dev.beginCommandBuffer(cmd, &begin).check();
    dev.cmdBindPipeline(cmd, .compute, pipeline);
    dev.cmdBindDescriptorSets(cmd, .compute, pipeline_layout, 0, 1, &set_layouts_set(set), 0, null);
    dev.cmdDispatch(cmd, count / local_size, 1, 1);
    _ = try dev.endCommandBuffer(cmd).check();

    var fence: gpu.Fence = .none;
    const fence_info: gpu.FenceCreateInfo = .{};
    _ = try dev.createFence(device, &fence_info, null, &fence).check();
    defer dev.destroyFence(device, fence, null);

    const command_buffers = [_]gpu.CommandBuffer{cmd};
    const submits = [_]gpu.SubmitInfo{.{
        .command_buffer_count = command_buffers.len,
        .command_buffers = &command_buffers,
    }};
    _ = try dev.queueSubmit(queue, submits.len, &submits, fence).check();

    const fences = [_]gpu.Fence{fence};
    _ = try dev.waitForFences(device, fences.len, &fences, vk.types.vk_true, gpu.forever).check();

    try out.print("dispatch  {d} groups of {d}\n", .{ count / local_size, local_size });

    // --- and the answers -------------------------------------------------
    var wrong: usize = 0;
    var first_wrong: usize = 0;
    var first_got: u32 = 0;
    {
        var mapped: ?*anyopaque = null;
        _ = try dev.mapMemory(device, memory, 0, bytes, 0, &mapped).check();
        defer dev.unmapMemory(device, memory);

        const values: [*]const u32 = @ptrCast(@alignCast(mapped.?));
        for (0..count) |i| {
            const want: u32 = @intCast(i * 3); // i * 2 + i
            if (values[i] != want) {
                if (wrong == 0) {
                    first_wrong = i;
                    first_got = values[i];
                }
                wrong += 1;
            }
        }

        try out.print("results   {d}, {d}, {d}, {d}, ... {d}\n", .{
            values[0], values[1], values[2], values[3], values[count - 1],
        });
    }

    _ = try core.deviceWaitIdle(device).check();

    if (wrong != 0) {
        try out.print(
            "\nWRONG: {d} of {d} disagree. First at {d}: got {d}, wanted {d}.\n",
            .{ wrong, count, first_wrong, first_got, first_wrong * 3 },
        );
        try out.flush();
        return error.WrongAnswer;
    }

    try out.print("checked   all {d} correct\n", .{count});
}

/// The descriptor set as a one-element array, since `cmdBindDescriptorSets`
/// takes a pointer to many.
fn set_layouts_set(set: gpu.DescriptorSet) [1]gpu.DescriptorSet {
    return .{set};
}

// -------------------------------------------------------------------------
// The shader
// -------------------------------------------------------------------------

/// The GLSL at the top of this file, as SPIR-V.
///
/// Every id is named, and they run 1 to 22 in the order they are defined -
/// which is what `bound` counts. Read it alongside the GLSL: the first half is
/// the plumbing a shading language hides, and the function at the end is the
/// one line that does the work.
fn shader() []const u32 {
    @setEvalBranchQuota(10_000);

    const op = spirv.op;
    const Op = spirv.Op;
    const Class = spirv.StorageClass;
    const Dec = spirv.Decoration;

    // Result ids.
    const void_t = 1;
    const fn_t = 2; // void ()
    const uint_t = 3;
    const uvec3_t = 4;
    const ptr_in_uvec3 = 5;
    const gid = 6; // gl_GlobalInvocationID
    const array_t = 7; // uint[]
    const data_t = 8; // struct { uint[] }
    const ptr_uniform_data = 9;
    const data = 10; // the buffer itself
    const ptr_uniform_uint = 11;
    const ptr_in_uint = 12;
    const uint_0 = 13;
    const uint_2 = 14;
    const main_fn = 15;
    const entry_block = 16;
    const index_ptr = 17;
    const index = 18;
    const element_ptr = 19;
    const value = 20;
    const doubled = 21;
    const result = 22;

    const module: spirv.Module = .{
        .bound = 23,

        .capabilities = op(Op.capability, &.{spirv.Capability.shader}),

        .memory_model = op(Op.memory_model, &.{
            spirv.AddressingModel.logical,
            spirv.MemoryModel.glsl450,
        }),

        // The interface list at the end is every Input and Output variable the
        // entry point touches. Leaving one out is a validation error.
        .entry_points = op(Op.entry_point, spirv.cat(&.{
            &.{ spirv.ExecutionModel.gl_compute, main_fn },
            spirv.string("main"),
            &.{gid},
        })),

        .execution_modes = op(Op.execution_mode, &.{
            main_fn,
            spirv.ExecutionMode.local_size,
            local_size,
            1,
            1,
        }),

        .decorations = // `values` is an array of 4-byte elements...
        op(Op.decorate, &.{ array_t, Dec.array_stride, 4 }) ++
            // ...inside a block the shader may write to...
            op(Op.decorate, &.{ data_t, Dec.buffer_block }) ++
            op(Op.member_decorate, &.{ data_t, 0, Dec.offset, 0 }) ++
            // ...bound where the descriptor set puts it...
            op(Op.decorate, &.{ data, Dec.descriptor_set, 0 }) ++
            op(Op.decorate, &.{ data, Dec.binding, 0 }) ++
            // ...and the invocation id comes from the hardware.
            op(Op.decorate, &.{ gid, Dec.builtin, spirv.BuiltIn.global_invocation_id }),

        .globals = op(Op.type_void, &.{void_t}) ++
            op(Op.type_function, &.{ fn_t, void_t }) ++
            op(Op.type_int, &.{ uint_t, 32, 0 }) ++ // 32 bits, unsigned
            op(Op.type_vector, &.{ uvec3_t, uint_t, 3 }) ++
            op(Op.type_pointer, &.{ ptr_in_uvec3, Class.input, uvec3_t }) ++
            op(Op.variable, &.{ ptr_in_uvec3, gid, Class.input }) ++
            op(Op.type_runtime_array, &.{ array_t, uint_t }) ++
            op(Op.type_struct, &.{ data_t, array_t }) ++
            op(Op.type_pointer, &.{ ptr_uniform_data, Class.uniform, data_t }) ++
            op(Op.variable, &.{ ptr_uniform_data, data, Class.uniform }) ++
            op(Op.type_pointer, &.{ ptr_uniform_uint, Class.uniform, uint_t }) ++
            op(Op.type_pointer, &.{ ptr_in_uint, Class.input, uint_t }) ++
            op(Op.constant, &.{ uint_t, uint_0, 0 }) ++
            op(Op.constant, &.{ uint_t, uint_2, 2 }),

        .functions = op(Op.function, &.{
            void_t,
            main_fn,
            spirv.FunctionControl.none,
            fn_t,
        }) ++
            op(Op.label, &.{entry_block}) ++
            // uint i = gl_GlobalInvocationID.x;
            op(Op.access_chain, &.{ ptr_in_uint, index_ptr, gid, uint_0 }) ++
            op(Op.load, &.{ uint_t, index, index_ptr }) ++
            // values[i]
            op(Op.access_chain, &.{ ptr_uniform_uint, element_ptr, data, uint_0, index }) ++
            op(Op.load, &.{ uint_t, value, element_ptr }) ++
            // * 2 + i
            op(Op.i_mul, &.{ uint_t, doubled, value, uint_2 }) ++
            op(Op.i_add, &.{ uint_t, result, doubled, index }) ++
            op(Op.store, &.{ element_ptr, result }) ++
            op(Op.@"return", &.{}) ++
            op(Op.function_end, &.{}),
    };

    return module.words();
}
