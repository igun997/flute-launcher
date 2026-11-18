import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:focus_launcher/agent/llm/responses_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const baseUrl = 'https://chatgpt.example.com/backend-api/codex';
const token = 'tok-secret-123';

/// The fields this endpoint refuses. None of them may appear in the body.
const forbiddenFields = [
  'temperature',
  'max_output_tokens',
  'metadata',
  'user',
  'truncation',
  'previous_response_id',
  'conversation',
  'top_p',
];

http.Response eventReply(List<Map<String, dynamic>> events, {String? named}) =>
    http.Response.bytes(
      utf8.encode([
        for (final event in events)
          '${named == null ? '' : 'event: $named\n'}data: ${jsonEncode(event)}\n\n',
      ].join()),
      200,
      headers: {'content-type': 'text/event-stream'},
    );

ResponsesClient clientFor(http.Client http) => ResponsesClient(
      baseUrl: baseUrl,
      accessToken: () async => token,
      httpClient: http,
    );

Future<List<LlmEvent>> run(ResponsesClient client, LlmRequest request) =>
    client.stream(request).toList();

LlmRequest sampleRequest({List<ToolSpec> tools = const []}) => LlmRequest(
      model: 'gpt-5.1',
      instructions: 'Be brief.',
      messages: [
        ChatMessage.text(Role.system, 'Rules: answer in English.'),
        ChatMessage(role: Role.user, parts: [
          const TextPart('look at this'),
          ImagePart(Uint8List.fromList([1, 2, 3]), mime: 'image/png'),
          FilePart(Uint8List.fromList([4, 5]), name: 'a.pdf', mime: 'application/pdf'),
        ]),
        ChatMessage.text(Role.assistant, 'Sure.'),
        const ChatMessage(role: Role.assistant, toolCalls: [
          ToolCall(id: 'call_1', name: 'notes_list', arguments: {'limit': 2}),
        ]),
        ChatMessage.toolResult('call_1', '[]'),
      ],
      tools: tools,
    );

