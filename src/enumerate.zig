// SPDX-License-Identifier: BSL-1.0

//! Vulkan's two-call idiom, done once.
//!
//! Every Vulkan command that hands back a list is called twice: once with a
//! null array to get the count, once with an array that size to fill it.
//! Between the two the answer can change - a layer installed, a GPU plugged in
//! - and the second call says so with `.incomplete` rather than overrunning.
//! Doing it correctly is five lines, and writing them five times is how the
//! fifth ends up wrong.
//!
//! So: one loop, in `collect`, and the six lists a loader needs on top of it.
//! Each returns memory you own and free.
//!
//! On top of that, the two questions anyone actually asks of a list of
//! extension names:
//!
//!   `firstMissing`  is anything I *require* not here? Then stop.
//!   `supported`     which of the ones I would *like* are here? Enable those.
//!
//! Both take the names in the form `InstanceCreateInfo` wants them, so the
//! answer goes straight back into the create info.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const commands = @import("commands.zig");
const types = @import("types.zig");

pub const Error = Allocator.Error || types.Result.Error || error{
    /// The list changed between the count and the fill, over and over. Vulkan
    /// permits this to happen once; a machine where it happens sixteen times
    /// running has something else wrong with it.
    ListKeptChanging,
};

/// How many times a list may change underneath us before we give up.
const max_attempts = 16;

// -------------------------------------------------------------------------
// The lists
// -------------------------------------------------------------------------

/// Every layer installed on this machine. The names go in
/// `InstanceCreateInfo.setLayers`; `VK_LAYER_KHRONOS_validation` is the one
/// worth looking for.
pub fn instanceLayers(
    allocator: Allocator,
    global: commands.Global,
) Error![]types.LayerProperties {
    const Query = struct {
        cmds: commands.Global,
        fn call(self: @This(), count: *u32, into: ?[*]types.LayerProperties) types.Result {
            return self.cmds.enumerateInstanceLayerProperties(count, into);
        }
    };
    return collect(allocator, types.LayerProperties, Query{ .cmds = global }, Query.call);
}

/// Every instance extension the implementation offers, or - with `layer` set -
/// the ones that layer adds on top of it.
///
/// A layer's extensions only exist while that layer is enabled, which is why
/// the two questions are asked separately.
pub fn instanceExtensions(
    allocator: Allocator,
    global: commands.Global,
    layer: ?[*:0]const u8,
) Error![]types.ExtensionProperties {
    const Query = struct {
        cmds: commands.Global,
        layer: ?[*:0]const u8,
        fn call(self: @This(), count: *u32, into: ?[*]types.ExtensionProperties) types.Result {
            return self.cmds.enumerateInstanceExtensionProperties(self.layer, count, into);
        }
    };
    return collect(
        allocator,
        types.ExtensionProperties,
        Query{ .cmds = global, .layer = layer },
        Query.call,
    );
}

/// Every GPU this instance found, in the driver's preferred order - which is
/// a hint and not an answer. See `types.PhysicalDeviceProperties.device_type`.
pub fn physicalDevices(
    allocator: Allocator,
    cmds: commands.Instance,
    instance: types.Instance,
) Error![]types.PhysicalDevice {
    const Query = struct {
        cmds: commands.Instance,
        instance: types.Instance,
        fn call(self: @This(), count: *u32, into: ?[*]types.PhysicalDevice) types.Result {
            return self.cmds.enumeratePhysicalDevices(self.instance, count, into);
        }
    };
    return collect(
        allocator,
        types.PhysicalDevice,
        Query{ .cmds = cmds, .instance = instance },
        Query.call,
    );
}

/// Every extension one physical device offers. These are the names that go in
/// `DeviceCreateInfo.setExtensions` - `VK_KHR_swapchain` above all.
pub fn deviceExtensions(
    allocator: Allocator,
    cmds: commands.Instance,
    physical_device: types.PhysicalDevice,
    layer: ?[*:0]const u8,
) Error![]types.ExtensionProperties {
    const Query = struct {
        cmds: commands.Instance,
        physical_device: types.PhysicalDevice,
        layer: ?[*:0]const u8,
        fn call(self: @This(), count: *u32, into: ?[*]types.ExtensionProperties) types.Result {
            return self.cmds.enumerateDeviceExtensionProperties(
                self.physical_device,
                self.layer,
                count,
                into,
            );
        }
    };
    return collect(
        allocator,
        types.ExtensionProperties,
        Query{ .cmds = cmds, .physical_device = physical_device, .layer = layer },
        Query.call,
    );
}

