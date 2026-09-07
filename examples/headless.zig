// SPDX-License-Identifier: BSL-1.0

//! The smallest complete Vulkan program. Run it with
//! `zig build example-headless`.
//!
//! Library, instance, device, queue - and then all of it down again, in the
//! order that does not crash. No window, no surface, no swapchain: nothing
//! here needs a display, so it runs the same over SSH as it does on a desktop.
//!
//! Sixty lines, and every one of them is something a real program also does.

const std = @import("std");
const Io = std.Io;
const vk = @import("fluxion_vulkan");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // 1. Find Vulkan. `error.NotFound` means no driver is installed, which is
    //    an answer to report rather than a reason to crash.
    var loader = vk.Loader.init() catch |err| switch (err) {
        error.NotFound, error.NotSupported => {
            try out.writeAll("No Vulkan on this machine. Nothing else to do.\n");
            return;
        },
        else => return err,
    };
    defer loader.deinit(); // 6. Last, because everything points into it.

    try out.print("{s}, Vulkan {f}\n", .{ loader.name().?, try loader.apiVersion() });

    // 2. An instance. No layers and no extensions: a headless program needs
    //    neither, and asking for nothing cannot fail for want of it.
    const app: vk.ApplicationInfo = .{
        .application_name = "headless",
        .api_version = vk.v1_0.toInt(),
    };
    const info: vk.InstanceCreateInfo = .{ .application_info = &app };

    const instance = try loader.createInstance(&info, null);
    const inst = try loader.instanceCommands(instance);
    defer inst.destroyInstance(instance, null); // 5.

    // 3. A device. The first one Vulkan listed, which is the driver's
    //    preference and not an answer - weighing them properly is what the
    //    devices example is for.
    const gpus = try vk.enumerate.physicalDevices(gpa, inst, instance);
    if (gpus.len == 0) {
        try out.writeAll("A Vulkan loader, but no devices behind it.\n");
        return;
    }

    const gpu = gpus[0];
    var props: vk.PhysicalDeviceProperties = undefined;
    inst.getPhysicalDeviceProperties(gpu, &props);

    const families = try vk.enumerate.queueFamilies(gpa, inst, gpu);
    const family = vk.queueFamily(families, .{ .compute = true }) orelse {
        try out.print("{s} has no compute queue.\n", .{props.name()});
        return;
    };

    const priorities = [_]f32{1.0};
    const queue_infos = [_]vk.DeviceQueueCreateInfo{.queues(family, &priorities)};
    var device_info: vk.DeviceCreateInfo = .{};
    device_info.setQueues(&queue_infos);

    var device: vk.Device = undefined;
    _ = try inst.createDevice(gpu, &device_info, null, &device).check();

    const dev = try inst.deviceCommands(device);
    defer dev.destroyDevice(device, null); // 4.

    // 4. A queue, taken out of the device rather than created.
    var queue: vk.Queue = undefined;
    dev.getDeviceQueue(device, family, 0, &queue);

    try out.print("{s}, queue family {d}\n", .{ props.name(), family });

    // Real work would go here. There is none, so wait for the nothing to
    // finish - which is what you do before tearing a device down either way.
    _ = try dev.deviceWaitIdle(device).check();

    try out.writeAll("opened and closed cleanly\n");
}
