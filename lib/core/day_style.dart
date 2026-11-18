import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../weather/weather_service.dart';
import 'mode_engine.dart';

/// Lighting phase of the day. Drives the sky, the scrim over it and the accent colour.
enum DayPhase {
  night('Night'),
  dawn('Dawn'),
  morning('Morning'),
  day('Day'),
  dusk('Dusk');

  const DayPhase(this.label);
  final String label;

  static DayPhase? fromName(String? name) {
    for (final p in DayPhase.values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// Fallback sunrise and sunset (minutes since midnight) when the weather service has none.
const defaultSunriseMinute = 6 * 60;
const defaultSunsetMinute = 18 * 60;

/// Phase for local time [now]. Dawn spans 45 minutes either side of sunrise, dusk runs from
/// an hour before sunset to 45 minutes after it. Pure, so it is easy to test.
DayPhase phaseFor(DateTime now, {int? sunriseMinute, int? sunsetMinute}) {
  final rise = sunriseMinute ?? defaultSunriseMinute;
  final set = sunsetMinute ?? defaultSunsetMinute;
  final m = now.hour * 60 + now.minute;
  if (m >= rise - 45 && m < rise + 45) return DayPhase.dawn;
  // Morning runs until 11:00 (or an hour before the day ends on very short days).
  final noon = math.min(11 * 60, set - 120);
  if (m >= rise + 45 && m < noon) return DayPhase.morning;
  if (m >= noon && m < set - 60) return DayPhase.day;
  if (m >= set - 60 && m < set + 45) return DayPhase.dusk;
  return DayPhase.night;
}

/// Colours and strengths that change with the phase.
///
/// Dark skies (night, dawn, dusk, storms) use a dark scrim and light ink. Bright skies (morning,
/// day) use a pale veil and dark ink, so text stays readable and the screen feels fresh.
class DayStyle {
  const DayStyle({
    required this.scrim,
    required this.scrimAlpha,
    required this.accent,
    required this.cardAlpha,
    this.light = false,
  });

  /// Colour laid over the sky so text stays readable.
  final Color scrim;

  /// Scrim opacity at the top, middle and bottom of the screen.
  final (double, double, double) scrimAlpha;

  final Color accent;

  /// Opacity of the cards over the sky.
  final double cardAlpha;

  /// True for bright skies: pale veil, dark ink.
  final bool light;

  static const _inkLightMode = Color(0xFF0A1A2A);
  static const _inkSoftLightMode = Color(0xFF1E3347);
  static const _inkDarkMode = Color(0xFFE8EEF2);
  static const _inkSoftDarkMode = Color(0xFFCBD7DB);

  /// Main text colour on the sky.
  Color get ink => light ? _inkLightMode : _inkDarkMode;

  /// Secondary text colour on the sky.
  Color get inkSoft => light ? _inkSoftLightMode : _inkSoftDarkMode;

  /// Attention colour (missing permission and similar) with enough contrast on this sky.
  Color get warn => light ? const Color(0xFF8A4B00) : const Color(0xFFF5B86B);

  /// Glow behind text: dark on dark skies, white on bright ones.
  Color get shadow => light ? const Color(0x99FFFFFF) : const Color(0x99000000);

  /// Fill for pills and cards that sit on the sky.
  Color get pill => light ? const Color(0x66FFFFFF) : const Color(0x66000000);

  static const night = DayStyle(
    scrim: Color(0xFF050809),
    scrimAlpha: (0.20, 0.62, 0.78),
    accent: Color(0xFF5EEAD4),
    cardAlpha: 0.82,
  );

  static const dawn = DayStyle(
    scrim: Color(0xFF160F1E),
    scrimAlpha: (0.26, 0.46, 0.52),
    accent: Color(0xFFFFC7A0),
    cardAlpha: 0.70,
  );

  static const dusk = DayStyle(
    scrim: Color(0xFF1A0F1B),
    scrimAlpha: (0.26, 0.48, 0.54),
    accent: Color(0xFFFFB27A),
    cardAlpha: 0.70,
  );

  /// Day sky in rain or a storm: dark, so light ink.
  static const dayDark = DayStyle(
    scrim: Color(0xFF08202F),
    scrimAlpha: (0.40, 0.56, 0.46),
    accent: Color(0xFF9CF3E4),
    cardAlpha: 0.58,
  );

  static const morning = DayStyle(
    scrim: Color(0xFFFFF6EA),
    scrimAlpha: (0.40, 0.50, 0.40),
    accent: Color(0xFF0B6B5E),
    cardAlpha: 0.55,
    light: true,
  );

  static const dayLight = DayStyle(
    scrim: Color(0xFFF1F7FB),
    scrimAlpha: (0.42, 0.52, 0.42),
    accent: Color(0xFF0B6B5E),
    cardAlpha: 0.55,
    light: true,
  );

  /// A copy with a stronger scrim, for very bright skies (snow, fog).
  DayStyle boosted(double by) => DayStyle(
    scrim: scrim,
    scrimAlpha: (
      (scrimAlpha.$1 + by).clamp(0.0, 0.95),
      (scrimAlpha.$2 + by).clamp(0.0, 0.95),
      (scrimAlpha.$3 + by * 0.5).clamp(0.0, 0.95),
    ),
    accent: accent,
    cardAlpha: (cardAlpha + by * 0.5).clamp(0.0, 0.95),
    light: light,
  );
}

/// Style for a phase and weather.
DayStyle styleFor(DayPhase phase, WeatherKind kind) {
  final storm = kind == WeatherKind.drizzle || kind == WeatherKind.rain || kind == WeatherKind.thunder;
  final bright = kind == WeatherKind.snow || kind == WeatherKind.fog;
  switch (phase) {
    case DayPhase.night:
      return DayStyle.night;
    case DayPhase.dawn:
      return DayStyle.dawn;
    case DayPhase.dusk:
      return DayStyle.dusk;
    case DayPhase.morning:
    case DayPhase.day:
      if (storm) return DayStyle.dayDark;
      final base = phase == DayPhase.morning ? DayStyle.morning : DayStyle.dayLight;
      return bright ? base.boosted(0.14) : base;
  }
}

/// Current phase and weather kind for the UI, with optional manual previews.
///
/// The phase follows the clock (re-checked every minute) and the city's sunrise and sunset.
/// A preview overrides it until set back to automatic, which is how you can see every
/// lighting and weather combination without waiting for it.
class StyleController extends ChangeNotifier {
  StyleController(this._prefs, this._weather, this._modes, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    final until = _prefs.getInt(_kUntil);
    _previewUntil = until == null ? null : DateTime.fromMillisecondsSinceEpoch(until);
    if (_previewUntil != null && !_previewUntil!.isAfter(_clock())) {
      _previewUntil = null;
      _prefs.remove(_kPhase);
      _prefs.remove(_kKind);
      _prefs.remove(_kUntil);
    } else {
      _phasePreview = DayPhase.fromName(_prefs.getString(_kPhase));
      final kind = _prefs.getString(_kKind);
      for (final k in WeatherKind.values) {
        if (k.name == kind) _kindPreview = k;
      }
    }
    _weather.addListener(_recompute);
    _modes.addListener(_recompute);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _recompute());
    _phase = _compute();
    _kind = _computeKind();
  }

  static const _kPhase = 'style.phase';
  static const _kKind = 'style.kind';
  static const _kUntil = 'style.previewUntil';

  /// Previews end by themselves, so a forgotten test never leaves the home screen stuck.
  static const previewLifetime = Duration(minutes: 10);

  final SharedPreferences _prefs;
  final WeatherService _weather;
  final ModeEngine _modes;
  final DateTime Function() _clock;
  Timer? _timer;

  DateTime? _previewUntil;
  DayPhase? _phasePreview;
  WeatherKind? _kindPreview;
  late DayPhase _phase;
  late WeatherKind _kind;

  DayPhase get phase => _phase;
  WeatherKind get kind => _kind;
  DayStyle get style => styleFor(_phase, _kind);

  /// Null means automatic.
  DayPhase? get phasePreview => _phasePreview;
  WeatherKind? get kindPreview => _kindPreview;

  /// True while a time-of-day or weather preview is overriding the live values.
  bool get previewActive => _phasePreview != null || _kindPreview != null;
  DateTime? get previewUntil => _previewUntil;

  Future<void> _stampPreview() async {
    if (!previewActive) {
      _previewUntil = null;
      await _prefs.remove(_kUntil);
      return;
    }
    _previewUntil = _clock().add(previewLifetime);
    await _prefs.setInt(_kUntil, _previewUntil!.millisecondsSinceEpoch);
  }

  /// Clears every preview now.
  Future<void> endPreview() async {
    _phasePreview = null;
    _kindPreview = null;
    await _prefs.remove(_kPhase);
    await _prefs.remove(_kKind);
    await _stampPreview();
    _recompute();
  }

  DayPhase _compute() {
    final preview = _phasePreview;
    if (preview != null) return preview;
    // Sleep mode always looks like night, whatever the clock says.
    if (_modes.current.id == 'sleep') return DayPhase.night;
    final w = _weather.now;
    return phaseFor(_clock(), sunriseMinute: w?.sunriseMinute, sunsetMinute: w?.sunsetMinute);
  }

  WeatherKind _computeKind() => _kindPreview ?? _weather.now?.kind ?? WeatherKind.clear;

  void _recompute() {
    final until = _previewUntil;
    if (until != null && !until.isAfter(_clock())) {
      _phasePreview = null;
      _kindPreview = null;
      _previewUntil = null;
      _prefs.remove(_kPhase);
      _prefs.remove(_kKind);
      _prefs.remove(_kUntil);
    }
    final p = _compute();
    final k = _computeKind();
    if (p == _phase && k == _kind) return;
    _phase = p;
    _kind = k;
    notifyListeners();
  }

  Future<void> previewPhase(DayPhase? p) async {
    _phasePreview = p;
    p == null ? await _prefs.remove(_kPhase) : await _prefs.setString(_kPhase, p.name);
    await _stampPreview();
    _recompute();
  }

  Future<void> previewKind(WeatherKind? k) async {
    _kindPreview = k;
    k == null ? await _prefs.remove(_kKind) : await _prefs.setString(_kKind, k.name);
    await _stampPreview();
    _recompute();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _weather.removeListener(_recompute);
    _modes.removeListener(_recompute);
    super.dispose();
  }
}
