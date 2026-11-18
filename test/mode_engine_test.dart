import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/core/mode_engine.dart';
import 'package:focus_launcher/core/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ModeEngine> engine(DateTime Function() clock) async {
  SharedPreferences.setMockInitialValues({});
  final e = ModeEngine(await SharedPreferences.getInstance(), clock: clock)..load();
  addTearDown(e.dispose);
  return e;
}

void main() {
  test('Do Not Disturb is wanted only in Sleep, and only when allowed', () async {
    final e = await engine(DateTime.now);
    expect(e.wantsDnd, isFalse);
    await e.setMode(Mode.sleep);
    expect(e.wantsDnd, isTrue);
    await e.setDndInSleep(false);
    expect(e.wantsDnd, isFalse);
    await e.setDndInSleep(true);
    await e.setMode(Mode.work);
    expect(e.wantsDnd, isFalse);
  });

  test('a schedule switches the mode on its own, and the timer outranks it', () async {
    var now = DateTime(2026, 11, 18, 23, 30); // Wednesday
    final e = await engine(() => now);
    await e.setSchedules([
      const Schedule(modeId: 'sleep', days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 22 * 60, endMinute: 6 * 60),
    ]);
    expect(e.current.id, 'sleep');
    expect(e.wantsDnd, isTrue);

    await e.startTimer(Mode.focus, const Duration(hours: 1));
    expect(e.current.id, 'focus');
    expect(e.wantsDnd, isFalse);

    now = now.add(const Duration(hours: 2)); // timer over; 01:30 is still in the sleep window
    expect(e.current.id, 'sleep');
  });

  test('always-allowed apps ignore the mode, others follow it', () async {
    final e = await engine(DateTime.now);
    await e.setMode(Mode.focus);
    const social = FluteApp(package: 'com.example.social', label: 'Social', category: AppCategory.social);
    const dialer = FluteApp(package: 'com.android.dialer', label: 'Phone', category: AppCategory.chat);
    expect(e.ruleFor(social), Rule.hide);
    expect(e.ruleFor(dialer), Rule.show);
    await e.setAllowed(social.package, true);
    expect(e.ruleFor(social), Rule.show);
  });
}
