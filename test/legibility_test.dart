import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/core/day_style.dart';
import 'package:focus_launcher/core/sky_palette.dart';
import 'package:focus_launcher/weather/weather_service.dart';

double _lin(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
double _luminance(Color c) => 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);
double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Background colour at height [y] (0 top .. 1 bottom): the sky gradient, the densest cloud the
/// shader can paint, then the scrim. The text colours come from the same [styleFor].
Color _background(WeatherKind kind, DayPhase phase, double y) {
  final (top, bottom) = skyColors(kind, phase);
  var bg = Color.lerp(top, bottom, y)!;
  if (kind != WeatherKind.clear) {
    final cloud = cloudColor(kind, phase);
    // The shader boosts cloud alpha 1.5x at night only (capped at 1).
    final a = math.min(1.0, cloud.a * (phase == DayPhase.night ? 1.5 : 1.0));
    bg = Color.lerp(bg, Color.fromARGB(255, (cloud.r * 255).round(), (cloud.g * 255).round(), (cloud.b * 255).round()), a)!;
  }
  final s = styleFor(phase, kind);
  final (a0, a1, a2) = s.scrimAlpha;
  final alpha = y < 0.45 ? a0 + (a1 - a0) * (y / 0.45) : a1 + (a2 - a1) * ((y - 0.45) / 0.55);
  return Color.alphaBlend(s.scrim.withValues(alpha: alpha), bg);
}

void main() {
  // Rows where text sits on the sky itself: clock and date (top), then the inbox line, pins and
  // hints (down to about two thirds of the screen).
  test('clock digits stay readable on every sky', () {
    for (final phase in DayPhase.values) {
      for (final kind in WeatherKind.values) {
        final ink = styleFor(phase, kind).ink;
        for (final y in [0.05, 0.12, 0.2]) {
          final c = _contrast(ink, _background(kind, phase, y));
          expect(c, greaterThanOrEqualTo(3.0), reason: '${phase.name} ${kind.name} y=$y contrast $c');
        }
      }
    }
  });

  test('secondary text stays readable on every sky', () {
    for (final phase in DayPhase.values) {
      for (final kind in WeatherKind.values) {
        final ink = styleFor(phase, kind).inkSoft;
        for (final y in [0.2, 0.3, 0.45, 0.62]) {
          final c = _contrast(ink, _background(kind, phase, y));
          expect(c, greaterThanOrEqualTo(4.5), reason: '${phase.name} ${kind.name} y=$y contrast $c');
        }
      }
    }
  });

  test('bright skies use dark ink, dark skies light ink', () {
    expect(styleFor(DayPhase.morning, WeatherKind.clear).light, isTrue);
    expect(styleFor(DayPhase.day, WeatherKind.snow).light, isTrue);
    expect(styleFor(DayPhase.day, WeatherKind.rain).light, isFalse);
    expect(styleFor(DayPhase.night, WeatherKind.clear).light, isFalse);
    expect(styleFor(DayPhase.dusk, WeatherKind.clear).light, isFalse);
  });
}
