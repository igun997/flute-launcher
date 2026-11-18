import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:focus_launcher/agent/llm/model_catalog.dart';
import 'package:focus_launcher/agent/llm/model_info.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const baseUrl = 'https://gw.example.com/v1';

http.Response json(Object body, {int status = 200}) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

Future<List<ModelInfo>> fetchFrom(
  http.Response reply, {
  ProviderKind kind = ProviderKind.openaiCompatible,
  List<http.Request>? sent,
}) =>
    ModelCatalog.fetch(
      kind: kind,
      baseUrl: baseUrl,
      token: 'sk-test-123',
      httpClient: MockClient((request) async {
        sent?.add(request);
        return reply;
      }),
    );

void main() {
  group('fetch', () {
    test('OpenAI shape: sorted by name and one entry per id', () async {
      final sent = <http.Request>[];
      final models = await fetchFrom(
        json({
          'object': 'list',
          'data': [
            {'id': 'gpt-b', 'owned_by': 'openai'},
            {'id': 'gpt-a', 'owned_by': 'openai'},
            {'id': 'gpt-a', 'owned_by': 'duplicate'},
          ],
        }),
        sent: sent,
      );

      expect(models.map((m) => m.id), ['gpt-a', 'gpt-b']);
      expect(models.first.ownedBy, 'openai');
      expect(models.first.name, 'gpt-a');
      expect(sent.single.url.toString(), '$baseUrl/models');
      expect(sent.single.headers['Authorization'], 'Bearer sk-test-123');
    });

    test('OpenRouter shape: name, context, image input and price per million tokens', () async {
      final models = await fetchFrom(json({
        'data': [
          {
            'id': 'openai/gpt-4o',
            'name': 'OpenAI: GPT-4o',
            'context_length': 128000,
            'architecture': {
              'modality': 'text+image->text',
              'input_modalities': ['text', 'image'],
            },
            'pricing': {'prompt': '0.0000025', 'completion': '0.00001'},
          },
          {
            'id': 'meta/llama',
            'name': 'Llama',
            'context_length': 8192,
            'architecture': {'modality': 'text->text', 'input_modalities': ['text']},
            'pricing': {'prompt': '0'},
          },
          {
            'id': 'variable/price',
            'name': 'Variable',
            'pricing': {'prompt': '-1'},
          },
        ],
      }));

      final gpt = models.firstWhere((m) => m.id == 'openai/gpt-4o');
      expect(gpt.name, 'OpenAI: GPT-4o');
      expect(gpt.contextLength, 128000);
      expect(gpt.acceptsImages, isTrue);
      expect(gpt.promptPricePerMillion, closeTo(2.5, 1e-6));

      final llama = models.firstWhere((m) => m.id == 'meta/llama');
      expect(llama.acceptsImages, isFalse);
      expect(llama.promptPricePerMillion, 0);

      final variable = models.firstWhere((m) => m.id == 'variable/price');
      expect(variable.promptPricePerMillion, isNull);
      expect(variable.acceptsImages, isNull);
    });

    test('ChatGPT plan shape: slug is the id, hidden models are dropped', () async {
      final models = await fetchFrom(
        json({
          'models': [
            {
              'slug': 'gpt-5.1',
              'display_name': 'GPT-5.1',
              'visibility': 'list',
              'context_window': 400000,
              'input_modalities': ['text', 'image'],
            },
            {'slug': 'hidden-one', 'display_name': 'Hidden', 'visibility': 'hide'},
            {'slug': 'gpt-5-mini', 'display_name': 'GPT-5 mini'},
          ],
        }),
        kind: ProviderKind.chatgptPlan,
      );

      expect(models.map((m) => m.id), ['gpt-5-mini', 'gpt-5.1']);
      final current = models.firstWhere((m) => m.id == 'gpt-5.1');
      expect(current.name, 'GPT-5.1');
      expect(current.contextLength, 400000);
      expect(current.acceptsImages, isTrue);
    });

    test('plain list shape', () async {
      final models = await fetchFrom(json([
        {'id': 'b-model'},
        {'id': 'a-model'},
      ]));
      expect(models.map((m) => m.id), ['a-model', 'b-model']);
    });

    test('Ollama-style shape uses the model field as the id', () async {
      final models = await fetchFrom(json({
        'models': [
          {'name': 'llama3', 'model': 'llama3:latest'},
        ],
      }));
      expect(models.single.id, 'llama3:latest');
      expect(models.single.name, 'llama3');
    });

    test('an unknown shape is an error, not an empty list', () async {
      await expectLater(
        fetchFrom(json({'unexpected': 1})),
        throwsA(isA<LlmException>()),
      );
    });

    test('a refused key says so and never shows the key', () async {
      await expectLater(
        fetchFrom(json({'error': {'message': 'Bad key sk-test-123'}}, status: 401)),
        throwsA(isA<LlmException>()
            .having((e) => e.isAuth, 'isAuth', isTrue)
            .having((e) => e.message, 'message', contains('refused'))
            .having((e) => e.message, 'message', isNot(contains('sk-test-123')))),
      );
    });

    test('a ChatGPT session refused asks for a new sign-in', () async {
      await expectLater(
        fetchFrom(http.Response('', 403), kind: ProviderKind.chatgptPlan),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', contains('Sign in with ChatGPT again'))),
      );
    });

    test('an unreachable host names the host only', () async {
      await expectLater(
        ModelCatalog.fetch(
          kind: ProviderKind.openaiCompatible,
          baseUrl: baseUrl,
          token: 'sk-test-123',
          httpClient: MockClient((_) async => throw const SocketException('refused')),
        ),
        throwsA(isA<LlmException>().having((e) => e.message, 'message', 'Cannot reach gw.example.com')),
      );
    });
  });

  group('search', () {
    final models = [
      const ModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', ownedBy: 'openai'),
      const ModelInfo(id: 'gpt-4-turbo', name: 'GPT-4 Turbo'),
      const ModelInfo(id: 'claude-3-haiku', name: 'Claude 3 Haiku', ownedBy: 'anthropic'),
      const ModelInfo(id: 'mistral-gpt-tune', name: 'Mistral tune'),
    ];

    List<String> ids(List<ModelInfo> found) => found.map((m) => m.id).toList();

    test('ranks an id prefix first, then id contains, then name contains', () {
      expect(ids(ModelCatalog.search(models, 'gpt')), [
        'gpt-4-turbo', // id starts with the query
        'openai/gpt-4o', // id contains it; name "GPT-4o" sorts before "Mistral tune"
        'mistral-gpt-tune',
      ]);
    });

    test('matches the owner too', () {
      expect(ids(ModelCatalog.search(models, 'anthropic')), ['claude-3-haiku']);
    });

    test('every token must occur somewhere in id, name or owner', () {
      expect(ids(ModelCatalog.search(models, '4 turbo')), ['gpt-4-turbo']);
    });

    test('is case-insensitive and ignores extra spaces', () {
      expect(ids(ModelCatalog.search(models, '  GPT-4O ')), ['openai/gpt-4o']);
    });

    test('an empty query returns everything in the given order', () {
      expect(ids(ModelCatalog.search(models, '   ')), ids(models));
    });

    test('no match returns an empty list', () {
      expect(ModelCatalog.search(models, 'zzz'), isEmpty);
    });
  });

  group('cache', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a saved list loads back for the same profile only', () async {
      final prefs = await SharedPreferences.getInstance();
      const models = [
        ModelInfo(
          id: 'openai/gpt-4o',
          name: 'OpenAI: GPT-4o',
          ownedBy: 'openai',
          contextLength: 128000,
          acceptsImages: true,
          promptPricePerMillion: 2.5,
        ),
      ];

      await ModelCatalog.saveCache(prefs, 'profile-1', models);

      final loaded = ModelCatalog.loadCache(prefs, 'profile-1')!;
      expect(loaded.single.id, 'openai/gpt-4o');
      expect(loaded.single.name, 'OpenAI: GPT-4o');
      expect(loaded.single.ownedBy, 'openai');
      expect(loaded.single.contextLength, 128000);
      expect(loaded.single.acceptsImages, isTrue);
      expect(loaded.single.promptPricePerMillion, 2.5);
      expect(prefs.getString('agent.models.profile-1'), isNotNull);
      expect(ModelCatalog.loadCache(prefs, 'profile-2'), isNull);
    });

    test('a damaged cache reads as no cache', () async {
      SharedPreferences.setMockInitialValues({'agent.models.profile-1': 'not json'});
      final prefs = await SharedPreferences.getInstance();
      expect(ModelCatalog.loadCache(prefs, 'profile-1'), isNull);
    });
  });
}
