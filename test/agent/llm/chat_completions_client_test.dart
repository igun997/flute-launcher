import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/llm/chat_completions_client.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const baseUrl = 'https://gw.example.com/v1';
const key = 'sk-test-123';

http.Response sseReply(List<String> data) => http.Response.bytes(
      utf8.encode([for (final d in data) 'data: $d\n\n'].join()),
      200,
      headers: {'content-type': 'text/event-stream'},
    );

http.Response jsonReply(Object body, {int status = 200}) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Answers requests in order and records each one.
MockClient scripted(List<http.Response> replies, List<http.Request> sent) {
  var next = 0;
  return MockClient((request) async {
    sent.add(request);
    return replies[next++];
  });
}

ChatCompletionsClient clientFor(http.Client http) => ChatCompletionsClient(
      baseUrl: '$baseUrl/',
      apiKey: () async => key,
      httpClient: http,
    );

LlmRequest requestWith({
  List<ChatMessage>? messages,
  List<ToolSpec> tools = const [],
  String? instructions = 'Be brief.',
}) =>
    LlmRequest(
      model: 'gpt-test',
      messages: messages ?? [ChatMessage.text(Role.user, 'Hi')],
      tools: tools,
      instructions: instructions,
    );

Future<List<LlmEvent>> run(ChatCompletionsClient client, [LlmRequest? request]) =>
    client.stream(request ?? requestWith()).toList();

Map<String, dynamic> bodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

Map<String, dynamic> chunk(Map<String, dynamic> delta, {String? finish, Object? usage}) => {
      'choices': [
        {'delta': delta, if (finish != null) 'finish_reason': finish},
      ],
      if (usage != null) 'usage': usage,
    };

