import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'llm_types.dart';
import 'model_info.dart';

/// Gives up when the provider has not answered with response headers.
const llmConnectTimeout = Duration(seconds: 60);

/// Gives up when a stream goes quiet. Reasoning models can pause for a long time before text.
const llmIdleTimeout = Duration(seconds: 120);

/// The host name for messages. Never includes credentials, paths or query strings.
String hostOf(String baseUrl) {
  final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
  return host.isEmpty ? 'the provider' : host;
}

/// Trims whitespace and trailing slashes so `$baseUrl/chat/completions` is well formed.
String normaliseBaseUrl(String baseUrl) => baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');

bool isNetworkError(Object error) =>
    error is SocketException ||
    error is HandshakeException ||
    error is TimeoutException ||
    error is http.ClientException;

LlmException unreachable(String host) => LlmException('Cannot reach $host');

/// Turns network failures from [events] into [LlmException]; other errors pass through.
Stream<LlmEvent> mapNetworkErrors(Stream<LlmEvent> events, String host) async* {
  try {
    // Not `yield*`: that forwards the inner stream's errors past this catch.
    await for (final event in events) {
      yield event;
    }
  } catch (error) {
    if (isNetworkError(error)) throw unreachable(host);
    rethrow;
  }
}

/// POSTs a JSON body asking for an event stream. Completes when the response headers arrive.
Future<http.StreamedResponse> postEventStream(
  http.Client client,
  Uri uri, {
  required Map<String, String> extraHeaders,
  required String bearer,
  required Map<String, dynamic> body,
}) {
  final request = http.Request('POST', uri)
    ..headers.addAll({
      ...extraHeaders,
      if (bearer.isNotEmpty) 'Authorization': 'Bearer $bearer',
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    })
    ..bodyBytes = utf8.encode(jsonEncode(body));
  return client.send(request).timeout(llmConnectTimeout);
}

/// The first header whose name matches [name], case-insensitively.
String? headerOf(http.BaseResponse response, String name) {
  final wanted = name.toLowerCase();
  for (final entry in response.headers.entries) {
    if (entry.key.toLowerCase() == wanted) return entry.value;
  }
  return null;
}

bool isJsonResponse(http.BaseResponse response) =>
    (headerOf(response, 'content-type') ?? '').toLowerCase().contains('application/json');

/// The whole body as text. Malformed UTF-8 is replaced, never fatal.
Future<String> readBody(http.StreamedResponse response, String host) async {
  try {
    return utf8.decode(await response.stream.toBytes(), allowMalformed: true);
  } catch (error) {
    if (isNetworkError(error)) throw unreachable(host);
    rethrow;
  }
}

/// The error for an HTTP failure. The provider's own message is shown; [secret] is removed from
/// anything shown, and the request is never included.
LlmException httpFailure({
  required int status,
  required String body,
  required String host,
  String? secret,
  ProviderKind? kind,
}) {
  final json = _decodeOrNull(body);
  final error = json?['error'];
  final code = error is Map ? textOf(error['code']) : textOf(json?['code']);
  final detail = _providerMessage(json);
  final String message;
  if (status == 401 || status == 403) {
    final base = kind == ProviderKind.chatgptPlan
        ? 'ChatGPT refused the session. Sign in with ChatGPT again.'
        : 'The key was refused by $host. Check it in Agent settings.';
    message = detail == null ? base : '$base $detail';
  } else {
    message = detail ?? _bodyPrefix(body, status);
  }
  return LlmException(_redact(friendlyCode(code) ?? message, secret),
      statusCode: status, code: code);
}

/// An error carried inside a stream or a body: `{code, message}`, or a plain string.
LlmException providerError(Object? error, {required String fallback, String? secret}) {
  final map = error is Map ? error : null;
  final code = textOf(map?['code']);
  final message = textOf(map?['message']) ?? textOf(error) ?? fallback;
  return LlmException(_redact(friendlyCode(code) ?? message, secret), code: code);
}

/// Plain-language text for provider codes that need an explanation the user can act on.
String? friendlyCode(String? code) => switch (code) {
      'subscription_sharing_usage_limit_exceeded' ||
      'subscription_sharing_usage_unavailable' =>
        'Your ChatGPT plan limit for apps is used up. Wait for it to reset or raise the limit in ChatGPT > Settings > Usage.',
      _ => null,
    };

/// Parses a provider body. Text that is not JSON is a protocol failure, reported as such.
Object? decodeJson(String text, String host) {
  try {
    return jsonDecode(text);
  } on FormatException {
    throw LlmException('Unexpected reply from $host');
  }
}

Map<String, dynamic> decodeObject(String text, String host) {
  final value = decodeJson(text, host);
  if (value is Map<String, dynamic>) return value;
  throw LlmException('Unexpected reply from $host');
}

/// Tool-call arguments as a map. Arguments that are not a JSON object are kept as text under
/// `_raw` so the model can be told what went wrong.
Map<String, dynamic> parseToolArguments(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return {};
  final Object? value;
  try {
    value = jsonDecode(text);
  } on FormatException {
    return {'_raw': raw};
  }
  if (value == null) return {};
  if (value is Map<String, dynamic>) return value;
  return {'_raw': raw};
}

String dataUrl(String mime, List<int> bytes) => 'data:$mime;base64,${base64Encode(bytes)}';

/// A non-empty string, or a number written as text. Anything else is null.
String? textOf(Object? value) => switch (value) {
      String s when s.isNotEmpty => s,
      num n => '$n',
      _ => null,
    };

int? intOf(Object? value) => switch (value) {
      int i => i,
      num n => n.toInt(),
      String s => int.tryParse(s),
      _ => null,
    };

double? numOf(Object? value) => switch (value) {
      num n => n.toDouble(),
      String s => double.tryParse(s),
      _ => null,
    };

Map<String, dynamic>? _decodeOrNull(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}

String? _providerMessage(Map<String, dynamic>? json) {
  if (json == null) return null;
  final error = json['error'];
  if (error is Map) return textOf(error['message']);
  return textOf(error) ?? textOf(json['message']) ?? textOf(json['detail']);
}

String _bodyPrefix(String body, int status) {
  final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty || flat.startsWith('<')) return 'The provider answered with HTTP $status.';
  return flat.length > 200 ? '${flat.substring(0, 200)}...' : flat;
}

String _redact(String text, String? secret) =>
    secret == null || secret.isEmpty ? text : text.replaceAll(secret, '[key]');
