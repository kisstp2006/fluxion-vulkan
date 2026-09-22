// SPDX-License-Identifier: BSL-1.0

//! How the registry's names become this library's.
//!
//! The rules are the ones `types.zig` already followed by hand, written down:
//!
//!   * types lose their `Vk`, and keep their vendor tag: `VkSwapchainKHR` is
//!     `SwapchainKHR`, `PFN_vkAllocationFunction` is `PfnAllocationFunction`;
//!   * members and parameters are `snake_case`, and lose the Hungarian
//!     prefix the registry gives a pointer: `pNext` is `next`, `ppEnabledLayerNames`
//!     is `enabled_layer_names`, `pfnAllocation` is `allocation`;
//!   * enumerants lose the enum's own name and are lower-cased:
//!     `VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL` is `.transfer_src_optimal`;
//!   * a flag bit also loses its `_BIT`, and a vendor tag that the enum's own
//!     name does not carry stays: `VK_QUEUE_VIDEO_DECODE_BIT_KHR` is
//!     `.video_decode_khr`, while `VK_PRESENT_MODE_FIFO_KHR` is `.fifo`;
//!   * commands are the registry's name without `vk` and with the first letter
//!     lower-cased, which is exactly what `dispatch` does the other way.
//!
//! Nothing here knows a Vulkan name. It only knows how names are written.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// `camelCase` to `snake_case`, the way `types.zig` reads Vulkan's names:
///
///   * a capital after a lower-case letter starts a word: `queueFlags`;
///   * an acronym is one word, and the capital that starts the next word
///     ends it: `pipelineCacheUUID`, `residencyStandard2DBlockShape`;
///   * digits stay with the letters before them - `uint32`, `etc2` - unless
///     what follows them is a capital, when they start a word of their own:
///     `maxImageDimension1D` is `max_image_dimension_1d` and
///     `sparseResidency2Samples` is `sparse_residency_2_samples`.
pub fn snake(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        const prev: u8 = if (i > 0) name[i - 1] else 0;
        const next: u8 = if (i + 1 < name.len) name[i + 1] else 0;

        const boundary = blk: {
            if (i == 0 or prev == '_') break :blk false;
            if (isUpper(c)) {
                if (isLower(prev)) break :blk true;
                if (isUpper(prev)) break :blk isLower(next);
                if (isDigit(prev)) break :blk isLower(next);
                break :blk false;
            }
            if (isDigit(c)) {
                if (isDigit(prev)) break :blk false;
                if (isLower(prev)) {
                    // A run of digits starts a word when a capital follows it.
                    var j = i;
                    while (j < name.len and isDigit(name[j])) j += 1;
                    break :blk j < name.len and isUpper(name[j]);
                }
                break :blk false;
            }
            break :blk false;
        };
        if (boundary) try out.append(arena, '_');
        try out.append(arena, std.ascii.toLower(c));
    }
    return out.items;
}

/// `PhysicalDeviceType` as `PHYSICAL_DEVICE_TYPE`, for finding where an enum's
/// own name ends in the names of its values. Unlike `snake`, a digit is always
/// a word of its own here: `PipelineStage2` is `PIPELINE_STAGE_2`, which is how
/// the registry writes `VK_PIPELINE_STAGE_2_COPY_BIT`.
pub fn upperSnake(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        const prev: u8 = if (i > 0) name[i - 1] else 0;
        const next: u8 = if (i + 1 < name.len) name[i + 1] else 0;
        const boundary = i > 0 and blk: {
            if (isUpper(c)) break :blk isLower(prev) or isDigit(prev) or (isUpper(prev) and isLower(next));
            if (isDigit(c)) break :blk !isDigit(prev);
            break :blk false;
        };
        if (boundary) try out.append(arena, '_');
        try out.append(arena, std.ascii.toUpper(c));
    }
    return out.items;
}