void main() {
  group('streaming', () {
    test('text, reasoning, a tool call and usage arrive as events', () async {
      final sent = <http.Request>[];
      final client = clientFor(scripted([
        sseReply([
          jsonEncode(chunk({'reasoning_content': 'Thinking'})),
          jsonEncode(chunk({'content': 'Hel'})),
          jsonEncode(chunk({'content': 'lo'})),
          jsonEncode(chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'notes_list', 'arguments': ''},
              },
            ],
          })),
          jsonEncode(chunk({
            'tool_calls': [
              {'index': 0, 'function': {'arguments': '{"limit":'}},
            ],
          })),
          jsonEncode(chunk({
            'tool_calls': [
              {'index': 0, 'function': {'arguments': ' 5}'}},
            ],
          }, finish: 'tool_calls')),
          jsonEncode({
            'choices': <Object>[],
            'usage': {'prompt_tokens': 12, 'completion_tokens': 7},
          }),
          '[DONE]',
        ]),
      ], sent));

      final events = await run(client);

      expect(events[0], isA<ReasoningDelta>());
      expect((events[0] as ReasoningDelta).text, 'Thinking');
      expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Hello');
      final finished = events.last as LlmFinished;
      expect(finished.reason, FinishReason.toolCalls);
      expect(finished.toolCalls, hasLength(1));
      expect(finished.toolCalls.single.id, 'call_1');
      expect(finished.toolCalls.single.name, 'notes_list');
      expect(finished.toolCalls.single.arguments, {'limit': 5});
      expect(finished.usage?.inputTokens, 12);
      expect(finished.usage?.outputTokens, 7);
      expect(events.whereType<LlmFinished>(), hasLength(1));
    });

    test('a gateway that repeats id and name on every fragment still makes one call', () async {
      final client = clientFor(scripted([
        sseReply([
          jsonEncode(chunk({
            'tool_calls': [
              {'index': 0, 'id': 'call_a', 'function': {'name': 'list_x', 'arguments': '{"q"'}},
            ],
          })),
          jsonEncode(chunk({
            'tool_calls': [
              {'index': 0, 'id': 'call_a', 'function': {'name': 'list_x', 'arguments': ':"hi"}'}},
            ],
          }, finish: 'tool_calls')),
          '[DONE]',
        ]),
      ], []));

      final finished = (await run(client)).last as LlmFinished;
      expect(finished.toolCalls.map((c) => c.name), ['list_x']);
      expect(finished.toolCalls.single.arguments, {'q': 'hi'});
    });

    test('a gateway that sends each whole call in one chunk gets one call per id', () async {
      final client = clientFor(scripted([
        sseReply([
          jsonEncode(chunk({
            'tool_calls': [
              {'index': 0, 'id': 'c1', 'function': {'name': 'time', 'arguments': '{}'}},
              {'index': 0, 'id': 'c2', 'function': {'name': 'notes_list', 'arguments': '{"limit":2}'}},
            ],
          }, finish: 'tool_calls')),
          '[DONE]',
        ]),
      ], []));

      final finished = (await run(client)).last as LlmFinished;
      expect(finished.toolCalls.map((c) => c.id), ['c1', 'c2']);
      expect(finished.toolCalls.map((c) => c.name), ['time', 'notes_list']);
      expect(finished.toolCalls[1].arguments, {'limit': 2});
    });

    test('a call without an index, sent whole, is still kept', () async {
      final client = clientFor(scripted([
        sseReply([
          jsonEncode(chunk({
            'tool_calls': [
              {'id': 'c9', 'function': {'name': 'current_time', 'arguments': '{}'}},
            ],
          }, finish: 'tool_calls')),
          '[DONE]',
        ]),
      ], []));

      final finished = (await run(client)).last as LlmFinished;
      expect(finished.toolCalls.single.name, 'current_time');
      expect(finished.toolCalls.single.arguments, isEmpty);
    });

    test('arguments that are not JSON are kept under _raw', () async {
      final client = clientFor(scripted([
        sseReply([
          jsonEncode(chunk({
            'tool_calls': [
              {'index': 0, 'id': 'c1', 'function': {'name': 'notes_read', 'arguments': '{"id":'}},
            ],
          }, finish: 'tool_calls')),
          '[DONE]',
        ]),
      ], []));

      final finished = (await run(client)).last as LlmFinished;
      expect(finished.toolCalls.single.arguments, {'_raw': '{"id":'});
    });

    test('finish reasons map to FinishReason', () async {
      for (final (raw, expected) in [
        ('stop', FinishReason.stop),
        ('length', FinishReason.length),
        ('content_filter', FinishReason.filtered),
      ]) {
        final client = clientFor(scripted([
          sseReply([
            jsonEncode(chunk({'content': 'x'}, finish: raw)),
            '[DONE]',
          ]),
        ], []));
        final finished = (await run(client)).last as LlmFinished;
        expect(finished.reason, expected);
      }
    });

    test('a stream that stops without a finish reason is reported as cut off', () async {
      final client = clientFor(scripted([
        sseReply([jsonEncode(chunk({'content': 'partial'}))]),
      ], []));

      await expectLater(
        run(client),
        throwsA(isA<LlmException>().having((e) => e.message, 'message', 'The reply was cut off')),
      );
    });

    test('an error object inside the stream is raised', () async {
      final client = clientFor(scripted([
        sseReply([
          jsonEncode({'error': {'message': 'Overloaded', 'code': 'overloaded'}}),
        ]),
      ], []));

      await expectLater(
        run(client),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', 'Overloaded')
            .having((e) => e.code, 'code', 'overloaded')),
      );
    });
  });

  group('non-streamed answer', () {
    test('a JSON completion yields the same events', () async {
      final client = clientFor(scripted([
        jsonReply({
          'choices': [
            {
              'message': {
                'content': 'Done',
                'reasoning_content': 'ok',
                'tool_calls': [
                  {
                    'id': 'c9',
                    'type': 'function',
                    'function': {'name': 'contacts_get', 'arguments': '{"id":"7"}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
          'usage': {'prompt_tokens': 3, 'completion_tokens': 4},
        }),
      ], []));

      final events = await run(client);
      expect(events.whereType<ReasoningDelta>().single.text, 'ok');
      expect(events.whereType<TextDelta>().single.text, 'Done');
      final finished = events.last as LlmFinished;
      expect(finished.reason, FinishReason.toolCalls);
      expect(finished.toolCalls.single.arguments, {'id': '7'});
      expect(finished.usage?.outputTokens, 4);
    });
  });

  group('requests', () {
    test('posts to /chat/completions with bearer auth and an event-stream accept header', () async {
      final sent = <http.Request>[];
      final client = clientFor(scripted([
        sseReply(['[DONE]']),
      ], sent));

      await run(client);

      final request = sent.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$baseUrl/chat/completions');
      expect(request.headers['Authorization'], 'Bearer $key');
      expect(request.headers['Accept'], 'text/event-stream');
      expect(bodyOf(request)['stream'], isTrue);
      expect(bodyOf(request)['stream_options'], {'include_usage': true});
    });

    test('maps the system prompt, images, files, tool calls, tool results and tools', () async {
      final sent = <http.Request>[];
      final client = clientFor(scripted([
        sseReply(['[DONE]']),
      ], sent));

      await run(
        client,
        requestWith(
          messages: [
            ChatMessage(role: Role.user, parts: [
              const TextPart('look'),
              ImagePart(Uint8List.fromList([1, 2, 3]), mime: 'image/png'),
              FilePart(Uint8List.fromList([1, 2, 3]), name: 'a.pdf', mime: 'application/pdf'),
            ]),
            const ChatMessage(role: Role.assistant, toolCalls: [
              ToolCall(id: 'c1', name: 'notes_list', arguments: {'limit': 3}),
            ]),
            ChatMessage.toolResult('c1', 'ok'),
          ],
          tools: const [
            ToolSpec(name: 'notes_list', description: 'List notes', parameters: {'type': 'object'}),
          ],
        ),
      );

      final body = bodyOf(sent.single);
      final messages = body['messages'] as List;
      expect(messages[0], {'role': 'system', 'content': 'Be brief.'});

      final user = messages[1] as Map;
      expect(user['role'], 'user');
      final content = user['content'] as List;
      expect(content[0], {'type': 'text', 'text': 'look'});
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AQID'},
      });
      expect(content[2], {
        'type': 'file',
        'file': {'filename': 'a.pdf', 'file_data': 'data:application/pdf;base64,AQID'},
      });

      expect(messages[2], {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'c1',
            'type': 'function',
            'function': {'name': 'notes_list', 'arguments': '{"limit":3}'},
          },
        ],
      });
      expect(messages[3], {'role': 'tool', 'tool_call_id': 'c1', 'content': 'ok'});

      expect(body['tools'], [
        {
          'type': 'function',
          'function': {
            'name': 'notes_list',
            'description': 'List notes',
            'parameters': {'type': 'object'},
          },
        },
      ]);
    });

    test('a lone text message is sent as a plain string and no tools key without tools', () async {
      final sent = <http.Request>[];
      final client = clientFor(scripted([
        sseReply(['[DONE]']),
      ], sent));

      await run(client, requestWith(instructions: null));

      final body = bodyOf(sent.single);
      expect(body.containsKey('tools'), isFalse);
      expect(body['messages'], [
        {'role': 'user', 'content': 'Hi'},
      ]);
    });

    test('retries once without stream_options when the gateway refuses them', () async {
      final sent = <http.Request>[];
      final client = clientFor(scripted([
        http.Response.bytes(
          utf8.encode(jsonEncode({
            'error': {'message': 'Unrecognized request argument: stream_options'},
          })),
          400,
          headers: {'content-type': 'application/json'},
        ),
        sseReply([jsonEncode(chunk({'content': 'ok'})), '[DONE]']),
      ], sent));

      final events = await run(client);

      expect(sent, hasLength(2));
      expect(bodyOf(sent[0]).containsKey('stream_options'), isTrue);
      expect(bodyOf(sent[1]).containsKey('stream_options'), isFalse);
      expect(events.whereType<TextDelta>().single.text, 'ok');
    });
  });

  group('errors', () {
    test('a refused key says so and never shows the key', () async {
      final client = clientFor(scripted([
        jsonReply({'error': {'message': 'Invalid key $key'}}, status: 401),
      ], []));

      await expectLater(
        run(client),
        throwsA(isA<LlmException>()
            .having((e) => e.isAuth, 'isAuth', isTrue)
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', contains('refused'))
            .having((e) => e.message, 'message', isNot(contains(key)))),
      );
    });

    test('a provider error message and code are shown', () async {
      final client = clientFor(scripted([
        jsonReply({'error': {'message': 'Rate limit hit', 'code': 'rate_limited'}}, status: 429),
      ], []));

      await expectLater(
        run(client),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', 'Rate limit hit')
            .having((e) => e.code, 'code', 'rate_limited')
            .having((e) => e.statusCode, 'statusCode', 429)),
      );
    });

    test('a non-JSON error body is shown as a short prefix', () async {
      final client = clientFor(scripted([
        http.Response('Bad gateway upstream timeout', 502),
      ], []));

      await expectLater(
        run(client),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', 'Bad gateway upstream timeout')
            .having((e) => e.statusCode, 'statusCode', 502)),
      );
    });

    test('an unreachable host names the host only', () async {
      final client = ChatCompletionsClient(
        baseUrl: baseUrl,
        apiKey: () async => key,
        httpClient: MockClient((_) async => throw const SocketException('Connection refused')),
      );

      await expectLater(
        run(client),
        throwsA(isA<LlmException>().having((e) => e.message, 'message', 'Cannot reach gw.example.com')),
      );
    });
  });
}
