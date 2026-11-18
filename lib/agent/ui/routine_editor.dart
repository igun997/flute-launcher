import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../routines/routine.dart';
import '../routines/routine_store.dart';
import 'settings_widgets.dart';

const _triggerLabels = {
  RoutineTrigger.daily: 'Daily',
  RoutineTrigger.weekly: 'Weekly',
  RoutineTrigger.interval: 'Every N minutes',
};

const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Creates or edits one routine. [routine] is null for a new one (or a template to start from).
class RoutineEditorPage extends StatefulWidget {
  const RoutineEditorPage({super.key, required this.flute, this.routine});
  final Flute flute;

  /// An existing routine (its id is kept), or a template with an empty id.
  final Routine? routine;

  @override
  State<RoutineEditorPage> createState() => _RoutineEditorPageState();
}

class _RoutineEditorPageState extends State<RoutineEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _time;
  late final TextEditingController _every;
  late final TextEditingController _model;
  late RoutineTrigger _trigger;
  late Set<int> _days;
  late bool _allowWrites;
  late bool _speak;
  late bool _enabled;
  String? _error;
  bool _saving = false;

  Routine? get _base => widget.routine;

  @override
  void initState() {
    super.initState();
    final r = widget.routine;
    _name = TextEditingController(text: r?.name ?? '');
    _prompt = TextEditingController(text: r?.prompt ?? '');
    _time = TextEditingController(text: formatMinuteOfDay(r?.minuteOfDay ?? 8 * 60));
    _every = TextEditingController(text: '${r?.everyMinutes ?? 60}');
    _model = TextEditingController(text: r?.modelOverride ?? '');
    _trigger = r?.trigger ?? RoutineTrigger.daily;
    _days = Set.of(r == null ? const {1, 2, 3, 4, 5} : r.weekdays);
    _allowWrites = r?.allowWrites ?? false;
    _speak = r?.speak ?? false;
    _enabled = r?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _time.dispose();
    _every.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final time = parseClockMinutes(_time.text);
    final every = int.tryParse(_every.text.trim());
    final String? input;
    if (_trigger != RoutineTrigger.interval && time == null) {
      input = 'Use a time like 07:30.';
    } else if (_trigger == RoutineTrigger.interval && every == null) {
      input = 'Use a whole number of minutes.';
    } else {
      input = null;
    }
    if (input != null) {
      setState(() => _error = input);
      return;
    }
    final model = _model.text.trim();
    final routine = (_base ?? Routine(id: '', name: '', prompt: '', trigger: _trigger)).copyWith(
      name: _name.text.trim(),
      prompt: _prompt.text.trim(),
      trigger: _trigger,
      minuteOfDay: time ?? _base?.minuteOfDay ?? 8 * 60,
      weekdays: _days,
      everyMinutes: every ?? 60,
      enabled: _enabled,
      allowWrites: _allowWrites,
      speak: _speak,
      modelOverride: model,
      clearModelOverride: model.isEmpty,
    );
    final problem = routine.validationError();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await widget.flute.routines.save(routine);
      if (_enabled) await _ensureNotifications();
      if (mounted) Navigator.of(context).pop();
    } on RoutineException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _saving = false;
        });
      }
    }
  }

  /// Results arrive as notifications, so the first enabled routine asks for the permission.
  Future<void> _ensureNotifications() async {
    final native = widget.flute.routineRunner.native;
    if (await native.hasNotificationPermission()) return;
    await native.requestNotificationPermission();
  }

  Future<void> _delete() async {
    final base = _base;
    if (base == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: FluteColors.surface,
        title: const Text('Delete this routine?'),
        content: Text('"${base.name}" and its history are removed. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true) return;
    await widget.flute.routines.remove(base.id);
    if (mounted) Navigator.of(context).pop();
  }

  void _toggleDay(int day) {
    setState(() {
      if (_days.contains(day)) {
        _days.remove(day);
      } else {
        _days.add(day);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom + 24;
    return Scaffold(
      backgroundColor: FluteColors.bg,
      appBar: AppBar(
        backgroundColor: FluteColors.bg,
        scrolledUnderElevation: 0,
        title: Text(
          _base == null ? 'New routine' : 'Edit routine',
          style: const TextStyle(fontWeight: FontWeight.w300),
        ),
        actions: [
          if (_base != null)
            TextButton(
              onPressed: _saving ? null : _delete,
              child: const Text('Delete', style: TextStyle(color: settingsAlert)),
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(24, 8, 24, bottom),
        children: [
          const SettingsLabel('NAME'),
          TextField(
            controller: _name,
            maxLength: 80,
            decoration: const InputDecoration(hintText: 'Morning briefing'),
          ),
          const SizedBox(height: 12),
          const SettingsLabel('PROMPT'),
          TextField(
            controller: _prompt,
            minLines: 3,
            maxLines: 8,
            maxLength: 4000,
            decoration: const InputDecoration(
              hintText: "What should it do? It runs alone, so nobody can answer questions.",
            ),
          ),
          const SizedBox(height: 12),
          const SettingsLabel('WHEN'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final trigger in RoutineTrigger.values)
                ChoiceChip(
                  label: Text(_triggerLabels[trigger]!),
                  selected: _trigger == trigger,
                  onSelected: _saving ? null : (_) => setState(() => _trigger = trigger),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_trigger != RoutineTrigger.interval) ...[
            TextField(
              controller: _time,
              keyboardType: TextInputType.datetime,
              decoration: const InputDecoration(labelText: 'Time (24 h)', hintText: '07:30'),
            ),
            const SizedBox(height: 12),
          ],
          if (_trigger == RoutineTrigger.weekly) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < 7; i++)
                  ChoiceChip(
                    label: Text(_dayLabels[i]),
                    selected: _days.contains(i + 1),
                    onSelected: _saving ? null : (_) => _toggleDay(i + 1),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (_trigger == RoutineTrigger.interval) ...[
            TextField(
              controller: _every,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Minutes between runs',
                hintText: '60 (at least 15)',
              ),
            ),
            const SizedBox(height: 12),
          ],
          const SettingsLabel('MODEL (OPTIONAL)'),
          TextField(
            controller: _model,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: 'Empty: the chat model',
              helperText: 'A model id from your provider, used for this routine only.',
            ),
          ),
          const SizedBox(height: 16),
          _switchRow(
            title: 'May change things',
            subtitle: _allowWrites
                ? 'On: it can change things (launcher mode, notes, calendar, contacts) without asking. It never runs sandbox code or deletes anything.'
                : 'Off: it can only read. Anything it tries to change is refused.',
            value: _allowWrites,
            onChanged: (v) => setState(() => _allowWrites = v),
          ),
          _switchRow(
            title: 'Speak the summary',
            subtitle: 'When the screen is on, read one sentence aloud after the run.',
            value: _speak,
            onChanged: (v) => setState(() => _speak = v),
          ),
          _switchRow(
            title: 'On',
            subtitle: 'Runs on its schedule, even when Flute is closed.',
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 12),
          if (_error != null) ErrorLine(_error!),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: FluteColors.text, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: settingsMuted),
                ],
              ),
            ),
            Switch(value: value, onChanged: _saving ? null : onChanged),
          ],
        ),
      );
}
