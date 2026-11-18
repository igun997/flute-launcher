import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../native/flute_native.dart';

const _forecastHost = 'api.open-meteo.com';
const _geocodingHost = 'geocoding-api.open-meteo.com';
const _cityKey = 'weather.city';
const _nowKey = 'weather.now';
const _followKey = 'weather.follow';
const _minInterval = Duration(minutes: 20);
const _requestTimeout = Duration(seconds: 8);
const _headers = {'Accept': 'application/json'};

/// Broad condition families used for icons and procedural scenes.
enum WeatherKind {
  clear('Clear'),
  partlyCloudy('Partly cloudy'),
  cloudy('Cloudy'),
  fog('Fog'),
  drizzle('Drizzle'),
  rain('Rain'),
  thunder('Thunderstorm'),
  snow('Snow');

  const WeatherKind(this.label);

  final String label;
}

/// Maps a WMO weather interpretation code (as used by Open-Meteo) to a kind.
/// Unknown codes fall back to [WeatherKind.cloudy].
WeatherKind kindFromWmo(int code) => switch (code) {
  0 => WeatherKind.clear,
  1 || 2 => WeatherKind.partlyCloudy,
  3 => WeatherKind.cloudy,
  >= 45 && <= 48 => WeatherKind.fog,
  >= 51 && <= 57 => WeatherKind.drizzle,
  >= 61 && <= 67 => WeatherKind.rain,
  >= 71 && <= 77 => WeatherKind.snow,
  >= 80 && <= 82 => WeatherKind.rain,
  85 || 86 => WeatherKind.snow,
  >= 95 && <= 99 => WeatherKind.thunder,
  _ => WeatherKind.cloudy,
};

class WeatherException implements Exception {
  const WeatherException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CitySuggestion {
  const CitySuggestion({
    required this.name,
    required this.admin,
    required this.country,
    required this.latitude,
    required this.longitude,
    required this.timezone,
  });

  factory CitySuggestion.fromJson(Map<String, dynamic> json) => CitySuggestion(
    name: json['name'] as String,
    admin: json['admin'] as String? ?? '',
    country: json['country'] as String? ?? '',
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    timezone: json['timezone'] as String? ?? '',
  );

  final String name;
  final String admin;
  final String country;
  final double latitude;
  final double longitude;
  final String timezone;

  /// Human label such as "Bandung, West Java, Indonesia".
  String get label => [
    name,
    if (admin.isNotEmpty && admin != name) admin,
    if (country.isNotEmpty) country,
  ].join(', ');

  Map<String, Object?> toJson() => {
    'name': name,
    'admin': admin,
    'country': country,
    'latitude': latitude,
    'longitude': longitude,
    'timezone': timezone,
  };

  @override
  bool operator ==(Object other) =>
      other is CitySuggestion &&
      other.name == name &&
      other.admin == admin &&
      other.country == country &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(name, admin, country, latitude, longitude);
}

const CitySuggestion defaultCity = CitySuggestion(
  name: 'Jakarta',
  admin: 'Jakarta',
  country: 'Indonesia',
  latitude: -6.2088,
  longitude: 106.8456,
  timezone: 'Asia/Jakarta',
);

class WeatherNow {
  const WeatherNow({
    required this.tempC,
    required this.code,
    required this.isDay,
    required this.hi,
    required this.lo,
    required this.city,
    required this.updated,
    this.sunriseMinute,
    this.sunsetMinute,
  });

  factory WeatherNow.fromJson(Map<String, dynamic> json) => WeatherNow(
    tempC: (json['tempC'] as num).toDouble(),
    code: (json['code'] as num).toInt(),
    isDay: json['isDay'] as bool,
    hi: (json['hi'] as num).toDouble(),
    lo: (json['lo'] as num).toDouble(),
    city: json['city'] as String,
    updated: DateTime.parse(json['updated'] as String),
    sunriseMinute: (json['sunrise'] as num?)?.toInt(),
    sunsetMinute: (json['sunset'] as num?)?.toInt(),
  );

  final double tempC;
  final int code;
  final bool isDay;
  final double hi;
  final double lo;
  final String city;
  final DateTime updated;

  /// Sunrise and sunset as minutes since local midnight in the city's time zone, when known.
  final int? sunriseMinute;
  final int? sunsetMinute;

  WeatherKind get kind => kindFromWmo(code);

