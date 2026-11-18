import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/provider_store.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:focus_launcher/agent/runtime/agent_runtime.dart';
import 'package:focus_launcher/agent/skills/skill_manager.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plays one scripted turn per request and remembers what it was asked.
class FakeClient implements LlmClient {
  FakeClient(this.turns);
  final List<Stream<LlmEvent> Function()> turns;
  final requests = <LlmRequest>[];
  bool closed = false;

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    requests.add(request);
    return turns[requests.length - 1]();
  }

  @override
  void close() => closed = true;
}

Stream<LlmEvent> reply(String text) async* {
  yield TextDelta(text);
  yield const LlmFinished(reason: FinishReason.stop);
}

Stream<LlmEvent> asks(String id, String name, Map<String, dynamic> args) async* {
  yield LlmFinished(
    reason: FinishReason.toolCalls,
    toolCalls: [ToolCall(id: id, name: name, arguments: args)],
  );
}

class FakeTool extends AgentTool {
  FakeTool(this.name, this.risk, this.source, {this.result = 'ok'});
  @override
  final String name;
  @override
  final ToolRisk risk;
  @override
  final String source;
  final String result;
  final calls = <Map<String, dynamic>>[];

  @override
  String get description => 'fake';
  @override
  Map<String, dynamic> get parameters => {'type': 'object', 'properties': <String, dynamic>{}};
  @override
  String describeCall(Map<String, dynamic> args) => 'Do $name';
  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    calls.add(args);
    return ToolResult(result);
  }
}

class FakeSource implements ToolSource {
  FakeSource(this.tools);
  @override
  final List<AgentTool> tools;
  @override
  Stream<void> get changes => const Stream.empty();
}

class ScriptConfirmer implements Confirmer {
  ScriptConfirmer(this.answers);
  final List<ConfirmDecision> answers;
  final asked = <ConfirmRequest>[];

  @override
  Future<ConfirmDecision> ask(ConfirmRequest request) async {
    asked.add(request);
    return answers.isEmpty ? ConfirmDecision.allowOnce : answers.removeAt(0);
  }
}

