import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/pets/pet_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<PetSettings> settings(Map<String, Object> initial) async {
  SharedPreferences.setMockInitialValues(initial);
  final s = PetSettings(await SharedPreferences.getInstance());
  addTearDown(s.dispose);
  return s;
}

void main() {
  test('one character by default', () async {
    final s = await settings({});
    expect(s.enabled, isTrue);
    expect(s.selected, ['pip']);
  });

  test('an older list of several characters is cut to the first', () async {
    final s = await settings({'pets.selected': ['nori', 'sora', 'pip']});
    expect(s.selected, ['nori']);
  });

  test('selecting replaces the character and persists', () async {
    final s = await settings({});
    var notified = 0;
    s.addListener(() => notified++);
    await s.select('luma');
    expect(s.selected, ['luma']);
    expect(notified, 1);
    await s.select('luma'); // same again: nothing changes
    expect(notified, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('pets.selected'), ['luma']);
  });

  test('a tap on a character is remembered briefly so double-tap to lock can ignore it', () async {
    final s = await settings({});
    expect(s.hitRecently, isFalse);
    s.markHit();
    expect(s.hitRecently, isTrue);
  });
}
