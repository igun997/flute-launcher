import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../routines/routine.dart';
import '../tools/calendar_backend.dart';
import 'chat_bubbles.dart' show motion;
import 'settings_widgets.dart';

/// Upcoming fires are shown this far ahead.
const _horizon = Duration(days: 60);
const _maxOccurrences = 500;
const _gridDays = 42;
const _cellHeight = 48.0;
const _dayCircle = 34.0;
const _dotSize = 5.0;
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// `2026-11-05`: the key for one local day.
String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

/// "in 1 234 · out ~320 · 41 tok/s". Estimated counts get a tilde.
String routineRunStats(RoutineRun run) {
  final approx = run.tokensEstimated ? '~' : '';
  final parts = <String>[
    if (run.inputTokens != null) '${_thousands(run.inputTokens!)} in',
    if (run.outputTokens != null) '$approx${_thousands(run.outputTokens!)} out',
    if (run.tokensPerSecond != null)
      '$approx${run.tokensPerSecond! < 10 ? run.tokensPerSecond!.toStringAsFixed(1) : run.tokensPerSecond!.round()} tok/s',
  ];
  return parts.join(' · ');
}

String _thousands(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return out.toString();
}

/// One line of the agenda or one dot: a scheduled fire, a finished run, or a device calendar event.
class CalendarEntry {
  const CalendarEntry._({
    required this.at,
    required this.title,
    this.occurrence,
    this.run,
    this.deviceEvent = false,
  });

  final DateTime at;
  final String title;
  final RoutineOccurrence? occurrence;
  final RoutineRun? run;
  final bool deviceEvent;

  bool get scheduled => occurrence != null;
}

/// Month grid (Monday first) with a dot per kind of entry on each day, and an agenda for the
/// selected day. Swipe sideways to change the month; tap the month title to jump to today.
class RoutinesCalendar extends StatefulWidget {
  const RoutinesCalendar({
    super.key,
    required this.routines,
    required this.runs,
    required this.now,
    required this.onOpenOccurrence,
    required this.onOpenRun,
    this.deviceEvents = const [],
    this.onMonthChanged,
  });

  final List<Routine> routines;

  /// Every run of every routine, newest first.
  final List<RoutineRun> runs;
  final DateTime now;
  final ValueChanged<RoutineOccurrence> onOpenOccurrence;
  final ValueChanged<RoutineRun> onOpenRun;

  /// Device calendar events, shown as faint dots (the page loads them only with permission).
  final List<CalendarEvent> deviceEvents;

  /// Called when the visible month changes, so the page can load device events for it.
  final ValueChanged<DateTime>? onMonthChanged;

  @override
  State<RoutinesCalendar> createState() => _RoutinesCalendarState();
}

