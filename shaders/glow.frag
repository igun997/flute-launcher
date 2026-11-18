#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

// Soft warm window light behind a house, drawn on the GPU. Premultiplied output; draw it with
// BlendMode.plus so it adds light instead of covering the art.
uniform vec2 uSize;
uniform float uTime;
uniform float uIntensity;  // 0..1
uniform vec3 uColor;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 p = (uv - 0.5) * 2.0;
  float d = length(p);
  float flicker = 0.92 + 0.08 * sin(uTime * 2.7) * sin(uTime * 1.3 + 1.0);
  float a = pow(smoothstep(1.0, 0.0, d), 2.0) * uIntensity * flicker;
  fragColor = vec4(uColor * a, a);
}
