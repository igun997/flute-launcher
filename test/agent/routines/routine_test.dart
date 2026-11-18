import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/routines/routine.dart';

Routine _daily({int minute = 7 * 60 + 30, bool enabled = true, DateTime? lastRun}) => Routine(
      id: 'daily',
      name: 'Morning briefing',
      prompt: 'Brief me.',
      trigger: RoutineTrigger.daily,
      minuteOfDay: minute,
      enabled: enabled,
      lastRun: lastRun,
    );

Routine _weekly(Set<int> days, {int minute = 9 * 60}) => Routine(
      id: 'weekly',
      name: 'Weekly mail',
      prompt: 'Summarise.',
      trigger: RoutineTrigger.weekly,
      minuteOfDay: minute,
      weekdays: days,
    );

Routine _every(int minutes, {DateTime? lastRun}) => Routine(
      id: 'every',
      name: 'Check',
      prompt: 'Check.',
      trigger: RoutineTrigger.interval,
      everyMinutes: minutes,
      lastRun: lastRun,
    );

void main() {
  // 2026-11-01 is a Sunday, so 18 Nov is a Wednesday and 23 Nov a Monday.
  final wednesday = DateTime(2026, 11, 18, 10);

  group('next fire', () {
    test('the calendar fixture days are what the tests assume', () {
      expect(DateTime(2026, 11, 1).weekday, DateTime.sunday);
      expect(wednesday.weekday, DateTime.wednesday);
      expect(DateTime(2026, 11, 23).weekday, DateTime.monday);
    });

    test('daily: later today when the time has not come, tomorrow once it passed', () {
      expect(_daily().nextFire(DateTime(2026, 11, 18, 6)), DateTime(2026, 11, 18, 7, 30));
      expect(_daily().nextFire(wednesday), DateTime(2026, 11, 19, 7, 30));
      // Exactly at the time counts as passed: a fire never repeats the same minute.
      expect(_daily().nextFire(DateTime(2026, 11, 18, 7, 30)), DateTime(2026, 11, 19, 7, 30));
    });

    test('daily keeps the clock time across the end of the month', () {
      expect(_daily().nextFire(DateTime(2026, 11, 30, 23)), DateTime(2026, 12, 1, 7, 30));
    });

    test('weekly: the next chosen weekday at the time', () {
      expect(_weekly({DateTime.monday}).nextFire(wednesday), DateTime(2026, 11, 23, 9));
      expect(_weekly({DateTime.wednesday}).nextFire(wednesday), DateTime(2026, 11, 25, 9));
      expect(_weekly({DateTime.wednesday}, minute: 8 * 60).nextFire(wednesday), DateTime(2026, 11, 25, 8));
    });

    test('weekly with no days never fires', () {
      expect(_weekly(const <int>{}).nextFire(wednesday), isNull);
    });

    test('disabled routines have no next fire', () {
      expect(_daily(enabled: false).nextFire(wednesday), isNull);
    });

    test('interval: first run one interval after now when it never ran', () {
      expect(_every(60).nextFire(wednesday), DateTime(2026, 11, 18, 11));
    });

    test('interval: last run plus the interval', () {
      final last = DateTime(2026, 11, 18, 10, 20);
      expect(_every(60, lastRun: last).nextFire(DateTime(2026, 11, 18, 10, 30)), DateTime(2026, 11, 18, 11, 20));
    });

    test('interval: an overdue run fires once, now, not for every missed slot', () {
      final last = DateTime(2026, 11, 18, 8);
      expect(_every(60, lastRun: last).nextFire(wednesday), wednesday);
    });

    test('interval counts elapsed minutes across midnight', () {
      final last = DateTime(2026, 11, 18, 23, 50);
      expect(_every(30, lastRun: last).nextFire(DateTime(2026, 11, 18, 23, 55)), DateTime(2026, 11, 19, 0, 20));
    });
  });

  group('occurrences', () {
    test('daily across a month boundary, end exclusive', () {
      final list = occurrencesBetween([_daily()], DateTime(2026, 11, 30), DateTime(2026, 12, 2));
      expect(list.map((o) => o.at), [DateTime(2026, 11, 30, 7, 30), DateTime(2026, 12, 1, 7, 30)]);
      expect(list.every((o) => o.routineId == 'daily'), isTrue);
    });

    test('weekly only on the chosen days', () {
      final list = occurrencesBetween(
        [_weekly({DateTime.monday, DateTime.wednesday})],
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 9),
      );
      // Mon 2 Nov and Wed 4 Nov; Mon 9 Nov is at 09:00, after the exclusive end at midnight.
      expect(list.map((o) => o.at), [DateTime(2026, 11, 2, 9), DateTime(2026, 11, 4, 9)]);
    });

    test('interval steps from the start of the range when it never ran', () {
      final list = occurrencesBetween([_every(120)], DateTime(2026, 11, 18, 10), DateTime(2026, 11, 18, 16, 30));
      expect(list.map((o) => o.at), [
        DateTime(2026, 11, 18, 12),
        DateTime(2026, 11, 18, 14),
        DateTime(2026, 11, 18, 16),
      ]);
    });

    test('interval keeps the phase of the last run', () {
      final last = DateTime(2026, 11, 18, 9, 15);
      final list = occurrencesBetween(
        [_every(60, lastRun: last)],
        DateTime(2026, 11, 18, 10),
        DateTime(2026, 11, 18, 12, 30),
      );
      expect(list.map((o) => o.at), [
        DateTime(2026, 11, 18, 10, 15),
        DateTime(2026, 11, 18, 11, 15),
        DateTime(2026, 11, 18, 12, 15),
      ]);
    });

    test('merges routines in time order and caps the total', () {
      final list = occurrencesBetween(
        [_daily(), _weekly({DateTime.thursday}, minute: 7 * 60 + 30)],
        DateTime(2026, 11, 18),
        DateTime(2026, 11, 25),
        limit: 5,
      );
      expect(list.length, 5);
      for (var i = 1; i < list.length; i++) {
        expect(list[i].at.isBefore(list[i - 1].at), isFalse);
      }
    });

    test('disabled routines are left out and an empty range gives nothing', () {
      expect(occurrencesBetween([_daily(enabled: false)], DateTime(2026, 11, 1), DateTime(2026, 12, 1)), isEmpty);
      expect(occurrencesBetween([_daily()], DateTime(2026, 11, 2), DateTime(2026, 11, 2)), isEmpty);
    });

    test('a 60 day horizon of daily fires is about 60 entries', () {
      final list = occurrencesBetween([_daily()], DateTime(2026, 11, 18), DateTime(2026, 11, 18).add(const Duration(days: 60)));
      expect(list.length, 60);
    });
  });

  group('validation and persistence', () {
    test('a routine needs a name, a prompt and sensible times', () {
      expect(_daily().validationError(), isNull);
      expect(Routine(id: 'x', name: ' ', prompt: 'p', trigger: RoutineTrigger.daily).validationError(), isNotNull);
      expect(Routine(id: 'x', name: 'n', prompt: '', trigger: RoutineTrigger.daily).validationError(), isNotNull);
      expect(_daily(minute: 1440).validationError(), isNotNull);
      expect(_weekly(const <int>{}).validationError(), isNotNull);
      expect(_every(10).validationError(), contains('at least 15'));
      expect(_every(15).validationError(), isNull);
      expect(_every(10081).validationError(), isNotNull);
    });

    test('clock times parse 24 h text only', () {
      expect(parseClockMinutes('7:30'), 450);
      expect(parseClockMinutes('22:30'), 22 * 60 + 30);
      expect(parseClockMinutes('24:00'), isNull);
      expect(parseClockMinutes('7.30'), isNull);
      expect(formatMinuteOfDay(450), '07:30');
    });

    test('json round trip keeps every field', () {
      final original = Routine(
        id: 'abc',
        name: 'Evening',
        prompt: 'Sleep mode, goodnight.',
        trigger: RoutineTrigger.weekly,
        minuteOfDay: 22 * 60 + 30,
        weekdays: const {1, 6},
        allowWrites: true,
        speak: true,
        modelOverride: 'gpt-x',
        lastRun: DateTime(2026, 11, 17, 22, 30),
        lastResult: 'Goodnight.',
      );
      final back = Routine.fromJson(original.toJson());
      expect(back.id, 'abc');
      expect(back.trigger, RoutineTrigger.weekly);
      expect(back.weekdays, {1, 6});
      expect(back.minuteOfDay, 22 * 60 + 30);
      expect(back.allowWrites, isTrue);
      expect(back.speak, isTrue);
      expect(back.modelOverride, 'gpt-x');
      expect(back.lastRun, DateTime(2026, 11, 17, 22, 30));
      expect(back.lastResult, 'Goodnight.');
    });

    test('a stored routine with an unknown trigger falls back to daily', () {
      final back = Routine.fromJson({'id': 'x', 'name': 'n', 'prompt': 'p', 'trigger': 'hourly'});
      expect(back.trigger, RoutineTrigger.daily);
      expect(back.allowWrites, isFalse, reason: 'writes stay off unless saved as on');
    });

    test('run results are trimmed to 4000 characters', () {
      final long = 'a' * 5000;
      final trimmed = RoutineRun.trimResult(long);
      expect(trimmed.length, routineResultLimit);
      expect(trimmed.endsWith('…'), isTrue);
      expect(RoutineRun.trimResult('short'), 'short');
    });

    test('describes the schedule in words', () {
      expect(_daily().describeTrigger(), 'Every day at 07:30');
      expect(_weekly({1, 2, 3, 4, 5}).describeTrigger(), 'Weekdays at 09:00');
      expect(_weekly({6, 7}).describeTrigger(), 'Weekends at 09:00');
      expect(_weekly({1, 3}).describeTrigger(), 'Mon, Wed at 09:00');
      expect(_every(90).describeTrigger(), 'Every 1 h 30 min');
      expect(_every(120).describeTrigger(), 'Every 2 hours');
    });

    test('relative day labels for the list and agenda', () {
      final now = DateTime(2026, 11, 18, 10);
      expect(formatRoutineTime(DateTime(2026, 11, 18, 22, 30), now), 'Today 22:30');
      expect(formatRoutineTime(DateTime(2026, 11, 19, 7, 30), now), 'Tomorrow 07:30');
      expect(formatRoutineTime(DateTime(2026, 11, 23, 9), now), 'Mon 09:00');
      expect(formatRoutineTime(DateTime(2026, 12, 3, 9), now), '2026-12-03 09:00');
    });
  });
}