/// `OUT_OF_HOST_MEMORY` as `OutOfHostMemory`, for the names of errors.
pub fn pascal(arena: Allocator, upper: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var new_word = true;
    for (upper) |c| {
        if (c == '_') {
            new_word = true;
            continue;
        }
        try out.append(arena, if (new_word) std.ascii.toUpper(c) else std.ascii.toLower(c));
        new_word = false;
    }
    return out.items;
}

/// A member or parameter name, with its Hungarian prefix off.
///
/// The registry marks a pointer with `p` (one level), `pp` (two), and a
/// function pointer with `pfn`, and that is information the *type* already
/// carries. `depth` is how many `*` the declaration has; a name is only
/// stripped when the letter after the prefix is a capital, so `pipelineCache`
/// is left alone.
pub fn memberName(arena: Allocator, name: []const u8, depth: usize, is_function_pointer: bool) Allocator.Error![]const u8 {
    var rest = name;
    if (is_function_pointer) {
        if (std.mem.startsWith(u8, rest, "pfn") and rest.len > 3 and isUpper(rest[3])) rest = rest[3..];
    } else {
        // One `p` per level of pointer, and only when a capital follows the
        // run: `ppEnabledLayerNames` and `pName` are Hungarian, `pipeline` is
        // not.
        var n: usize = 0;
        while (n < depth and n < rest.len and rest[n] == 'p') n += 1;
        if (n > 0 and n < rest.len and isUpper(rest[n])) rest = rest[n..];
    }
    // The first letter is a capital now, and `snake` lower-cases it.
    return snake(arena, rest);
}

/// The name of a type in this library: `Vk` off the front, the tag kept.
/// Function pointer types are `pfnTypeName`'s.
pub fn typeName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "Vk") and name.len > 2 and isUpper(name[2])) return name[2..];
    return name;
}

/// `PFN_vkAllocationFunction` as `PfnAllocationFunction`.
pub fn pfnTypeName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, name, "PFN_vk"));
    return std.fmt.allocPrint(arena, "Pfn{s}", .{name["PFN_vk".len..]});
}

/// A command as a table field: `vkCmdDraw` is `cmdDraw`.
pub fn commandField(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, name, "vk"));
    const rest = try arena.dupe(u8, name[2..]);
    rest[0] = std.ascii.toLower(rest[0]);
    return rest;
}