  Map<String, Object?> toJson() => {
    'tempC': tempC,
    'code': code,
    'isDay': isDay,
    'hi': hi,
    'lo': lo,
    'city': city,
    'updated': updated.toIso8601String(),
    'sunrise': sunriseMinute,
    'sunset': sunsetMinute,
  };
}

/// Open-Meteo forecast request for the current conditions and today's range.
Uri forecastUri(CitySuggestion c) => Uri.https(_forecastHost, '/v1/forecast', {
  'latitude': c.latitude.toStringAsFixed(4),
  'longitude': c.longitude.toStringAsFixed(4),
  'current': 'temperature_2m,weather_code,is_day',
  'daily': 'temperature_2m_max,temperature_2m_min,sunrise,sunset',
  'timezone': 'auto',
  'forecast_days': '1',
});

/// Open-Meteo geocoding search for a free-text city name.
Uri geocodingUri(String query) =>
    Uri.https(_geocodingHost, '/v1/search', {
      'name': query,
      'count': '8',
      'language': 'en',
      'format': 'json',
    });

/// Parses a forecast response body. Throws [FormatException] or [TypeError]
/// when the body does not have the expected shape.
WeatherNow parseForecast(
  String body, {
  required String city,
  required DateTime updated,
}) {
  final root = jsonDecode(body) as Map<String, dynamic>;
  final current = root['current'] as Map<String, dynamic>;
  final daily = root['daily'] as Map<String, dynamic>?;
  final temp = (current['temperature_2m'] as num).toDouble();
  final maxList = daily?['temperature_2m_max'] as List<dynamic>?;
  final minList = daily?['temperature_2m_min'] as List<dynamic>?;
  return WeatherNow(
    tempC: temp,
    code: (current['weather_code'] as num).toInt(),
    isDay: (current['is_day'] as num).toInt() == 1,
    hi: (maxList == null || maxList.isEmpty ? null : maxList.first as num?)
            ?.toDouble() ??
        temp,
    lo: (minList == null || minList.isEmpty ? null : minList.first as num?)
            ?.toDouble() ??
        temp,
    city: city,
    updated: updated,
    sunriseMinute: _minuteOfDay(daily?['sunrise']),
    sunsetMinute: _minuteOfDay(daily?['sunset']),
  );
}

/// Minutes since midnight from the first entry of an Open-Meteo time list such as
/// `["2026-11-18T05:42"]`. Null when absent or malformed.
int? _minuteOfDay(Object? list) {
  if (list is! List || list.isEmpty) return null;
  final raw = list.first;
  if (raw is! String || raw.length < 16) return null;
  final hour = int.tryParse(raw.substring(11, 13));
  final minute = int.tryParse(raw.substring(14, 16));
  if (hour == null || minute == null) return null;
  return hour * 60 + minute;
}

/// Parses a geocoding search response. A response without matches yields an
/// empty list.
List<CitySuggestion> parseGeocoding(String body) {
  final root = jsonDecode(body) as Map<String, dynamic>;
  final results = root['results'] as List<dynamic>? ?? const <dynamic>[];
  return results.map((item) {
    final r = item as Map<String, dynamic>;
    return CitySuggestion(
      name: r['name'] as String,
      admin: r['admin1'] as String? ?? '',
      country: r['country'] as String? ?? '',
      latitude: (r['latitude'] as num).toDouble(),
      longitude: (r['longitude'] as num).toDouble(),
      timezone: r['timezone'] as String? ?? '',
    );
  }).toList();
}

/// Current weather for the chosen city. Persists the city and the last good
/// result, so the UI still has something to show offline.
class WeatherService extends ChangeNotifier {
  WeatherService({http.Client? client, DateTime Function()? clock})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _clock = clock ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;

  CitySuggestion _city = defaultCity;
  bool _follow = false;
  DateTime? _lastLocationCheck;
  bool _checkingLocation = false;
  WeatherNow? _now;
  DateTime? _lastAttempt;
  Future<void>? _inFlight;
  bool _disposed = false;

  CitySuggestion get city => _city;

  /// True when the city is the phone's own location and follows it as you travel.
  bool get followLocation => _follow;

  WeatherNow? get now => _now;

