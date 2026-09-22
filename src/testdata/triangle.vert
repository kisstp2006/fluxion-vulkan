// SPDX-License-Identifier: BSL-1.0
//
// Three vertices and no vertex buffer: the corners are in the shader, so the
// pipeline needs no vertex input at all. `scale` arrives as a push constant,
// which is what makes the pipeline layout's push constant range matter.
//
//     glslc --target-env=vulkan1.0 -O triangle.vert -o triangle.vert.spv

#version 450

layout(push_constant) uniform Push {
    float scale;
} push;

void main() {
    vec2 corners[3] = vec2[](vec2(-0.8, -0.8), vec2(0.8, -0.8), vec2(0.0, 0.8));
    gl_Position = vec4(corners[gl_VertexIndex] * push.scale, 0.0, 1.0);
}
