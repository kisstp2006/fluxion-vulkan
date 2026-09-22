// SPDX-License-Identifier: BSL-1.0
//
// The colour comes out of a uniform buffer, so that the descriptor set layout,
// the pool, the set, the write and the bind all have to be right for the
// triangle to be the colour it should.
//
//     glslc --target-env=vulkan1.0 -O triangle.frag -o triangle.frag.spv

#version 450

layout(set = 0, binding = 0) uniform Colour {
    vec4 value;
} colour;

layout(location = 0) out vec4 target;

void main() {
    target = colour.value;
}
