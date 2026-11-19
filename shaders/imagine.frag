#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

// The "creating an image" canvas: slow colour fields that drift and fold into each other, with a
// soft light sweeping across. uTime is seconds modulo 60, and every speed below is a whole number
// of cycles per minute, so the loop has no visible seam.
uniform vec2 uSize;
uniform float uTime;
uniform vec3 uColor;

out vec4 fragColor;

const float TAU = 6.2831853;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 p = uv * 2.0 - 1.0;
  float t = uTime / 60.0 * TAU;

  // Domain warp: each pass bends the coordinates with the previous one.
  vec2 q = p;
  q += 0.35 * vec2(sin(q.y * 2.3 + t * 2.0), cos(q.x * 2.1 - t * 3.0));
  q += 0.25 * vec2(cos(q.y * 3.1 - t * 4.0), sin(q.x * 2.7 + t * 2.0));

  float a = 0.5 + 0.5 * sin(q.x * 2.4 + q.y * 1.7 + t * 3.0);
  float b = 0.5 + 0.5 * sin(q.y * 2.9 - q.x * 1.3 - t * 2.0);

  vec3 deep = vec3(0.03, 0.05, 0.08);
  vec3 cool = vec3(0.16, 0.20, 0.48);
  vec3 warm = vec3(0.62, 0.30, 0.52);
  vec3 col = mix(deep, cool, a);
  col = mix(col, warm, b * 0.55 * a);
  col += uColor * pow(a * b, 3.0) * 0.55;

  // A soft diagonal band of light passes through once per cycle.
  float sweep = fract(uTime / 5.0);
  float d = (uv.x + uv.y) * 0.5 - (sweep * 1.6 - 0.3);
  col += vec3(0.9, 0.95, 1.0) * exp(-d * d * 60.0) * 0.18;

  float vignette = smoothstep(1.35, 0.35, length(p));
  col *= 0.55 + 0.45 * vignette;
  fragColor = vec4(col, 1.0);
}
