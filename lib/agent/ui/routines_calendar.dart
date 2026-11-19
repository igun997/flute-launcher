import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../routines/routine.dart';
import '../tools/calendar_backend.dart';

/// Upcoming fires are shown this far ahead.
const _horizon = Duration(days: 60);
const _maxOccurrences = 500;
const _gridDays = 42;

const _palette = [
  Color(0xFF5EEAD4),
  Color(0xFFF5B86B),
  Color(0xFF9AA8FF),
  Color(0xFFF28BB0),
  Color(0xFF9BE37A),
  Color(0xFFC9A6FF),
];
const _deviceColor = Color(0xFF6B7A80);
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// A stable colour per routine, so the same routine keeps its dot colour.
Color routineColor(String routineId) {
  var hash = 0;
  for (final unit in routineId.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _palette[hash % _palette.length];
}

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
    required this.color,
    this.occurrence,
    this.run,
    this.deviceEvent = false,
  });

  final DateTime at;
  final String title;
  final Color color;
  final RoutineOccurrence? occurrence;
  final RoutineRun? run;
  final bool deviceEvent;

  bool get scheduled => occurrence != null;
}

/// Month grid (Monday first) with a dot per day that has upcoming fires, past runs or device
/// events, and an agenda for the selected day. Swipe sideways to change the month; tap the month
/// title to jump to today.
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

  /// Device calendar events shown as grey dots (the page loads them only with permission).
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
        color: routineColor(occurrence.routineId),
        occurrence: occurrence,
      ));
    }
    for (final run in widget.runs) {
      if (run.startedAt.isBefore(start) || !run.startedAt.isBefore(end)) continue;
      add(CalendarEntry._(
        at: run.startedAt,
        title: titles[run.routineId] ?? 'Routine',
        color: routineColor(run.routineId),
        run: run,
      ));
    }
    for (final event in widget.deviceEvents) {
      if (event.start.isBefore(start) || !event.start.isBefore(end)) continue;
      add(CalendarEntry._(at: event.start, title: event.title, color: _deviceColor, deviceEvent: true));
    }
    for (final list in byDay.values) {
      list.sort((a, b) => a.at.compareTo(b.at));
    }
    return byDay;
  }

  @override
  Widget build(BuildContext context) {
    final byDay = _entriesByDay();
    final animate = !MediaQuery.disableAnimationsOf(context);
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
              icon: const Text('‹', style: TextStyle(fontSize: 22, color: FluteColors.text)),
            ),
            Expanded(
              child: GestureDetector(
                key: const ValueKey('month-title'),
                behavior: HitTestBehavior.opaque,
                onTap: _jumpToToday,
                child: Text(
                  '${_monthNames[_month.month - 1]} ${_month.year}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: FluteColors.text, fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: () => _moveMonth(1),
              icon: const Text('›', style: TextStyle(fontSize: 22, color: FluteColors.text)),
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
            duration: animate ? const Duration(milliseconds: 180) : Duration.zero,
            child: KeyedSubtree(
              key: ValueKey('month-${_month.year}-${_month.month}'),
              child: _grid(byDay, today),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _agendaTitle(today),
          style: const TextStyle(color: FluteColors.softText, fontSize: 14, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        if (agenda.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Nothing on this day.', style: TextStyle(color: FluteColors.muted, fontSize: 13)),
          )
        else
          for (final entry in agenda) _agendaTile(entry),
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
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Column(
      children: [
        Row(
          children: [
            for (final label in labels)
              Expanded(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: FluteColors.muted, fontSize: 11, letterSpacing: 0.4),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
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
    // Runs and device events are solid dots; scheduled fires are hollow rings.
    final dots = <CalendarEntry>[];
    for (final entry in entries) {
      if (dots.length == 3) break;
      if (!dots.any((d) => d.color == entry.color && d.scheduled == entry.scheduled)) dots.add(entry);
    }
    final labelColor = isToday
        ? FluteColors.bg
        : (inMonth ? FluteColors.text : FluteColors.muted.withValues(alpha: 0.5));
    return GestureDetector(
      key: ValueKey('day-$key'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(day),
      child: Container(
        height: 46,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isToday
              ? FluteColors.accent
              : (isSelected ? FluteColors.surfaceHigh : const Color(0x00000000)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              style: TextStyle(
                color: labelColor,
                fontSize: 14,
                fontWeight: isToday ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 5,
              child: dots.isEmpty
                  ? null
                  : Row(
                      key: ValueKey('dots-$key'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final entry in dots)
                          Container(
                            width: 5,
                            height: 5,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: entry.scheduled ? null : entry.color,
                              border: entry.scheduled ? Border.all(color: entry.color) : null,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _agendaTile(CalendarEntry entry) {
    final time = formatMinuteOfDay(entry.at.hour * 60 + entry.at.minute);
    final run = entry.run;
    final String status;
    final String detail;
    if (entry.scheduled) {
      status = 'Scheduled';
      detail = 'Runs by itself at $time';
    } else if (run != null) {
      status = run.skipped ? '–' : (run.ok ? '✓' : '✕');
      final stats = routineRunStats(run);
      detail = run.ok
          ? (stats.isEmpty ? 'Finished' : stats)
          : (run.summary.length > 90 ? '${run.summary.substring(0, 89)}…' : run.summary);
    } else {
      status = '';
      detail = 'From your calendar';
    }
    final tile = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: FluteColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FluteColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 36,
            margin: const EdgeInsets.only(right: 10, top: 2),
            decoration: BoxDecoration(color: entry.color, borderRadius: BorderRadius.circular(2)),
          ),
          Text(time, style: const TextStyle(color: FluteColors.muted, fontSize: 13)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.title, style: const TextStyle(color: FluteColors.text, fontSize: 14)),
                const SizedBox(height: 2),
                Text(detail, style: const TextStyle(color: FluteColors.muted, fontSize: 12)),
              ],
            ),
          ),
          if (status.isNotEmpty)
            Text(
              status,
              style: TextStyle(
                color: run != null && !run.ok && !run.skipped ? FluteColors.warn : FluteColors.accent,
                fontSize: 14,
              ),
            ),
        ],
      ),
    );
    final occurrence = entry.occurrence;
    if (occurrence != null) {
      return GestureDetector(onTap: () => widget.onOpenOccurrence(occurrence), child: tile);
    }
    final openRun = entry.run;
    if (openRun != null) {
      return GestureDetector(onTap: () => widget.onOpenRun(openRun), child: tile);
    }
    return tile;
  }
}
