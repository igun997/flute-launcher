import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_types.dart';
import 'sse.dart';
import 'wire_support.dart';

/// Chat Completions over HTTP: `POST {baseUrl}/chat/completions`, streamed as SSE. Covers
/// OpenAI-compatible gateways, OpenRouter, Ollama and anything that copies them.
class ChatCompletionsClient implements LlmClient {
  ChatCompletionsClient({
    required String baseUrl,
    required Future<String> Function() apiKey,
    Map<String, String> extraHeaders = const {},
    http.Client? httpClient,
  })  : _baseUrl = normaliseBaseUrl(baseUrl),
        _apiKey = apiKey,
        _extraHeaders = extraHeaders,
        _http = httpClient ?? http.Client();

  final String _baseUrl;
  final Future<String> Function() _apiKey;
  final Map<String, String> _extraHeaders;
  final http.Client _http;

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      mapNetworkErrors(_run(request), hostOf(_baseUrl));

  @override
  void close() => _http.close();

  Stream<LlmEvent> _run(LlmRequest request) async* {
    final host = hostOf(_baseUrl);
    final key = await _apiKey();
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final body = _body(request);

    var response = await _post(uri, key, body);
    if (response.statusCode == 400) {
      // Some gateways reject stream_options. Retry once without it.
      final text = await readBody(response, host);
      if (!text.contains('stream_options')) {
        throw httpFailure(status: 400, body: text, host: host, secret: key);
      }
      body.remove('stream_options');
      response = await _post(uri, key, body);
    }
    if (response.statusCode >= 400) {
      final text = await readBody(response, host);
      throw httpFailure(status: response.statusCode, body: text, host: host, secret: key);
    }

    final turn = _ChatTurn(secret: key);
    if (isJsonResponse(response)) {
      // The server ignored stream:true and answered with one complete message.
      final json = decodeObject(await readBody(response, host), host);
      for (final event in turn.apply(json, wholeMessage: true)) {
        yield event;
      }
      yield turn.finished();
      return;
    }

    var done = false;
    await for (final sse in parseSse(response.stream.timeout(llmIdleTimeout))) {
      final data = sse.data.trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') {
        done = true;
        break;
      }
      for (final event in turn.apply(decodeObject(data, host), wholeMessage: false)) {
        yield event;
      }
    }
    if (!done && turn.finishReason == null) {
      throw const LlmException('The reply was cut off');
    }
    yield turn.finished();
  }

  Future<http.StreamedResponse> _post(Uri uri, String key, Map<String, dynamic> body) =>
      postEventStream(_http, uri, extraHeaders: _extraHeaders, bearer: key, body: body);

  Map<String, dynamic> _body(LlmRequest request) {
    final instructions = request.instructions;
    return {
      'model': request.model,
      'messages': [
        if (instructions != null && instructions.trim().isNotEmpty)
          {'role': 'system', 'content': instructions},
        for (final message in request.messages) _message(message),
      ],
      'stream': true,
      'stream_options': {'include_usage': true},
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {
              'type': 'function',
              'function': {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
              },
            },
        ],
    };
  }

  Map<String, dynamic> _message(ChatMessage message) {
    if (message.role == Role.tool) {
      return {
        'role': 'tool',
        'tool_call_id': message.toolCallId ?? '',
        'content': message.text,
      };
    }
    if (message.role == Role.assistant) {
      final text = message.text;
      return {
        'role': 'assistant',
        'content': text.isEmpty && message.toolCalls.isNotEmpty ? null : text,
        if (message.toolCalls.isNotEmpty)
          'tool_calls': [
            for (final call in message.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {'name': call.name, 'arguments': jsonEncode(call.arguments)},
              },
          ],
      };
    }
    return {'role': message.role.name, 'content': _content(message.parts)};
  }

  /// A plain string for a lone text part, otherwise the typed content list.
  Object _content(List<Part> parts) {
    if (parts.isEmpty) return '';
    if (parts.length == 1 && parts.first is TextPart) {
      return (parts.first as TextPart).text;
    }
    return [
      for (final part in parts)
        switch (part) {
          TextPart(:final text) => {'type': 'text', 'text': text},
          ImagePart(:final bytes, :final mime) => {
              'type': 'image_url',
              'image_url': {'url': dataUrl(mime, bytes)},
            },
          FilePart(:final bytes, :final name, :final mime) => {
              'type': 'file',
              'file': {'filename': name, 'file_data': dataUrl(mime, bytes)},
            },
        },
    ];
  }
}

