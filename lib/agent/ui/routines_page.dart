import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../routines/routine.dart';
import '../tools/calendar_backend.dart';
import 'routine_editor.dart';
import 'routines_calendar.dart';
import 'settings_widgets.dart';

enum _RoutinesView { list, calendar }

/// Example routines offered on the empty page. Each opens the editor filled in.
List<Routine> routineExamples() => [
      Routine(
        id: '',
        name: 'Morning briefing',
        prompt: "Read today's calendar and the weather for my location, then give me a short briefing.",
        trigger: RoutineTrigger.daily,
        minuteOfDay: 7 * 60 + 30,
      ),
      Routine(
        id: '',
        name: 'Evening wind-down',
        prompt: 'Switch the launcher to Sleep mode now, then reply goodnight in one line.',
        trigger: RoutineTrigger.daily,
        minuteOfDay: 22 * 60 + 30,
        allowWrites: true,
      ),
      Routine(
        id: '',
        name: 'Weekly: summarise unread mail',
        prompt: 'Summarise my unread mail from the past week in five short bullet points.',
        trigger: RoutineTrigger.weekly,
        weekdays: const {1},
        minuteOfDay: 9 * 60,
      ),
    ];

/// Every routine with its schedule, last result and calendar. Results open with [showRoutineRunSheet].
class RoutinesPage extends StatefulWidget {
  const RoutinesPage({super.key, required this.flute});
  final Flute flute;

  @override
  State<RoutinesPage> createState() => _RoutinesPageState();
}

class _RoutinesPageState extends State<RoutinesPage> {
  _RoutinesView _view = _RoutinesView.list;
  final Set<String> _running = {};
  bool? _notifications;
  bool? _exactAlarms;

