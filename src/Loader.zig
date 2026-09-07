// SPDX-License-Identifier: CC0-1.0

//! The library, the entry point and the global commands, in one place.
//!
//! This is where a Vulkan program starts. `init` finds the platform's Vulkan
//! library, takes `vkGetInstanceProcAddr` out of it, and loads the four
//! commands that exist before there is an instance. From there:
//!
//! ```zig
//! var loader: vk.Loader = try .init();
//! defer loader.deinit();
//!
//! const instance = try loader.createInstance(&info, null);
//! const inst = try loader.instanceCommands(instance);
//! defer inst.destroyInstance(instance, null);
//!
//! const device_cmds = try inst.deviceCommands(device);
//! ```
//!
//! Nothing here allocates. The two commands that hand back lists take an
//! allocator of their own and say so.
//!
//! **Shutting down, in order.** Every command pointer anywhere - in the global
//! table, in an instance table, in a device table - points into the library
//! this holds open. `deinit` closes it, so it goes last: destroy the device,
//! destroy the instance, and only then `deinit` the loader. A loader built
//! with `adopt` opens nothing and closes nothing, and the order stops
//! mattering.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const commands = @import("commands.zig");
const dispatch = @import("dispatch.zig");
const enumerate = @import("enumerate.zig");
const types = @import("types.zig");
const version = @import("version.zig");

/// See `library` for the platform names and how they are tried.
const Library = @import("library.zig").Library;

const Loader = @This();

/// The open library, or null when the entry point came from somewhere else.
library: ?Library,

/// The one function everything in Vulkan is reached through. Worth keeping:
/// a window library that creates surfaces will ask for it back.
getInstanceProcAddr: dispatch.PfnGetInstanceProcAddr,

/// The commands that exist before there is an instance.
global: commands.Global,

pub const Error = @import("library.zig").Error || dispatch.Error;

// -------------------------------------------------------------------------
// Starting
// -------------------------------------------------------------------------

/// Find the platform's Vulkan library, and load the global commands out of it.
///
/// `error.NotFound` here means no Vulkan library opened under any of the names
/// this platform uses - which almost always means no GPU driver is installed,
/// rather than that the machine has no GPU. It is a thing to report and carry
/// on from, not a thing to crash on.
pub fn init() Error!Loader {
    var lib = try Library.open();
    errdefer lib.close();
    return fromLibrary(lib);
}

/// The same, from one named library rather than the platform's list. For a
/// loader shipped beside the executable, or one named by a setting.
pub fn open(path: [:0]const u8) Error!Loader {
    var lib = try Library.openPath(path);
    errdefer lib.close();
    return fromLibrary(lib);
}

/// Build a loader on a `vkGetInstanceProcAddr` somebody else already has.
///
/// GLFW hands one back from `glfwGetInstanceProcAddress`, and SDL from
/// `SDL_Vulkan_GetVkGetInstanceProcAddr`. Both have already opened the Vulkan
/// library by the time they do, and opening it a second time would leave two
/// handles on it where one is wanted. A loader made this way owns nothing, and
/// `deinit` closes nothing.
pub fn adopt(get_instance_proc_addr: dispatch.PfnGetInstanceProcAddr) Error!Loader {
    return .{
        .library = null,
        .getInstanceProcAddr = get_instance_proc_addr,
        .global = try dispatch.load(commands.Global, .{ .global = get_instance_proc_addr }),
    };
}

fn fromLibrary(lib: Library) Error!Loader {
    var owned = lib;
    const get_instance_proc_addr = try owned.getInstanceProcAddr();
    return .{
        .library = owned,
        .getInstanceProcAddr = get_instance_proc_addr,
        .global = try dispatch.load(commands.Global, .{ .global = get_instance_proc_addr }),
    };
}

/// Close the library, if this loader opened one.
///
/// Every command pointer taken out of it - including the ones in instance and
/// device tables made hours ago - points at unmapped memory afterwards.
pub fn deinit(self: *Loader) void {
    if (self.library) |*lib| lib.close();
    self.* = undefined;
}

/// The name the library opened under, or null for an adopted entry point.
/// `libMoltenVK.dylib` is a different answer from `libvulkan.dylib`, and this
/// is where the difference shows.
pub fn name(self: Loader) ?[:0]const u8 {
    return if (self.library) |lib| lib.name else null;
}

// -------------------------------------------------------------------------
// What this loader can do
// -------------------------------------------------------------------------

/// The highest Vulkan version this loader supports.
///
/// A ceiling, and not a promise about any device: a 1.3 loader in front of a
/// 1.1 driver still reports 1.3. `PhysicalDeviceProperties.api_version` is the
/// number that applies to a particular GPU.
///
/// A loader with no `vkEnumerateInstanceVersion` is a Vulkan 1.0 loader, which
/// is the whole reason that command is declared optional.
pub fn apiVersion(self: Loader) types.Result.Error!version.ApiVersion {
    const query = self.global.enumerateInstanceVersion orelse return version.v1_0;
    var packed_value: u32 = 0;
    _ = try query(&packed_value).check();
    return .fromInt(packed_value);
}

