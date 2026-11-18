import '../tools/agent_tool.dart';
import 'routine.dart';
import 'routine_runner.dart';
import 'routine_store.dart';

const _source = 'launcher';

const _dayNames = {
  'mon': 1, 'monday': 1, 'tue': 2, 'tuesday': 2, 'wed': 3, 'wednesday': 3, 'thu': 4, 'thursday': 4,
  'fri': 5, 'friday': 5, 'sat': 6, 'saturday': 6, 'sun': 7, 'sunday': 7,
};

/// Routines the agent can list, create, change, delete and run. Creating, changing, deleting and
/// running ask first; listing only reads.
class RoutineTools implements ToolSource {
  RoutineTools(RoutineStore store, RoutineRunner runner)
      : _tools = [
          _ListTool(store),
          _CreateTool(store),
          _UpdateTool(store),
          _DeleteTool(store),
          _RunNowTool(store, runner),
        ];

  final List<AgentTool> _tools;

  @override
  List<AgentTool> get tools => _tools;

  /// The tools never change; the store's routines are read at each call.
  @override
  Stream<void> get changes => const Stream<void>.empty();
}

Map<String, Object?> _schemaFor({required List<String> required, bool includeId = false}) => {
      'type': 'object',
      'properties': {
        if (includeId) 'id': {'type': 'string', 'description': 'Routine id from routine_list.'},
        'name': {'type': 'string', 'description': 'Short name, e.g. "Morning briefing".'},
        'prompt': {
          'type': 'string',
          'description': 'What the routine should do, written as an instruction the model follows alone.',
        },
        'trigger': {
          'type': 'string',
          'enum': ['daily', 'weekly', 'interval'],
          'description': 'daily or weekly at a clock time, or interval (every N minutes).',
        },
        'time': {'type': 'string', 'description': 'Clock time 24h "HH:mm" for daily and weekly, e.g. "07:30".'},
        'weekdays': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'For weekly: day names ("mon".."sun") or numbers 1 (Mon) to 7 (Sun).',
        },
        'every_minutes': {
          'type': 'integer',
          'description': 'For interval: minutes between runs, 15 to 10080.',
        },
        'allow_writes': {
          'type': 'boolean',
          'description': 'Let the routine change things (calendar, notes, launcher mode). Default false: read only.',
        },
        'speak': {'type': 'boolean', 'description': 'Speak a one-sentence summary when the screen is on.'},
        'enabled': {'type': 'boolean', 'description': 'Scheduled and active. Default true.'},
        'model': {'type': 'string', 'description': 'Optional model id for this routine only.'},
      },
      'required': required,
    };

/// Reads the routine's fields from tool arguments, starting from [base] (for updates).
/// Throws [FormatException] with a sentence the model can show.
Routine _routineFromArgs(Map<String, dynamic> args, {Routine? base, required String id}) {
  String? text(String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('"$key" must be text.');
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool? flag(String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is bool) return value;
    if (value is String && (value == 'true' || value == 'false')) return value == 'true';
    throw FormatException('"$key" must be true or false.');
  }

  int? whole(String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is num && value == value.roundToDouble()) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    throw FormatException('"$key" must be a whole number.');
  }

  final triggerText = text('trigger');
  final RoutineTrigger? trigger = triggerText == null
      ? null
      : RoutineTrigger.values.asNameMap()[triggerText] ??
          (throw const FormatException('"trigger" must be daily, weekly or interval.'));

  final timeText = text('time');
  final int? minute;
  if (timeText == null) {
    minute = null;
  } else {
    minute = parseClockMinutes(timeText) ?? (throw const FormatException('"time" must look like 07:30.'));
  }

  Set<int>? weekdays;
  final rawDays = args['weekdays'];
  if (rawDays != null) {
    if (rawDays is! List) throw const FormatException('"weekdays" must be a list.');
    weekdays = {
      for (final day in rawDays)
        if (day is num && day >= 1 && day <= 7)
          day.toInt()
        else if (day is String && _dayNames[day.trim().toLowerCase()] != null)
          _dayNames[day.trim().toLowerCase()]!
        else
          throw FormatException('Unknown day "$day". Use mon to sun.'),
    };
  }

  final model = text('model');
  final clearModel = args.containsKey('model') && model == null;
  final built = Routine(
    id: id,
    name: text('name') ?? base?.name ?? '',
    prompt: text('prompt') ?? base?.prompt ?? '',
    trigger: trigger ?? base?.trigger ?? RoutineTrigger.daily,
    minuteOfDay: minute ?? base?.minuteOfDay ?? 8 * 60,
    weekdays: weekdays ?? base?.weekdays ?? const {1, 2, 3, 4, 5, 6, 7},
    everyMinutes: whole('every_minutes') ?? base?.everyMinutes ?? 60,
    enabled: flag('enabled') ?? base?.enabled ?? true,
    allowWrites: flag('allow_writes') ?? base?.allowWrites ?? false,
    speak: flag('speak') ?? base?.speak ?? false,
    modelOverride: clearModel ? null : (model ?? base?.modelOverride),
    lastRun: base?.lastRun,
    lastResult: base?.lastResult,
  );
  return built;
}

