// Real calls to an OpenAI-compatible gateway. Skipped unless FLUTE_E2E_URL and FLUTE_E2E_KEY are set:
//   FLUTE_E2E_URL=https://host/v1 FLUTE_E2E_KEY=... flutter test test/e2e
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/provider_store.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/llm/chat_completions_client.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:focus_launcher/agent/llm/model_catalog.dart';
import 'package:focus_launcher/agent/llm/model_info.dart';
import 'package:focus_launcher/agent/runtime/agent_runtime.dart';
import 'package:focus_launcher/agent/skills/skill_manager.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Clock extends AgentTool {
  int calls = 0;
  @override
  String get name => 'notes_create';
  @override
  String get description => 'Save a note with a title and a body.';
  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'body': {'type': 'string'},
        },
        'required': ['title'],
      };
  @override
  ToolRisk get risk => ToolRisk.write;
  @override
  String get source => 'notes';
  @override
  String describeCall(Map<String, dynamic> a) => 'Create note "${a['title']}"';
  @override
  Future<ToolResult> run(Map<String, dynamic> a) async {
    calls++;
    return const ToolResult('Saved note n1.');
  }
}

class _Yes implements Confirmer {
  int asked = 0;
  @override
  Future<ConfirmDecision> ask(ConfirmRequest request) async {
    asked++;
    return ConfirmDecision.allowOnce;
  }
}

class _Src implements ToolSource {
  _Src(this.tools);
  @override
  final List<AgentTool> tools;
  @override
  Stream<void> get changes => const Stream.empty();
}

void main() {
  final url = Platform.environment['FLUTE_E2E_URL'];
  final key = Platform.environment['FLUTE_E2E_KEY'];
  final skip = (url == null || key == null) ? 'set FLUTE_E2E_URL and FLUTE_E2E_KEY' : null;
  late List<ModelInfo> models;

  setUpAll(() async {
    if (skip != null) return;
    // flutter_test replaces HttpClient with one that always answers 400; real network needs this.
    HttpOverrides.global = null;
    models = await ModelCatalog.fetch(kind: ProviderKind.openaiCompatible, baseUrl: url!, token: key!);
  });

  test('the gateway lists models and search finds cx models', () {
    expect(models, isNotEmpty);
    final cx = ModelCatalog.search(models, 'cx/');
    // ignore: avoid_print
    print('E2E models: ${models.length} total, ${cx.length} match "cx/"; first: ${cx.take(5).map((m) => m.id).join(', ')}');
    expect(cx, isNotEmpty);
    expect(ModelCatalog.search(models, 'zzzz-no-such-model'), isEmpty);
  }, skip: skip);

  String pick() {
    final preferred = ['cx/gpt-6.1-sol', 'cx/gpt-6.2-sol'];
    for (final id in preferred) {
      if (models.any((m) => m.id == id)) return id;
    }
    return ModelCatalog.search(models, 'cx/gpt').first.id;
  }

  test('a streamed reply arrives in pieces and finishes', () async {
    final client = ChatCompletionsClient(baseUrl: url!, apiKey: () async => key!);
    final events = await client
        .stream(LlmRequest(model: pick(), messages: [ChatMessage.text(Role.user, 'Reply with exactly: pong')]))
        .toList();
    client.close();
    final text = events.whereType<TextDelta>().map((e) => e.text).join();
    expect(text.toLowerCase(), contains('pong'));
    expect(events.last, isA<LlmFinished>());
    expect((events.last as LlmFinished).reason, FinishReason.stop);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('the agent calls a tool after asking and then answers with its result', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final providers = ProviderStore(prefs: prefs, secrets: MemorySecretStore());
    await providers.load();
    final p = await providers.addApiKeyProfile(label: 'Gateway', baseUrl: url!, apiKey: key!);
    await providers.setModel(p.id, pick());
    final dir = await Directory.systemTemp.createTemp('flute_e2e');
    final skills = SkillManager(root: dir);
    await skills.load();
    final tool = _Clock();
    final yes = _Yes();
    final agent = AgentRuntime(providers: providers, toolSources: [_Src([tool])], skills: skills, confirmer: yes);

    await agent.send('Please save a note titled "Milk" with the body "2 litres". Then tell me it is saved.');

    expect(yes.asked, 1);
    expect(tool.calls, 1);
    final last = agent.items.last as AssistantItem;
    expect(last.error, isNull);
    expect(last.text, isNotEmpty);
    // ignore: avoid_print
    print('E2E final reply: ${last.text}');
    agent.dispose();
    providers.dispose();
    await dir.delete(recursive: true);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
