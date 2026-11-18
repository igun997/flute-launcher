import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/core/day_style.dart';
import 'package:focus_launcher/weather/weather_service.dart';

void main() {
  group('phaseFor', () {
    // Sunrise 05:40, sunset 17:50 (Jakarta in November).
    DayPhase at(int h, int m) => phaseFor(DateTime(2026, 11, 18, h, m), sunriseMinute: 5 * 60 + 40, sunsetMinute: 17 * 60 + 50);

    test('covers the whole day in order', () {
      expect(at(3, 0), DayPhase.night);
      expect(at(5, 0), DayPhase.dawn); // 45 min before sunrise
      expect(at(6, 20), DayPhase.dawn);
      expect(at(6, 25), DayPhase.morning);
      expect(at(10, 59), DayPhase.morning);
      expect(at(11, 0), DayPhase.day);
      expect(at(12, 0), DayPhase.day);
      expect(at(16, 49), DayPhase.day);
      expect(at(16, 50), DayPhase.dusk); // one hour before sunset
      expect(at(18, 34), DayPhase.dusk);
      expect(at(18, 35), DayPhase.night); // 45 min after sunset
      expect(at(23, 59), DayPhase.night);
    });

    test('falls back to 06:00 and 18:00 without sunrise and sunset', () {
      expect(phaseFor(DateTime(2026, 1, 1, 12)), DayPhase.day);
      expect(phaseFor(DateTime(2026, 1, 1, 9)), DayPhase.morning);
      expect(phaseFor(DateTime(2026, 1, 1, 2)), DayPhase.night);
      expect(phaseFor(DateTime(2026, 1, 1, 6)), DayPhase.dawn);
    });
  });

  test('parseForecast reads sunrise and sunset as minutes of the day', () {
    const body = '{"current":{"temperature_2m":27.0,"weather_code":3,"is_day":1},'
        '"daily":{"temperature_2m_max":[31.0],"temperature_2m_min":[24.0],'
        '"sunrise":["2026-11-18T05:42"],"sunset":["2026-11-18T17:51"]}}';
    final now = parseForecast(body, city: 'Jakarta', updated: DateTime(2026, 11, 18));
    expect(now.sunriseMinute, 5 * 60 + 42);
    expect(now.sunsetMinute, 17 * 60 + 51);
    final back = WeatherNow.fromJson(now.toJson());
    expect(back.sunriseMinute, 5 * 60 + 42);
    expect(back.sunsetMinute, 17 * 60 + 51);
  });

  test('missing or malformed sun times stay null instead of failing', () {
    const body = '{"current":{"temperature_2m":27.0,"weather_code":3,"is_day":0},"daily":{"sunrise":["bad"]}}';
    final now = parseForecast(body, city: 'X', updated: DateTime(2026));
    expect(now.sunriseMinute, isNull);
    expect(now.sunsetMinute, isNull);
  });
}
