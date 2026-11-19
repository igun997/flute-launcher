#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

// The voice orb: a soft core, two thin rings and a halo.
// Dart eases four state weights (idle, listening, thinking, speaking) that always sum to 1, so every
// state mixes continuously instead of jumping:
//   idle: slow breathing. listening: the rings and halo follow the microphone level.
//   thinking: one bright arc orbits the first ring. speaking: a ripple travels outwards.
// uTime loops every 12 s (0..12) and every time term is an integer multiple of W, so the loop is
// seamless and the phases stay small enough for mediump.
// Premultiplied output; draw it with the default source-over blend.
uniform vec2 uSize;
uniform float uTime;    // seconds, 0..12, loops
uniform float uLevel;   // 0..1 microphone level
uniform float uIdle;    // state weights
uniform float uListen;
uniform float uThink;
uniform float uSpeak;
uniform vec3 uColor;

out vec4 fragColor;

const float W = 0.5235988;  // 2 * pi / 12

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 p = (uv - 0.5) * 2.0;
  float d = length(p);
  float angle = atan(p.y, p.x);
  float level = clamp(uLevel, 0.0, 1.0);

  float breath = sin(uTime * W * 3.0);  // 4 s cycle
  float wobble = 0.6 * sin(angle * 3.0 + uTime * W * 4.0)
               + 0.4 * sin(angle * 5.0 - uTime * W * 6.0);

  // Core: a soft disc that breathes at rest, swells with the voice and wobbles while speaking.
  float coreR = 0.30 + 0.035 * uIdle * breath + 0.05 * uListen * level
              + 0.035 * uSpeak * wobble + 0.02 * uThink;
  float core = 1.0 - smoothstep(coreR * 0.25, coreR, d);

  // Two thin rings. The first one expands with the microphone level and gently breathes at rest.
  float r1 = 0.56 + 0.10 * uListen * level + 0.015 * uIdle * breath + 0.02 * uSpeak * wobble;
  float r2 = 0.76 + 0.04 * uListen * level - 0.012 * uIdle * breath;
  float line1 = 1.0 - smoothstep(0.0, 0.012, abs(d - r1));
  float line2 = 1.0 - smoothstep(0.0, 0.010, abs(d - r2));

  // Thinking: one arc orbits the first ring, and the second ring turns into dashes.
  float arc = pow(0.5 + 0.5 * cos(angle - uTime * W), 6.0);
  float arcGain = mix(1.0, 0.15 + 0.85 * arc, uThink);
  float dash = smoothstep(0.2, 0.8, 0.5 + 0.5 * sin(angle * 6.0 - uTime * W * 2.0));
  float dashGain = mix(1.0, dash, uThink);
  float rings = 0.85 * line1 * arcGain + 0.45 * line2 * dashGain;

  // Speaking: a ripple travels outwards through the halo.
  float wave = 0.5 + 0.5 * sin(d * 14.0 - uTime * W * 5.0);
  float waveBand = smoothstep(0.3, 0.6, d) * (1.0 - smoothstep(0.85, 1.0, d));
  float waves = wave * waveBand * uSpeak * 0.32;

  // Halo: a soft glow that is brighter while listening, thinking and speaking.
  float halo = pow(max(1.0 - d, 0.0), 2.4)
             * (0.22 + 0.30 * uListen * level + 0.12 * uThink + 0.08 * uSpeak);

  float a = clamp(core * 0.9 + rings + waves + halo, 0.0, 1.0);
  vec3 col = mix(uColor, vec3(1.0), core * 0.35);
  fragColor = vec4(col * a, a);
}
