// SPDX-License-Identifier: BSL-1.0

//! A tour of Fluxion Vulkan. Run it with `zig build example`.
//!
//! It does what every Vulkan program does before it draws anything: finds the
//! library, asks what version it is, lists the layers and extensions, creates
//! an instance, looks at the GPUs, picks one, opens it, and takes a queue out
//! of it. Then it tears the whole thing down in the order that does not crash.
//!
//! On a machine with no GPU driver it says so and exits, because that is what
//! a loader is for: `error.NotFound` is an answer, not a crash.

const std = @import("std");
const Io = std.Io;
const vk = @import("fluxion_vulkan");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    // --- finding Vulkan ---------------------------------------------------
    var loader = vk.Loader.init() catch |err| switch (err) {
        error.NotFound => {
            try out.writeAll("No Vulkan library on this machine.\n\nTried, in order:\n");
            for (vk.library.candidates) |name| try out.print("  {s}\n", .{name});
            try out.writeAll(
                \\
                \\Which usually means no GPU driver is installed, rather than
                \\that there is no GPU. Nothing here crashed: this is the
                \\answer a loader exists to give.
                \\
            );
            try out.flush();
            return;
        },
        error.NotSupported => {
            // A platform with no run-time library loading at all, so there
            // were no names to try and nothing to report about this machine.
            try out.writeAll(
                \\This platform has no run-time library loading, so there is
                \\nothing to find. Vulkan has to arrive some other way - see
                \\the adopt example.
                \\
            );
            try out.flush();
            return;
        },
        else => return err,
    };
    defer loader.deinit();

    try out.print("--- the loader ---\nlibrary   {s}\nversion   {f}\n", .{
        loader.name().?,
        try loader.apiVersion(),
    });

    // Which of the four global commands were there. On a Vulkan 1.0 loader
    // `vkEnumerateInstanceVersion` is not, and that is not a failure.
    var report: vk.dispatch.Report = .{};
    _ = try vk.dispatch.loadReport(vk.GlobalCommands, .{ .global = loader.getInstanceProcAddr }, &report);
    try out.print("commands  {d} of {d} global\n", .{
        report.found,
        comptime vk.dispatch.names(vk.GlobalCommands).len,
    });

    // --- what is installed ------------------------------------------------
    const layers = try loader.layers(gpa);
    try out.print("\n--- {d} layer(s) ---\n", .{layers.len});
    for (layers) |*layer| {
        try out.print("{s}\n  {s}\n", .{ layer.name(), layer.describe() });
    }

    const available = try loader.extensions(gpa, null);
    try out.print("\n--- {d} instance extension(s) ---\n", .{available.len});
    for (available) |*extension| try out.print("{s}\n", .{extension.name()});

    // --- asking for what is there, and only that --------------------------
    // Required: fail here, by name, rather than inside `vkCreateInstance` with
    // a code that does not say which one.
    const required = [_][*:0]const u8{"VK_KHR_surface"};
    if (vk.firstMissing(available, &required)) |missing| {
        try out.print("\nthis loader has no {s}, which is unusual\n", .{missing});
        try out.flush();
        return;
    }

    // Optional: take the ones that are here and leave the rest. Portability is
    // the one MoltenVK cannot start without; where a loader offers it anyway,
    // asking for it costs nothing.
    const optional = [_][*:0]const u8{
        "VK_EXT_debug_utils",
        "VK_KHR_portability_enumeration",
    };
    var wanted: [required.len + optional.len][*:0]const u8 = undefined;
    wanted[0] = required[0];
    const extras = vk.supported(available, &optional, wanted[1..]);
    const enabled = wanted[0 .. 1 + extras.len];

    try out.writeAll("\n--- asking for ---\n");
    for (enabled) |name| try out.print("{s}\n", .{name});

    // --- the instance -----------------------------------------------------
    const app: vk.ApplicationInfo = .{
        .application_name = "fluxion-vulkan-demo",
        .application_version = vk.ApiVersion.init(0, 1, 0).toInt(),
        .api_version = vk.v1_1.toInt(),
    };
    var info: vk.InstanceCreateInfo = .{ .application_info = &app };
    info.setExtensions(enabled);
    // The flag and the extension go together, or neither does.
    info.flags.enumerate_portability_khr = vk.has(available, "VK_KHR_portability_enumeration");

    const instance = try loader.createInstance(&info, null);
    const inst = try loader.instanceCommands(instance);
    defer inst.destroyInstance(instance, null);

    // --- the GPUs ---------------------------------------------------------
    const gpus = try vk.enumerate.physicalDevices(gpa, inst, instance);
    try out.print("\n--- {d} device(s) ---\n", .{gpus.len});

    var best: ?vk.PhysicalDevice = null;
    var best_score: u64 = 0;
    var best_name: []const u8 = "";

    for (gpus) |gpu| {
        var props: vk.PhysicalDeviceProperties = undefined;
        inst.getPhysicalDeviceProperties(gpu, &props);

        var memory: vk.PhysicalDeviceMemoryProperties = undefined;
        inst.getPhysicalDeviceMemoryProperties(gpu, &memory);
        const vram = memory.deviceLocalBytes();

        const families = try vk.enumerate.queueFamilies(gpa, inst, gpu);
        const extensions = try vk.enumerate.deviceExtensions(gpa, inst, gpu, null);

        try out.print(
            \\
            \\{s}
            \\  kind     {s}
            \\  vulkan   {f}
            \\  driver   {f}
            \\  vendor   0x{X:0>4}
            \\  memory   {d} MiB device-local
            \\  present  {s}
            \\  queues
            \\
        , .{
            props.name(),
            props.device_type.label(),
            vk.ApiVersion.fromInt(props.api_version),
            vk.version.Driver{ .vendor_id = props.vendor_id, .value = props.driver_version },
            props.vendor_id,
            vram >> 20,
            if (vk.has(extensions, "VK_KHR_swapchain")) "yes" else "no",
        });

        for (families, 0..) |family, index| {
            try out.print("    {d}: {d:>2} queue(s)", .{ index, family.queue_count });
            const flags = family.queue_flags;
            if (flags.graphics) try out.writeAll("  graphics");
            if (flags.compute) try out.writeAll("  compute");
            if (flags.transfer) try out.writeAll("  transfer");
            if (flags.sparse_binding) try out.writeAll("  sparse");
            if (flags.video_decode_khr) try out.writeAll("  video-decode");
            if (flags.video_encode_khr) try out.writeAll("  video-encode");
            try out.writeAll("\n");
        }

        // Discrete beats integrated beats anything else, and video memory is
        // the tie-break. A real program would also want a device that can
        // present to its window.
        const kind: u64 = switch (props.device_type) {
            .discrete_gpu => 4,
            .integrated_gpu => 3,
            .virtual_gpu => 2,
            .cpu => 1,
            else => 0,
        };
        const score = kind << 40 | (vram >> 20);
        // `best == null` first, because a device can legitimately score zero -
        // an unrecognised kind with no device-local memory - and it is still
        // better than no device at all.
        if (best == null or score > best_score) {
            best_score = score;
            best = gpu;
            best_name = try gpa.dupe(u8, props.name());
        }
    }

    const gpu = best orelse {
        try out.writeAll("\nNo device to open. The loader did its job; there is nothing behind it.\n");
        try out.flush();
        return;
    };

    // --- opening one ------------------------------------------------------
    const families = try vk.enumerate.queueFamilies(gpa, inst, gpu);
    const graphics = vk.queueFamily(families, .{ .graphics = true }) orelse {
        try out.print("\n{s} has no graphics queue, which is a compute-only card.\n", .{best_name});
        try out.flush();
        return;
    };

    // The narrowest family that can do the job, which is how a dedicated
    // transfer queue is found on the hardware that has one. Never null here:
    // there is a graphics family, and graphics implies transfer whether or not
    // the driver sets the bit - see `enumerate.capabilities`.
    const transfer = vk.queueFamily(families, .{ .transfer = true }).?;

    const priorities = [_]f32{1.0};
    const queues = [_]vk.DeviceQueueCreateInfo{.queues(graphics, &priorities)};
    var device_info: vk.DeviceCreateInfo = .{};
    device_info.setQueues(&queues);

    var device: vk.Device = undefined;
    _ = try inst.createDevice(gpu, &device_info, null, &device).check();

    const dev = try inst.deviceCommands(device);
    defer dev.destroyDevice(device, null);

    var queue: vk.Queue = undefined;
    dev.getDeviceQueue(device, graphics, 0, &queue);

    try out.print(
        \\
        \\--- opened {s} ---
        \\graphics family  {d}
        \\transfer family  {d}{s}
        \\
    , .{
        best_name,
        graphics,
        transfer,
        if (transfer == graphics) " (the same one; no dedicated transfer queue)" else " (dedicated)",
    });

    // --- a table of your own ----------------------------------------------
    // Nothing about the tables in `commands` is privileged. This one is
    // declared here, loaded through the same device resolver, and gets
    // pointers that skip the loader's trampoline the same way.
    const Drawing = struct {
        cmdDraw: ?*const fn (
            command_buffer: *anyopaque,
            vertex_count: u32,
            instance_count: u32,
            first_vertex: u32,
            first_instance: u32,
        ) callconv(vk.call) void,
        cmdDrawMeshTasksEXT: ?*const fn (
            command_buffer: *anyopaque,
            x: u32,
            y: u32,
            z: u32,
        ) callconv(vk.call) void,
    };

    const drawing = try vk.load(Drawing, inst.deviceResolver(device));
    try out.print(
        \\
        \\--- a table declared in this file ---
        \\vkCmdDraw              {s}
        \\vkCmdDrawMeshTasksEXT  {s}
        \\
    , .{
        if (drawing.cmdDraw != null) "loaded" else "absent",
        if (drawing.cmdDrawMeshTasksEXT != null) "loaded" else "absent (no mesh shaders here)",
    });

    // --- and down again ---------------------------------------------------
    // Finish the work, then the device, then the instance, and only then the
    // library - which is what the two `defer`s above and `loader.deinit` do,
    // in that order, on the way out of this function.
    _ = try dev.deviceWaitIdle(device).check();

    try out.flush();
}
