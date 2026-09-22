// SPDX-License-Identifier: BSL-1.0

//! Internal plumbing: `gen/layout.zig`'s numbers, as data in an object file.
//!
//! Nothing imports this. `oracle.zig` compiles it for other targets with
//! `zig build-obj -femit-asm` and reads the table back out of the assembly,
//! which is how the 32-bit and ARM layouts are checked on a machine that cannot
//! run them. The C side does the same with `zig cc -S`.

export const fluxion_layout = @import("gen/layout.zig").values;
