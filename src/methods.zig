// SPDX-License-Identifier: BSL-1.0

//! The methods this library has always given its types, attached to the
//! generated ones.
//!
//! The generator writes types from the registry, and the registry knows nothing
//! about `props.name()` or `info.setExtensions(...)`. These are the few that are
//! written by hand: each is `methods.<Type>.<name>`, and `wanted.zon` lists which
//! generated type gets which, so that they sit inside it as declarations.
//!
//! ```zig
//! .{ .type = "VkPhysicalDeviceProperties", .decls = .{"name"} },
//! ```
//!
//! makes `props.name()` work on `PhysicalDeviceProperties`. Anything that is a
//! function of the registry alone - `Result.check`, `QueueFlags.contains` - is
//! generated and not here.

const std = @import("std");
const gen = @import("gen/types.zig");
const hand = @import("types.zig");

/// What kind of hardware a physical device is. The usual reason to look:
/// preferring `discrete_gpu` over the integrated one sitting next to it.
pub const PhysicalDeviceType = struct {
    /// A short name, for printing.
    pub fn label(self: gen.PhysicalDeviceType) []const u8 {
        return switch (self) {
            .other => "other",
            .integrated_gpu => "integrated GPU",
            .discrete_gpu => "discrete GPU",
            .virtual_gpu => "virtual GPU",
            .cpu => "CPU",
            _ => "unrecognised",
        };
    }
};

/// One entry of what `vkEnumerateInstanceExtensionProperties` and its device
/// counterpart return.
pub const ExtensionProperties = struct {
    /// The name, without the zero padding behind it.
    pub fn name(self: *const gen.ExtensionProperties) []const u8 {
        return hand.cstr(&self.extension_name);
    }
};

/// One entry of what `vkEnumerateInstanceLayerProperties` returns.
pub const LayerProperties = struct {
    pub fn name(self: *const gen.LayerProperties) []const u8 {
        return hand.cstr(&self.layer_name);
    }

    pub fn describe(self: *const gen.LayerProperties) []const u8 {
        return hand.cstr(&self.description);
    }
};

/// Who a physical device is, and what it will put up with.
pub const PhysicalDeviceProperties = struct {
    pub fn name(self: *const gen.PhysicalDeviceProperties) []const u8 {
        return hand.cstr(&self.device_name);
    }
};

/// Every kind of memory a device has, and the heaps they come out of.
///
/// Both arrays are fixed-width and mostly empty; read them through `types` and
/// `heaps` rather than to the end.
pub const PhysicalDeviceMemoryProperties = struct {
    pub fn types(self: *const gen.PhysicalDeviceMemoryProperties) []const gen.MemoryType {
        return self.memory_types[0..self.memory_type_count];
    }

    pub fn heaps(self: *const gen.PhysicalDeviceMemoryProperties) []const gen.MemoryHeap {
        return self.memory_heaps[0..self.memory_heap_count];
    }

    /// The size of the largest device-local heap: the number people mean when
    /// they ask how much video memory a card has.
    pub fn deviceLocalBytes(self: *const gen.PhysicalDeviceMemoryProperties) gen.DeviceSize {
        var largest: gen.DeviceSize = 0;
        for (heaps(self)) |heap| {
            if (heap.flags.device_local and heap.size > largest) largest = heap.size;
        }
        return largest;
    }
};

pub const InstanceCreateInfo = struct {
    /// Set the pointer and the count from one slice, so the two cannot
    /// disagree.
    pub fn setLayers(self: *gen.InstanceCreateInfo, names: []const [*:0]const u8) void {
        self.enabled_layer_count = @intCast(names.len);
        self.enabled_layer_names = names.ptr;
    }

    pub fn setExtensions(self: *gen.InstanceCreateInfo, names: []const [*:0]const u8) void {
        self.enabled_extension_count = @intCast(names.len);
        self.enabled_extension_names = names.ptr;
    }
};

pub const DeviceCreateInfo = struct {
    pub fn setQueues(self: *gen.DeviceCreateInfo, infos: []const gen.DeviceQueueCreateInfo) void {
        self.queue_create_info_count = @intCast(infos.len);
        self.queue_create_infos = infos.ptr;
    }

    pub fn setExtensions(self: *gen.DeviceCreateInfo, names: []const [*:0]const u8) void {
        self.enabled_extension_count = @intCast(names.len);
        self.enabled_extension_names = names.ptr;
    }
};

pub const DeviceQueueCreateInfo = struct {
    /// One queue per entry in `priorities`.
    ///
    /// ```zig
    /// const one = [_]f32{1.0};
    /// const queue_info: vk.DeviceQueueCreateInfo = .queues(family, &one);
    /// ```
    pub fn queues(family_index: u32, priorities: []const f32) gen.DeviceQueueCreateInfo {
        return .{
            .queue_family_index = family_index,
            .queue_count = @intCast(priorities.len),
            .queue_priorities = priorities.ptr,
        };
    }
};