/// Is this loader at least `required`? The patch number is ignored - see
/// `version.ApiVersion.atLeast`.
pub fn supports(self: Loader, required: version.ApiVersion) types.Result.Error!bool {
    return (try self.apiVersion()).atLeast(required);
}

/// Every layer installed on this machine. Yours to free.
pub fn layers(self: Loader, allocator: Allocator) enumerate.Error![]types.LayerProperties {
    return enumerate.instanceLayers(allocator, self.global);
}

/// Every instance extension on offer, or the ones one layer adds. Yours to
/// free.
pub fn extensions(
    self: Loader,
    allocator: Allocator,
    layer: ?[*:0]const u8,
) enumerate.Error![]types.ExtensionProperties {
    return enumerate.instanceExtensions(allocator, self.global, layer);
}

// -------------------------------------------------------------------------
// Getting an instance, and the commands that go with it
// -------------------------------------------------------------------------

/// Create an instance, and hand back the handle.
///
/// Destroying it is `commands.Instance.destroyInstance` - the loader does not
/// keep it, because how long an instance lives is the program's business and
/// not the loader's.
///
/// Two failures worth recognising. `error.ExtensionNotPresent` and
/// `error.LayerNotPresent` mean something in the create info is not installed:
/// ask `extensions` and `layers` first, and `enumerate.firstMissing` will name
/// it. `error.IncompatibleDriver` on macOS means the portability bit -
/// `InstanceCreateFlags.enumerate_portability_khr`, together with the
/// `VK_KHR_portability_enumeration` extension - which MoltenVK requires and
/// nothing else does.
pub fn createInstance(
    self: Loader,
    create_info: *const types.InstanceCreateInfo,
    allocation_callbacks: ?*const types.AllocationCallbacks,
) types.Result.Error!types.Instance {
    var instance: types.Instance = undefined;
    _ = try self.global.createInstance(create_info, allocation_callbacks, &instance).check();
    return instance;
}

/// Where instance-level commands are resolved: through the loader's
/// trampoline, which reads a command's first argument and picks a driver.
///
/// Hand it to `dispatch.load` with a table of your own to load instance
/// commands this library does not declare.
pub fn instanceResolver(self: Loader, instance: types.Instance) dispatch.Resolver {
    return .{ .instance = .{ .get = self.getInstanceProcAddr, .handle = instance } };
}

/// The instance-level commands the loader needs: physical devices, their
/// properties, creating a device, and `vkGetDeviceProcAddr`.
pub fn instanceCommands(
    self: Loader,
    instance: types.Instance,
) dispatch.Error!commands.Instance {
    return dispatch.load(commands.Instance, self.instanceResolver(instance));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const stub = @import("stub.zig");

test "a loader built on a Vulkan that is not there" {
    var loader = try Loader.adopt(stub.getInstanceProcAddr);
    defer loader.deinit();

    // Adopted, so it owns no library and closes none.
    try testing.expectEqual(@as(?[:0]const u8, null), loader.name());
    try testing.expectEqual(@as(?Library, null), loader.library);

    try testing.expectEqual(version.ApiVersion.init(1, 3, 280), try loader.apiVersion());
    try testing.expect(try loader.supports(version.v1_1));
    try testing.expect(!try loader.supports(version.v1_4));
}

test "a Vulkan 1.0 loader is the one without the version command" {
    stub.reset();
    stub.pretend_1_0 = true;
    defer stub.reset();

    var loader = try Loader.adopt(stub.getInstanceProcAddr);
    defer loader.deinit();

    // The command is absent, which is not a failure - it is the answer.
    try testing.expectEqual(@as(?*const fn (*u32) callconv(types.call) types.Result, null), loader.global.enumerateInstanceVersion);
    try testing.expectEqual(version.v1_0, try loader.apiVersion());
    try testing.expect(!try loader.supports(version.v1_1));
}

test "a loader on something that is not Vulkan at all" {
    // An entry point that answers nothing. The three required global commands
    // are not there, so the loader refuses rather than handing back a table of
    // null pointers.
    const Empty = struct {
        fn getProcAddr(_: ?types.Instance, _: [*:0]const u8) callconv(types.call) ?dispatch.PfnVoidFunction {
            return null;
        }
    };
    try testing.expectError(error.CommandNotFound, Loader.adopt(&Empty.getProcAddr));
}

test "the real loader, when this machine has one" {
    var loader = Loader.init() catch return error.SkipZigTest;
    defer loader.deinit();

    // It opened something, and that something is a Vulkan loader.
    try testing.expect(loader.name() != null);
    const reported = try loader.apiVersion();
    try testing.expect(reported.atLeast(version.v1_0));
    try testing.expect(reported.major >= 1);

    // Every Vulkan loader has the surface extension; none has this one.
    const available = try loader.extensions(testing.allocator, null);
    defer testing.allocator.free(available);
    try testing.expect(enumerate.has(available, "VK_KHR_surface"));
    try testing.expect(!enumerate.has(available, "VK_FLUXION_not_a_real_extension"));

    // Layers are a list that is often empty, and that is fine.
    const installed = try loader.layers(testing.allocator);
    defer testing.allocator.free(installed);
    for (installed) |*layer| try testing.expect(layer.name().len > 0);
}
