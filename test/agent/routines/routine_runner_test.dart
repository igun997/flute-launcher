import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/provider_store.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:focus_launcher/agent/routines/routine.dart';
import 'package:focus_launcher/agent/routines/routine_native.dart';
import 'package:focus_launcher/agent/routines/routine_runner.dart';
import 'package:focus_launcher/agent/routines/routine_store.dart';
import 'package:focus_launcher/agent/skills/skill_manager.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Plays one scripted turn per model request, and remembers every request.
class ScriptedClient implements LlmClient {
  ScriptedClient(this._turns);

  final List<Stream<LlmEvent> Function()> _turns;
  final requests = <LlmRequest>[];

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    requests.add(request);
    final index = requests.length - 1;
    return (index < _turns.length ? _turns[index] : _turns.last)();
  }

  @override
  void close() {}
}

Stream<LlmEvent> Function() answer(String text, {int input = 10, int output = 20}) => () async* {
      yield TextDelta(text);
      yield LlmFinished(
        reason: FinishReason.stop,
        usage: Usage(inputTokens: input, outputTokens: output),
      );
    };

Stream<LlmEvent> Function() toolCalls(List<ToolCall> calls) => () async* {
      yield LlmFinished(reason: FinishReason.toolCalls, toolCalls: calls);
    };

Stream<LlmEvent> Function() providerFails(String message) =>
    () => Stream<LlmEvent>.error(LlmException(message));

Stream<LlmEvent> Function() providerHangs() => () => StreamController<LlmEvent>().stream;

class FakeTool extends AgentTool {
  FakeTool(this.name, this.risk, this.source);

  @override
  final String name;
  @override
  final ToolRisk risk;
  @override
  final String source;
  final calls = <Map<String, dynamic>>[];

  @override
  String get description => 'fake $name';
  @override
  Map<String, dynamic> get parameters => {'type': 'object', 'properties': <String, dynamic>{}};
  @override
  String describeCall(Map<String, dynamic> args) => 'Do $name';
  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    calls.add(args);
    return const ToolResult('ok');
  }
}

class FakeSource implements ToolSource {
  FakeSource(this.tools);
  @override
  final List<AgentTool> tools;
  @override
  Stream<void> get changes => const Stream.empty();
}

class Harness {
  Harness({
    required this.providers,
    required this.store,
    required this.native,
    required this.client,
    required this.runner,
  });

  final ProviderStore providers;
  final RoutineStore store;
  final FakeRoutineNative native;
  final ScriptedClient client;
  final RoutineRunner runner;
}

final _clockNow = DateTime(2026, 11, 18, 10);

