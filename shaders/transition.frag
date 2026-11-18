#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

// Full-screen mode transition, drawn on the GPU over the UI.
//   kind 0 = sleep: the edges darken and close in on a soft moon glow, stars wake, then it all
//                   clears to reveal the night sky.
//   kind 1 = wake:  warm light blooms up from the bottom edge, brightens everything, then fades,
//                   leaving the day.
uniform vec2 uSize;
uniform float uProgress;  // 0..1
uniform float uKind;      // 0 sleep, 1 wake

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float easeInOut(float t) {
  return t * t * (3.0 - 2.0 * t);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;
  float aspect = uSize.x / uSize.y;
  vec2 p = vec2(uv.x * aspect, uv.y);
  float t = clamp(uProgress, 0.0, 1.0);

  vec3 rgb = vec3(0.0);
  float a = 0.0;

  if (uKind < 0.5) {
    // Sleep: close in (0..0.55), hold a beat, clear (0.7..1).
    vec2 c = vec2(0.5 * aspect, 0.56);
    float d = length(p - c);
    float closing = easeInOut(clamp(t / 0.55, 0.0, 1.0));
    float clearing = easeInOut(clamp((t - 0.7) / 0.3, 0.0, 1.0));
    float radius = mix(1.3, 0.34, closing);
    // Darkness outside the iris, soft edge.
    float dark = smoothstep(radius - 0.35, radius + 0.25, d);
    float level = (1.0 - clearing);
    vec3 night = vec3(0.012, 0.018, 0.06);
    a = dark * 0.92 * level;
    rgb = night;
    // Moon glow in the middle, pulsing slowly.
    float pulse = 0.5 + 0.5 * sin(t * 9.0);
    float glow = exp(-d * d / (0.012 + 0.004 * pulse)) * closing * level;
    rgb = mix(rgb, vec3(0.72, 0.8, 1.0), glow);
    a = max(a, glow * 0.85);
    // Stars appear as it closes.
    vec2 g = p * 34.0;
    vec2 id = floor(g);
    vec2 f = fract(g) - 0.5;
    float h = hash(id);
    float star = step(0.955, h) * smoothstep(0.14, 0.0, length(f)) * (0.5 + 0.5 * sin(t * 18.0 + h * 40.0));
    star *= closing * level * smoothstep(0.1, 0.5, d);
    rgb = mix(rgb, vec3(0.9, 0.94, 1.0), clamp(star, 0.0, 1.0));
    a = max(a, star * 0.9);
  } else {
    // Wake: a warm bloom from the bottom centre, peak around 30%, gone by the end.
    vec2 c = vec2(0.5 * aspect, 1.08);
    float d = length(p - c);
    float grow = easeInOut(clamp(t / 0.55, 0.0, 1.0));
    float radius = grow * 1.9;
    float fade = 1.0 - easeInOut(clamp((t - 0.35) / 0.65, 0.0, 1.0));
    float edge = smoothstep(radius, radius - 0.55, d);
    float core = exp(-d * d / (0.25 + 0.6 * grow));
    vec3 warm = vec3(1.0, 0.74, 0.42);
    vec3 white = vec3(1.0, 0.95, 0.85);
    rgb = mix(warm, white, core);
    a = (edge * 0.55 + core * 0.35) * fade;
    // Thin rays that sweep outward.
    float ang = atan(p.y - c.y, p.x - c.x);
    float rays = pow(abs(sin(ang * 9.0 + t * 3.0)), 14.0) * smoothstep(radius, 0.0, d) * 0.18 * fade;
    rgb += vec3(1.0, 0.9, 0.7) * rays;
    a = clamp(a + rays, 0.0, 0.8);
  }

  // Premultiplied output.
  fragColor = vec4(rgb * a, a);
}
