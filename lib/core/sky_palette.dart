import 'package:flutter/painting.dart';

import '../weather/weather_service.dart';
import 'day_style.dart';

/// Phase code the sky shader understands: 0 night, 1 dawn, 2 day (morning looks like day with a
/// warmer palette), 3 dusk.
double shaderPhase(DayPhase p) => switch (p) {
  DayPhase.night => 0,
  DayPhase.dawn => 1,
  DayPhase.morning || DayPhase.day => 2,
  DayPhase.dusk => 3,
};

(Color, Color) _palette(WeatherKind kind, bool isDay) {
  if (isDay) {
    return switch (kind) {
      WeatherKind.clear => (
        const Color(0xFF1C4A6B),
        const Color(0xFF6FA6C4),
      ),
      WeatherKind.partlyCloudy => (
        const Color(0xFF26506F),
        const Color(0xFF7DAAC0),
      ),
      WeatherKind.cloudy => (const Color(0xFF38475A), const Color(0xFF6E7F8E)),
      WeatherKind.fog => (const Color(0xFF59646C), const Color(0xFF9AA5AC)),
      WeatherKind.drizzle => (
        const Color(0xFF3A4A58),
        const Color(0xFF687C8B),
      ),
      WeatherKind.rain => (const Color(0xFF2F3E4C), const Color(0xFF5A6E7E)),
      WeatherKind.thunder => (
        const Color(0xFF202A35),
        const Color(0xFF4A5862),
      ),
      WeatherKind.snow => (const Color(0xFF4B5C6B), const Color(0xFFB7C5D1)),
    };
  }
  return switch (kind) {
    WeatherKind.clear => (const Color(0xFF05080F), const Color(0xFF1A2844)),
    WeatherKind.partlyCloudy => (
      const Color(0xFF080C14),
      const Color(0xFF1D2A40),
    ),
    WeatherKind.cloudy => (const Color(0xFF090C11), const Color(0xFF1C2430)),
    WeatherKind.fog => (const Color(0xFF0E1216), const Color(0xFF2A3238)),
    WeatherKind.drizzle => (const Color(0xFF0A0E14), const Color(0xFF202B38)),
    WeatherKind.rain => (const Color(0xFF080B10), const Color(0xFF1A2330)),
    WeatherKind.thunder => (const Color(0xFF06070B), const Color(0xFF171E2A)),
    WeatherKind.snow => (const Color(0xFF0C1322), const Color(0xFF2B3A4E)),
  };
}

Color _cloudColor(WeatherKind kind, bool isDay) {
  final storm =
      kind == WeatherKind.drizzle ||
      kind == WeatherKind.rain ||
      kind == WeatherKind.thunder;
  if (storm) {
    return isDay ? const Color(0xCC28323D) : const Color(0xCC0C1016);
  }
  if (kind == WeatherKind.snow) {
    return isDay ? const Color(0x8CC4D2DE) : const Color(0x995B6B80);
  }
  return isDay ? const Color(0x80AEBFCE) : const Color(0x66505E74);
}

/// Sky gradient (top, bottom) for a weather kind in a lighting phase. Dawn and dusk blend
/// the night and day skies and warm the horizon.
(Color, Color) skyColors(WeatherKind kind, DayPhase phase) {
  final night = _palette(kind, false);
  final day = _palette(kind, true);
  switch (phase) {
    case DayPhase.night:
      return night;
    case DayPhase.day:
      // An overcast day should still feel bright, not slate: a soft blue-gray under the pale veil.
      if (kind == WeatherKind.cloudy) return (const Color(0xFF6F93B8), const Color(0xFFC6D4E2));
      return day;
    case DayPhase.morning:
      // Fresh and warm: blue sky into a cream horizon. Storms keep their dark day palette.
      final storm = kind == WeatherKind.drizzle || kind == WeatherKind.rain || kind == WeatherKind.thunder;
      if (storm) return day;
      final clearish = kind == WeatherKind.clear || kind == WeatherKind.partlyCloudy;
      return clearish
          ? (const Color(0xFF3F86C6), const Color(0xFFF6DDB0))
          : (const Color(0xFF6E9FCB), const Color(0xFFEADFCB));
    case DayPhase.dawn:
      return (
        Color.lerp(night.$1, day.$1, 0.45)!,
        Color.lerp(Color.lerp(night.$2, day.$2, 0.45)!, const Color(0xFFE8A07A), kind == WeatherKind.clear || kind == WeatherKind.partlyCloudy ? 0.5 : 0.25)!,
      );
    case DayPhase.dusk:
      return (
        Color.lerp(night.$1, day.$1, 0.30)!,
        Color.lerp(Color.lerp(night.$2, day.$2, 0.30)!, const Color(0xFFD0705A), kind == WeatherKind.clear || kind == WeatherKind.partlyCloudy ? 0.55 : 0.28)!,
      );
  }
}

/// Cloud tint for a weather kind in a lighting phase. Dawn and dusk warm the clouds.
Color cloudColor(WeatherKind kind, DayPhase phase) {
  switch (phase) {
    case DayPhase.night:
      return _cloudColor(kind, false);
    case DayPhase.day:
    case DayPhase.morning:
      return _cloudColor(kind, true);
    case DayPhase.dawn:
    case DayPhase.dusk:
      final base = _cloudColor(kind, true);
      return Color.lerp(base, const Color(0x99B07A68), 0.5)!;
  }
}
