// SPDX-License-Identifier: CC0-1.0

//! Finding the Vulkan library on this machine, and getting one symbol out of
//! it.
//!
//! Vulkan is not linked against. There is no `libvulkan` on the command line
//! and no import library: the loader is found at run time, under whichever
//! name the platform uses, and `vkGetInstanceProcAddr` is the only symbol ever
//! looked up by name. Everything else in Vulkan comes out of that one
//! function - which is what makes a program that draws nothing on a machine
//! with no GPU driver a program that still starts.
//!
//! The names, in the order they are tried:
//!
//!   Windows          `vulkan-1.dll`
//!   Linux and BSD    `libvulkan.so.1`, then `libvulkan.so`
//!   Android          `libvulkan.so`, which is the only name there
//!   macOS and iOS    `libvulkan.dylib`, the versioned name, then MoltenVK
//!                    directly, then the two frameworks, then
//!                    `/usr/local/lib`, which is where the LunarG SDK puts it
//!
//! `open` walks that list. `openPath` takes one name instead, for a loader
//! shipped next to the executable or picked by a setting.
//!
//! **This is the only part of the library that is platform-specific**, and the
//! only part that can be unavailable. Where a platform has no run-time loading
//! Zig can reach - `wasm32`, and anything else `std.DynLib` does not cover -
//! `backend` is `.none`, both functions return `error.NotSupported`, and
//! everything else still compiles and works. There are two ways in that do not
//! need any of this:
//!
//!   * something else in the process already loaded Vulkan. GLFW hands back a
//!     `vkGetInstanceProcAddr` from `glfwGetInstanceProcAddress`, and SDL from
//!     `SDL_Vulkan_GetVkGetInstanceProcAddr`. Give it to `Loader.adopt`, and
//!     no second library is opened.
//!
//!   * Vulkan is linked into the executable rather than loaded - a static
//!     MoltenVK on iOS, or `vulkan-1.lib` on Windows. Then the entry point is
//!     an ordinary symbol, and `Loader.adopt` takes it directly:
//!
//!     ```zig
//!     extern fn vkGetInstanceProcAddr(
//!         instance: ?vk.Instance,
//!         name: [*:0]const u8,
//!     ) callconv(vk.call) ?vk.dispatch.PfnVoidFunction;
//!
//!     var loader = try vk.Loader.adopt(&vkGetInstanceProcAddr);
//!     ```
//!
//! Either way `Loader` owns no library, closes nothing, and the rest of this
//! module is never reached. See `examples/adopt.zig`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const dispatch = @import("dispatch.zig");

const windows = std.os.windows;

/// The symbol every Vulkan library exports, and the only one looked up by name.
pub const entry_point = "vkGetInstanceProcAddr";

/// How this platform opens a library at run time.
pub const Backend = enum {
    /// `LoadLibraryW`, `GetProcAddress`, `FreeLibrary`, declared at the bottom
    /// of this file because `std.DynLib` does not cover Windows.
    windows,
    /// `std.DynLib`: `dlopen` where there is a libc, and a hand-rolled ELF
    /// walker where there is not.
    posix,
    /// Nothing. Not a gap in this library - the platform has no run-time
    /// loading to reach, so there is nothing to find and `Loader.adopt` is the
    /// way in.
    none,
};

/// Which one this build got. The list of `.posix` platforms is the list
/// `std.DynLib` supports; anything outside it is `.none` rather than a
/// compile error, so that a cross-platform build matrix still builds.
pub const backend: Backend = switch (builtin.os.tag) {
    .windows => .windows,
    .linux,
    .driverkit,
    .ios,
    .maccatalyst,
    .macos,
    .tvos,
    .visionos,
    .watchos,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .illumos,
    => .posix,
    else => .none,
};