Future<Harness> harness({
  required List<Stream<LlmEvent> Function()> turns,
  List<AgentTool> tools = const [],
  Duration budget = const Duration(minutes: 3),
  bool withProvider = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final providers = ProviderStore(prefs: prefs, secrets: MemorySecretStore());
  await providers.load();
  if (withProvider) {
    final profile = await providers.addApiKeyProfile(
      label: 'Test gateway',
      baseUrl: 'https://gateway.example.com/v1',
      apiKey: 'test-key',
    );
    await providers.setModel(profile.id, 'model-a');
  }
  final native = FakeRoutineNative();
  final store = RoutineStore(prefs: prefs, native: native, clock: () => _clockNow);
  await store.load();
  final client = ScriptedClient(turns);
  final skills = SkillManager(root: Directory.systemTemp.createTempSync('routine_skills'));
  final runner = RoutineRunner(
    providers: providers,
    toolSources: tools.isEmpty ? const [] : [FakeSource(tools)],
    skills: skills,
    store: store,
    native: native,
    clock: () => _clockNow,
    budget: budget,
    clientFactory: (_) => client,
  );
  return Harness(providers: providers, store: store, native: native, client: client, runner: runner);
}

Future<Routine> savedRoutine(Harness h, {bool allowWrites = false, String prompt = 'Check the weather.'}) =>
    h.store.save(Routine(
      id: '',
      name: 'Morning briefing',
      prompt: prompt,
      trigger: RoutineTrigger.daily,
      minuteOfDay: 7 * 60 + 30,
      allowWrites: allowWrites,
    ));

Future<void> _until(bool Function() test) async {
  for (var i = 0; i < 500 && !test(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(test(), isTrue, reason: 'timed out waiting for the routine to finish');
}

void main() {
  group('run policy', () {
    test('reads are always allowed; writes need allowWrites; sandbox and deletions never run', () {
      final read = FakeTool('calendar_list_events', ToolRisk.read, 'calendar');
      final write = FakeTool('notes_create', ToolRisk.write, 'notes');
      final sandbox = FakeTool('sandbox_python', ToolRisk.write, 'sandbox');
      final delete = FakeTool('notes_delete', ToolRisk.write, 'notes');
      final mcpDelete = FakeTool('github__delete_file', ToolRisk.write, 'mcp:github');

      expect(RoutineRunPolicy.allows(read, allowWrites: false), isTrue);
      expect(RoutineRunPolicy.allows(write, allowWrites: false), isFalse);
      expect(RoutineRunPolicy.allows(write, allowWrites: true), isTrue);
      expect(RoutineRunPolicy.allows(sandbox, allowWrites: true), isFalse);
      expect(RoutineRunPolicy.allows(delete, allowWrites: true), isFalse);
      expect(RoutineRunPolicy.allows(mcpDelete, allowWrites: true), isFalse);
    });
  });

  test('a read-only routine answers, notifies with the answer and keeps tokens in its history', () async {
    final h = await harness(turns: [answer('Sunny, 14 °C.', input: 120, output: 40)]);
    final routine = await savedRoutine(h);

    final run = await h.runner.run(routine);

    expect(run.ok, isTrue);
    expect(run.result, 'Sunny, 14 °C.');
    expect(run.inputTokens, 120);
    expect(run.outputTokens, 40);
    expect(run.manual, isTrue);
    expect(h.native.notifications.single['ok'], isTrue);
    expect(h.native.notifications.single['text'], 'Sunny, 14 °C.');
    expect(h.native.notifications.single['title'], 'Morning briefing');
    expect(h.store.history(routine.id).single.id, run.id);
    expect(h.store.byId(routine.id)!.lastResult, 'Sunny, 14 °C.');

    final request = h.client.requests.single;
    expect(request.model, 'model-a');
    expect(request.messages.first.text, contains('read-only'));
    expect(request.messages.first.text, contains('Check the weather.'));
  });

  test('writes are denied by default: the tool never runs and the model is told why', () async {
    final create = FakeTool('calendar_create_event', ToolRisk.write, 'calendar');
    final h = await harness(
      turns: [
        toolCalls([const ToolCall(id: 'c1', name: 'calendar_create_event', arguments: {'title': 'Dentist'})]),
        answer('I could not add it.'),
      ],
      tools: [create],
    );
    final routine = await savedRoutine(h);

    final run = await h.runner.run(routine);

    expect(create.calls, isEmpty);
    expect(run.ok, isTrue);
    final refusal = h.client.requests[1].messages.firstWhere((m) => m.role == Role.tool);
    expect(refusal.isError, isTrue);
    expect(refusal.text, contains('declined'));
  });

  test('with allowWrites, ordinary writes run but sandbox code and deletions are refused', () async {
    final create = FakeTool('notes_create', ToolRisk.write, 'notes');
    final sandbox = FakeTool('sandbox_python', ToolRisk.write, 'sandbox');
    final delete = FakeTool('notes_delete', ToolRisk.write, 'notes');
    final h = await harness(
      turns: [
        toolCalls([
          const ToolCall(id: 'a', name: 'notes_create', arguments: {'title': 'Plan'}),
          const ToolCall(id: 'b', name: 'sandbox_python', arguments: {'code': 'print(1)'}),
          const ToolCall(id: 'c', name: 'notes_delete', arguments: {'id': '1'}),
        ]),
        answer('Saved the plan.'),
      ],
      tools: [create, sandbox, delete],
    );
    final routine = await savedRoutine(h, allowWrites: true, prompt: 'Save today plan.');

    final run = await h.runner.run(routine);

    expect(run.ok, isTrue);
    expect(create.calls, hasLength(1));
    expect(sandbox.calls, isEmpty);
    expect(delete.calls, isEmpty);
    expect(h.client.requests.first.messages.first.text, isNot(contains('read-only')));
  });

  test('two failed runs in a row pause the routine, and the second notification says so', () async {
    final h = await harness(turns: [providerFails('The provider is down.'), providerFails('The provider is down.')]);
    final routine = await savedRoutine(h);

    final first = await h.runner.run(routine);
    expect(first.ok, isFalse);
    expect(first.error, 'The provider is down.');
    expect(h.native.notifications.last['text'], isNot(contains('Paused')));
    expect(h.store.byId(routine.id)!.enabled, isTrue);

    await h.runner.run(routine);
    expect(h.store.byId(routine.id)!.enabled, isFalse);
    expect(h.store.isPaused(routine.id), isTrue);
    expect(h.native.notifications.last['text'], contains('Paused after two failed runs'));
    expect(h.native.notifications.last['ok'], isFalse);
  });

  test('a run that is out of time is cancelled and reported as timed out', () async {
    final h = await harness(turns: [providerHangs()], budget: const Duration(milliseconds: 50));
    final routine = await savedRoutine(h);

    final run = await h.runner.run(routine);

    expect(run.ok, isFalse);
    expect(run.error, startsWith('Timed out after'));
    expect(h.native.notifications.single['ok'], isFalse);
    expect(h.store.history(routine.id), hasLength(1));
  });

  test('without a provider the run is skipped, not failed, and the model is never called', () async {
    final h = await harness(turns: const [], withProvider: false);
    final routine = await savedRoutine(h);

    for (var i = 0; i < 3; i++) {
      final run = await h.runner.run(routine);
      expect(run.skipped, isTrue);
      expect(run.error, contains('add a provider'));
    }

    expect(h.client.requests, isEmpty);
    expect(h.store.byId(routine.id)!.enabled, isTrue, reason: 'skipped runs never pause a routine');
    expect(h.native.notifications.last['title'], 'Morning briefing: skipped');
  });

  test('a queued native fire runs once, is acknowledged and its wake lock released', () async {
    final h = await harness(turns: [answer('Hello.')]);
    final routine = await savedRoutine(h);
    final fire = RoutineFire(
      token: 't1',
      routineId: routine.id,
      firedAt: DateTime(2026, 11, 18, 7, 30),
      manual: false,
    );
    h.native.pending = [fire];

    await h.runner.start();
    // The same fire again, as an event (the app was just started): must not run twice.
    h.native.emit(RoutineNativeEvent.fired(fire));

    await _until(() => h.native.finished.contains('t1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(h.native.acked, ['t1']);
    expect(h.native.notifications, hasLength(1));
    expect(h.native.notifications.single['text'], 'Hello.');
    expect(h.store.history(routine.id), hasLength(1));
    expect(h.store.history(routine.id).single.manual, isFalse);
    expect(h.client.requests, hasLength(1));
  });

  test('a scheduled fire for a paused routine is recorded as skipped and nothing is run', () async {
    final h = await harness(turns: [answer('never')]);
    final routine = await savedRoutine(h);
    await h.store.setEnabled(routine.id, false);
    h.native.pending = [
      RoutineFire(token: 'p1', routineId: routine.id, firedAt: DateTime(2026, 11, 18, 7, 30), manual: false),
    ];

    await h.runner.start();
    await _until(() => h.native.finished.contains('p1'));

    expect(h.client.requests, isEmpty);
    expect(h.store.history(routine.id).single.skipped, isTrue);
  });

  test('a notification tap opens the run it was posted for', () async {
    final h = await harness(turns: [answer('Result text.')]);
    final routine = await savedRoutine(h);
    final run = await h.runner.run(routine, notify: false);
    expect(h.native.notifications, isEmpty, reason: 'notify: false keeps quiet for runs started on the page');

    h.native.openedRunId = run.id;
    final opened = h.runner.opened.first;
    await h.runner.start();

    expect((await opened).id, run.id);
  });
}