class _RoutinesCalendarState extends State<RoutinesCalendar> {
  late DateTime _month;
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    final today = _dayOnly(widget.now);
    _month = DateTime(today.year, today.month);
    _selected = today;
  }

  static DateTime _dayOnly(DateTime value) => DateTime(value.year, value.month, value.day);

  DateTime get _gridStart => DateTime(_month.year, _month.month, 1 - (_month.weekday - 1));

  void _moveMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selected = _month;
    });
    widget.onMonthChanged?.call(_month);
  }

  void _jumpToToday() {
    final today = _dayOnly(widget.now);
    setState(() {
      _month = DateTime(today.year, today.month);
      _selected = today;
    });
    widget.onMonthChanged?.call(_month);
  }

  void _select(DateTime day) {
    final day0 = _dayOnly(day);
    setState(() {
      _selected = day0;
      if (day0.month != _month.month || day0.year != _month.year) _month = DateTime(day0.year, day0.month);
    });
  }

  Map<String, List<CalendarEntry>> _entriesByDay() {
    final start = _gridStart;
    final end = DateTime(start.year, start.month, start.day + _gridDays);
    final byDay = <String, List<CalendarEntry>>{};
    void add(CalendarEntry entry) => byDay.putIfAbsent(dayKey(entry.at), () => []).add(entry);

    final titles = {for (final r in widget.routines) r.id: r.name};
    final horizon = widget.now.add(_horizon);
    final from = start.isBefore(widget.now) ? widget.now : start;
    final to = end.isBefore(horizon) ? end : horizon;
    for (final occurrence in occurrencesBetween(widget.routines, from, to, limit: _maxOccurrences)) {
      add(CalendarEntry._(
        at: occurrence.at,
        title: titles[occurrence.routineId] ?? 'Routine',
        occurrence: occurrence,
      ));
    }
    for (final run in widget.runs) {
      if (run.startedAt.isBefore(start) || !run.startedAt.isBefore(end)) continue;
      add(CalendarEntry._(
        at: run.startedAt,
        title: titles[run.routineId] ?? 'Routine',
        run: run,
      ));
    }
    for (final event in widget.deviceEvents) {
      if (event.start.isBefore(start) || !event.start.isBefore(end)) continue;
      add(CalendarEntry._(at: event.start, title: event.title, deviceEvent: true));
    }
    for (final list in byDay.values) {
      list.sort((a, b) => a.at.compareTo(b.at));
    }
    return byDay;
  }

  @override
  Widget build(BuildContext context) {
    final byDay = _entriesByDay();
    final agenda = byDay[dayKey(_selected)] ?? const <CalendarEntry>[];
    final today = _dayOnly(widget.now);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: () => _moveMonth(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: GestureDetector(
                key: const ValueKey('month-title'),
                behavior: HitTestBehavior.opaque,
                onTap: _jumpToToday,
                child: Text(
                  '${_monthNames[_month.month - 1]} ${_month.year}',
                  textAlign: TextAlign.center,
                  style: FluteText.heading.copyWith(color: FluteColors.text),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: () => _moveMonth(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        GestureDetector(
          key: const ValueKey('grid'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -300) _moveMonth(1);
            if (velocity > 300) _moveMonth(-1);
          },
          child: AnimatedSwitcher(
            duration: motion(context, 180),
            child: KeyedSubtree(
              key: ValueKey('month-${_month.year}-${_month.month}'),
              child: _grid(byDay, today),
            ),
          ),
        ),
        const SizedBox(height: FluteSpace.lg),
        Text(
          _agendaTitle(today),
          style: FluteText.label.copyWith(color: FluteColors.softText),
        ),
        const SizedBox(height: FluteSpace.sm),
        if (agenda.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: FluteSpace.md),
            child: Text('Nothing on this day.', style: FluteText.caption),
          )
        else
          SettingsGroup(children: [for (final entry in agenda) _agendaRow(entry)]),
      ],
    );
  }

  String _agendaTitle(DateTime today) {
    final d = _selected;
    final suffix = d == today ? ' · today' : '';
    return '${_weekdayName(d.weekday)} ${d.day} ${_monthNames[d.month - 1]}$suffix';
  }

  static String _weekdayName(int weekday) =>
      const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][weekday - 1];

  Widget _grid(Map<String, List<CalendarEntry>> byDay, DateTime today) {
    final start = _gridStart;
    return Column(
      children: [
        Row(
          children: [
            for (final label in _weekdayLabels)
              Expanded(
                child: Text(label, textAlign: TextAlign.center, style: FluteText.caption),
              ),
          ],
        ),
        const SizedBox(height: FluteSpace.xs),
        for (var week = 0; week < 6; week++)
          Row(
            children: [
              for (var column = 0; column < 7; column++)
                Expanded(
                  child: _cell(
                    DateTime(start.year, start.month, start.day + week * 7 + column),
                    byDay,
                    today,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _cell(DateTime day, Map<String, List<CalendarEntry>> byDay, DateTime today) {
    final key = dayKey(day);
    final entries = byDay[key] ?? const <CalendarEntry>[];
    final inMonth = day.month == _month.month;
    final isToday = day == today;
    final isSelected = day == _selected;
    return GestureDetector(
      key: ValueKey('day-$key'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(day),
      child: SizedBox(
        height: _cellHeight,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: _dayCircle,
              height: _dayCircle,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? FluteColors.surfaceHigh : Colors.transparent,
                shape: BoxShape.circle,
                border: isToday ? Border.all(color: FluteColors.accent, width: 1.5) : null,
              ),
              child: Text(
                '${day.day}',
                style: FluteText.label.copyWith(
                  fontWeight: isToday ? FontWeight.w600 : FontWeight.w400,
                  color: inMonth ? FluteColors.text : FluteColors.faint,
                ),
              ),
            ),
            const SizedBox(height: FluteSpace.xs),
            SizedBox(
              height: _dotSize,
              child: entries.isEmpty
                  ? null
                  : Row(
                      key: ValueKey('dots-$key'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final entry in _dotsFor(entries))
                          Container(
                            width: _dotSize,
                            height: _dotSize,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: _dotDecoration(entry),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// One dot per kind of entry on a day: a scheduled fire, a past run, a device event.
  static List<CalendarEntry> _dotsFor(List<CalendarEntry> entries) {
    final seen = <String>{};
    final dots = <CalendarEntry>[];
    for (final entry in entries) {
      final kind = entry.scheduled ? 'scheduled' : (entry.run != null ? 'run' : 'device');
      if (seen.add(kind)) dots.add(entry);
    }
    return dots;
  }

  /// Scheduled fires are hollow rings; runs and device events are solid dots.
  static BoxDecoration _dotDecoration(CalendarEntry entry) {
    if (entry.scheduled) {
      return BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: FluteColors.textSecondary),
      );
    }
    return BoxDecoration(
      shape: BoxShape.circle,
      color: entry.deviceEvent ? FluteColors.faint : FluteColors.softText,
    );
  }

  Widget _agendaRow(CalendarEntry entry) {
    final time = formatMinuteOfDay(entry.at.hour * 60 + entry.at.minute);
    final run = entry.run;
    final String detail;
    var status = '';
    var statusColor = FluteColors.textSecondary;
    if (entry.scheduled) {
      detail = 'Runs by itself at $time';
    } else if (run != null) {
      if (run.skipped) {
        status = '–';
        statusColor = FluteColors.muted;
      } else if (run.ok) {
        status = '✓';
      } else {
        status = '✕';
        statusColor = FluteColors.danger;
      }
      final stats = routineRunStats(run);
      detail = run.ok
          ? (stats.isEmpty ? 'Finished' : stats)
          : (run.summary.length > 90 ? '${run.summary.substring(0, 89)}…' : run.summary);
    } else {
      detail = 'From your calendar';
    }
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: FluteSpace.lg, vertical: FluteSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(time, style: FluteText.caption.copyWith(color: FluteColors.softText)),
          ),
          const SizedBox(width: FluteSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.title, style: FluteText.label.copyWith(color: FluteColors.text)),
                const SizedBox(height: FluteSpace.xs),
                Text(detail, style: FluteText.caption),
              ],
            ),
          ),
          if (status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: FluteSpace.sm),
              child: Text(status, style: FluteText.label.copyWith(color: statusColor)),
            ),
        ],
      ),
    );
    final occurrence = entry.occurrence;
    if (occurrence != null) {
      return SettingsPressable(onTap: () => widget.onOpenOccurrence(occurrence), child: content);
    }
    final openRun = entry.run;
    if (openRun != null) {
      return SettingsPressable(onTap: () => widget.onOpenRun(openRun), child: content);
    }
    return content;
  }
}
