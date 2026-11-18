import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:focus_launcher/weather/weather_service.dart';

const _forecastFixture = '''
{
  "latitude": -6.25,
  "longitude": 106.875,
  "timezone": "Asia/Jakarta",
  "current_units": {"time": "iso8601", "interval": "seconds", "temperature_2m": "°C", "weather_code": "wmo code", "is_day": ""},
  "current": {"time": "2026-11-18T14:00", "interval": 900, "temperature_2m": 31.4, "weather_code": 95, "is_day": 1},
  "daily_units": {"time": "iso8601", "temperature_2m_max": "°C", "temperature_2m_min": "°C"},
  "daily": {"time": ["2026-11-18"], "temperature_2m_max": [33.1], "temperature_2m_min": [25.6]}
}
''';

const _forecastNoDailyFixture = '''
{
  "current": {"time": "2026-11-18T02:00", "interval": 900, "temperature_2m": 24.0, "weather_code": 3, "is_day": 0}
}
''';

const _geocodingFixture = '''
{
  "results": [
    {
      "id": 1642911,
      "name": "Jakarta",
      "latitude": -6.21462,
      "longitude": 106.84513,
      "elevation": 8.0,
      "feature_code": "PPLC",
      "country_code": "ID",
      "admin1": "Jakarta",
      "timezone": "Asia/Jakarta",
      "country": "Indonesia"
    },
    {
      "id": 1650357,
      "name": "Bandung",
      "latitude": -6.91474,
      "longitude": 107.60981,
      "country_code": "ID",
      "admin1": "West Java",
      "timezone": "Asia/Jakarta",
      "country": "Indonesia"
    }
  ],
  "generationtime_ms": 0.5
}
''';

void main() {
  group('kindFromWmo', () {
    test('maps every documented WMO code to its family', () {
      const expected = <int, WeatherKind>{
        0: WeatherKind.clear,
        1: WeatherKind.partlyCloudy,
        2: WeatherKind.partlyCloudy,
        3: WeatherKind.cloudy,
        45: WeatherKind.fog,
        48: WeatherKind.fog,
        51: WeatherKind.drizzle,
        53: WeatherKind.drizzle,
        55: WeatherKind.drizzle,
        56: WeatherKind.drizzle,
        57: WeatherKind.drizzle,
        61: WeatherKind.rain,
        63: WeatherKind.rain,
        65: WeatherKind.rain,
        66: WeatherKind.rain,
        67: WeatherKind.rain,
        71: WeatherKind.snow,
        73: WeatherKind.snow,
        75: WeatherKind.snow,
        77: WeatherKind.snow,
        80: WeatherKind.rain,
        81: WeatherKind.rain,
        82: WeatherKind.rain,
        85: WeatherKind.snow,
        86: WeatherKind.snow,
        95: WeatherKind.thunder,
        96: WeatherKind.thunder,
        99: WeatherKind.thunder,
      };
      expected.forEach((code, kind) {
        expect(kindFromWmo(code), kind, reason: 'WMO code $code');
      });
    });

    test('falls back to cloudy for codes outside the table', () {
      expect(kindFromWmo(-1), WeatherKind.cloudy);
      expect(kindFromWmo(4), WeatherKind.cloudy);
      expect(kindFromWmo(100), WeatherKind.cloudy);
    });

    test('every kind has a human label', () {
      for (final kind in WeatherKind.values) {
        expect(kind.label, isNotEmpty);
      }
    });
  });

  group('parseForecast', () {
    final updated = DateTime(2026, 11, 18, 14);

    test('reads current conditions and today\'s range', () {
      final now = parseForecast(
        _forecastFixture,
        city: 'Jakarta',
        updated: updated,
      );
      expect(now.tempC, 31.4);
      expect(now.code, 95);
      expect(now.kind, WeatherKind.thunder);
      expect(now.isDay, isTrue);
      expect(now.hi, 33.1);
      expect(now.lo, 25.6);
      expect(now.city, 'Jakarta');
      expect(now.updated, updated);
    });

    test('uses the current temperature as range when daily is missing', () {
      final now = parseForecast(
        _forecastNoDailyFixture,
        city: 'Jakarta',
        updated: updated,
      );
      expect(now.tempC, 24.0);
      expect(now.kind, WeatherKind.cloudy);
      expect(now.isDay, isFalse);
      expect(now.hi, 24.0);
      expect(now.lo, 24.0);
    });

    test('throws on a payload without current conditions', () {
      expect(
        () => parseForecast('{"daily": {}}', city: 'X', updated: updated),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('parseGeocoding', () {
    test('returns suggestions with admin and country', () {
      final cities = parseGeocoding(_geocodingFixture);
      expect(cities, hasLength(2));
      expect(cities.first.name, 'Jakarta');
      expect(cities.first.admin, 'Jakarta');
      expect(cities.first.country, 'Indonesia');
      expect(cities.first.latitude, closeTo(-6.21462, 1e-9));
      expect(cities.first.longitude, closeTo(106.84513, 1e-9));
      expect(cities.first.timezone, 'Asia/Jakarta');
      expect(cities.last.label, 'Bandung, West Java, Indonesia');
    });

    test('returns an empty list when there are no matches', () {
      expect(parseGeocoding('{"generationtime_ms": 0.2}'), isEmpty);
    });
  });

  group('serialisation', () {
    test('CitySuggestion round-trips through JSON', () {
      const city = CitySuggestion(
        name: 'Bandung',
        admin: 'West Java',
        country: 'Indonesia',
        latitude: -6.91474,
        longitude: 107.60981,
        timezone: 'Asia/Jakarta',
      );
      final back = CitySuggestion.fromJson(
        jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
      );
      expect(back, city);
      expect(back.timezone, 'Asia/Jakarta');
    });

    test('CitySuggestion label omits a duplicated admin name', () {
      expect(defaultCity.label, 'Jakarta, Indonesia');
    });

    test('WeatherNow round-trips through JSON', () {
      final now = WeatherNow(
        tempC: 31.4,
        code: 2,
        isDay: true,
        hi: 33.1,
        lo: 25.6,
        city: 'Jakarta',
        updated: DateTime(2026, 11, 18, 14, 5),
      );
      final back = WeatherNow.fromJson(
        jsonDecode(jsonEncode(now.toJson())) as Map<String, dynamic>,
      );
      expect(back.tempC, 31.4);
      expect(back.code, 2);
      expect(back.kind, WeatherKind.partlyCloudy);
      expect(back.isDay, isTrue);
      expect(back.hi, 33.1);
      expect(back.lo, 25.6);
      expect(back.city, 'Jakarta');
      expect(back.updated, DateTime(2026, 11, 18, 14, 5));
    });
  });

  group('request URIs', () {
    test('forecast requests current fields and auto timezone', () {
      final uri = forecastUri(defaultCity);
      expect(uri.host, 'api.open-meteo.com');
      expect(uri.path, '/v1/forecast');
      expect(uri.queryParameters['current'],
          'temperature_2m,weather_code,is_day');
      expect(uri.queryParameters['daily'],
          'temperature_2m_max,temperature_2m_min,sunrise,sunset');
      expect(uri.queryParameters['timezone'], 'auto');
      expect(uri.queryParameters['latitude'], '-6.2088');
    });

    test('geocoding encodes the query text', () {
      final uri = geocodingUri('Kuala Lumpur');
      expect(uri.host, 'geocoding-api.open-meteo.com');
      expect(uri.path, '/v1/search');
      expect(uri.queryParameters['name'], 'Kuala Lumpur');
    });
  });
}
