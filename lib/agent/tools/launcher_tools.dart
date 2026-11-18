import '../../core/app_repository.dart';
import '../../core/mode_engine.dart';
import '../../core/models.dart';
import '../../lock/lock_settings.dart';
import '../../pets/pet_settings.dart';
import 'agent_tool.dart';

/// Tools that manage the launcher itself: mode, schedules, apps, pins and a few toggles.
/// Reads are [ToolRisk.read]; every change is [ToolRisk.write] and asks the person first.
List<AgentTool> launcherTools({
  required ModeEngine modes,
  required AppRepository apps,
  required LockSettings lock,
  required PetSettings pets,
}) {
  final categoryNames = [for (final c in AppCategory.values) c.name];
  const modeIds = ['free', 'work', 'focus', 'sleep'];

  return [
    _LauncherTool(
      name: 'launcher_status',
      description:
          'Shows the active mode (and when a timed mode ends), the base mode, schedules, pinned apps and '
          'whether Do Not Disturb is on now. No parameters.',
      parameters: _schema({}),
      risk: ToolRisk.read,
      describe: (_) => 'Read launcher status',
      handler: (_) async {
        final now = DateTime.now();
        final until = modes.overrideUntil;
        final b = StringBuffer()..writeln('Active mode: ${modes.current.name} (${modes.current.id})');
        if (until != null && until.isAfter(now)) {
          b.writeln('Timed until ${_stamp(until)}; base mode ${modes.base.name}.');
        } else {
          b.writeln('Base mode: ${modes.base.name}.');
        }
        b.writeln('Do Not Disturb now: ${modes.wantsDnd ? 'on' : 'off'}.');
        final schedules = modes.schedules;
        if (schedules.isEmpty) {
          b.writeln('Schedules: none.');
        } else {
          b.writeln('Schedules:');
          for (var i = 0; i < schedules.length; i++) {
            b.writeln('  $i: ${_describeSchedule(schedules[i])}');
          }
        }
        final pins = apps.favoritePackages;
        final pinNames = pins.isEmpty ? 'none' : pins.map((p) => _label(apps, p)).join(', ');
        b.write('Pinned (${pins.length}/${AppRepository.maxFavorites}): $pinNames');
        return ToolResult(b.toString());
      },
    ),
    _LauncherTool(
      name: 'launcher_set_mode',
      description:
          'Switches the launcher mode. Without minutes it sets the base mode (free, work, focus or sleep). '
          'With minutes it applies that mode for that many minutes, then returns to the previous one.',
      parameters: _schema({
        'mode': _enumString(modeIds, 'Mode to switch to'),
        'minutes': {'type': 'integer', 'minimum': 1, 'maximum': 1440, 'description': 'Optional duration in minutes'},
      }, ['mode']),
      risk: ToolRisk.write,
      describe: (a) {
        final minutes = _optInt(a, 'minutes');
        return 'Switch mode to ${_optStr(a, 'mode') ?? '?'}${minutes != null ? ' for $minutes min' : ''}';
      },
      handler: (a) async {
        final mode = _modeFor(_optStr(a, 'mode'));
        if (mode == null) return _badMode();
        final minutes = _optInt(a, 'minutes');
        if (minutes == null) {
          await modes.setMode(mode);
          return ToolResult('Mode set to ${mode.name}.');
        }
        if (minutes < 1 || minutes > 1440) return const ToolResult.error('minutes must be 1 to 1440.');
        await modes.startTimer(mode, Duration(minutes: minutes));
        return ToolResult('${mode.name} set for $minutes minutes, then back to ${modes.base.name}.');
      },
    ),
    _LauncherTool(
      name: 'launcher_wake_up',
      description: 'Ends the current mode early and returns to Free. Use when the person wants to be done with focus or sleep now.',
      parameters: _schema({}),
      risk: ToolRisk.write,
      describe: (_) => 'End the current mode and go to Free',
      handler: (_) async {
        await modes.wakeUp();
        return ToolResult('Now in ${modes.current.name}.');
      },
    ),
    _LauncherTool(
      name: 'launcher_list_schedules',
      description: 'Lists the recurring mode schedules with their index (used by update and delete). No parameters.',
      parameters: _schema({}),
      risk: ToolRisk.read,
      describe: (_) => 'Read schedules',
      handler: (_) async {
        final schedules = modes.schedules;
        if (schedules.isEmpty) return const ToolResult('No schedules.');
        return ToolResult([
          for (var i = 0; i < schedules.length; i++) '$i: ${_describeSchedule(schedules[i])}',
        ].join('\n'));
      },
    ),
    _LauncherTool(
      name: 'launcher_add_schedule',
      description:
          'Adds a recurring window that switches to a mode. days are weekday numbers 1-7 (1 = Monday, 7 = Sunday). '
          'start and end are 24-hour HH:MM; a window may cross midnight (start later than end).',
      parameters: _schema({
        'mode': _enumString(modeIds, 'Mode to apply during the window'),
        'days': _daysSchema(),
        'start': {'type': 'string', 'description': 'Start time, 24-hour HH:MM, e.g. 22:00'},
        'end': {'type': 'string', 'description': 'End time, 24-hour HH:MM, e.g. 07:00'},
      }, ['mode', 'days', 'start', 'end']),
      risk: ToolRisk.write,
      describe: (a) =>
          'Add schedule: ${_optStr(a, 'mode') ?? '?'} ${a['days'] ?? '?'} ${_optStr(a, 'start') ?? '?'}-${_optStr(a, 'end') ?? '?'}',
      handler: (a) async {
        final mode = _modeFor(_optStr(a, 'mode'));
        if (mode == null) return _badMode();
        final days = _parseDays(a['days']);
        if (days == null) return const ToolResult.error('days: give weekday numbers 1-7 (1 = Monday, 7 = Sunday).');
        final start = _parseHm(_optStr(a, 'start') ?? '');
        final end = _parseHm(_optStr(a, 'end') ?? '');
        if (start == null || end == null) return const ToolResult.error('start and end: 24-hour HH:MM.');
        if (start == end) return const ToolResult.error('start and end must differ.');
        final schedule = Schedule(modeId: mode.id, days: days, startMinute: start, endMinute: end);
        await modes.setSchedules([...modes.schedules, schedule]);
        return ToolResult('Added schedule ${modes.schedules.length - 1}: ${_describeSchedule(schedule)}.');
      },
    ),
    _LauncherTool(
      name: 'launcher_update_schedule',
      description:
          'Changes one schedule by index (from launcher_list_schedules). Only the fields given are changed; '
          'days, start and end use the same format as launcher_add_schedule.',
      parameters: _schema({
        'index': {'type': 'integer', 'minimum': 0, 'description': 'Schedule index from launcher_list_schedules'},
        'mode': _enumString(modeIds, 'New mode'),
        'days': _daysSchema(),
        'start': {'type': 'string', 'description': 'New start, 24-hour HH:MM'},
        'end': {'type': 'string', 'description': 'New end, 24-hour HH:MM'},
      }, ['index']),
      risk: ToolRisk.write,
      describe: (a) => 'Change schedule ${a['index'] ?? '?'}',
      handler: (a) async {
        final index = _optInt(a, 'index');
        if (index == null || index < 0 || index >= modes.schedules.length) return _noSchedule();
        final old = modes.schedules[index];

        var modeId = old.modeId;
        if (_optStr(a, 'mode') != null) {
          final mode = _modeFor(_optStr(a, 'mode'));
          if (mode == null) return _badMode();
          modeId = mode.id;
        }
        var days = old.days;
        if (a.containsKey('days')) {
          final parsed = _parseDays(a['days']);
          if (parsed == null) return const ToolResult.error('days: give weekday numbers 1-7 (1 = Monday, 7 = Sunday).');
          days = parsed;
        }
        var start = old.startMinute;
        if (_optStr(a, 'start') != null) {
          final parsed = _parseHm(_optStr(a, 'start')!);
          if (parsed == null) return const ToolResult.error('start: 24-hour HH:MM.');
          start = parsed;
        }
        var end = old.endMinute;
        if (_optStr(a, 'end') != null) {
          final parsed = _parseHm(_optStr(a, 'end')!);
          if (parsed == null) return const ToolResult.error('end: 24-hour HH:MM.');
          end = parsed;
        }
        if (start == end) return const ToolResult.error('start and end must differ.');

        final updated = Schedule(modeId: modeId, days: days, startMinute: start, endMinute: end);
        final list = [...modes.schedules]..[index] = updated;
        await modes.setSchedules(list);
        return ToolResult('Updated schedule $index: ${_describeSchedule(updated)}.');
      },
    ),
    _LauncherTool(
      name: 'launcher_delete_schedule',
      description: 'Deletes one schedule by index (from launcher_list_schedules).',
      parameters: _schema({
        'index': {'type': 'integer', 'minimum': 0, 'description': 'Schedule index from launcher_list_schedules'},
      }, ['index']),
      risk: ToolRisk.write,
      describe: (a) => 'Delete schedule ${a['index'] ?? '?'}',
      handler: (a) async {
        final index = _optInt(a, 'index');
        if (index == null || index < 0 || index >= modes.schedules.length) return _noSchedule();
        final removed = modes.schedules[index];
        final list = [...modes.schedules]..removeAt(index);
        await modes.setSchedules(list);
        return ToolResult('Deleted schedule $index: ${_describeSchedule(removed)}.');
      },
    ),
    _LauncherTool(
      name: 'launcher_list_apps',
      description:
          'Lists installed apps as label | package | category. Optional query matches the label or package; '
          'optional category filters by category name. limit defaults to 50 (max 200). With no parameters it lists the first apps.',
      parameters: _schema({
        'query': {'type': 'string', 'description': 'Text to match in the app label or package'},
        'category': _enumString(categoryNames, 'Only apps in this category'),
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200, 'description': 'Max apps to return, default 50'},
      }),
      risk: ToolRisk.read,
      describe: (a) => 'Read installed apps${_optStr(a, 'query') != null ? ' matching "${_optStr(a, 'query')}"' : ''}',
      handler: (a) async {
        final query = _optStr(a, 'query')?.toLowerCase();
        final categoryName = _optStr(a, 'category');
        AppCategory? category;
        if (categoryName != null) {
          category = AppCategory.fromName(categoryName);
          if (category == null) {
            return ToolResult.error('Unknown category. Use one of: ${categoryNames.join(', ')}.');
          }
        }
        final limit = (_optInt(a, 'limit') ?? 50).clamp(1, 200).toInt();
        final matched = [
          for (final app in apps.apps)
            if ((query == null || app.label.toLowerCase().contains(query) || app.package.toLowerCase().contains(query)) &&
                (category == null || app.category == category))
              app,
        ];
        final shown = matched.take(limit).toList();
        final cut = matched.length > shown.length;
        final b = StringBuffer()
          ..writeln(
            '${shown.length} of ${matched.length} apps matched'
            '${cut ? ' (cut at $limit; narrow with query or category)' : ''}.',
          );
        for (final app in shown) {
          b.writeln('${app.label} | ${app.package} | ${app.category.name}');
        }
        return ToolResult(b.toString().trimRight());
      },
    ),
    _LauncherTool(
      name: 'launcher_set_app_category',
      description: 'Moves one installed app to a category (package from launcher_list_apps). Modes act on categories.',
      parameters: _schema({
        'package': {'type': 'string', 'description': 'App package name'},
        'category': _enumString(categoryNames, 'New category'),
      }, ['package', 'category']),
      risk: ToolRisk.write,
      describe: (a) => 'Set category of ${_optStr(a, 'package') ?? '?'} to ${_optStr(a, 'category') ?? '?'}',
      handler: (a) async {
        final pkg = _optStr(a, 'package');
        if (pkg == null) return const ToolResult.error('Give the app package (see launcher_list_apps).');
        final app = apps.byPackage(pkg);
        if (app == null) return ToolResult.error('No installed app with package $pkg. Use launcher_list_apps.');
        final category = AppCategory.fromName(_optStr(a, 'category'));
        if (category == null) {
          return ToolResult.error('Unknown category. Use one of: ${categoryNames.join(', ')}.');
        }
        await apps.setCategory(app, category);
        return ToolResult('${app.label} is now in ${category.label}.');
      },
    ),
    _LauncherTool(
      name: 'launcher_pin_app',
      description:
          'Pins an installed app to the home favorites (package from launcher_list_apps). At most ${AppRepository.maxFavorites} pins.',
      parameters: _schema({
        'package': {'type': 'string', 'description': 'App package name'},
      }, ['package']),
      risk: ToolRisk.write,
      describe: (a) => 'Pin ${_optStr(a, 'package') ?? '?'}',
      handler: (a) async {
        final pkg = _optStr(a, 'package');
        if (pkg == null) return const ToolResult.error('Give the app package (see launcher_list_apps).');
        if (apps.byPackage(pkg) == null) {
          return ToolResult.error('No installed app with package $pkg. Use launcher_list_apps.');
        }
        if (apps.isFavorite(pkg)) return ToolResult('${_label(apps, pkg)} is already pinned.');
        final ok = await apps.toggleFavorite(pkg);
        if (!ok) {
          return ToolResult.error('Pins are full (${AppRepository.maxFavorites}). Unpin one first.');
        }
        return ToolResult('Pinned ${_label(apps, pkg)}.');
      },
    ),
    _LauncherTool(
      name: 'launcher_unpin_app',
      description: 'Removes an app from the pinned favorites (package from launcher_list_pins).',
      parameters: _schema({
        'package': {'type': 'string', 'description': 'App package name'},
      }, ['package']),
      risk: ToolRisk.write,
      describe: (a) => 'Unpin ${_optStr(a, 'package') ?? '?'}',
      handler: (a) async {
        final pkg = _optStr(a, 'package');
        if (pkg == null) return const ToolResult.error('Give the app package (see launcher_list_pins).');
        if (!apps.isFavorite(pkg)) return ToolResult('${_label(apps, pkg)} is not pinned.');
        await apps.toggleFavorite(pkg);
        return ToolResult('Unpinned ${_label(apps, pkg)}.');
      },
    ),
    _LauncherTool(
      name: 'launcher_list_pins',
      description: 'Lists the pinned apps in order, with their packages. No parameters.',
      parameters: _schema({}),
      risk: ToolRisk.read,
      describe: (_) => 'Read pinned apps',
      handler: (_) async {
        final pins = apps.favoritePackages;
        if (pins.isEmpty) return ToolResult('No pinned apps (up to ${AppRepository.maxFavorites}).');
        return ToolResult([
          '${pins.length}/${AppRepository.maxFavorites} pinned:',
          for (final p in pins) '${_label(apps, p)} | $p',
        ].join('\n'));
      },
    ),
    _LauncherTool(
      name: 'launcher_set_always_allowed',
      description:
          'Adds or removes an app from the always-allowed list. Always-allowed apps open normally in every mode.',
      parameters: _schema({
        'package': {'type': 'string', 'description': 'App package name'},
        'allowed': {'type': 'boolean', 'description': 'true to always allow, false to remove'},
      }, ['package', 'allowed']),
      risk: ToolRisk.write,
      describe: (a) =>
          '${a['allowed'] == false ? 'Remove' : 'Always allow'} ${_optStr(a, 'package') ?? '?'}',
      handler: (a) async {
        final pkg = _optStr(a, 'package');
        final allowed = a['allowed'];
        if (pkg == null || allowed is! bool) {
          return const ToolResult.error('Give package and allowed (true or false).');
        }
        await modes.setAllowed(pkg, allowed);
        return ToolResult(allowed ? '$pkg is always allowed.' : '$pkg is no longer always allowed.');
      },
    ),
    _LauncherTool(
      name: 'launcher_set_setting',
      description:
          'Turns one launcher toggle on or off. dnd_in_sleep: Do Not Disturb during Sleep mode. '
          'pets_enabled: the desk pet. lock_enabled: the app lock (pause screen before locked apps).',
      parameters: _schema({
        'setting': _enumString(['dnd_in_sleep', 'pets_enabled', 'lock_enabled'], 'Which toggle'),
        'value': {'type': 'boolean', 'description': 'true to turn on, false to turn off'},
      }, ['setting', 'value']),
      risk: ToolRisk.write,
      describe: (a) =>
          'Turn ${_optStr(a, 'setting') ?? '?'} ${a['value'] == true ? 'on' : 'off'}',
      handler: (a) async {
        final setting = _optStr(a, 'setting');
        final value = a['value'];
        if (value is! bool) return const ToolResult.error('value: true or false.');
        switch (setting) {
          case 'dnd_in_sleep':
            await modes.setDndInSleep(value);
          case 'pets_enabled':
            await pets.setEnabled(value);
          case 'lock_enabled':
            await lock.setEnabled(value);
          default:
            return ToolResult.error('Unknown setting. Use dnd_in_sleep, pets_enabled or lock_enabled.');
        }
        return ToolResult('$setting is now ${value ? 'on' : 'off'}.');
      },
    ),
  ];
}

