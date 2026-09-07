// SPDX-License-Identifier: CC0-1.0

//! Which GPU should this program use? Run it with
//! `zig build example-devices`.
//!
//! Vulkan hands back every device it found, in the driver's preferred order,
//! which is a hint and not an answer. Choosing between them is the program's
//! job, and what it weighs depends on what the program does - so this prints
//! everything the choice could reasonably be made on, then makes one.
//!
//! The rule here is the usual one: a device must be able to do the work at
//! all, and among the ones that can, discrete beats integrated beats software,
//! with video memory as the tie-break.

const std = @import("std");
const Io = std.Io;
const vk = @import("fluxion_vulkan");

/// What this imaginary program cannot run without.
const requirements = struct {
    const api = vk.v1_1;
    const queues: vk.QueueFlags = .{ .graphics = true, .compute = true };
    const extension = "VK_KHR_swapchain";
};

const Candidate = struct {
    handle: vk.PhysicalDevice,
    name: []const u8,
    score: u64,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var loader = vk.Loader.init() catch |err| switch (err) {
        error.NotFound, error.NotSupported => {
            try out.writeAll("No Vulkan on this machine, so no devices to weigh.\n");
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
    try out.print("{d} device(s), in the order the driver listed them\n", .{gpus.len});

    var best: ?Candidate = null;

    for (gpus, 0..) |gpu, position| {
        var props: vk.PhysicalDeviceProperties = undefined;
        inst.getPhysicalDeviceProperties(gpu, &props);

        var memory: vk.PhysicalDeviceMemoryProperties = undefined;
        inst.getPhysicalDeviceMemoryProperties(gpu, &memory);

        const families = try vk.enumerate.queueFamilies(gpa, inst, gpu);
        const extensions = try vk.enumerate.deviceExtensions(gpa, inst, gpu, null);

        const supported = vk.ApiVersion.fromInt(props.api_version);
        const vram_mib = memory.deviceLocalBytes() >> 20;

        try out.print(
            \\
            \\[{d}] {s}
            \\    kind      {s}
            \\    vulkan    {f}
            \\    driver    {f}
            \\    memory    {d} MiB device-local, {d} heap(s), {d} type(s)
            \\    families  {d}
            \\
        , .{
            position,
            props.name(),
            props.device_type.label(),
            supported,
            vk.version.Driver{ .vendor_id = props.vendor_id, .value = props.driver_version },
            vram_mib,
            memory.heaps().len,
            memory.types().len,
            families.len,
        });

        // Every requirement, checked one at a time, so a rejection can say
        // which one it was rather than just "unsuitable".
        const rejected: ?[]const u8 = blk: {
            if (!supported.atLeast(requirements.api)) break :blk "too old";
            if (vk.queueFamily(families, requirements.queues) == null)
                break :blk "no graphics-and-compute family";
            if (!vk.has(extensions, requirements.extension)) break :blk "cannot present";
            break :blk null;
        };

        if (rejected) |why| {
            try out.print("    rejected  {s}\n", .{why});
            continue;
        }

        // Kind first, memory second: shifting the kind past any plausible
        // number of mebibytes makes one strictly outrank the other.
        const kind: u64 = switch (props.device_type) {
            .discrete_gpu => 4,
            .integrated_gpu => 3,
            .virtual_gpu => 2,
            .cpu => 1,
            else => 0,
        };
        const score = kind << 32 | @min(vram_mib, std.math.maxInt(u32));
        try out.print("    score     {d}\n", .{score});

        if (best == null or score > best.?.score) {
            best = .{
                .handle = gpu,
                .name = try gpa.dupe(u8, props.name()),
                .score = score,
            };
        }
    }

    const chosen = best orelse {
        try out.print(
            \\
            \\Nothing here can run this program. It wants Vulkan {f}, a family
            \\that does graphics and compute, and {s}.
            \\
        , .{ requirements.api, requirements.extension });
        return;
    };

    try out.print("\nchosen: {s}\n", .{chosen.name});

    // The one detail worth a second look on the device actually picked: which
    // family would carry transfers. `queueFamily` returns the narrowest match,
    // so a card with a dedicated copy engine reports a different family here
    // than it does for graphics.
    const families = try vk.enumerate.queueFamilies(gpa, inst, chosen.handle);
    const graphics = vk.queueFamily(families, .{ .graphics = true }).?;
    const transfer = vk.queueFamily(families, .{ .transfer = true }).?;
    try out.print("  graphics family {d}, transfer family {d}{s}\n", .{
        graphics,
        transfer,
        if (transfer == graphics) " (the same one)" else " (dedicated)",
    });
}
