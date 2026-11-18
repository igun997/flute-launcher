import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/core/day_style.dart';
import 'package:focus_launcher/core/mode_engine.dart';
import 'package:focus_launcher/core/models.dart';
import 'package:focus_launcher/weather/weather_service.dart';
import 'package:focus_launcher/widgets/mode_fx.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ModeEngine> engine(DateTime Function() clock) async {
  SharedPreferences.setMockInitialValues({});
  final e = ModeEngine(await SharedPreferences.getInstance(), clock: clock)..load();
  addTearDown(e.dispose);
  return e;
}

void main() {
  group('fxForChange', () {
    test('entering Sleep plays the sleep animation, leaving it plays the wake animation', () {
      expect(fxForChange('free', 'sleep'), ModeFxKind.sleep);
      expect(fxForChange('work', 'sleep'), ModeFxKind.sleep);
      expect(fxForChange('sleep', 'free'), ModeFxKind.wake);
      expect(fxForChange('sleep', 'work'), ModeFxKind.wake);
    });

    test('other changes and no change play nothing', () {
      expect(fxForChange('free', 'work'), isNull);
      expect(fxForChange('focus', 'work'), isNull);
      expect(fxForChange('sleep', 'sleep'), isNull);
    });
  });

  group('Schedule.endsAt', () {
    test('same-day window ends today', () {
      const s = Schedule(modeId: 'work', days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 9 * 60, endMinute: 17 * 60);
      expect(s.endsAt(DateTime(2026, 11, 18, 10, 30)), DateTime(2026, 11, 18, 17));
    });

    test('overnight window ends tomorrow before midnight and today after it', () {
      const s = Schedule(modeId: 'sleep', days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 22 * 60, endMinute: 6 * 60);
      expect(s.endsAt(DateTime(2026, 11, 18, 23, 15)), DateTime(2026, 11, 19, 6));
      expect(s.endsAt(DateTime(2026, 11, 19, 2, 0)), DateTime(2026, 11, 19, 6));
    });
  });

  group('wakeUp', () {
    test('without a schedule it simply goes to Free', () async {
      final e = await engine(() => DateTime(2026, 11, 18, 23));
      await e.setMode(Mode.sleep);
      await e.wakeUp();
      expect(e.current.id, 'free');
      expect(e.wantsDnd, isFalse);
    });

    test('with a covering schedule Free holds until the window ends, then Sleep returns next night', () async {
      var now = DateTime(2026, 11, 18, 23, 30);
      final e = await engine(() => now);
      await e.setSchedules([
        const Schedule(modeId: 'sleep', days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 22 * 60, endMinute: 6 * 60),
      ]);
      expect(e.current.id, 'sleep');
      await e.wakeUp();
      expect(e.current.id, 'free');

      now = DateTime(2026, 11, 19, 3); // still inside the window: stays awake
      expect(e.current.id, 'free');

      now = DateTime(2026, 11, 19, 6, 5); // window over
      expect(e.current.id, 'free');
      now = DateTime(2026, 11, 19, 22, 30); // next night: schedule applies again
      expect(e.current.id, 'sleep');
    });
  });

  test('Sleep mode always shows the night sky, even at noon', () async {
    final noon = DateTime(2026, 11, 18, 12);
    final modes = await engine(() => noon);
    final prefs = await SharedPreferences.getInstance();
    final weather = WeatherService();
    final style = StyleController(prefs, weather, modes, clock: () => noon);
    addTearDown(style.dispose);

    expect(style.phase, DayPhase.day);
    await modes.setMode(Mode.sleep);
    expect(style.phase, DayPhase.night);
    await modes.wakeUp();
    expect(style.phase, DayPhase.day);
  });
}