/// The queue families of one physical device. A family's index is its position
/// in this slice, which is why the whole slice comes back.
///
/// This one command returns nothing rather than a result, because it cannot
/// fail: the count is fixed for the lifetime of the device.
pub fn queueFamilies(
    allocator: Allocator,
    cmds: commands.Instance,
    physical_device: types.PhysicalDevice,
) Allocator.Error![]types.QueueFamilyProperties {
    var count: u32 = 0;
    cmds.getPhysicalDeviceQueueFamilyProperties(physical_device, &count, null);
    if (count == 0) return allocator.alloc(types.QueueFamilyProperties, 0);

    const families = try allocator.alloc(types.QueueFamilyProperties, count);
    errdefer allocator.free(families);
    cmds.getPhysicalDeviceQueueFamilyProperties(physical_device, &count, families.ptr);

    if (count < families.len) return allocator.realloc(families, count);
    return families;
}

// -------------------------------------------------------------------------
// Reading the answers
// -------------------------------------------------------------------------

/// Is `name` among these extensions?
pub fn has(list: []const types.ExtensionProperties, name: []const u8) bool {
    for (list) |*entry| {
        if (std.mem.eql(u8, entry.name(), name)) return true;
    }
    return false;
}

/// Is `name` among these layers?
pub fn hasLayer(list: []const types.LayerProperties, name: []const u8) bool {
    for (list) |*entry| {
        if (std.mem.eql(u8, entry.name(), name)) return true;
    }
    return false;
}

/// The first name in `wanted` that `list` does not have, or null if it has
/// them all.
///
/// For the extensions a program cannot run without: failing here, by name,
/// beats `error.ExtensionNotPresent` from `vkCreateInstance` with no
/// indication of which one.
///
/// ```zig
/// const required = [_][*:0]const u8{ "VK_KHR_surface", surface_extension };
/// if (enumerate.firstMissing(available, &required)) |name| {
///     std.log.err("this driver has no {s}", .{name});
///     return error.Unsupported;
/// }
/// ```
pub fn firstMissing(
    list: []const types.ExtensionProperties,
    wanted: []const [*:0]const u8,
) ?[]const u8 {
    for (wanted) |name| {
        const text = std.mem.span(name);
        if (!has(list, text)) return text;
    }
    return null;
}

/// The entries of `wanted` that `list` actually has, written into `into` and
/// returned as the prefix that was used.
///
/// For extensions a program would like but can do without. `into` must have
/// room for `wanted.len`, and the result borrows it, so it has to outlive the
/// create info.
///
/// ```zig
/// var buffer: [3][*:0]const u8 = undefined;
/// const enabled = enumerate.supported(available, &optional, &buffer);
/// info.setExtensions(enabled);
/// ```
pub fn supported(
    list: []const types.ExtensionProperties,
    wanted: []const [*:0]const u8,
    into: [][*:0]const u8,
) [][*:0]const u8 {
    std.debug.assert(into.len >= wanted.len);
    var n: usize = 0;
    for (wanted) |name| {
        if (has(list, std.mem.span(name))) {
            into[n] = name;
            n += 1;
        }
    }
    return into[0..n];
}

/// What a family can really do, which is not quite what it says.
///
/// Vulkan lets a driver leave the transfer bit off a family that does graphics
/// or compute, because those already imply it - "reporting the
/// `VK_QUEUE_TRANSFER_BIT` capability separately for that queue family is
/// optional". Plenty of drivers take that option, so a program asking for a
/// transfer queue on hardware with no dedicated copy engine would be told
/// there is none at all.
pub fn capabilities(family: types.QueueFamilyProperties) types.QueueFlags {
    var flags = family.queue_flags;
    if (flags.graphics or flags.compute) flags.transfer = true;
    return flags;
}

/// The index of the queue family that can do everything in `wanted`, choosing
/// the one that can do as little else as possible.
///
/// The tie-break is what finds a dedicated transfer or compute queue: on
/// hardware that has one, it is the family with `transfer` and nothing else,
/// sitting behind a family that can do transfers along with everything else.
/// Asking for `.{ .graphics = true }` gets the graphics family either way,
/// since there is almost never more than one.
///
/// Both the match and the tie-break go through `capabilities`, so a family
/// that can transfer without saying so counts - and counts as one bit wider
/// than it looks, which is what keeps a dedicated copy queue ahead of it.
pub fn queueFamily(
    families: []const types.QueueFamilyProperties,
    wanted: types.QueueFlags,
) ?u32 {
    var best: ?u32 = null;
    var fewest: usize = std.math.maxInt(usize);
    for (families, 0..) |family, index| {
        if (family.queue_count == 0) continue;

        const can = capabilities(family);
        if (!can.contains(wanted)) continue;

        const breadth = @popCount(@as(u32, @bitCast(can)));
        if (breadth < fewest) {
            fewest = breadth;
            best = @intCast(index);
        }
    }
    return best;
}