/// `VK_MAX_EXTENSION_NAME_SIZE` as `max_extension_name_size`.
pub fn constantName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const rest = if (std.mem.startsWith(u8, name, "VK_")) name[3..] else name;
    const out = try arena.alloc(u8, rest.len);
    for (rest, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn isTag(tags: []const []const u8, word: []const u8) bool {
    for (tags) |t| if (std.mem.eql(u8, t, word)) return true;
    return false;
}

/// The vendor tag a name ends in - `KHR` in `VkSwapchainKHR` - or null. `tags`
/// is the registry's own list of vendors.
pub fn trailingTag(name: []const u8, tags: []const []const u8) ?[]const u8 {
    // A tag is the trailing run of capitals and digits after the last
    // lower-case letter: `KHR`, `EXT`, `NV`, `AMDX`. Try each split, longest
    // first, so that `...FlagBitsEXT` finds `EXT` and not `T`.
    var start = name.len;
    while (start > 0 and (isUpper(name[start - 1]) or isDigit(name[start - 1]))) start -= 1;
    var i = start;
    while (i < name.len) : (i += 1) {
        if (isTag(tags, name[i..])) return name[i..];
    }
    return null;
}

/// The vendor tag on an `UPPER_SNAKE` name: `_KHR` in `VK_SUBOPTIMAL_KHR`.
pub fn trailingUpperTag(name: []const u8, tags: []const []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const tag = name[at + 1 ..];
    return if (isTag(tags, tag)) tag else null;
}

/// The Zig spelling of one enumerant.
///
/// `enum_name` is the registry's name for the type (`VkQueueFlagBits`),
/// `value_name` the enumerant (`VK_QUEUE_VIDEO_DECODE_BIT_KHR`). The result is
/// what stays once the enum's own name is taken off the front, the tag and
/// `_BIT` come off the back, and the tag goes back on if the enum did not
/// carry it.
///
/// `tags` is the registry's list of vendor tags.
pub fn enumerantName(
    arena: Allocator,
    enum_name: []const u8,
    value_name: []const u8,
    is_flag_bit: bool,
    tags: []const []const u8,
) Allocator.Error![]const u8 {
    // The enum's own name, without `Vk`, without `FlagBits`, without its tag.
    var base = if (std.mem.startsWith(u8, enum_name, "Vk")) enum_name[2..] else enum_name;
    const enum_tag = trailingTag(base, tags);
    if (enum_tag) |t| base = base[0 .. base.len - t.len];
    if (is_flag_bit) {
        if (std.mem.indexOf(u8, base, "FlagBits")) |at| {
            base = try std.mem.concat(arena, u8, &.{ base[0..at], base[at + "FlagBits".len ..] });
        }
    }

    const prefix = try std.fmt.allocPrint(arena, "VK_{s}_", .{try upperSnake(arena, base)});

    var rest = value_name;
    if (std.mem.startsWith(u8, rest, prefix)) {
        rest = rest[prefix.len..];
    } else if (std.mem.startsWith(u8, rest, "VK_")) {
        // `VkResult`'s values are `VK_SUCCESS` and `VK_ERROR_*`: the enum's
        // name is nowhere in them.
        rest = rest[3..];
    }

    const value_tag = trailingUpperTag(rest, tags);
    if (value_tag) |t| rest = rest[0 .. rest.len - t.len - 1];
    if (is_flag_bit and std.mem.endsWith(u8, rest, "_BIT")) rest = rest[0 .. rest.len - "_BIT".len];

    var out: std.ArrayList(u8) = .empty;
    for (rest) |c| try out.append(arena, std.ascii.toLower(c));
    if (value_tag) |t| {
        // Keep the tag unless the enum carries the same one.
        if (enum_tag == null or !std.mem.eql(u8, enum_tag.?, t)) {
            try out.append(arena, '_');
            for (t) |c| try out.append(arena, std.ascii.toLower(c));
        }
    }
    return out.items;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const test_tags = [_][]const u8{ "KHR", "EXT", "NV", "AMD", "AMDX" };

fn expectSnake(expected: []const u8, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(expected, try snake(arena_state.allocator(), input));
}

test "snake case follows the names types.zig already had" {
    // Every one of these is a name the hand-written declarations use.
    try expectSnake("s_type", "sType");
    try expectSnake("queue_flags", "queueFlags");
    try expectSnake("max_image_dimension_1d", "maxImageDimension1D");
    try expectSnake("max_image_dimension_3d", "maxImageDimension3D");
    try expectSnake("residency_standard_2d_block_shape", "residencyStandard2DBlockShape");
    try expectSnake("sparse_residency_2_samples", "sparseResidency2Samples");
    try expectSnake("sparse_residency_16_samples", "sparseResidency16Samples");
    try expectSnake("full_draw_index_uint32", "fullDrawIndexUint32");
    try expectSnake("shader_int64", "shaderInt64");
    try expectSnake("texture_compression_etc2", "textureCompressionETC2");
    try expectSnake("texture_compression_astc_ldr", "textureCompressionASTC_LDR");
    try expectSnake("pipeline_cache_uuid", "pipelineCacheUUID");
    try expectSnake("device_luid", "deviceLUID");
    try expectSnake("float32", "float32");
    try expectSnake("storage_buffer_16_bit_access", "storageBuffer16BitAccess");
    try expectSnake("sparse_residency_image_2d", "sparseResidencyImage2D");
    try expectSnake("max_compute_work_group_count", "maxComputeWorkGroupCount");
    try expectSnake("timestamp_compute_and_graphics", "timestampComputeAndGraphics");
}

test "the Hungarian prefix comes off pointers and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("next", try memberName(arena, "pNext", 1, false));
    try testing.expectEqualStrings("enabled_layer_names", try memberName(arena, "ppEnabledLayerNames", 2, false));
    try testing.expectEqualStrings("create_info", try memberName(arena, "pCreateInfo", 1, false));
    try testing.expectEqualStrings("allocation", try memberName(arena, "pfnAllocation", 0, true));
    try testing.expectEqualStrings("user_data", try memberName(arena, "pUserData", 1, false));
    // Not a pointer, so `p` is part of the word.
    try testing.expectEqualStrings("pipeline_cache", try memberName(arena, "pipelineCache", 0, false));
    try testing.expectEqualStrings("physical_device", try memberName(arena, "physicalDevice", 0, false));
    // A pointer that happens to have a capital second letter but is not Hungarian.
    try testing.expectEqualStrings("pipeline", try memberName(arena, "pipeline", 1, false));
}

test "type and command names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("SwapchainKHR", typeName("VkSwapchainKHR"));
    try testing.expectEqualStrings("Bool32", typeName("VkBool32"));
    try testing.expectEqualStrings("PfnAllocationFunction", try pfnTypeName(arena, "PFN_vkAllocationFunction"));
    try testing.expectEqualStrings("cmdDraw", try commandField(arena, "vkCmdDraw"));
    try testing.expectEqualStrings("createSwapchainKHR", try commandField(arena, "vkCreateSwapchainKHR"));
    try testing.expectEqualStrings("max_extension_name_size", try constantName(arena, "VK_MAX_EXTENSION_NAME_SIZE"));
    try testing.expectEqualStrings("OutOfHostMemory", try pascal(arena, "OUT_OF_HOST_MEMORY"));
}