String _yesNo(bool value) => value ? 'yes' : 'no';

class _ListTool extends AgentTool {
  _ListTool(this._store);
  final RoutineStore _store;

  @override
  String get name => 'routine_list';

  @override
  String get description =>
      'List the saved routines with id, name, schedule, whether they are on, whether they may write, '
      'the next run and the last result. Call it without parameters.';

  @override
  Map<String, dynamic> get parameters => _schemaFor(required: const []);

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String get source => _source;

  @override
  String describeCall(Map<String, dynamic> args) => 'List routines';

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final routines = _store.routines;
    if (routines.isEmpty) return const ToolResult('No routines yet.');
    final now = _store.now();
    final lines = <String>[];
    for (final r in routines) {
      final next = _store.nextRun(r.id);
      final state = !r.enabled
          ? (_store.isPaused(r.id) ? 'paused after failures' : 'off')
          : 'on';
      final last = r.lastResult == null ? 'never run' : _short(r.lastResult!, 160);
      lines.add(
        '- id ${r.id} | "${r.name}" | ${r.describeTrigger()} | $state | '
        'writes: ${_yesNo(r.allowWrites)} | next: ${next == null ? '-' : formatRoutineTime(next, now)} | last: $last',
      );
    }
    return ToolResult(lines.join('\n'));
  }
}

class _CreateTool extends AgentTool {
  _CreateTool(this._store);
  final RoutineStore _store;

  @override
  String get name => 'routine_create';

  @override
  String get description =>
      'Create a routine: a prompt the model runs by itself on a schedule (daily or weekly at a time, or every '
      'N minutes) and reports by notification. Reads only unless allow_writes is true. Asks the person first.';

  @override
  Map<String, dynamic> get parameters => _schemaFor(required: const ['name', 'prompt', 'trigger']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String get source => _source;

  @override
  String describeCall(Map<String, dynamic> args) {
    try {
      final r = _routineFromArgs(args, id: '');
      return 'Create routine "${r.name}": ${r.describeTrigger()}, ${r.allowWrites ? 'may change things' : 'reads only'}';
    } on FormatException catch (e) {
      return 'Create a routine (${e.message})';
    }
  }

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    try {
      final routine = _routineFromArgs(args, id: '');
      final saved = await _store.save(routine);
      final next = _store.nextRun(saved.id);
      return ToolResult(
        'Created routine "${saved.name}" (id ${saved.id}). ${saved.describeTrigger()}. '
        'Writes: ${_yesNo(saved.allowWrites)}. Next run: ${next == null ? 'none (it is off)' : formatRoutineTime(next, _store.now())}.',
      );
    } on FormatException catch (e) {
      return ToolResult.error(e.message);
    } on RoutineException catch (e) {
      return ToolResult.error(e.message);
    }
  }
}

