import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/routines/routine.dart';
import 'package:focus_launcher/agent/tools/calendar_backend.dart';
import 'package:focus_launcher/agent/ui/routines_calendar.dart';
import 'package:material_ui/material_ui.dart';

// Wednesday 18 November 2026, 10:00. The 07:30 routine has already fired today.
final _now = DateTime(2026, 11, 18, 10);

final _routine = Routine(
  id: 'morning',
  name: 'Morning briefing',
  prompt: 'Brief me.',
  trigger: RoutineTrigger.daily,
  minuteOfDay: 7 * 60 + 30,
);

final _pastRun = RoutineRun(
  id: 'run-1',
  routineId: 'morning',
  startedAt: DateTime(2026, 11, 17, 7, 31),
  endedAt: DateTime(2026, 11, 17, 7, 31, 8),
  ok: true,
  result: 'Sunny, 14 °C.',
  inputTokens: 1200,
  outputTokens: 340,
  tokensPerSecond: 41.2,
);

class _Taps {
  final occurrences = <RoutineOccurrence>[];
  final runs = <RoutineRun>[];
  final months = <DateTime>[];
}

// ignore: library_private_types_in_public_api
Future<_Taps> pumpCalendar(
  WidgetTester tester, {
  List<RoutineRun> runs = const [],
  List<CalendarEvent> deviceEvents = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(480, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final taps = _Taps();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: RoutinesCalendar(
              routines: [_routine],
              runs: runs,
              now: _now,
              deviceEvents: deviceEvents,
              onOpenOccurrence: taps.occurrences.add,
              onOpenRun: taps.runs.add,
              onMonthChanged: taps.months.add,
            ),
          ),
        ),
      ),
    ),
  );
  return taps;
}

void main() {
  testWidgets('lays out November 2026 Monday first, six weeks, starting on the Monday before the 1st', (tester) async {
    await pumpCalendar(tester);

    expect(find.text('November 2026'), findsOneWidget);
    expect(find.text('Mon'), findsOneWidget);
    expect(find.text('Sun'), findsOneWidget);
    // 1 Nov 2026 is a Sunday: the grid starts on Monday 26 October and ends on Sunday 6 December.
    expect(find.byKey(const ValueKey('day-2026-10-26')), findsOneWidget);
    expect(find.byKey(const ValueKey('day-2026-11-01')), findsOneWidget);
    expect(find.byKey(const ValueKey('day-2026-12-06')), findsOneWidget);
    expect(find.byKey(const ValueKey('day-2026-12-07')), findsNothing);
  });

  testWidgets('a dot marks the days with an upcoming fire or a past run, on the right days only', (tester) async {
    await pumpCalendar(tester, runs: [_pastRun]);

    expect(find.byKey(const ValueKey('dots-2026-11-19')), findsOneWidget, reason: 'tomorrow 07:30');
    expect(find.byKey(const ValueKey('dots-2026-11-20')), findsOneWidget);
    expect(find.byKey(const ValueKey('dots-2026-11-17')), findsOneWidget, reason: 'the past run');
    expect(find.byKey(const ValueKey('dots-2026-11-18')), findsNothing, reason: 'today 07:30 has passed');
    expect(find.byKey(const ValueKey('dots-2026-11-16')), findsNothing);
  });

  testWidgets('device calendar events show as a grey dot only when they are passed in', (tester) async {
    await pumpCalendar(
      tester,
      deviceEvents: [
        CalendarEvent(title: 'Dentist', start: DateTime(2026, 11, 24, 15), end: DateTime(2026, 11, 24, 16)),
      ],
    );
    expect(find.byKey(const ValueKey('dots-2026-11-24')), findsOneWidget);
  });

  testWidgets('selecting a day lists its scheduled fires, and tapping one opens the routine', (tester) async {
    final taps = await pumpCalendar(tester);

    expect(find.text('Nothing on this day.'), findsOneWidget, reason: 'today is selected first');

    await tester.tap(find.byKey(const ValueKey('day-2026-11-20')));
    await tester.pump();

    expect(find.text('Friday 20 November'), findsOneWidget);
    expect(find.text('Morning briefing'), findsOneWidget);
    expect(find.text('Runs by itself at 07:30'), findsOneWidget);

    await tester.tap(find.text('Morning briefing'));
    await tester.pump();

    expect(taps.occurrences, hasLength(1));
    expect(taps.occurrences.single.routineId, 'morning');
    expect(taps.occurrences.single.at, DateTime(2026, 11, 20, 7, 30));
  });

  testWidgets('a past run shows its status and token figures, and tapping it opens the result', (tester) async {
    final taps = await pumpCalendar(tester, runs: [_pastRun]);

    await tester.tap(find.byKey(const ValueKey('day-2026-11-17')));
    await tester.pump();

    expect(find.text('✓'), findsOneWidget);
    expect(find.text('1 200 in · 340 out · 41 tok/s'), findsOneWidget);

    await tester.tap(find.text('1 200 in · 340 out · 41 tok/s'));
    await tester.pump();

    expect(taps.runs.single.id, 'run-1');
  });

  testWidgets('swiping moves to the next month; tapping the title jumps back to today', (tester) async {
    final taps = await pumpCalendar(tester);

    await tester.fling(find.byKey(const ValueKey('grid')), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text('December 2026'), findsOneWidget);
    expect(taps.months.last, DateTime(2026, 12));

    await tester.tap(find.byKey(const ValueKey('month-title')));
    await tester.pumpAndSettle();

    expect(find.text('November 2026'), findsOneWidget);
    expect(taps.months.last, DateTime(2026, 11));
  });

  test('the same routine always gets the same colour', () {
    expect(routineColor('morning'), routineColor('morning'));
    expect(routineColorIsOneOfPalette(routineColor('morning')), isTrue);
  });

  test('run stats read as tokens in, tokens out and speed, with an estimate mark', () {
    expect(routineRunStats(_pastRun), '1 200 in · 340 out · 41 tok/s');
    final estimated = RoutineRun(
      id: 'e',
      routineId: 'morning',
      startedAt: _now,
      endedAt: _now,
      ok: true,
      outputTokens: 12,
      tokensPerSecond: 6.44,
      tokensEstimated: true,
    );
    expect(routineRunStats(estimated), '~12 out · ~6.4 tok/s');
  });
}

bool routineColorIsOneOfPalette(Color color) => const [
      Color(0xFF5EEAD4),
      Color(0xFFF5B86B),
      Color(0xFF9AA8FF),
      Color(0xFFF28BB0),
      Color(0xFF9BE37A),
      Color(0xFFC9A6FF),
    ].contains(color);