  /// Loads the saved city and cached result. Starts a refresh when the cache
  /// is older than 20 minutes; does not wait for the network.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCity = _decode(
      prefs.getString(_cityKey),
      CitySuggestion.fromJson,
    );
    if (savedCity != null) _city = savedCity;
    _follow = prefs.getBool(_followKey) ?? false;
    final cached = _decode(prefs.getString(_nowKey), WeatherNow.fromJson);
    if (cached != null && cached.city == _city.name) _now = cached;
    notifyListeners();
    refresh();
  }

  Future<List<CitySuggestion>> searchCity(String q) async {
    final query = q.trim();
    if (query.length < 2) return const [];
    final res = await _client
        .get(geocodingUri(query), headers: _headers)
        .timeout(_requestTimeout);
    if (res.statusCode != 200) {
      throw WeatherException('City search failed (${res.statusCode})');
    }
    return parseGeocoding(res.body);
  }

  /// The user picked a city by hand: stop following the phone's location.
  Future<void> chooseCity(CitySuggestion c) async {
    await _setFollow(false);
    await setCity(c);
  }

  Future<void> _setFollow(bool value) async {
    if (_follow == value) return;
    _follow = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_followKey, value);
  }

  /// Sets the city from the phone's coarse location and keeps following it. Returns a message for
  /// the user when it cannot, or null on success.
  Future<String?> useMyLocation() async {
    if (!await FluteNative.hasLocationPermission() && !await FluteNative.requestLocationPermission()) {
      return 'Location permission is needed to use your location.';
    }
    final here = await _locate();
    if (here == null) return "Couldn't find your location. Check that Location is turned on.";
    await _setFollow(true);
    await setCity(here);
    return null;
  }

  Future<void> setFollowLocation(bool on) async {
    if (on) {
      await useMyLocation();
    } else {
      await _setFollow(false);
    }
  }

  Future<CitySuggestion?> _locate() async {
    final loc = await FluteNative.getLocation();
    if (loc == null) return null;
    final place = await FluteNative.reverseGeocode(loc.latitude, loc.longitude);
    return CitySuggestion(
      name: place?.name.isNotEmpty == true ? tidyPlaceName(place!.name) : 'My location',
      admin: place?.admin ?? '',
      country: place?.country ?? '',
      latitude: loc.latitude,
      longitude: loc.longitude,
      timezone: '',
    );
  }

  /// While following, re-checks the location at most every 30 minutes and switches city when the
  /// phone has moved more than 5 km. Never prompts for permission.
  Future<void> _followCheck() async {
    if (!_follow || _checkingLocation) return;
    final last = _lastLocationCheck;
    if (last != null && _clock().difference(last) < const Duration(minutes: 30)) return;
    _checkingLocation = true;
    try {
      _lastLocationCheck = _clock();
      if (!await FluteNative.hasLocationPermission()) return;
      final here = await _locate();
      if (here == null) return;
      if (distanceKm(here.latitude, here.longitude, _city.latitude, _city.longitude) > 5) {
        await setCity(here);
      }
    } finally {
      _checkingLocation = false;
    }
  }

  Future<void> setCity(CitySuggestion c) async {
    if (c == _city) return;
    _city = c;
    _now = null;
    _lastAttempt = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cityKey, jsonEncode(c.toJson()));
    await refresh(force: true);
  }

  /// Fetches the forecast for the current city. Unless [force] is set, does
  /// nothing when the last attempt or successful result is under 20 minutes
  /// old. Never throws: failures keep the cached value.
  Future<void> refresh({bool force = false}) async {
    await _followCheck();
    final pending = _inFlight;
    if (pending != null) return pending;
    if (!force && !_isStale()) return;
    return _inFlight = _fetch().whenComplete(() => _inFlight = null);
  }

  bool _isStale() {
    final last = _lastAttempt ?? _now?.updated;
    return last == null || _clock().difference(last) >= _minInterval;
  }

  Future<void> _fetch() async {
    final target = _city;
    _lastAttempt = _clock();
    try {
      final res = await _client
          .get(forecastUri(target), headers: _headers)
          .timeout(_requestTimeout);
      if (res.statusCode != 200) {
        throw WeatherException('Forecast failed (${res.statusCode})');
      }
      final parsed = parseForecast(
        res.body,
        city: target.name,
        updated: _clock(),
      );
      if (_disposed || target != _city) return;
      _now = parsed;
      notifyListeners();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_nowKey, jsonEncode(parsed.toJson()));
    } on Object catch (_) {
      // Offline or unexpected payload: keep whatever is cached.
    }
  }

  static T? _decode<T>(
    String? raw,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (raw == null) return null;
    try {
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

/// Great-circle distance in kilometres between two coordinates.
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  const earthKm = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earthKm * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Indonesian geocoders return the administrative level ("Kecamatan Purwaharja", "Kota Bandung");
/// people say the bare name.
String tidyPlaceName(String name) {
  final cleaned = name.replaceFirst(RegExp(r'^(kecamatan|kabupaten|kelurahan|kota|desa)\s+', caseSensitive: false), '').trim();
  return cleaned.isEmpty ? name : cleaned;
}