test "enumerants lose their enum's name, their tag if it is the enum's, and _BIT" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { enum_name: []const u8, value: []const u8, bit: bool, want: []const u8 }{
        .{ .enum_name = "VkImageLayout", .value = "VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL", .bit = false, .want = "transfer_src_optimal" },
        .{ .enum_name = "VkStructureType", .value = "VK_STRUCTURE_TYPE_APPLICATION_INFO", .bit = false, .want = "application_info" },
        .{ .enum_name = "VkStructureType", .value = "VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR", .bit = false, .want = "swapchain_create_info_khr" },
        .{ .enum_name = "VkResult", .value = "VK_ERROR_OUT_OF_HOST_MEMORY", .bit = false, .want = "error_out_of_host_memory" },
        .{ .enum_name = "VkResult", .value = "VK_SUBOPTIMAL_KHR", .bit = false, .want = "suboptimal_khr" },
        .{ .enum_name = "VkQueueFlagBits", .value = "VK_QUEUE_GRAPHICS_BIT", .bit = true, .want = "graphics" },
        .{ .enum_name = "VkQueueFlagBits", .value = "VK_QUEUE_VIDEO_DECODE_BIT_KHR", .bit = true, .want = "video_decode_khr" },
        .{ .enum_name = "VkPresentModeKHR", .value = "VK_PRESENT_MODE_FIFO_KHR", .bit = false, .want = "fifo" },
        .{ .enum_name = "VkSurfaceTransformFlagBitsKHR", .value = "VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR", .bit = true, .want = "identity" },
        .{ .enum_name = "VkPipelineStageFlagBits2", .value = "VK_PIPELINE_STAGE_2_COPY_BIT", .bit = true, .want = "copy" },
        .{ .enum_name = "VkPipelineStageFlagBits2", .value = "VK_PIPELINE_STAGE_2_COPY_BIT_KHR", .bit = true, .want = "copy_khr" },
        .{ .enum_name = "VkSampleCountFlagBits", .value = "VK_SAMPLE_COUNT_16_BIT", .bit = true, .want = "16" },
        .{ .enum_name = "VkImageType", .value = "VK_IMAGE_TYPE_2D", .bit = false, .want = "2d" },
        .{ .enum_name = "VkDebugUtilsMessageSeverityFlagBitsEXT", .value = "VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT", .bit = true, .want = "error" },
    };
    for (cases) |case| {
        const got = try enumerantName(arena, case.enum_name, case.value, case.bit, &test_tags);
        try testing.expectEqualStrings(case.want, got);
    }
}
