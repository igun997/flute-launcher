import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/weather/weather_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('distanceKm is accurate enough for a 5 km "have I moved" check', () {
    // Jakarta to Bandung is about 116 km by great circle.
    final d = distanceKm(-6.2146, 106.8451, -6.9175, 107.6191);
    expect(d, inInclusiveRange(110, 122));
    expect(distanceKm(-6.2, 106.8, -6.2, 106.8), 0);
    // About 1 km north: well under the 5 km threshold.
    expect(distanceKm(-6.2, 106.8, -6.191, 106.8), lessThan(5));
    // Antipodal-ish points must not produce NaN.
    expect(distanceKm(0, 0, 0, 180).isNaN, isFalse);
  });

  test('administrative prefixes are dropped from a geocoded place name', () {
    expect(tidyPlaceName('Kecamatan Purwaharja'), 'Purwaharja');
    expect(tidyPlaceName('Kota Bandung'), 'Bandung');
    expect(tidyPlaceName('Jakarta'), 'Jakarta');
    expect(tidyPlaceName('Kota'), 'Kota');
  });

  test('picking a city by hand turns following off and stores it', () async {
    SharedPreferences.setMockInitialValues({'weather.follow': true});
    final service = WeatherService();
    addTearDown(service.dispose);
    await service.init();
    expect(service.followLocation, isTrue);

    const bandung = CitySuggestion(
      name: 'Bandung',
      admin: 'West Java',
      country: 'Indonesia',
      latitude: -6.9175,
      longitude: 107.6191,
      timezone: 'Asia/Jakarta',
    );
    await service.chooseCity(bandung);
    expect(service.followLocation, isFalse);
    expect(service.city.name, 'Bandung');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('weather.follow'), isFalse);
    expect(prefs.getString('weather.city'), contains('Bandung'));
  });
}
