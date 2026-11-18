import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/core/default_pins.dart';

void main() {
  test('pins follow the requested order using what is installed', () {
    final pins = resolveDefaultPins({
      'com.samsung.android.dialer',
      'com.google.android.dialer', // a second dialer must not add a second Phone pin
      'com.google.android.apps.messaging',
      'com.samsung.android.messaging',
      'com.whatsapp',
      'com.whatsapp.w4b',
      'org.telegram.messenger',
      'com.bca',
      'com.bca.mybca.omni.android',
      'com.grabtaxi.passenger',
      'com.example.other',
    });
    expect(pins, [
      'com.samsung.android.dialer',
      'com.google.android.apps.messaging',
      'com.whatsapp.w4b',
      'com.whatsapp',
      'org.telegram.messenger',
      'com.bca.mybca.omni.android',
      'com.grabtaxi.passenger',
    ]);
  });

  test('uninstalled apps are skipped and alternatives are used', () {
    expect(resolveDefaultPins({'com.google.android.dialer', 'com.bca', 'org.telegram.messenger.web'}), [
      'com.google.android.dialer',
      'org.telegram.messenger.web',
      'com.bca',
    ]);
    expect(resolveDefaultPins({}), isEmpty);
  });
}