void main() {
  late Directory dir;
  late ProviderStore providers;
  late SkillManager skills;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    providers = ProviderStore(prefs: prefs, secrets: MemorySecretStore());
    await providers.load();
    dir = await Directory.systemTemp.createTemp('flute_agent_test');
    skills = SkillManager(root: dir);
    await skills.load();
  });

  tearDown(() async {
    providers.dispose();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<void> ready() async {
    final p = await providers.addApiKeyProfile(label: 'Gateway', baseUrl: 'https://gw.example.com/v1', apiKey: 'k');
    await providers.setModel(p.id, 'some-model');
  }

  AgentRuntime runtime(FakeClient client, List<AgentTool> tools, Confirmer confirmer, {int maxRounds = 12}) {
    final r = AgentRuntime(
      providers: providers,
      toolSources: [FakeSource(tools)],
      skills: skills,
      confirmer: confirmer,
      clientFactory: (_) => client,
      clock: () => DateTime(2026, 11, 20, 14, 5),
      maxRounds: maxRounds,
    );
    addTearDown(r.dispose);
    return r;
  }

  test('a plain reply streams into one assistant item and the date reaches the model', () async {
    await ready();
    final client = FakeClient([() => reply('Hello there')]);
    final r = runtime(client, const [], ScriptConfirmer([]));
    await r.send('Hi');

    final items = r.items;
    expect(items[0], isA<UserItem>());
    final a = items[1] as AssistantItem;
    expect(a.text, 'Hello there');
    expect(a.streaming, isFalse);
    expect(a.error, isNull);
    expect(r.busy, isFalse);
    expect(client.requests.single.model, 'some-model');
    expect(client.requests.single.instructions, contains('20 November 2026'));
    expect(client.closed, isTrue);
  });

  test('without a provider the message is kept but nothing is sent', () async {
    final client = FakeClient([() => reply('never')]);
    final r = runtime(client, const [], ScriptConfirmer([]));
    expect(r.setupProblem, isNotNull);
    await r.send('Hi');
    expect(client.requests, isEmpty);
    expect((r.items.last as AssistantItem).error, contains('provider'));
  });

  test('a write tool asks first, then runs, and the result goes back to the model', () async {
    await ready();
    final tool = FakeTool('notes_create', ToolRisk.write, 'notes', result: 'created note n1');
    final confirmer = ScriptConfirmer([ConfirmDecision.allowOnce]);
    final client = FakeClient([
      () => asks('c1', 'notes_create', {'title': 'Milk'}),
      () => reply('Saved.'),
    ]);
    final r = runtime(client, [tool], confirmer);
    await r.send('Remember milk');

    expect(confirmer.asked.single.summary, 'Do notes_create');
    expect(tool.calls.single, {'title': 'Milk'});
    final second = client.requests[1].messages;
    expect(second.map((m) => m.role), [Role.user, Role.assistant, Role.tool]);
    expect(second[1].toolCalls.single.id, 'c1');
    expect(second[2].toolCallId, 'c1');
    expect(second[2].text, 'created note n1');
    final card = r.items.whereType<ToolItem>().single;
    expect(card.state, ToolState.done);
    expect((r.items.last as AssistantItem).text, 'Saved.');
    // The empty first turn (tools only) leaves no blank bubble behind.
    expect(r.items.whereType<AssistantItem>().length, 1);
  });

  test('declining a write never runs it and tells the model not to retry', () async {
    await ready();
    final tool = FakeTool('calendar_delete_event', ToolRisk.write, 'calendar');
    final client = FakeClient([
      () => asks('c1', 'calendar_delete_event', {'id': '9'}),
      () => reply('Okay, I left it.'),
    ]);
    final r = runtime(client, [tool], ScriptConfirmer([ConfirmDecision.deny]));
    await r.send('Delete my dentist event');

    expect(tool.calls, isEmpty);
    expect(r.items.whereType<ToolItem>().single.state, ToolState.denied);
    final result = client.requests[1].messages.last;
    expect(result.isError, isTrue);
    expect(result.text, contains('declined'));
  });

  test('reading calendar, contacts or notes asks too; reading an MCP server does not', () async {
    await ready();
    final personal = FakeTool('contacts_search', ToolRisk.read, 'contacts');
    final remote = FakeTool('github__search', ToolRisk.read, 'mcp:github');
    final confirmer = ScriptConfirmer([]);
    final client = FakeClient([
      () => asks('c1', 'contacts_search', {'query': 'Ann'}),
      () => asks('c2', 'github__search', {'q': 'bug'}),
      () => reply('Done'),
    ]);
    final r = runtime(client, [personal, remote], confirmer);
    await r.send('Find Ann and bugs');

    expect(confirmer.asked.map((a) => a.tool.name), ['contacts_search']);
    expect(personal.calls, hasLength(1));
    expect(remote.calls, hasLength(1));
  });

  test('an unknown tool is reported to the model, not crashed on', () async {
    await ready();
    final client = FakeClient([
      () => asks('c1', 'does_not_exist', {}),
      () => reply('Sorry'),
    ]);
    final r = runtime(client, const [], ScriptConfirmer([]));
    await r.send('Do it');
    expect(client.requests[1].messages.last.isError, isTrue);
    expect(r.items.whereType<ToolItem>().single.state, ToolState.failed);
  });

  test('a model that keeps calling tools is stopped after maxRounds', () async {
    await ready();
    final tool = FakeTool('current_time', ToolRisk.read, 'time');
    final client = FakeClient(List.generate(5, (_) => () => asks('c', 'current_time', {})));
    final r = runtime(client, [tool], ScriptConfirmer([]), maxRounds: 3);
    await r.send('Loop');
    expect(client.requests, hasLength(3));
    expect((r.items.last as AssistantItem).error, contains('3 steps'));
    expect(r.busy, isFalse);
  });

  test('a provider error lands on the assistant bubble and the chat stays usable', () async {
    await ready();
    final client = FakeClient([
      () => Stream.error(const LlmException('The key was refused.', statusCode: 401)),
      () => reply('Back again'),
    ]);
    final r = runtime(client, const [], ScriptConfirmer([]));
    await r.send('One');
    expect((r.items.last as AssistantItem).error, 'The key was refused.');
    await r.send('Two');
    expect((r.items.last as AssistantItem).text, 'Back again');
  });

  test('stopping mid-reply keeps what streamed and frees the composer', () async {
    await ready();
    final gate = StreamController<LlmEvent>();
    final client = FakeClient([() => gate.stream]);
    final r = runtime(client, const [], ScriptConfirmer([]));
    final sent = r.send('Long one');
    await Future<void>.delayed(Duration.zero);
    gate.add(const TextDelta('Partial'));
    await Future<void>.delayed(Duration.zero);
    r.cancel();
    await sent;
    final a = r.items.whereType<AssistantItem>().single;
    expect(a.text, 'Partial');
    expect(a.streaming, isFalse);
    expect(r.busy, isFalse);
    await gate.close();
  });

  test('a skills command is answered locally without calling the model', () async {
    await ready();
    final client = FakeClient([() => reply('never')]);
    final r = runtime(client, const [], ScriptConfirmer([]));
    await r.send('skills list');
    expect(client.requests, isEmpty);
    expect(r.items.last, isA<NoticeItem>());
  });

  test('new chat forgets the conversation and calls the reset hook', () async {
    await ready();
    var resets = 0;
    final client = FakeClient([() => reply('A'), () => reply('B')]);
    final r = AgentRuntime(
      providers: providers,
      toolSources: const [],
      skills: skills,
      confirmer: ScriptConfirmer([]),
      clientFactory: (_) => client,
      onNewChat: () => resets++,
    );
    addTearDown(r.dispose);
    await r.send('one');
    r.newChat();
    expect(r.items, isEmpty);
    expect(resets, 1);
    await r.send('two');
    expect(client.requests[1].messages, hasLength(1));
  });
}
