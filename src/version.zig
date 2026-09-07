// SPDX-License-Identifier: BSL-1.0

//! Vulkan versions, packed into the `u32` the API passes them in.
//!
//! Four versions matter, and they are four different numbers:
//!
//!   * what the **loader** supports - `Loader.apiVersion`, the ceiling for
//!     everything below;
//!   * what the **application** asks for - `ApplicationInfo.api_version`, a
//!     promise about which version's rules you expect;
//!   * what a **device** supports - `PhysicalDeviceProperties.api_version`,
//!     which can be lower than the loader's on an older driver;
//!   * what the **driver** calls itself - `driver_version`, which is not an
//!     API version at all and is packed however the vendor felt like. See
//!     `Driver` for reading one anyway.
//!
//! The first three are `ApiVersion`, and comparing them is what
//! `atLeast` is for.

const std = @import("std");
const testing = std.testing;

/// A Vulkan API version: `1.3.280`, and the variant nobody outside a bespoke
/// implementation ever sets.
///
/// The field order is the bit order, low to high, which is what makes this a
/// drop-in replacement for the `u32` the API actually passes.
pub const ApiVersion = packed struct(u32) {
    patch: u12 = 0,
    minor: u10,
    major: u7,
    /// Non-zero only for a Vulkan variant - a different API built out of the
    /// same machinery. Zero means Vulkan itself, and two versions with
    /// different variants are not comparable at all.
    variant: u3 = 0,

    /// `VK_MAKE_API_VERSION(0, major, minor, patch)`.
    pub fn init(major: u7, minor: u10, patch: u12) ApiVersion {
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    /// The version as the API passes it - `VK_MAKE_API_VERSION`.
    pub fn toInt(self: ApiVersion) u32 {
        return @bitCast(self);
    }

    /// A version as the API handed it back - `VK_VERSION_MAJOR` and friends,
    /// all at once.
    pub fn fromInt(value: u32) ApiVersion {
        return @bitCast(value);
    }

    /// Is `self` at least `required`, ignoring the patch?
    ///
    /// Patch numbers are deliberately left out: Vulkan promises that a patch
    /// release changes nothing an application can depend on, so requiring one
    /// only rules out drivers that would have worked.
    pub fn atLeast(self: ApiVersion, required: ApiVersion) bool {
        if (self.variant != required.variant) return false;
        if (self.major != required.major) return self.major > required.major;
        return self.minor >= required.minor;
    }

    /// Full ordering, patch included, for sorting and for equality.
    pub fn order(self: ApiVersion, other: ApiVersion) std.math.Order {
        if (self.variant != other.variant) return std.math.order(self.variant, other.variant);
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }

    /// The lower of two versions - which is the one that actually applies when
    /// an application asks for more than the loader has.
    pub fn min(self: ApiVersion, other: ApiVersion) ApiVersion {
        return if (self.order(other) == .lt) self else other;
    }

    /// `1.3.280`, or `2:1.0.0` when a variant is set.
    pub fn format(self: ApiVersion, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.variant != 0) try w.print("{d}:", .{self.variant});
        try w.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

/// The versions with names, for asking and for comparing against.
pub const v1_0: ApiVersion = .init(1, 0, 0);
pub const v1_1: ApiVersion = .init(1, 1, 0);
pub const v1_2: ApiVersion = .init(1, 2, 0);
pub const v1_3: ApiVersion = .init(1, 3, 0);
pub const v1_4: ApiVersion = .init(1, 4, 0);

/// A driver's own version, which follows no standard at all.
///
/// `VkPhysicalDeviceProperties.driver_version` is a `u32` the vendor packs as
/// it likes, so printing it as `major.minor.patch` gives the wrong answer on
/// most hardware. The two that differ in practice are NVIDIA everywhere, and
/// Intel on Windows; everyone else happens to use the Vulkan layout.
///
/// ```zig
/// const driver: version.Driver = .{ .vendor_id = props.vendor_id, .value = props.driver_version };
/// try w.print("{f}", .{driver});   // 566.36.0 on an NVIDIA card
/// ```
pub const Driver = struct {
    vendor_id: u32,
    value: u32,

    pub const nvidia = 0x10DE;
    pub const amd = 0x1002;
    pub const intel = 0x8086;

    pub fn format(self: Driver, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.vendor_id) {
            nvidia => try w.print("{d}.{d}.{d}.{d}", .{
                self.value >> 22 & 0x3FF,
                self.value >> 14 & 0xFF,
                self.value >> 6 & 0xFF,
                self.value & 0x3F,
            }),
            intel => if (@import("builtin").os.tag == .windows)
                // Intel's Windows driver packs a major and a build number, and
                // nothing else.
                try w.print("{d}.{d}", .{ self.value >> 14, self.value & 0x3FFF })
            else
                try ApiVersion.fromInt(self.value).format(w),
            else => try ApiVersion.fromInt(self.value).format(w),
        }
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the packing is the one the headers use" {
    // VK_MAKE_API_VERSION(variant, major, minor, patch) is
    //   (variant << 29) | (major << 22) | (minor << 12) | patch
    const v: ApiVersion = .init(1, 3, 280);
    try testing.expectEqual(@as(u32, (1 << 22) | (3 << 12) | 280), v.toInt());
    try testing.expectEqual(v, ApiVersion.fromInt(v.toInt()));

    // And the constants match what the headers call them.
    try testing.expectEqual(@as(u32, 1 << 22), v1_0.toInt());
    try testing.expectEqual(@as(u32, (1 << 22) | (1 << 12)), v1_1.toInt());
    try testing.expectEqual(@as(u32, (1 << 22) | (4 << 12)), v1_4.toInt());

    // A variant sits in the top three bits.
    const variant: ApiVersion = .{ .variant = 2, .major = 1, .minor = 0 };
    try testing.expectEqual(@as(u32, (2 << 29) | (1 << 22)), variant.toInt());

    // The whole 32-bit range round-trips, since every bit pattern is a version.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), ApiVersion.fromInt(0xFFFFFFFF).toInt());
}

test "atLeast ignores the patch, order does not" {
    const supported: ApiVersion = .init(1, 3, 280);

    try testing.expect(supported.atLeast(v1_0));
    try testing.expect(supported.atLeast(v1_3));
    try testing.expect(!supported.atLeast(v1_4));

    // A patch release changes nothing an application can depend on, so
    // requiring one would only rule out drivers that would have worked.
    try testing.expect(supported.atLeast(.init(1, 3, 999)));
    try testing.expect(ApiVersion.init(1, 3, 0).atLeast(.init(1, 3, 280)));

    // Ordering is total and does look at the patch.
    try testing.expectEqual(std.math.Order.gt, supported.order(v1_3));
    try testing.expectEqual(std.math.Order.lt, supported.order(v1_4));
    try testing.expectEqual(std.math.Order.eq, supported.order(.init(1, 3, 280)));

    // Versions of different variants are not comparable, and `atLeast` says so
    // rather than guessing.
    const other_api: ApiVersion = .{ .variant = 1, .major = 9, .minor = 9 };
    try testing.expect(!other_api.atLeast(v1_0));
    try testing.expect(!v1_0.atLeast(other_api));
}

test "the effective version is the lower of the two" {
    // An application asking for more than the loader has gets the loader's.
    const loader: ApiVersion = .init(1, 3, 280);
    const wanted: ApiVersion = .init(1, 4, 0);
    try testing.expectEqual(loader, loader.min(wanted));
    try testing.expectEqual(loader, wanted.min(loader));
    try testing.expectEqual(loader, loader.min(loader));
}

test "versions print the way people write them" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.3.280", try std.fmt.bufPrint(&buf, "{f}", .{
        ApiVersion.init(1, 3, 280),
    }));
    try testing.expectEqualStrings("1.0.0", try std.fmt.bufPrint(&buf, "{f}", .{v1_0}));
    try testing.expectEqualStrings("2:1.0.0", try std.fmt.bufPrint(&buf, "{f}", .{
        ApiVersion{ .variant = 2, .major = 1, .minor = 0 },
    }));
}

test "a driver version is not an API version" {
    var buf: [32]u8 = undefined;

    // NVIDIA 595.95: 10 bits of major, 8 of minor, 8 and 6 of build.
    const nvidia_595_95: u32 = (595 << 22) | (95 << 14);
    try testing.expectEqualStrings("595.95.0.0", try std.fmt.bufPrint(&buf, "{f}", .{
        Driver{ .vendor_id = Driver.nvidia, .value = nvidia_595_95 },
    }));

    // The same number read as an API version, which is what printing a driver
    // version the obvious way gets you. The major does not even fit in seven
    // bits, so it spills into the variant.
    try testing.expectEqualStrings("4:83.380.0", try std.fmt.bufPrint(&buf, "{f}", .{
        ApiVersion.fromInt(nvidia_595_95),
    }));

    // AMD and everyone else happen to use the Vulkan layout.
    try testing.expectEqualStrings("2.0.294", try std.fmt.bufPrint(&buf, "{f}", .{
        Driver{ .vendor_id = Driver.amd, .value = ApiVersion.init(2, 0, 294).toInt() },
    }));
}