// -------------------------------------------------------------------------
// The loop itself
// -------------------------------------------------------------------------

/// Count, allocate, fill - and start over if the answer moved in between.
///
/// `query` is the Vulkan command with its handles already bound up in
/// `context`, so this loop never has to know which list it is fetching.
fn collect(
    allocator: Allocator,
    comptime T: type,
    context: anytype,
    comptime query: fn (@TypeOf(context), *u32, ?[*]T) types.Result,
) Error![]T {
    for (0..max_attempts) |_| {
        var count: u32 = 0;
        _ = try query(context, &count, null).check();
        if (count == 0) return allocator.alloc(T, 0);

        const items = try allocator.alloc(T, count);
        errdefer allocator.free(items);

        // The second call writes the count back: fewer if the list shrank,
        // and `.incomplete` if it grew past what was allocated.
        const result = try query(context, &count, items.ptr).check();
        if (result == .incomplete) {
            allocator.free(items);
            continue;
        }

        if (count < items.len) return allocator.realloc(items, count);
        return items;
    }
    return error.ListKeptChanging;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// A list that behaves however a test needs it to.
const Source = struct {
    entries: []const u32,
    /// How many more times the count will be a lie, to force a retry.
    lies: usize = 0,

    fn call(self: *Source, count: *u32, into: ?[*]u32) types.Result {
        if (into == null) {
            // The count query, understating the answer while `lies` says to.
            count.* = @intCast(if (self.lies > 0) self.entries.len - 1 else self.entries.len);
            return .success;
        }
        if (count.* < self.entries.len) {
            self.lies -|= 1;
            @memcpy(into.?[0..count.*], self.entries[0..count.*]);
            return .incomplete;
        }
        count.* = @intCast(self.entries.len);
        @memcpy(into.?[0..self.entries.len], self.entries);
        return .success;
    }
};

fn callSource(source: *Source, count: *u32, into: ?[*]u32) types.Result {
    return source.call(count, into);
}

test "the two calls become one list" {
    var source: Source = .{ .entries = &.{ 10, 20, 30 } };
    const list = try collect(testing.allocator, u32, &source, callSource);
    defer testing.allocator.free(list);

    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, list);
}

test "an empty list is an empty slice, not a null one" {
    var source: Source = .{ .entries = &.{} };
    const list = try collect(testing.allocator, u32, &source, callSource);
    defer testing.allocator.free(list);

    try testing.expectEqual(@as(usize, 0), list.len);
}

test "a list that grows between the calls is fetched again" {
    // The count query understates by one, so the fill returns `.incomplete`
    // and the whole thing starts over - which is what happens when a GPU is
    // plugged in at exactly the wrong moment.
    var source: Source = .{ .entries = &.{ 1, 2, 3, 4 }, .lies = 1 };
    const list = try collect(testing.allocator, u32, &source, callSource);
    defer testing.allocator.free(list);

    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, list);
    try testing.expectEqual(@as(usize, 0), source.lies);
}

test "a list that never settles gives up rather than spinning" {
    var source: Source = .{ .entries = &.{ 1, 2, 3 }, .lies = std.math.maxInt(usize) };
    try testing.expectError(
        error.ListKeptChanging,
        collect(testing.allocator, u32, &source, callSource),
    );
}

test "a failure comes back as an error, not as an empty list" {
    const Failing = struct {
        fn call(_: void, count: *u32, into: ?[*]u32) types.Result {
            _ = count;
            _ = into;
            return .error_out_of_host_memory;
        }
    };
    try testing.expectError(
        error.OutOfHostMemory,
        collect(testing.allocator, u32, {}, Failing.call),
    );
}

/// An extension list built by hand, for the questions below.
fn extensions(comptime names: []const []const u8) [names.len]types.ExtensionProperties {
    var list: [names.len]types.ExtensionProperties = undefined;
    for (names, 0..) |name, i| {
        list[i] = .{ .extension_name = @splat(0), .spec_version = 1 };
        @memcpy(list[i].extension_name[0..name.len], name);
    }
    return list;
}

test "the required extensions are checked by name" {
    const available = extensions(&.{ "VK_KHR_surface", "VK_KHR_win32_surface", "VK_EXT_debug_utils" });

    try testing.expect(has(&available, "VK_KHR_surface"));
    try testing.expect(!has(&available, "VK_KHR_swapchain"));
    // A prefix is not a match, and neither is a name with the padding on it.
    try testing.expect(!has(&available, "VK_KHR_surf"));
    try testing.expect(!has(&available, "VK_KHR_surface_more"));

    const required = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_win32_surface" };
    try testing.expectEqual(@as(?[]const u8, null), firstMissing(&available, &required));

    const too_much = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_xlib_surface" };
    try testing.expectEqualStrings("VK_KHR_xlib_surface", firstMissing(&available, &too_much).?);
}

