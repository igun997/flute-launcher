#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

// The voice orb: a soft core that breathes with the microphone level and swirls while the agent
// thinks or speaks. Premultiplied output; draw it with the default source-over blend.
uniform vec2 uSize;
uniform float uTime;
uniform float uLevel;   // 0..1 microphone level
uniform float uState;   // 0 idle, 1 listening, 2 thinking, 3 speaking
uniform vec3 uColor;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 p = (uv - 0.5) * 2.0;
  float d = length(p);
  float angle = atan(p.y, p.x);

  float speed = uState > 1.5 ? 1.6 : 0.6;
  float wobble = 0.5 + 0.5 * sin(angle * 3.0 + uTime * speed)
               * sin(angle * 2.0 - uTime * speed * 0.7);
  float reach = 0.42 + 0.12 * uLevel + 0.04 * uState;
  float radius = reach + 0.06 * wobble * (0.4 + uLevel);

  float core = smoothstep(radius, radius - 0.18, d);
  float halo = pow(smoothstep(1.0, 0.0, d), 2.2) * (0.35 + 0.45 * uLevel);
  float a = clamp(core * 0.9 + halo, 0.0, 1.0);
  fragColor = vec4(uColor * a, a);
}
