import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_types.dart';
import 'model_info.dart';
import 'sse.dart';
import 'wire_support.dart';

/// The Responses API as used by ChatGPT plan sign-in: `POST {baseUrl}/responses`, streamed.
/// The endpoint rejects several common fields, so the body is built from an allow-list.
class ResponsesClient implements LlmClient {
  ResponsesClient({
    required String baseUrl,
    required Future<String> Function() accessToken,
    Map<String, String> extraHeaders = const {},
    http.Client? httpClient,
  })  : _baseUrl = normaliseBaseUrl(baseUrl),
        _accessToken = accessToken,
        _extraHeaders = extraHeaders,
        _http = httpClient ?? http.Client();

  final String _baseUrl;
  final Future<String> Function() _accessToken;
  final Map<String, String> _extraHeaders;
  final http.Client _http;

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      mapNetworkErrors(_run(request), hostOf(_baseUrl));

  @override
  void close() => _http.close();

  Stream<LlmEvent> _run(LlmRequest request) async* {
    final host = hostOf(_baseUrl);
    final token = await _accessToken();
    final response = await postEventStream(
      _http,
      Uri.parse('$_baseUrl/responses'),
      extraHeaders: _extraHeaders,
      bearer: token,
      body: _body(request),
    );
    if (response.statusCode >= 400) {
      final text = await readBody(response, host);
      throw httpFailure(
        status: response.statusCode,
        body: text,
        host: host,
        secret: token,
        kind: ProviderKind.chatgptPlan,
      );
    }

    final turn = _ResponsesTurn();
    var finished = false;
    await for (final sse in parseSse(response.stream.timeout(llmIdleTimeout))) {
      final data = sse.data.trim();
      if (data.isEmpty) continue;
      final json = decodeObject(data, host);
      final type = textOf(json['type']) ?? sse.event ?? '';
      if (type == 'response.output_text.delta') {
        final text = textOf(json['delta']);
        if (text != null) yield TextDelta(text);
      } else if (type == 'response.reasoning_summary_text.delta' ||
          type == 'response.reasoning_text.delta') {
        final text = textOf(json['delta']);
        if (text != null) yield ReasoningDelta(text);
      } else if (type == 'response.output_item.added' || type == 'response.output_item.done') {
        final item = json['item'];
        if (item is Map) turn.addItem(item);
      } else if (type == 'response.function_call_arguments.delta') {
        final itemId = textOf(json['item_id']);
        if (itemId != null) turn.appendArguments(itemId, textOf(json['delta']) ?? '');
      } else if (type == 'response.function_call_arguments.done') {
        final itemId = textOf(json['item_id']);
        final arguments = textOf(json['arguments']);
        if (itemId != null && arguments != null) turn.setArguments(itemId, arguments);
      } else if (type == 'response.completed' || type == 'response.incomplete') {
        final completed = json['response'];
        if (completed is Map) turn.complete(completed);
        turn.incomplete = type == 'response.incomplete';
        finished = true;
        break;
      } else if (type == 'response.failed') {
        final completed = json['response'];
        final failure = (completed is Map ? completed['error'] : null) ?? json['error'];
        throw providerError(failure, fallback: 'The reply failed.', secret: token);
      } else if (type == 'error') {
        throw providerError(json['error'] ?? json,
            fallback: 'The provider stopped the reply.', secret: token);
      }
    }
    if (!finished) throw const LlmException('The reply was cut off');
    yield turn.finished();
  }

  /// Only the fields this endpoint accepts. System messages travel in `instructions`.
  Map<String, dynamic> _body(LlmRequest request) {
    final instructions = <String>[
      if (request.instructions != null && request.instructions!.trim().isNotEmpty)
        request.instructions!,
    ];
    final input = <Map<String, dynamic>>[];
    for (final message in request.messages) {
      if (message.role == Role.system) {
        if (message.text.trim().isNotEmpty) instructions.add(message.text);
      } else if (message.role == Role.tool) {
        input.add({
          'type': 'function_call_output',
          'call_id': message.toolCallId ?? '',
          'output': message.text,
        });
      } else if (message.role == Role.assistant) {
        final text = message.text;
        if (text.isNotEmpty) {
          input.add({
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          });
        }
        for (final call in message.toolCalls) {
          input.add({
            'type': 'function_call',
            'call_id': call.id,
            'name': call.name,
            'arguments': jsonEncode(call.arguments),
          });
        }
      } else {
        final content = [
          for (final part in message.parts)
            switch (part) {
              TextPart(:final text) => {'type': 'input_text', 'text': text},
              ImagePart(:final bytes, :final mime) => {
                  'type': 'input_image',
                  'image_url': dataUrl(mime, bytes),
                },
              FilePart(:final bytes, :final name, :final mime) => {
                  'type': 'input_file',
                  'filename': name,
                  'file_data': dataUrl(mime, bytes),
                },
            },
        ];
        if (content.isNotEmpty) input.add({'role': 'user', 'content': content});
      }
    }
    return {
      'model': request.model,
      'instructions': instructions.join('\n\n'),
      'input': input,
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
        ],
      'store': false,
      'stream': true,
    };
  }
}

/// Accumulates one assistant turn from Responses events.
class _ResponsesTurn {
  /// Keyed by the output item id, in the order the calls started.
  final Map<String, _FunctionCall> _calls = {};
  Usage? usage;
  bool incomplete = false;

  void addItem(Map<dynamic, dynamic> item) {
    if (item['type'] != 'function_call') return;
    final key = textOf(item['id']) ?? textOf(item['call_id']) ?? 'item_${_calls.length}';
    final call = _calls.putIfAbsent(key, () => _FunctionCall());
    call.callId ??= textOf(item['call_id']);
    if (call.name.isEmpty) call.name = textOf(item['name']) ?? '';
    final arguments = textOf(item['arguments']);
    if (arguments != null) call.arguments = arguments;
  }

  void appendArguments(String itemId, String delta) {
    _calls.putIfAbsent(itemId, () => _FunctionCall()).arguments += delta;
  }

  void setArguments(String itemId, String arguments) {
    _calls.putIfAbsent(itemId, () => _FunctionCall()).arguments = arguments;
  }

  /// The final `response` object: usage, and any function calls not seen as events.
  void complete(Map<dynamic, dynamic> response) {
    final usageJson = response['usage'];
    if (usageJson is Map) {
      usage = Usage(
        inputTokens: intOf(usageJson['input_tokens']),
        outputTokens: intOf(usageJson['output_tokens']),
      );
    }
    final output = response['output'];
    if (output is List) {
      for (final item in output) {
        if (item is Map) addItem(item);
      }
    }
  }

  LlmFinished finished() {
    final calls = <ToolCall>[
      for (final entry in _calls.entries)
        if (entry.value.name.isNotEmpty)
          ToolCall(
            id: entry.value.callId ?? entry.key,
            name: entry.value.name,
            arguments: parseToolArguments(entry.value.arguments),
          ),
    ];
    final reason = calls.isNotEmpty
        ? FinishReason.toolCalls
        : (incomplete ? FinishReason.length : FinishReason.stop);
    return LlmFinished(reason: reason, toolCalls: calls, usage: usage);
  }
}

class _FunctionCall {
  String? callId;
  String name = '';
  String arguments = '';
}
