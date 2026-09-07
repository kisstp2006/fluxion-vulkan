// SPDX-License-Identifier: CC0-1.0

//! Vulkan you did not open yourself. Run it with `zig build example-adopt`.
//!
//! `Loader.init` opens the platform's Vulkan library. Often something else
//! already did, or there is no library at all because Vulkan is linked into
//! the executable - and opening it a second time would leave two handles on it
//! where one is wanted, or fail outright.
//!
//! `Loader.adopt` takes a `vkGetInstanceProcAddr` from anywhere. The loader
//! then owns nothing, `deinit` closes nothing, and everything else is the
//! same: the same three scopes, the same tables, the same commands. This file
//! shows the four places that pointer comes from, and runs two of them.
//!
//! It is also the way in on a platform where `library.backend` is `.none` -
//! `wasm32`, or anything else `std.DynLib` does not cover. Nothing in this
//! file touches the platform.

const std = @import("std");
const Io = std.Io;
const vk = @import("fluxion_vulkan");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("this platform loads libraries by: {t}\n", .{vk.library.backend});

    try one(out);
    try two(out);
    try three(out);
    try four(out);
}

// -------------------------------------------------------------------------
// 1. A library you opened yourself
// -------------------------------------------------------------------------

/// For when the name comes from a setting, or the loader ships beside the
/// executable, or you want the handle for something else as well.
///
/// The `Library` is yours: `Loader.deinit` will not close it, and closing it
/// while the instance is alive is the one ordering mistake to avoid.
fn one(out: *Io.Writer) !void {
    try out.writeAll("\n--- 1. a library opened by hand ---\n");

    var lib = vk.library.open() catch {
        try out.writeAll("no Vulkan library here; nothing to open\n");
        return;
    };
    defer lib.close(); // Ours to close, and last.

    var loader = try vk.Loader.adopt(try vk.library.getInstanceProcAddr(&lib));
    defer loader.deinit(); // Closes nothing: this loader owns nothing.

    try out.print("opened {s}, Vulkan {f}\n", .{ lib.name, try loader.apiVersion() });
    try out.print("loader owns a library: {}\n", .{loader.name() != null});
}

// -------------------------------------------------------------------------
// 2. A window library that already loaded it
// -------------------------------------------------------------------------

/// GLFW and SDL both load Vulkan to create surfaces, and both hand the entry
/// point back. Declaring the function is all it takes:
///
/// ```zig
/// extern fn glfwGetInstanceProcAddress(
///     instance: ?vk.Instance,
///     name: [*:0]const u8,
/// ) callconv(vk.call) ?vk.dispatch.PfnVoidFunction;
///
/// var loader = try vk.Loader.adopt(&glfwGetInstanceProcAddress);
/// ```
///
/// SDL returns the pointer rather than being it, so it is one step further:
///
/// ```zig
/// extern fn SDL_Vulkan_GetVkGetInstanceProcAddr() callconv(vk.call) ?vk.dispatch.PfnGetInstanceProcAddr;
///
/// var loader = try vk.Loader.adopt(SDL_Vulkan_GetVkGetInstanceProcAddr() orelse
///     return error.NoVulkan);
/// ```
///
/// Neither is linked here, so this only says so.
fn two(out: *Io.Writer) !void {
    try out.writeAll("\n--- 2. from GLFW or SDL ---\n");
    try out.writeAll(
        \\Not linked in this example. See the doc comment on `two` for the two
        \\declarations; both end in `Loader.adopt` and neither opens a second
        \\library.
        \\
    );
}

// -------------------------------------------------------------------------
// 3. Vulkan linked into the executable
// -------------------------------------------------------------------------