/// The names to try, in order, on this platform. Empty where `backend` is
/// `.none`, because there is nothing to try them with.
pub const candidates: []const [:0]const u8 = switch (backend) {
    .none => &.{},
    .windows => &.{"vulkan-1.dll"},
    .posix => switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => &.{
            "libvulkan.dylib",
            "libvulkan.1.dylib",
            "libMoltenVK.dylib",
            // Bundled inside an application, which is how a signed app ships
            // one.
            "vulkan.framework/vulkan",
            "MoltenVK.framework/MoltenVK",
            // Where the LunarG SDK installs it.
            "/usr/local/lib/libvulkan.dylib",
        },
        // Android ships exactly one name, and no versioned symlink to try
        // first.
        else => if (builtin.abi.isAndroid())
            &.{"libvulkan.so"}
        else
            &.{ "libvulkan.so.1", "libvulkan.so" },
    },
};

pub const Error = error{
    /// No Vulkan library opened, under any of the names this platform uses.
    /// Usually means no GPU driver is installed - not that the machine has no
    /// GPU.
    NotFound,
    /// Something opened, but it does not export `vkGetInstanceProcAddr`, so
    /// whatever it is, it is not a Vulkan loader.
    NoEntryPoint,
    /// This platform has no run-time library loading at all - see `backend`.
    /// `Loader.adopt` is the way in.
    NotSupported,
    /// Windows only: a path handed to `openPath` was longer than this library
    /// converts to UTF-16 in.
    NameTooLong,
};

/// An open handle on the platform's Vulkan library.
///
/// Closing it while an instance is still alive unmaps code the driver is
/// standing in, so the order at shutdown is: destroy the device, destroy the
/// instance, and only then `close`. `Loader.deinit` does exactly that.
pub const Library = struct {
    handle: Handle,
    /// The name it opened under, for the times when which one matters -
    /// `libMoltenVK.dylib` is a different answer from `libvulkan.dylib`.
    name: [:0]const u8,

    const Handle = switch (backend) {
        .windows => windows.HMODULE,
        .posix => std.DynLib,
        .none => noreturn,
    };

    /// Try every name in `candidates`, and keep the first that opens.
    pub fn open() Error!Library {
        if (backend == .none) return error.NotSupported;
        for (candidates) |name| {
            return openPath(name) catch continue;
        }
        return error.NotFound;
    }

    /// Open one named library, and nothing else.
    ///
    /// The name goes to the platform's loader as given, so a bare name is
    /// searched for the way that platform searches and a path is taken
    /// literally. It is also kept, in `name`, rather than copied - so a path
    /// built at run time has to outlive the `Library`.
    pub fn openPath(path: [:0]const u8) Error!Library {
        switch (backend) {
            .none => return error.NotSupported,
            .windows => {
                var wide: [max_wide_path]u16 = undefined;
                // Checked before converting, not after: `utf8ToUtf16Le` writes
                // as it goes and would run off the end. A UTF-8 string never
                // needs more UTF-16 units than it has bytes - a surrogate pair
                // costs two units and four bytes - so its length is a sound
                // bound, with one more for the terminator.
                if (path.len + 1 > wide.len) return error.NameTooLong;
                const len = std.unicode.utf8ToUtf16Le(&wide, path) catch return error.NotFound;
                wide[len] = 0;
                const handle = LoadLibraryW(wide[0..len :0].ptr) orelse return error.NotFound;
                return .{ .handle = handle, .name = path };
            },
            .posix => {
                const handle = std.DynLib.openZ(path.ptr) catch return error.NotFound;
                return .{ .handle = handle, .name = path };
            },
        }
    }

    /// Give the library back to the operating system.
    ///
    /// After this every command pointer taken out of it points at unmapped
    /// memory, including the ones sitting in dispatch tables.
    pub fn close(self: *Library) void {
        switch (backend) {
            // Unreachable: with no backend there is no way to have opened one.
            .none => unreachable,
            .windows => _ = FreeLibrary(self.handle),
            .posix => self.handle.close(),
        }
        self.* = undefined;
    }

    /// One symbol, by name. Only `vkGetInstanceProcAddr` is ever worth asking
    /// for: every other Vulkan command is reached through it, and a driver is
    /// under no obligation to export any of them.
    pub fn lookup(self: *Library, name: [:0]const u8) ?dispatch.PfnVoidFunction {
        return switch (backend) {
            .none => unreachable,
            .windows => blk: {
                const symbol = GetProcAddress(self.handle, name.ptr) orelse break :blk null;
                break :blk @ptrCast(@alignCast(symbol));
            },
            .posix => self.handle.lookup(dispatch.PfnVoidFunction, name),
        };
    }

    /// The entry point, and the last time a string is looked up in a shared
    /// library rather than asked of Vulkan itself.
    pub fn getInstanceProcAddr(self: *Library) Error!dispatch.PfnGetInstanceProcAddr {
        const symbol = self.lookup(entry_point) orelse return error.NoEntryPoint;
        return @ptrCast(symbol);
    }
};

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------
//
// `std.DynLib` covers POSIX and stops there, so Windows gets the three calls
// it needs declared here. Nothing else in this library is platform-specific.

