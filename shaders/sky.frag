#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

// Procedural weather sky, rendered entirely on the GPU.
uniform vec2 uSize;     // pixels
uniform float uTime;    // seconds
uniform float uKind;    // 0 clear, 1 partly cloudy, 2 cloudy, 3 fog, 4 drizzle, 5 rain, 6 thunder, 7 snow
uniform float uPhase;   // 0 night, 1 dawn, 2 day, 3 dusk
uniform vec3 uTop;      // sky gradient, top
uniform vec3 uBottom;   // sky gradient, bottom
uniform vec4 uCloud;    // cloud rgb + max alpha

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 3; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(7.1, 3.7);
    a *= 0.5;
  }
  return v / 0.875;
}

// One layer of falling streaks.
float rainLayer(vec2 uv, float cols, float speed, float t) {
  float x = uv.x + uv.y * 0.12;
  float col = floor(x * cols);
  float h = hash(vec2(col, 3.0));
  float on = step(0.4, hash(vec2(col, 9.0)));
  float xc = (col + 0.2 + 0.6 * h) / cols;
  float dxPx = abs(x - xc) * uSize.x;
  float y = fract(uv.y * 1.3 - t * speed * (0.7 + h) + h * 5.0);
  float tail = clamp(1.0 - y / 0.1, 0.0, 1.0);
  return on * tail * smoothstep(1.5, 0.3, dxPx);
}

// One layer of drifting flakes.
float snowLayer(vec2 uv, float aspect, float scale, float speed, float t) {
  vec2 g = vec2(uv.x * aspect, uv.y - t * speed) * scale;
  vec2 id = floor(g);
  vec2 f = fract(g) - 0.5;
  float h = hash(id);
  f.x += (h - 0.5) * 0.5 + sin(t * 1.5 + h * 6.28) * 0.15;
  float r = 0.07 + 0.05 * hash(id + 7.0);
  return step(0.55, hash(id + 3.0)) * smoothstep(r, r * 0.35, length(f));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;
  float aspect = uSize.x / uSize.y;
  vec2 p = vec2(uv.x * aspect, uv.y);
  float t = uTime;

  vec3 col = mix(uTop, uBottom, uv.y);

  // Warm glow near the horizon at dawn and dusk.
  if (uPhase > 0.5 && uPhase < 1.5 || uPhase > 2.5) {
    float g = exp(-pow((uv.y - 0.9) * 3.0, 2.0));
    col += vec3(1.0, 0.55, 0.32) * g * 0.32;
  }

  // Sun or moon, only when the sky is mostly clear.
  if (uKind < 1.5) {
    bool sunUp = uPhase > 0.5;
    // The orb sits in the empty lower part of the screen so it never lands on the clock or text.
    float orbX = uPhase < 0.5 ? 0.8 : (uPhase < 1.5 ? 0.22 : (uPhase < 2.5 ? 0.78 : 0.8));
    float orbY = uPhase < 0.5 ? 0.9 : (uPhase < 1.5 ? 0.95 : (uPhase < 2.5 ? 0.88 : 0.96));
    vec2 orb = vec2(orbX * aspect, orbY);
    float d = length(p - orb);
    if (sunUp) {
      float pulse = 0.5 + 0.5 * sin(t * 0.8);
      float glow = exp(-d * d / (0.0105 + 0.0012 * pulse));
      float ang = atan(p.y - orb.y, p.x - orb.x);
      float rays = pow(abs(sin(ang * 6.0 + t * 0.4)), 10.0) * exp(-d * 9.0);
      vec3 sunTint = (uPhase > 1.5 && uPhase < 2.5) ? vec3(1.0, 0.89, 0.66) : vec3(1.0, 0.62, 0.38);
      col += sunTint * (glow * 0.5 + rays * 0.18);
      col = mix(col, mix(vec3(1.0, 0.96, 0.84), vec3(1.0, 0.82, 0.6), step(1.5, abs(uPhase - 2.0) + 0.5)), smoothstep(0.034, 0.029, d));
    } else {
      float glow = exp(-d * d / 0.006);
      col += vec3(0.55, 0.65, 0.85) * glow * 0.22;
      col = mix(col, vec3(0.9, 0.93, 1.0), smoothstep(0.03, 0.026, d));
      // Twinkling stars in the upper sky.
      vec2 g = p * vec2(38.0, 38.0);
      vec2 id = floor(g);
      vec2 f = fract(g) - 0.5;
      float h = hash(id);
      float star = step(0.965, h) * smoothstep(0.12, 0.0, length(f)) * (1.0 - smoothstep(0.35, 0.7, uv.y));
      star *= 0.55 + 0.45 * sin(t * (1.5 + h * 3.0) + h * 40.0);
      col += vec3(0.85, 0.9, 1.0) * star;
    }
  }

  // Clouds.
  float cov = uKind < 0.5 ? 0.0
            : uKind < 1.5 ? 0.38
            : uKind < 2.5 ? 0.72
            : uKind < 3.5 ? 0.3
            : uKind < 6.5 ? 0.82
            : 0.62;
  if (cov > 0.02) {
    vec2 q = vec2(p.x * 1.7 + t * 0.018, p.y * 3.2);
    float n = fbm(q);
    float mask = smoothstep(0.75, 0.15, uv.y);
    float a = smoothstep(1.0 - cov, 1.0 - cov + 0.22, n) * mask * min(1.0, uCloud.a * (uPhase < 0.5 ? 1.5 : 1.0));
    col = mix(col, uCloud.rgb, a);
  }

  // Fog bands.
  if (uKind > 2.5 && uKind < 3.5) {
    float n = fbm(vec2(p.x * 1.2 + t * 0.015, p.y * 5.0));
    float band = smoothstep(0.35, 0.85, n) * smoothstep(0.2, 0.5, uv.y) * smoothstep(1.0, 0.7, uv.y);
    col = mix(col, uCloud.rgb, band * 0.45);
  }

  // Rain, drizzle and thunderstorms.
  if (uKind > 3.5 && uKind < 6.5) {
    float heavy = uKind < 4.5 ? 0.55 : 1.0;
    float r = rainLayer(uv, 26.0, 1.5, t) * 0.6 + rainLayer(uv + vec2(0.31, 0.17), 44.0, 1.9, t) * 0.45;
    col += vec3(0.72, 0.8, 0.88) * r * 0.55 * heavy;
  }

  // Lightning.
  if (uKind > 5.5 && uKind < 6.5) {
    float s = floor(t * 0.7);
    float flash = exp(-fract(t * 0.7) * 7.0) * step(0.72, hash(vec2(s, 1.0)));
    col += vec3(0.7, 0.8, 1.0) * flash * 0.32;
  }

  // Snow.
  if (uKind > 6.5) {
    float s = snowLayer(uv, aspect, 14.0, 0.07, t) * 0.9 + snowLayer(uv + vec2(0.4, 0.2), aspect, 26.0, 0.12, t) * 0.7;
    col = mix(col, vec3(0.95, 0.97, 1.0), clamp(s, 0.0, 1.0) * 0.85);
  }

  fragColor = vec4(col, 1.0);
}