class _UpdateTool extends AgentTool {
  _UpdateTool(this._store);
  final RoutineStore _store;

  @override
  String get name => 'routine_update';

  @override
  String get description =>
      'Change a saved routine by id: any of name, prompt, trigger, time, weekdays, every_minutes, allow_writes, '
      'speak, enabled, model. Only the given fields change. Asks the person first.';

  @override
  Map<String, dynamic> get parameters => _schemaFor(required: const ['id'], includeId: true);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String get source => _source;

  @override
  String describeCall(Map<String, dynamic> args) {
    final id = args['id'];
    final base = id is String ? _store.byId(id) : null;
    final label = base == null ? 'routine $id' : '"${base.name}"';
    final changed = [
      for (final key in const ['name', 'prompt', 'trigger', 'time', 'weekdays', 'every_minutes', 'allow_writes', 'speak', 'enabled', 'model'])
        if (args.containsKey(key)) key,
    ];
    return 'Change $label: ${changed.isEmpty ? 'nothing' : changed.join(', ')}';
  }

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final id = args['id'];
    if (id is! String || id.isEmpty) return const ToolResult.error('Give the routine id (see routine_list).');
    final base = _store.byId(id);
    if (base == null) return ToolResult.error('No routine with id $id.');
    try {
      final saved = await _store.save(_routineFromArgs(args, base: base, id: id));
      final next = _store.nextRun(saved.id);
      return ToolResult(
        'Updated routine "${saved.name}": ${saved.describeTrigger()}, '
        '${saved.enabled ? 'on' : 'off'}, writes: ${_yesNo(saved.allowWrites)}. '
        'Next run: ${next == null ? 'none' : formatRoutineTime(next, _store.now())}.',
      );
    } on FormatException catch (e) {
      return ToolResult.error(e.message);
    } on RoutineException catch (e) {
      return ToolResult.error(e.message);
    }
  }
}

class _DeleteTool extends AgentTool {
  _DeleteTool(this._store);
  final RoutineStore _store;

  @override
  String get name => 'routine_delete';

  @override
  String get description => 'Delete a saved routine and its history, by id. Asks the person first.';

  @override
  Map<String, dynamic> get parameters => _schemaFor(required: const ['id'], includeId: true);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String get source => _source;

  @override
  String describeCall(Map<String, dynamic> args) {
    final id = args['id'];
    final base = id is String ? _store.byId(id) : null;
    return base == null ? 'Delete routine $id' : 'Delete routine "${base.name}" and its history';
  }

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final id = args['id'];
    if (id is! String || _store.byId(id) == null) {
      return ToolResult.error('No routine with id $id.');
    }
    final name = _store.byId(id)!.name;
    await _store.remove(id);
    return ToolResult('Deleted routine "$name".');
  }
}

class _RunNowTool extends AgentTool {
  _RunNowTool(this._store, this._runner);
  final RoutineStore _store;
  final RoutineRunner _runner;

  @override
  String get name => 'routine_run_now';

  @override
  String get description =>
      'Run a saved routine now, by id, and return its answer (it also posts the usual notification). '
      'Waits for the run to finish. Asks the person first.';

  @override
  Map<String, dynamic> get parameters => _schemaFor(required: const ['id'], includeId: true);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String get source => _source;

  @override
  String describeCall(Map<String, dynamic> args) {
    final id = args['id'];
    final base = id is String ? _store.byId(id) : null;
    if (base == null) return 'Run routine $id now';
    return 'Run routine "${base.name}" now (${base.allowWrites ? 'may change things' : 'reads only'})';
  }

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final id = args['id'];
    final routine = id is String ? _store.byId(id) : null;
    if (routine == null) return ToolResult.error('No routine with id $id.');
    final run = await _runner.run(routine);
    if (!run.ok) return ToolResult.error(run.summary);
    return ToolResult('Routine "${routine.name}" finished:\n${_short(run.result, 2000)}');
  }
}

String _short(String text, int limit) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= limit ? flat : '${flat.substring(0, limit - 1)}…';
}
