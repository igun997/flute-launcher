import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/lock/lock_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('lockscreen is off and previews are off by default', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = LockSettings(prefs);
    await settings.init();
    expect(settings.enabled, isFalse);
    expect(settings.showPreviews, isFalse);
  });

  test('init loads saved choices', () async {
    SharedPreferences.setMockInitialValues({'lock.enabled': true, 'lock.previews': true});
    final prefs = await SharedPreferences.getInstance();
    final settings = LockSettings(prefs);
    await settings.init();
    expect(settings.enabled, isTrue);
    expect(settings.showPreviews, isTrue);
  });

  test('setters update the value, notify and persist', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = LockSettings(prefs);
    var notified = 0;
    settings.addListener(() => notified++);

    await settings.setEnabled(true);
    await settings.setShowPreviews(true);

    expect(settings.enabled, isTrue);
    expect(settings.showPreviews, isTrue);
    expect(prefs.getBool('lock.enabled'), isTrue);
    expect(prefs.getBool('lock.previews'), isTrue);
    expect(notified, 2);

    await settings.setShowPreviews(true);
    expect(notified, 2, reason: 'setting the same value must not notify again');
  });
}