/// A static MoltenVK on iOS, or `vulkan-1.lib` on Windows: there is no library
/// to find, because the entry point is an ordinary symbol in the program.
///
/// ```zig
/// extern fn vkGetInstanceProcAddr(
///     instance: ?vk.Instance,
///     name: [*:0]const u8,
/// ) callconv(vk.call) ?vk.dispatch.PfnVoidFunction;
///
/// var loader = try vk.Loader.adopt(&vkGetInstanceProcAddr);
/// ```
///
/// This is the only form that works on iOS, where an app may not dlopen code
/// it did not ship. Declaring it here would make the example fail to link on
/// every machine without a Vulkan import library, so it stays a comment.
fn three(out: *Io.Writer) !void {
    try out.writeAll("\n--- 3. statically linked ---\n");
    try out.writeAll(
        \\Not linked here either - an `extern fn vkGetInstanceProcAddr` needs
        \\something to resolve against at link time. On iOS this is the only
        \\way in, and it is three lines.
        \\
    );
}

// -------------------------------------------------------------------------
// 4. Something that is not Vulkan at all
// -------------------------------------------------------------------------

/// The loader has no way to tell where a pointer came from, and does not try.
/// Anything with the right signature will do - which is what makes a Vulkan
/// program testable without a GPU: a recording implementation, a version that
/// pretends to be older than it is, or the twelve lines below.
///
/// This one has exactly the four global commands and nothing else, so the
/// global table loads and the instance table would not.
fn four(out: *Io.Writer) !void {
    try out.writeAll("\n--- 4. a Vulkan written in this file ---\n");

    var loader = try vk.Loader.adopt(&Fake.getInstanceProcAddr);
    defer loader.deinit();

    try out.print("version   {f}\n", .{try loader.apiVersion()});

    var count: u32 = 0;
    _ = try loader.global.enumerateInstanceExtensionProperties(null, &count, null).check();
    try out.print("extensions {d}\n", .{count});

    // And the instance table refuses, by name, because this Vulkan does not
    // go that far.
    const info: vk.InstanceCreateInfo = .{};
    const instance = try loader.createInstance(&info, null);
    var report: vk.dispatch.Report = .{};
    if (vk.dispatch.loadReport(vk.InstanceCommands, loader.instanceResolver(instance), &report)) |_| {
        try out.writeAll("instance table loaded, which it should not have\n");
    } else |err| {
        try out.print("instance  {t}: {s}\n", .{ err, report.missing.? });
    }
}

/// Four commands, which is enough to be a loader and not enough to be a Vulkan.
const Fake = struct {
    fn getInstanceProcAddr(
        instance: ?vk.Instance,
        name: [*:0]const u8,
    ) callconv(vk.call) ?vk.dispatch.PfnVoidFunction {
        _ = instance;
        const wanted = std.mem.span(name);
        if (std.mem.eql(u8, wanted, "vkCreateInstance")) return @ptrCast(&createInstance);
        if (std.mem.eql(u8, wanted, "vkEnumerateInstanceVersion")) return @ptrCast(&version);
        if (std.mem.eql(u8, wanted, "vkEnumerateInstanceExtensionProperties"))
            return @ptrCast(&extensions);
        if (std.mem.eql(u8, wanted, "vkEnumerateInstanceLayerProperties"))
            return @ptrCast(&layers);
        return null;
    }

    fn createInstance(
        _: *const vk.InstanceCreateInfo,
        _: ?*const vk.AllocationCallbacks,
        instance: *vk.Instance,
    ) callconv(vk.call) vk.Result {
        instance.* = @ptrFromInt(0xF1);
        return .success;
    }

    fn version(value: *u32) callconv(vk.call) vk.Result {
        value.* = vk.ApiVersion.init(1, 2, 0).toInt();
        return .success;
    }

    fn extensions(
        _: ?[*:0]const u8,
        count: *u32,
        into: ?[*]vk.ExtensionProperties,
    ) callconv(vk.call) vk.Result {
        _ = into;
        count.* = 0;
        return .success;
    }

    fn layers(count: *u32, into: ?[*]vk.LayerProperties) callconv(vk.call) vk.Result {
        _ = into;
        count.* = 0;
        return .success;
    }
};