/// Long enough for any library name, and short enough to sit on the stack.
/// Windows itself allows far longer paths; `openPath` says so rather than
/// truncating.
const max_wide_path = 1024;

extern "kernel32" fn LoadLibraryW(
    lpLibFileName: [*:0]const u16,
) callconv(.winapi) ?windows.HMODULE;

extern "kernel32" fn FreeLibrary(
    hLibModule: windows.HMODULE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetProcAddress(
    hModule: windows.HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?*const anyopaque;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a platform either has names to try or has no way to try them" {
    switch (backend) {
        // Nothing to open, and nothing claiming otherwise.
        .none => try testing.expectEqual(@as(usize, 0), candidates.len),
        else => {
            try testing.expect(candidates.len > 0);
            for (candidates) |name| {
                try testing.expect(name.len > 0);
                try testing.expectEqual(@as(u8, 0), name.ptr[name.len]);
            }
        },
    }

    // And the right ones for the platform being built for.
    switch (builtin.os.tag) {
        .windows => try testing.expectEqualStrings("vulkan-1.dll", candidates[0]),
        .macos => try testing.expectEqualStrings("libvulkan.dylib", candidates[0]),
        .linux => if (builtin.abi.isAndroid()) {
            // Android has one name, and trying a versioned one first would be
            // a dlopen that can never succeed.
            try testing.expectEqual(@as(usize, 1), candidates.len);
            try testing.expectEqualStrings("libvulkan.so", candidates[0]);
        } else {
            try testing.expectEqualStrings("libvulkan.so.1", candidates[0]);
        },
        else => {},
    }
}

test "a platform with no backend says so rather than failing to find" {
    if (backend != .none) return error.SkipZigTest;

    // Not `NotFound`: there is nothing wrong with this machine, and looking
    // harder would not help.
    try testing.expectError(error.NotSupported, Library.open());
    try testing.expectError(error.NotSupported, Library.openPath("libvulkan.so"));
}

test "a library that is not there is not found" {
    if (backend == .none) return error.SkipZigTest;

    // Not an assertion about this machine: no platform loads a library under
    // this name, whether or not Vulkan is installed.
    try testing.expectError(
        error.NotFound,
        Library.openPath("fluxion-no-such-library-0000.so"),
    );
}

test "a name too long to convert is refused rather than truncated" {
    // Windows is the only platform that converts the name at all, and the one
    // place a fixed buffer could be overrun.
    if (backend != .windows) return error.SkipZigTest;

    // The buffer holds the name and a terminator, so the longest that fits is
    // one shorter than the buffer - and one past that is refused.
    try testing.expectError(error.NameTooLong, Library.openPath("x" ** max_wide_path));
    try testing.expectError(error.NotFound, Library.openPath("x" ** (max_wide_path - 1)));
    try testing.expectError(error.NotFound, Library.openPath("x" ** 64));
}

test "the real loader, when this machine has one" {
    var lib = Library.open() catch return error.SkipZigTest;
    defer lib.close();

    // It opened under one of the names this platform uses.
    var recognised = false;
    for (candidates) |name| {
        if (std.mem.eql(u8, name, lib.name)) recognised = true;
    }
    try testing.expect(recognised);

    // And it is a Vulkan loader, which is to say it has the one symbol.
    _ = try lib.getInstanceProcAddr();
    try testing.expect(lib.lookup("vkNoSuchCommandAtAll") == null);
}