class _LauncherTool extends AgentTool {
  _LauncherTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.risk,
    required String Function(Map<String, dynamic> args) describe,
    required Future<ToolResult> Function(Map<String, dynamic> args) handler,
  })  : _describe = describe,
        _handler = handler;

  @override
  final String name;
  @override
  final String description;
  @override
  final Map<String, dynamic> parameters;
  @override
  final ToolRisk risk;
  @override
  String get source => 'launcher';

  final String Function(Map<String, dynamic> args) _describe;
  final Future<ToolResult> Function(Map<String, dynamic> args) _handler;

  @override
  String describeCall(Map<String, dynamic> args) => _describe(args);

  @override
  Future<ToolResult> run(Map<String, dynamic> args) => _handler(args);
}

Map<String, dynamic> _schema(Map<String, dynamic> properties, [List<String> required = const []]) => {
      'type': 'object',
      'properties': properties,
      'required': required,
    };

Map<String, dynamic> _enumString(List<String> values, String description) => {
      'type': 'string',
      'enum': values,
      'description': description,
    };

Map<String, dynamic> _daysSchema() => {
      'type': 'array',
      'items': {'type': 'integer', 'minimum': 1, 'maximum': 7},
      'description': 'Weekday numbers: 1 = Monday ... 7 = Sunday',
    };

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String? _optStr(Map<String, dynamic> a, String key) {
  final v = a[key];
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

int? _optInt(Map<String, dynamic> a, String key) {
  final v = a[key];
  return v is num ? v.toInt() : null;
}

Mode? _modeFor(String? id) {
  if (id == null) return null;
  for (final m in Mode.all) {
    if (m.id == id) return m;
  }
  return null;
}

ToolResult _badMode() => const ToolResult.error('Unknown mode. Use free, work, focus or sleep.');

/// Shown when a schedule index is missing or out of range.
ToolResult _noSchedule() =>
    const ToolResult.error('No schedule at that index. launcher_list_schedules lists them.');

/// "HH:MM" to minutes since midnight, or null when it is not a valid 24-hour time.
int? _parseHm(String s) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

String _hm(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

String _stamp(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${_hm(d.hour * 60 + d.minute)}';

Set<int>? _parseDays(Object? v) {
  if (v is! List || v.isEmpty) return null;
  final out = <int>{};
  for (final d in v) {
    if (d is! num || d != d.toInt() || d < 1 || d > 7) return null;
    out.add(d.toInt());
  }
  return out;
}

String _daysText(Set<int> days) => ([...days]..sort()).map((d) => _dayNames[d - 1]).join(' ');

String _describeSchedule(Schedule s) =>
    '${Mode.byId(s.modeId).name} ${_daysText(s.days)} ${_hm(s.startMinute)}-${_hm(s.endMinute)}';

String _label(AppRepository apps, String package) => apps.byPackage(package)?.label ?? package;
