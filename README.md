# Fluxion Vulkan

Finding Vulkan at run time, and turning its names into function pointers. For
Zig 0.16.

| Module | What it is |
| --- | --- |
| `library` | Finding and opening the platform's Vulkan library, under whichever name it uses, and the one symbol everything else comes from. The names are Vulkan's; the opening is [Fluxion Dyn](https://github.com/kisstp2006/fluxion-dyn). |
| `dispatch` | A struct of function pointers, filled in by name. Three scopes, required and optional commands, and aliases for the promoted ones. |
| `commands` | The three tables the loader itself needs: global, instance, device. Ordinary structs, with no special status. |
| `types` | The slice of the Vulkan ABI those tables speak. Handles, result codes, create infos, and the properties a device is chosen by. |
| `enumerate` | Vulkan's two-call idiom, done once — and the two questions anyone asks of a list of extension names. |
| `version` | The packed `u32` a Vulkan version travels in, and the vendor packings a driver version does not. |
| `Loader` | The first five in the order you use them. |

Vulkan is never linked against. There is no `libvulkan` on the command line and
no import library: the loader is found at run time and `vkGetInstanceProcAddr`
is the only symbol looked up by name. Everything else comes out of that one
function — which is what makes a program on a machine with no driver a program
that still starts.

Commands arrive in three tiers, and the difference is not cosmetic:

| Scope | Resolved through | What it costs |
| --- | --- | --- |
| Global | `vkGetInstanceProcAddr(null, …)` | Exists before there is an instance. |
| Instance | `vkGetInstanceProcAddr(instance, …)` | Goes through the loader's trampoline, which reads the first argument and picks a driver. |
| Device | `vkGetDeviceProcAddr(device, …)` | Nothing. The pointer belongs to one driver already. |

Nothing here allocates unless it takes an `Allocator`, and everything that
allocates says who owns the result.

## Platforms

`library` is the only platform-specific part, and the only part that can be
unavailable:

| `library.backend` | Where | How |
| --- | --- | --- |
| `.windows` | Windows | `LoadLibraryW` and `GetProcAddress`, declared here — `std.DynLib` does not cover Windows. |
| `.posix` | Linux, Android, macOS, iOS, the BSDs, illumos | `std.DynLib`: `dlopen` where there is a libc, a hand-rolled ELF walker where there is not. |
| `.none` | `wasm32`, and anything else Zig cannot dlopen on | Nothing to open. `open` and `openPath` return `error.NotSupported`, and everything else still compiles and works. |

Everything above `library` is portable, so a `.none` target is not a wall:
`Loader.adopt` takes a `vkGetInstanceProcAddr` from anywhere, and the rest of
the library never learns where it came from.

**The calling convention is not the same everywhere.** The C headers call it
`VKAPI_CALL`: empty on most platforms, `__stdcall` on Windows, `aapcs-vfp` on
32-bit ARM Android. It makes no difference on 64-bit Windows; on 32-bit x86 it
decides who cleans the stack, and getting it wrong crashes somewhere unrelated.
`vk.call` is that convention, and every command pointer should use it:

```zig
cmdDraw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(vk.call) void,
```

Verified by building the library and every example for Windows (x86, x86-64,
arm64), Linux (x86, x86-64, arm, arm64, riscv64, glibc and musl), Android (arm,
arm64), macOS (x86-64, arm64), FreeBSD, NetBSD and `wasm32-wasi` — and by
running the test suite on both x86 and x86-64 Windows, which is what found the
`__stdcall` bug in the first place.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-vulkan
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_vulkan = .{ .path = "../fluxion-vulkan" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_vulkan", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_vulkan", fluxion.module("fluxion_vulkan"));
```

```zig
const vk = @import("fluxion_vulkan");
```

One dependency comes with it, fetched the same way and needing nothing from
you: [Fluxion Dyn](https://github.com/kisstp2006/fluxion-dyn), which is where
`library` gets its opening and `dispatch` its command naming.

## Tour

### Loader

Where a Vulkan program starts:

```zig
var loader: vk.Loader = try .init();
defer loader.deinit();

std.debug.print("{s}, Vulkan {f}\n", .{ loader.name().?, try loader.apiVersion() });
```

`error.NotFound` means no Vulkan library opened under any of the names this
platform uses — almost always no GPU driver installed, rather than no GPU. It is
a thing to report and carry on from, not a thing to crash on.

```zig
Windows          vulkan-1.dll
Linux and BSD    libvulkan.so.1, then libvulkan.so
Android          libvulkan.so, which is the only name there
macOS and iOS    libvulkan.dylib, the versioned name, MoltenVK directly,
                 the two frameworks, then /usr/local/lib
```

If something else in the process already loaded Vulkan — GLFW and SDL both do,
and both hand back a `vkGetInstanceProcAddr` — give that pointer to
`Loader.adopt` and no second library is opened. A loader made that way owns
nothing and closes nothing.

```zig
var loader = try vk.Loader.adopt(&glfwGetInstanceProcAddress);
```

The same for Vulkan linked into the executable rather than loaded — a static
MoltenVK on iOS, or `vulkan-1.lib` on Windows. There is no library to find,
because the entry point is an ordinary symbol:

```zig
extern fn vkGetInstanceProcAddr(
    instance: ?vk.Instance,
    name: [*:0]const u8,
) callconv(vk.call) ?vk.dispatch.PfnVoidFunction;

var loader = try vk.Loader.adopt(&vkGetInstanceProcAddr);
```

On iOS that is the only way in, since an app may not dlopen code it did not
ship. `examples/adopt.zig` has all four.

**The version.** `apiVersion` is a ceiling and not a promise about any device: a
1.3 loader in front of a 1.1 driver still reports 1.3.
`PhysicalDeviceProperties.api_version` is the number that applies to a
particular GPU.

```zig
if (!try loader.supports(vk.v1_1)) return error.TooOld;
```

A loader with no `vkEnumerateInstanceVersion` is a Vulkan 1.0 loader, which is
the whole reason that command is declared optional. There is no separate flag
for it and no probing — the absence is the answer.

### dispatch

The part that does the actual work. Declare a struct whose fields are named
after the commands you want, and it fills them in:

```zig
const Draw = struct {
    cmdBindPipeline: *const fn (CommandBuffer, PipelineBindPoint, Pipeline) callconv(vk.call) void,
    cmdDraw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(vk.call) void,
    cmdDrawMeshTasksEXT: ?*const fn (CommandBuffer, u32, u32, u32) callconv(vk.call) void,
};

const draw = try vk.load(Draw, inst.deviceResolver(device));
```

The field name is the command name with `vk` in front and the first letter
capitalised, so `cmdDraw` is `vkCmdDraw` and `createSwapchainKHR` is
`vkCreateSwapchainKHR`. Nothing is generated and nothing is registered: the
table is an ordinary struct, and the loading is a comptime walk over its fields.
A table of this library's declarations and a table of a full binding's load
identically.

**The field's type says whether the command is required.** A plain function
pointer must be found or the load fails. An optional one may be absent and is
left `null` — which is how a command from a version or an extension you did not
get is meant to be handled, and how `cmdDrawMeshTasksEXT` above is a runtime
question rather than a build-time one.

Anything that is not a function pointer is a compile error naming the field,
rather than a cast that happens to go through.

**When it fails, ask which one.** `loadReport` fills in a `Report` either way:

```zig
var report: vk.dispatch.Report = .{};
const table = vk.dispatch.loadReport(Draw, resolver, &report) catch {
    std.log.err("this driver has no {s}", .{report.missing.?});
    return error.DriverTooOld;
};
std.log.info("{d} loaded, {d} optional and absent", .{ report.found, report.absent });
```

**Promoted extensions have two names.** A command that was an extension and
became core answers to whichever one the driver is old enough for. A table says
so once:

```zig
const Commands = struct {
    getPhysicalDeviceProperties2: ?*const fn (PhysicalDevice, *PhysicalDeviceProperties2) callconv(vk.call) void,

    pub const aliases = .{
        .getPhysicalDeviceProperties2 = .{"vkGetPhysicalDeviceProperties2KHR"},
    };
};
```

The derived name is tried first, then each alias in turn.

### commands

The three shipped tables, and the whole setup path:

```zig
const instance = try loader.createInstance(&info, null);
const inst = try loader.instanceCommands(instance);
defer inst.destroyInstance(instance, null);

const dev = try inst.deviceCommands(device);
defer dev.destroyDevice(device, null);
```

`commands.Device` has three commands in it, on purpose. Once there is a device
the loader's job is done and Vulkan's begins — the remaining several thousand
commands are the API, not the loading of it. Declare the ones you use and hand
them to the same resolver:

```zig
const mine = try vk.load(MyCommands, inst.deviceResolver(device));
```

### enumerate

Every Vulkan command that hands back a list is called twice: once with a null
array, which writes the count, and once with an array that size, which fills it.
Between the two the answer can change — a layer is installed, a GPU is plugged
in — and the second call says so by returning `.incomplete` rather than
overrunning the array. Doing that correctly is five lines, and writing them five
times is how the fifth one ends up wrong.

```zig
const layers = try loader.layers(gpa);
const available = try loader.extensions(gpa, null);
const gpus = try vk.enumerate.physicalDevices(gpa, inst, instance);
const families = try vk.enumerate.queueFamilies(gpa, inst, gpu);
const supported_here = try vk.enumerate.deviceExtensions(gpa, inst, gpu, null);
```

Then the two questions anyone actually asks of a list of extension names:

```zig
// Required: fail here, by name, rather than inside vkCreateInstance with a
// code that does not say which one.
if (vk.firstMissing(available, &required)) |name| {
    std.log.err("this driver has no {s}", .{name});
    return error.Unsupported;
}

// Optional: enable the ones that are there and leave the rest.
var buffer: [optional.len][*:0]const u8 = undefined;
info.setExtensions(vk.supported(available, &optional, &buffer));
```

**Queue families.** `queueFamily` returns the family that can do everything you
asked for and as little else as possible. The tie-break is what finds a
dedicated transfer or compute queue on the hardware that has one:

```zig
const graphics = vk.queueFamily(families, .{ .graphics = true }).?;
const transfer = vk.queueFamily(families, .{ .transfer = true }).?;
```

On an NVIDIA T500 that picks family 0 for graphics and family 1 — two queues,
transfer and sparse binding and nothing else — for transfers.

Both go through `enumerate.capabilities`, which is where one Vulkan subtlety
lives: a driver may leave the transfer bit off a family that does graphics or
compute, because those already imply it, and plenty of drivers do. Matching on
the bits as written would tell a program with no dedicated copy engine that it
cannot copy at all — so the implication is applied first, and the second `.?`
above is sound wherever the first one is.

### types

Enough Vulkan to open the door, and nothing past it. Two things the C headers do
not have:

```zig
// Every s_type field defaults to the right tag.
const app: vk.ApplicationInfo = .{ .application_name = "demo", .api_version = vk.v1_1.toInt() };
var info: vk.InstanceCreateInfo = .{ .application_info = &app };

// Every count-and-pointer pair is set from one slice, so the two cannot drift.
info.setExtensions(enabled);
```

Handles are distinct opaque pointer types, so a `Device` will not go where an
`Instance` was meant. Result codes are an open enum, and `check` divides them
the way Vulkan does — negative is a failure, and a success comes back rather
than being thrown away, because `incomplete` and `suboptimal_khr` are successes
that mean you have something else to do:

```zig
const result = try inst.enumeratePhysicalDevices(instance, &count, buffer).check();
if (result == .incomplete) {} // there were more than the buffer could hold
```

The structs the driver writes into — properties, limits, memory heaps — are
pinned to their C sizes by a test, because a declaration one field short is a
buffer overflow that no test of behaviour would catch.

### version

A Vulkan version is a `u32` with four fields packed into it, and this is that
`u32` with names on:

```zig
const v: vk.ApiVersion = .init(1, 3, 280);
v.toInt() == (1 << 22) | (3 << 12) | 280;
v.atLeast(vk.v1_3);   // true
v.atLeast(vk.v1_4);   // false
```

`atLeast` ignores the patch number deliberately: Vulkan promises a patch release
changes nothing an application can depend on, so requiring one would only rule
out drivers that would have worked.

A **driver** version is not an API version. It is a `u32` the vendor packs as it
likes, and printing it as `major.minor.patch` gives the wrong answer on most
hardware:

```zig
const driver: vk.version.Driver = .{ .vendor_id = props.vendor_id, .value = props.driver_version };
std.debug.print("{f}\n", .{driver});   // 595.95.0.0, not 4:83.380.0
```

## Everything together

```zig
var loader: vk.Loader = try .init();
defer loader.deinit();

const available = try loader.extensions(gpa, null);
if (vk.firstMissing(available, &required)) |name| return error.Unsupported;

var info: vk.InstanceCreateInfo = .{ .application_info = &app };
info.setExtensions(&required);

const instance = try loader.createInstance(&info, null);
const inst = try loader.instanceCommands(instance);
defer inst.destroyInstance(instance, null);

// Pick a GPU: discrete first, most video memory as the tie-break.
const gpus = try vk.enumerate.physicalDevices(gpa, inst, instance);
const gpu = pick(inst, gpus);

const families = try vk.enumerate.queueFamilies(gpa, inst, gpu);
const graphics = vk.queueFamily(families, .{ .graphics = true }).?;

const priorities = [_]f32{1.0};
const queues = [_]vk.DeviceQueueCreateInfo{.queues(graphics, &priorities)};
var device_info: vk.DeviceCreateInfo = .{};
device_info.setQueues(&queues);

var device: vk.Device = undefined;
_ = try inst.createDevice(gpu, &device_info, null, &device).check();

const dev = try inst.deviceCommands(device);
defer dev.destroyDevice(device, null);
```

`zig build example` runs exactly this, on whatever this machine has, and prints
what it finds on the way — or explains that there is no Vulkan library here and
exits, which is the other thing a loader is for.

Tearing down goes the other way, and the order is not optional: every command
pointer anywhere points into the library the loader holds open, so it is finish
the work, destroy the device, destroy the instance, and only then `deinit` the
loader. The `defer`s above are already in that order.

## Examples

Seven programs in `examples/`, each one thing and each runnable on its own. All
seven say so and exit cleanly on a machine with no driver.

**Using the loader:**

| | What it shows |
| --- | --- |
| `zig build example` | The tour: library, version, layers, extensions, every GPU and its queue families, then opening one. |
| `zig build example-headless` | The smallest complete Vulkan program — loader to queue and back down, sixty lines, no window. |
| `zig build example-devices` | Weighing the GPUs against what a program needs, and saying why each rejected one was rejected. |
| `zig build example-table` | Declaring your own commands: required against optional, aliases, and what a load reports. |
| `zig build example-adopt` | The four places a `vkGetInstanceProcAddr` comes from when you did not open the library yourself. |

**Doing actual work on the GPU** — the samples every graphics API opens with:

| | What it shows |
| --- | --- |
| `zig build example-compute` | Numbers into a buffer, a compute shader over them, numbers back — and all 1024 answers checked. |
| `zig build example-triangle` | Hello triangle: the whole graphics pipeline, rendered offscreen, the pixels verified, and written out as `triangle.ppm`. |

Those two need Vulkan the loader deliberately does not declare, so they declare
it themselves — [`examples/beyond.zig`](examples/beyond.zig) is what "write the
part of the binding you need" looks like in practice, and it loads through
`vk.load` like anything else.

They need shaders too, and there is no `glslc` in the build:
[`examples/spirv.zig`](examples/spirv.zig) assembles the SPIR-V at compile time
out of the instructions `glslc` would have emitted. Nothing is generated ahead
of time and nothing is read from disk.

**Both render offscreen on purpose.** No surface, no swapchain, no windowing
library and no platform code — so they run over SSH, and, more to the point,
their output can be checked rather than looked at. The triangle asserts that its
corners are the clear colour, that its centre is lit, that each vertex leans
towards its own primary, and that every pixel is opaque; it exits non-zero if
any of that is wrong.

```
  corner is untouched          ok
  centre is drawn              ok
  top vertex is reddest        ok
  bottom right is greenest     ok
  bottom left is bluest        ok
  the face is interpolated     ok
  every pixel is opaque        ok
```

`zig build examples` builds all seven without running any, which is what a
cross-compiled check wants.

## Build

```bash
zig build test        # run the test suite
zig build example     # build and run the demo tour
zig build examples    # build every example without running one
zig build docs        # generate API docs into zig-out/docs
```

Any of it cross-compiles with `-Dtarget=`, and `zig build test -Dtarget=` runs
where the host can execute the result — `x86-windows-gnu` on 64-bit Windows,
for one, which is the only way the `__stdcall` difference shows up at all.

A loader can only be tested against something to load, and a real driver is the
one thing a test suite cannot assume. So the tests run against a Vulkan that is
not there: an implementation of the far side of `vkGetInstanceProcAddr`, with
two invented GPUs, a layer, three extensions and a swapchain, following the
rules the real thing follows — the two-call idiom, `.incomplete` on a short
array, `vkGetDeviceProcAddr` answering a different set of names. The whole path
from library to device table runs on a machine with no GPU at all, including the
awkward cases: a Vulkan 1.0 loader, a driver with a promoted command under only
its old name, an instance that refuses to be created.

The handful of tests that do need a driver find one or skip.

The sizes of the structs a driver writes into are pinned too, per ABI: the
64-bit one, the 32-bit one where `u64` is still eight-aligned (armv7 Android,
32-bit Windows), and i386 System V where it is not. A declaration one field
short is a buffer overflow that no test of behaviour would catch.

## Requirements

Zig 0.16.0. No system headers, no `vulkan-headers`, and nothing to link.

## License


`SPDX-License-Identifier: BSL-1.0`

[Boost Software License 1.0](LICENSE) - permissive, and short enough to read
in a minute: use it, change it, ship it, in anything. The one obligation is
that the copyright notice and the licence text travel with the *source*; a
binary built from it carries nothing, which is the difference from MIT and
BSD and the reason this is the usual choice for a library that ends up
compiled into somebody else's program.

Fluxion libraries are licensed by layer: the foundation is CC0, the engine
infrastructure this one belongs to is BSL-1.0, and what builds on top of it
is BSD.