/// Accumulates one assistant turn from stream chunks, or from one complete message.
class _ChatTurn {
  _ChatTurn({required this.secret});

  final String secret;
  final List<_CallFragments> _calls = [];
  final Map<int, _CallFragments> _byIndex = {};
  String? finishReason;
  Usage? usage;

  /// Events for one parsed chunk. [wholeMessage] is set for a non-streamed completion, where
  /// tool calls carry no index and each one is complete.
  List<LlmEvent> apply(Map<String, dynamic> json, {required bool wholeMessage}) {
    if (json['error'] != null) {
      throw providerError(json['error'],
          fallback: 'The provider stopped the reply.', secret: secret);
    }
    final usageJson = json['usage'];
    if (usageJson is Map) {
      final input = intOf(usageJson['prompt_tokens']);
      final output = intOf(usageJson['completion_tokens']);
      if (input != null || output != null) {
        usage = Usage(inputTokens: input, outputTokens: output);
      }
    }
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) return const [];
    final choice = choices.first as Map;
    finishReason = textOf(choice['finish_reason']) ?? finishReason;
    final delta = choice['delta'] ?? choice['message'];
    if (delta is! Map) return const [];

    final events = <LlmEvent>[];
    final text = _text(delta['content']);
    if (text.isNotEmpty) events.add(TextDelta(text));
    final thinking = textOf(delta['reasoning_content']) ?? textOf(delta['reasoning']);
    if (thinking != null) events.add(ReasoningDelta(thinking));
    final calls = delta['tool_calls'];
    if (calls is List) {
      for (var i = 0; i < calls.length; i++) {
        final call = calls[i];
        if (call is Map) {
          _addFragment(call, index: intOf(call['index']) ?? (wholeMessage ? i : null));
        }
      }
    }
    return events;
  }

  LlmFinished finished() {
    final calls = <ToolCall>[];
    for (var i = 0; i < _calls.length; i++) {
      final call = _calls[i];
      if (call.name.isEmpty) continue;
      calls.add(ToolCall(
        id: call.id ?? 'call_$i',
        name: call.name,
        arguments: parseToolArguments(call.arguments.toString()),
      ));
    }
    return LlmFinished(
      reason: calls.isNotEmpty ? FinishReason.toolCalls : _reasonFor(finishReason),
      toolCalls: calls,
      usage: usage,
    );
  }

  /// Gateways differ: some send id and name once, some repeat them on every fragment, some send
  /// a whole call in one chunk. Fragments are merged by index; a new id on a reused index starts
  /// a new call.
  void _addFragment(Map call, {int? index}) {
    final function = call['function'];
    final fn = function is Map ? function : const <dynamic, dynamic>{};
    final id = textOf(call['id']);
    final name = textOf(fn['name']);
    final args = fn['arguments'];
    final fragment = args is String ? args : (args == null ? null : jsonEncode(args));

    var slot = index == null ? null : _byIndex[index];
    if (slot != null && !slot.accepts(id)) slot = null;
    if (slot == null && index == null && _calls.isNotEmpty && _calls.last.accepts(id)) {
      slot = _calls.last;
    }
    if (slot == null) {
      slot = _CallFragments();
      _calls.add(slot);
    }
    if (index != null) _byIndex[index] = slot;
    slot.id ??= id;
    if (name != null) slot.addName(name);
    if (fragment != null) slot.arguments.write(fragment);
  }

  static String _text(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is Map) buffer.write(textOf(part['text']) ?? '');
    }
    return buffer.toString();
  }

  static FinishReason _reasonFor(String? raw) => switch (raw) {
        null || 'stop' => FinishReason.stop,
        'tool_calls' || 'function_call' => FinishReason.toolCalls,
        'length' => FinishReason.length,
        'content_filter' => FinishReason.filtered,
        _ => FinishReason.other,
      };
}

class _CallFragments {
  String? id;
  String name = '';
  final StringBuffer arguments = StringBuffer();

  /// Whether a fragment carrying [otherId] can belong to this call. A missing id always fits.
  bool accepts(String? otherId) => otherId == null || id == null || id == otherId;

  void addName(String part) {
    if (name.isEmpty) {
      name = part;
    } else if (part != name) {
      // Some gateways split the name across fragments.
      name += part;
    }
  }
}