test "the optional extensions come back as the ones that are there" {
    const available = extensions(&.{ "VK_KHR_surface", "VK_EXT_debug_utils" });

    const wanted = [_][*:0]const u8{
        "VK_EXT_debug_utils",
        "VK_KHR_portability_enumeration",
        "VK_KHR_surface",
    };
    var buffer: [wanted.len][*:0]const u8 = undefined;
    const enabled = supported(&available, &wanted, &buffer);

    // In the order asked, and only the ones that exist.
    try testing.expectEqual(@as(usize, 2), enabled.len);
    try testing.expectEqualStrings("VK_EXT_debug_utils", std.mem.span(enabled[0]));
    try testing.expectEqualStrings("VK_KHR_surface", std.mem.span(enabled[1]));

    // Nothing wanted, nothing enabled.
    try testing.expectEqual(@as(usize, 0), supported(&available, &.{}, &buffer).len);
}

test "the narrowest family that can do the job" {
    // What a discrete GPU usually looks like: one family that does everything,
    // one for transfers, one for compute.
    const families = [_]types.QueueFamilyProperties{
        .{
            .queue_flags = .{ .graphics = true, .compute = true, .transfer = true, .sparse_binding = true },
            .queue_count = 16,
            .timestamp_valid_bits = 64,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
        .{
            .queue_flags = .{ .transfer = true, .sparse_binding = true },
            .queue_count = 2,
            .timestamp_valid_bits = 64,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
        .{
            .queue_flags = .{ .compute = true, .transfer = true, .sparse_binding = true },
            .queue_count = 8,
            .timestamp_valid_bits = 64,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
    };

    // Graphics is only on the first family, so there is nothing to choose.
    try testing.expectEqual(@as(u32, 0), queueFamily(&families, .{ .graphics = true }).?);
    // Transfer is on all three, and the dedicated one is the narrowest.
    try testing.expectEqual(@as(u32, 1), queueFamily(&families, .{ .transfer = true }).?);
    // Compute is on two, and the one that cannot draw wins.
    try testing.expectEqual(@as(u32, 2), queueFamily(&families, .{ .compute = true }).?);
    // Both at once is only the first.
    try testing.expectEqual(
        @as(u32, 0),
        queueFamily(&families, .{ .graphics = true, .compute = true }).?,
    );
    // And nothing here does video.
    try testing.expectEqual(@as(?u32, null), queueFamily(&families, .{ .video_decode_khr = true }));
    try testing.expectEqual(@as(?u32, null), queueFamily(&.{}, .{ .graphics = true }));
}

test "a family that can transfer without saying so still counts" {
    // A driver is allowed to leave the transfer bit off a graphics family,
    // and several do. This card has no dedicated copy engine and no transfer
    // bit anywhere - and can obviously still copy.
    const quiet = [_]types.QueueFamilyProperties{
        .{
            .queue_flags = .{ .graphics = true, .compute = true },
            .queue_count = 4,
            .timestamp_valid_bits = 64,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
    };
    try testing.expect(!quiet[0].queue_flags.transfer);
    try testing.expect(capabilities(quiet[0]).transfer);
    try testing.expectEqual(@as(u32, 0), queueFamily(&quiet, .{ .transfer = true }).?);

    // And a dedicated copy queue still wins over one that only implies it.
    const with_copy = [_]types.QueueFamilyProperties{
        quiet[0],
        .{
            .queue_flags = .{ .transfer = true },
            .queue_count = 2,
            .timestamp_valid_bits = 64,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
    };
    try testing.expectEqual(@as(u32, 1), queueFamily(&with_copy, .{ .transfer = true }).?);
    try testing.expectEqual(@as(u32, 0), queueFamily(&with_copy, .{ .graphics = true }).?);

    // The implication runs one way only: compute is not implied by anything.
    const copy_only = [_]types.QueueFamilyProperties{with_copy[1]};
    try testing.expectEqual(@as(?u32, null), queueFamily(&copy_only, .{ .compute = true }));
    try testing.expect(!capabilities(copy_only[0]).graphics);
}

test "a family with no queues in it is not a candidate" {
    const families = [_]types.QueueFamilyProperties{
        .{
            .queue_flags = .{ .graphics = true },
            .queue_count = 0,
            .timestamp_valid_bits = 0,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
        .{
            .queue_flags = .{ .graphics = true, .compute = true },
            .queue_count = 1,
            .timestamp_valid_bits = 64,
            .min_image_transfer_granularity = .{ .width = 1, .height = 1, .depth = 1 },
        },
    };
    try testing.expectEqual(@as(u32, 1), queueFamily(&families, .{ .graphics = true }).?);
}
