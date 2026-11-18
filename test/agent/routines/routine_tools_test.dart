import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/provider_store.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/routines/routine_runner.dart';
import 'package:focus_launcher/agent/routines/routine_store.dart';
import 'package:focus_launcher/agent/routines/routine_tools.dart';
import 'package:focus_launcher/agent/skills/skill_manager.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

AgentTool _tool(RoutineTools tools, String name) => tools.tools.firstWhere((t) => t.name == name);

void main() {
  late FakeRoutineNative native;
  late RoutineStore store;
  late RoutineTools tools;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    native = FakeRoutineNative();
    store = RoutineStore(prefs: prefs, native: native, clock: () => DateTime(2026, 11, 18, 10));
    await store.load();
    final providers = ProviderStore(prefs: prefs, secrets: MemorySecretStore());
    await providers.load();
    final runner = RoutineRunner(
      providers: providers,
      toolSources: const [],
      skills: SkillManager(root: Directory.systemTemp.createTempSync('routine_tools')),
      store: store,
      native: native,
      clock: () => DateTime(2026, 11, 18, 10),
    );
    tools = RoutineTools(store, runner);
  });

  tearDown(() async {
    await native.close();
  });

  test('the five tools have the agreed names; only listing reads', () {
    expect(tools.tools.map((t) => t.name), [
      'routine_list',
      'routine_create',
      'routine_update',
      'routine_delete',
      'routine_run_now',
    ]);
    expect(_tool(tools, 'routine_list').risk, ToolRisk.read);
    for (final name in ['routine_create', 'routine_update', 'routine_delete', 'routine_run_now']) {
      expect(_tool(tools, name).risk, ToolRisk.write, reason: name);
    }
    expect(tools.tools.every((t) => t.source == 'launcher'), isTrue);
  });

  test('creating a daily routine reads only by default and says when it will run', () async {
    final create = _tool(tools, 'routine_create');
    final args = {'name': 'Morning briefing', 'prompt': "Today's calendar.", 'trigger': 'daily', 'time': '7:30'};

    expect(create.describeCall(args), 'Create routine "Morning briefing": Every day at 07:30, reads only');

    final result = await create.run(args);
    expect(result.isError, isFalse);
    expect(result.text, contains('Created routine "Morning briefing"'));
    expect(result.text, contains('Writes: no'));
    expect(result.text, contains('Next run: Tomorrow 07:30'));

    final saved = store.routines.single;
    expect(saved.minuteOfDay, 7 * 60 + 30);
    expect(saved.allowWrites, isFalse);
    expect(native.syncs.last.single['id'], saved.id);
  });

  test('weekly accepts day names or numbers; interval enforces the minimum', () async {
    final create = _tool(tools, 'routine_create');

    final weekly = await create.run({
      'name': 'Mail',
      'prompt': 'Summarise.',
      'trigger': 'weekly',
      'time': '09:00',
      'weekdays': ['mon', 'Wednesday', 5, 7],
    });
    expect(weekly.isError, isFalse);
    expect(store.routines.single.weekdays, {1, 3, 5, 7});

    final tooOften = await create.run({
      'name': 'Check',
      'prompt': 'Check.',
      'trigger': 'interval',
      'every_minutes': 5,
    });
    expect(tooOften.isError, isTrue);
    expect(tooOften.text, contains('at least 15'));
    expect(store.routines, hasLength(1));
  });

  test('bad input is refused with a sentence the model can read', () async {
    final create = _tool(tools, 'routine_create');
    final badTime = await create.run({'name': 'a', 'prompt': 'b', 'trigger': 'daily', 'time': '25:00'});
    expect(badTime.isError, isTrue);
    expect(badTime.text, contains('07:30'));

    final badTrigger = await create.run({'name': 'a', 'prompt': 'b', 'trigger': 'hourly'});
    expect(badTrigger.isError, isTrue);
    expect(store.routines, isEmpty);
  });

  test('describing a write names the real values and whether it may change things', () {
    final create = _tool(tools, 'routine_create');
    final text = create.describeCall({
      'name': 'Evening wind-down',
      'prompt': 'Sleep mode.',
      'trigger': 'daily',
      'time': '22:30',
      'allow_writes': true,
    });
    expect(text, 'Create routine "Evening wind-down": Every day at 22:30, may change things');
  });

  test('update changes only the fields it is given', () async {
    final create = _tool(tools, 'routine_create');
    await create.run({'name': 'Briefing', 'prompt': 'Brief.', 'trigger': 'daily', 'time': '07:30'});
    final id = store.routines.single.id;

    final update = _tool(tools, 'routine_update');
    final result = await update.run({'id': id, 'time': '08:15', 'allow_writes': true});
    expect(result.isError, isFalse);

    final saved = store.byId(id)!;
    expect(saved.name, 'Briefing', reason: 'not given, so unchanged');
    expect(saved.prompt, 'Brief.');
    expect(saved.minuteOfDay, 8 * 60 + 15);
    expect(saved.allowWrites, isTrue);
    expect(update.describeCall({'id': id, 'time': '08:15'}), 'Change "Briefing": time');
  });

  test('update and delete name an unknown id as an error', () async {
    final update = await _tool(tools, 'routine_update').run({'id': 'nope', 'name': 'x'});
    expect(update.isError, isTrue);
    final delete = await _tool(tools, 'routine_delete').run({'id': 'nope'});
    expect(delete.isError, isTrue);
  });

  test('delete removes the routine and its history; its description names it', () async {
    await _tool(tools, 'routine_create').run({'name': 'Old', 'prompt': 'p', 'trigger': 'daily'});
    final id = store.routines.single.id;
    final del = _tool(tools, 'routine_delete');
    expect(del.describeCall({'id': id}), 'Delete routine "Old" and its history');

    final result = await del.run({'id': id});
    expect(result.isError, isFalse);
    expect(store.routines, isEmpty);
  });

  test('list reads every routine with id, schedule, writes and next run', () async {
    await _tool(tools, 'routine_create').run({'name': 'Briefing', 'prompt': 'p', 'trigger': 'daily', 'time': '07:30'});
    await _tool(tools, 'routine_create').run({'name': 'Wind-down', 'prompt': 'p', 'trigger': 'daily', 'time': '22:30', 'allow_writes': true});

    final list = await _tool(tools, 'routine_list').run({});
    expect(list.text, contains('"Briefing" | Every day at 07:30 | on | writes: no | next: Tomorrow 07:30 | last: never run'));
    expect(list.text, contains('"Wind-down" | Every day at 22:30 | on | writes: yes'));
  });

  test('listing with nothing saved says so', () async {
    final list = await _tool(tools, 'routine_list').run({});
    expect(list.text, 'No routines yet.');
  });

  test('run now for an unknown routine is an error, not a crash', () async {
    final result = await _tool(tools, 'routine_run_now').run({'id': 'missing'});
    expect(result.isError, isTrue);
  });
}