  /// The device calendar overlay. Read only when access was already granted; never prompts here.
  final CalendarBackend _calendar = DeviceCalendarBackend();
  bool _showDeviceEvents = false;
  bool? _calendarAccess;
  List<CalendarEvent> _deviceEvents = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_refreshPermissions());
  }

  Future<void> _refreshPermissions() async {
    final native = widget.flute.routineRunner.native;
    final notifications = await native.hasNotificationPermission();
    final exact = await native.canScheduleExact();
    if (!mounted) return;
    setState(() {
      _notifications = notifications;
      _exactAlarms = exact;
    });
  }

  Future<void> _allowNotifications() async {
    await widget.flute.routineRunner.native.requestNotificationPermission();
    await _refreshPermissions();
  }

  Future<void> _setEnabled(Routine routine, bool on) async {
    await widget.flute.routines.setEnabled(routine.id, on);
    if (!on || !mounted) return;
    final native = widget.flute.routineRunner.native;
    if (!await native.hasNotificationPermission()) {
      await native.requestNotificationPermission();
    }
    await _refreshPermissions();
  }

  Future<void> _runNow(Routine routine) async {
    setState(() => _running.add(routine.id));
    try {
      final run = await widget.flute.routineRunner.run(routine, notify: false);
      if (!mounted) return;
      await showRoutineRunSheet(context, run, routine);
    } finally {
      if (mounted) setState(() => _running.remove(routine.id));
    }
  }

  void _openEditor([Routine? routine]) {
    Navigator.of(context).push(
      settingsRoute<void>(context, (_) => RoutineEditorPage(flute: widget.flute, routine: routine)),
    );
  }

  Future<void> _toggleDeviceEvents(bool on) async {
    if (on) {
      final granted = await _calendar.hasAccess();
      if (!mounted) return;
      setState(() {
        _calendarAccess = granted;
        _showDeviceEvents = granted;
      });
      if (granted) await _loadDeviceEvents(DateTime.now());
    } else {
      setState(() {
        _showDeviceEvents = false;
        _deviceEvents = const [];
      });
    }
  }

  Future<void> _loadDeviceEvents(DateTime month) async {
    if (!_showDeviceEvents) return;
    final start = DateTime(month.year, month.month);
    final end = DateTime(start.year, start.month, start.day + 42);
    List<CalendarEvent> events;
    try {
      events = await _calendar.events(start: start, end: end);
    } catch (_) {
      events = const [];
    }
    if (mounted && _showDeviceEvents) setState(() => _deviceEvents = events);
  }

  @override
  Widget build(BuildContext context) {
    final flute = widget.flute;
    final bottom = MediaQuery.paddingOf(context).bottom + 24;
    return Scaffold(
      backgroundColor: FluteColors.bg,
      appBar: AppBar(
        backgroundColor: FluteColors.bg,
        scrolledUnderElevation: 0,
        title: const Text('Routines', style: TextStyle(fontWeight: FontWeight.w300)),
        actions: [
          TextButton(onPressed: () => _openEditor(), child: const Text('New')),
        ],
      ),
      body: ListenableBuilder(
        listenable: flute.routines,
        builder: (context, _) {
          final routines = flute.routines.routines;
          return ListView(
            padding: EdgeInsets.fromLTRB(24, 8, 24, bottom),
            children: [
              if (routines.isNotEmpty) ..._permissionBanners(),
              _viewToggle(),
              const SizedBox(height: 16),
              ...(_view == _RoutinesView.calendar
                  ? _calendarView(routines)
                  : (routines.isEmpty ? _emptyState() : _list(routines))),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _permissionBanners() => [
        if (_notifications == false)
          _banner(
            'Notifications are off, so routine results will not appear.',
            actionLabel: 'Allow',
            onAction: _allowNotifications,
          ),
        if (_exactAlarms == false)
          _banner(
            'Exact timing is off: Android may run routines a few minutes late.',
            actionLabel: 'Allow exact timing',
            onAction: () => widget.flute.routineRunner.native.openExactAlarmSettings(),
          ),
      ];

  Widget _banner(String text, {required String actionLabel, required Future<void> Function() onAction}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: FluteColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: FluteColors.warn.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(child: Text(text, style: const TextStyle(color: FluteColors.softText, fontSize: 13))),
            TextButton(onPressed: () => onAction(), child: Text(actionLabel)),
          ],
        ),
      );

  Widget _viewToggle() {
    Widget segment(String label, _RoutinesView view) {
      final selected = _view == view;
      return Expanded(
        child: GestureDetector(
          key: ValueKey('view-${view.name}'),
          onTap: () => setState(() => _view = view),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? FluteColors.surfaceHigh : const Color(0x00000000),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? FluteColors.text : FluteColors.muted,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: FluteColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: FluteColors.line),
      ),
      child: Row(
        children: [
          segment('List', _RoutinesView.list),
          segment('Calendar', _RoutinesView.calendar),
        ],
      ),
    );
  }

  List<Widget> _emptyState() => [
        const SizedBox(height: 8),
        const Text(
          'Routines run by themselves on a schedule and send you the answer as a notification.',
          style: TextStyle(color: FluteColors.softText, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 16),
        const SettingsLabel('START WITH AN EXAMPLE'),
        for (final example in routineExamples())
          _exampleCard(example),
      ];

  Widget _exampleCard(Routine example) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: FluteColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: FluteColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(example.name, style: const TextStyle(color: FluteColors.text, fontSize: 15)),
            const SizedBox(height: 4),
            Text(example.describeTrigger(), style: settingsMuted),
            const SizedBox(height: 6),
            Text(example.prompt, style: const TextStyle(color: FluteColors.softText, fontSize: 13)),
            if (example.allowWrites) ...[
              const SizedBox(height: 4),
              const Text('Needs "May change things" on.', style: TextStyle(color: FluteColors.warn, fontSize: 12)),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => _openEditor(example), child: const Text('Use this')),
            ),
          ],
        ),
      );

  List<Widget> _list(List<Routine> routines) => [
        for (final routine in routines) _routineCard(routine),
      ];

  Widget _routineCard(Routine routine) {
    final store = widget.flute.routines;
    final now = DateTime.now();
    final next = store.nextRun(routine.id);
    final history = store.history(routine.id);
    final latest = history.isEmpty ? null : history.first;
    final running = _running.contains(routine.id);
    final paused = store.isPaused(routine.id);
    final String status;
    if (!routine.enabled) {
      status = paused ? 'Paused after two failed runs' : 'Off';
    } else {
      status = next == null ? 'Not scheduled' : 'Next ${formatRoutineTime(next, now)}';
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      decoration: BoxDecoration(
        color: FluteColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FluteColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _openEditor(routine),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(routine.name, style: const TextStyle(color: FluteColors.text, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text(
                          '${routine.describeTrigger()} · $status',
                          style: TextStyle(color: paused ? FluteColors.warn : FluteColors.muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Semantics(
                label: 'Turn on ${routine.name}',
                child: Switch(value: routine.enabled, onChanged: (on) => _setEnabled(routine, on)),
              ),
            ],
          ),
          if (latest != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: InkWell(
                key: ValueKey('last-${routine.id}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => showRoutineRunSheet(context, latest, routine),
                child: Text(
                  '${latest.ok ? '' : (latest.skipped ? 'Skipped: ' : 'Failed: ')}${_oneLine(latest.summary, 160)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: FluteColors.softText, fontSize: 13),
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: running ? null : () => _runNow(routine),
              child: Text(running ? 'Running…' : 'Run now'),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _calendarView(List<Routine> routines) {
    final runs = <RoutineRun>[
      for (final routine in routines) ...widget.flute.routines.history(routine.id),
    ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return [
      RoutinesCalendar(
        routines: routines,
        runs: runs,
        now: DateTime.now(),
        deviceEvents: _showDeviceEvents ? _deviceEvents : const [],
        onMonthChanged: _loadDeviceEvents,
        onOpenOccurrence: (occurrence) {
          final routine = widget.flute.routines.byId(occurrence.routineId);
          if (routine != null) _openEditor(routine);
        },
        onOpenRun: (run) => showRoutineRunSheet(context, run, widget.flute.routines.byId(run.routineId)),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Text(
              'Show my calendar events',
              style: const TextStyle(color: FluteColors.softText, fontSize: 13),
            ),
          ),
          Switch(value: _showDeviceEvents, onChanged: (on) => _toggleDeviceEvents(on)),
        ],
      ),
      if (_calendarAccess == false)
        const Text(
          'Allow calendar access in Agent settings > Tools to see your events here.',
          style: settingsMuted,
        ),
    ];
  }
}

/// The full result of one run: status, time, token counts, and the answer (selectable).
/// The notification tap owner calls this with the run it receives from `RoutineRunner.opened`.
Future<void> showRoutineRunSheet(BuildContext context, RoutineRun run, Routine? routine) {
  final stats = routineRunStats(run);
  final title = routine?.name ?? 'Routine';
  final status = run.skipped ? 'Skipped' : (run.ok ? 'Finished' : 'Failed');
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: FluteColors.surface,
    builder: (ctx) {
      final height = MediaQuery.sizeOf(ctx).height;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height * 0.8),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.paddingOf(ctx).bottom + 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: const TextStyle(color: FluteColors.text, fontSize: 17)),
              const SizedBox(height: 4),
              Text(
                '$status · ${formatRoutineTime(run.startedAt, DateTime.now())}${run.manual ? ' · by hand' : ''}',
                style: settingsMuted,
              ),
              if (stats.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(stats, style: settingsMuted),
              ],
              const SizedBox(height: 14),
              if (!run.ok && run.error != null) ErrorLine(run.error!),
              if (run.result.isNotEmpty)
                SelectableText(run.result, style: const TextStyle(color: FluteColors.softText, fontSize: 14, height: 1.45))
              else if (run.ok)
                const Text('No answer was kept.', style: settingsMuted),
            ],
          ),
        ),
      );
    },
  );
}

String _oneLine(String text, int limit) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= limit ? flat : '${flat.substring(0, limit - 1)}…';
}