void main() {
  group('request body', () {
    test('carries only allowed fields, with store false and stream true', () async {
      final sent = <http.Request>[];
      final client = clientFor(MockClient((request) async {
        sent.add(request);
        return eventReply([
          {'type': 'response.completed', 'response': {}},
        ]);
      }));

      await run(
        client,
        sampleRequest(tools: const [
          ToolSpec(name: 'notes_list', description: 'List notes', parameters: {'type': 'object'}),
        ]),
      );

      final request = sent.single;
      expect(request.url.toString(), '$baseUrl/responses');
      expect(request.headers['Authorization'], 'Bearer $token');
      expect(request.headers['Accept'], 'text/event-stream');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'model', 'instructions', 'input', 'tools', 'store', 'stream'});
      for (final field in forbiddenFields) {
        expect(body.containsKey(field), isFalse, reason: '$field must not be sent');
      }
      expect(body['store'], isFalse);
      expect(body['stream'], isTrue);
      expect(body['model'], 'gpt-5.1');
    });

    test('folds system messages into instructions and never sends a system item', () async {
      final sent = <http.Request>[];
      final client = clientFor(MockClient((request) async {
        sent.add(request);
        return eventReply([
          {'type': 'response.completed', 'response': {}},
        ]);
      }));

      await run(client, sampleRequest());

      final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
      expect(body['instructions'], 'Be brief.\n\nRules: answer in English.');
      final input = body['input'] as List;
      for (final item in input) {
        expect((item as Map)['role'], isNot('system'));
      }
      expect(body.containsKey('tools'), isFalse);
    });

    test('maps user, assistant, tool call and tool result items', () async {
      final sent = <http.Request>[];
      final client = clientFor(MockClient((request) async {
        sent.add(request);
        return eventReply([
          {'type': 'response.completed', 'response': {}},
        ]);
      }));

      await run(client, sampleRequest());

      final input = (jsonDecode(sent.single.body) as Map)['input'] as List;
      expect(input, [
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'look at this'},
            {'type': 'input_image', 'image_url': 'data:image/png;base64,AQID'},
            {'type': 'input_file', 'filename': 'a.pdf', 'file_data': 'data:application/pdf;base64,BAU='},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'Sure.'},
          ],
        },
        {
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'notes_list',
          'arguments': '{"limit":2}',
        },
        {'type': 'function_call_output', 'call_id': 'call_1', 'output': '[]'},
      ]);
    });
  });

  group('events', () {
    test('text and reasoning deltas, then completion with usage', () async {
      final client = clientFor(MockClient((_) async => eventReply([
            {'type': 'response.reasoning_summary_text.delta', 'delta': 'Plan'},
            {'type': 'response.output_text.delta', 'delta': 'Hi'},
            {'type': 'response.output_text.delta', 'delta': ' there'},
            {
              'type': 'response.completed',
              'response': {
                'usage': {'input_tokens': 5, 'output_tokens': 9},
                'output': [],
              },
            },
          ])));

      final events = await run(client, sampleRequest());

      expect(events[0], isA<ReasoningDelta>());
      expect((events[0] as ReasoningDelta).text, 'Plan');
      expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Hi there');
      final finished = events.last as LlmFinished;
      expect(finished.reason, FinishReason.stop);
      expect(finished.toolCalls, isEmpty);
      expect(finished.usage?.inputTokens, 5);
      expect(finished.usage?.outputTokens, 9);
    });

    test('a function call assembled from item and argument events', () async {
      final client = clientFor(MockClient((_) async => eventReply([
            {
              'type': 'response.output_item.added',
              'item': {
                'type': 'function_call',
                'id': 'fc_1',
                'call_id': 'call_1',
                'name': 'notes_list',
                'arguments': '',
              },
            },
            {'type': 'response.function_call_arguments.delta', 'item_id': 'fc_1', 'delta': '{"limit"'},
            {'type': 'response.function_call_arguments.delta', 'item_id': 'fc_1', 'delta': ':2}'},
            {'type': 'response.function_call_arguments.done', 'item_id': 'fc_1', 'arguments': '{"limit":2}'},
            {
              'type': 'response.output_item.done',
              'item': {
                'type': 'function_call',
                'id': 'fc_1',
                'call_id': 'call_1',
                'name': 'notes_list',
                'arguments': '{"limit":2}',
              },
            },
            {
              'type': 'response.completed',
              'response': {'usage': {'input_tokens': 1, 'output_tokens': 2}, 'output': []},
            },
          ])));

      final finished = (await run(client, sampleRequest())).last as LlmFinished;
      expect(finished.reason, FinishReason.toolCalls);
      expect(finished.toolCalls, hasLength(1));
      expect(finished.toolCalls.single.id, 'call_1');
      expect(finished.toolCalls.single.name, 'notes_list');
      expect(finished.toolCalls.single.arguments, {'limit': 2});
    });

    test('an incomplete response finishes with length', () async {
      final client = clientFor(MockClient((_) async => eventReply([
            {'type': 'response.output_text.delta', 'delta': 'Long'},
            {
              'type': 'response.incomplete',
              'response': {'incomplete_details': {'reason': 'max_output_tokens'}},
            },
          ])));

      final finished = (await run(client, sampleRequest())).last as LlmFinished;
      expect(finished.reason, FinishReason.length);
    });

    test('a failed response raises its error with a friendly subscription message', () async {
      final client = clientFor(MockClient((_) async => eventReply([
            {
              'type': 'response.failed',
              'response': {
                'error': {
                  'code': 'subscription_sharing_usage_limit_exceeded',
                  'message': 'raw provider text',
                },
              },
            },
          ])));

      await expectLater(
        run(client, sampleRequest()),
        throwsA(isA<LlmException>()
            .having((e) => e.code, 'code', 'subscription_sharing_usage_limit_exceeded')
            .having(
              (e) => e.message,
              'message',
              'Your ChatGPT plan limit for apps is used up. Wait for it to reset or raise the '
                  'limit in ChatGPT > Settings > Usage.',
            )),
      );
    });

    test('an error event raises its message and code', () async {
      final client = clientFor(MockClient((_) async => eventReply(
            [
              {'type': 'error', 'code': 'server_error', 'message': 'Boom'},
            ],
            named: 'error',
          )));

      await expectLater(
        run(client, sampleRequest()),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', 'Boom')
            .having((e) => e.code, 'code', 'server_error')),
      );
    });

    test('a stream that ends without a terminal event is reported as cut off', () async {
      final client = clientFor(MockClient((_) async => eventReply([
            {'type': 'response.output_text.delta', 'delta': 'half'},
          ])));

      await expectLater(
        run(client, sampleRequest()),
        throwsA(isA<LlmException>().having((e) => e.message, 'message', 'The reply was cut off')),
      );
    });
  });

  group('errors', () {
    test('a refused token asks for a new ChatGPT sign-in and never shows the token', () async {
      final client = clientFor(MockClient((_) async => http.Response(
            'Token $token expired',
            401,
          )));

      await expectLater(
        run(client, sampleRequest()),
        throwsA(isA<LlmException>()
            .having((e) => e.isAuth, 'isAuth', isTrue)
            .having((e) => e.message, 'message', contains('Sign in with ChatGPT again'))
            .having((e) => e.message, 'message', isNot(contains(token)))),
      );
    });

    test('an unreachable host names the host only', () async {
      final client = clientFor(MockClient((_) async => throw http.ClientException('no route')));

      await expectLater(
        run(client, sampleRequest()),
        throwsA(isA<LlmException>().having((e) => e.message, 'message', 'Cannot reach chatgpt.example.com')),
      );
    });
  });
}
