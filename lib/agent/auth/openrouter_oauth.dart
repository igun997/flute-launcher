import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../llm/llm_types.dart';
import 'loopback_server.dart';
import 'pkce.dart';

/// OpenRouter's PKCE sign-in, per https://openrouter.ai/docs/guides/overview/auth/oauth. The browser
/// returns a one-time code to a loopback listener; the code and verifier exchange for an API key.
class OpenRouterOAuth {
  OpenRouterOAuth({
    required http.Client httpClient,
    required Future<bool> Function(Uri url) openBrowser,
  })  : _http = httpClient,
        _openBrowser = openBrowser;

  final http.Client _http;
  final Future<bool> Function(Uri url) _openBrowser;

  static final _keysEndpoint = Uri.https('openrouter.ai', '/api/v1/auth/keys');
  static const _requestTimeout = Duration(seconds: 30);
  static const _unreachable =
      LlmException('Cannot reach OpenRouter. Check your connection.');

  /// [loopback] must be listening on path `/callback`; the redirect uses `localhost`.
  Uri authorizeUri({
    required String callbackUrl,
    required String codeChallenge,
    required String state,
    String keyLabel = 'Flute',
  }) {
    return Uri.https('openrouter.ai', '/auth', {
      'callback_url': callbackUrl,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'state': state,
      'key_label': keyLabel,
    });
  }

  /// Runs the browser flow and returns the new API key.
  Future<String> signIn({
    required LoopbackServer loopback,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final pkce = Pkce.generate();
    final state = Pkce.randomUrlSafe();
    final url = authorizeUri(
      callbackUrl: loopback.redirectUri(host: 'localhost').toString(),
      codeChallenge: pkce.challenge,
      state: state,
    );
    if (!await _openBrowser(url)) {
      throw const LlmException('Could not open the browser for OpenRouter sign-in.');
    }
    final query = await loopback.waitForCallback(timeout: timeout);
    final code = query['code'];
    if (code == null || code.isEmpty) {
      throw const LlmException('OpenRouter sign-in was not completed.');
    }
    if (query['state'] != state) {
      throw const LlmException('The OpenRouter sign-in did not match this request. Try again.');
    }
    return _exchange(code: code, verifier: pkce.verifier);
  }

  Future<String> _exchange({required String code, required String verifier}) async {
    final response = await _send(() => _http.post(
          _keysEndpoint,
          headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
          body: jsonEncode({
            'code': code,
            'code_verifier': verifier,
            'code_challenge_method': 'S256',
          }),
        ));
    if (response.statusCode != 200) {
      final message = switch (response.statusCode) {
        403 => 'OpenRouter did not accept the sign-in. The code may have expired; try again.',
        400 => 'OpenRouter rejected the sign-in request. Try again.',
        _ => 'OpenRouter sign-in failed (HTTP ${response.statusCode}).',
      };
      throw LlmException(message, statusCode: response.statusCode);
    }
    final key = _jsonKey(response);
    if (key == null || key.isEmpty) {
      throw const LlmException('OpenRouter did not return a key. Try again.');
    }
    return key;
  }

  String? _jsonKey(http.Response response) {
    try {
      final value = jsonDecode(response.body);
      if (value is Map && value['key'] is String) return value['key'] as String;
    } on FormatException {
      // Reported by the caller.
    }
    return null;
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_requestTimeout);
    } on SocketException {
      throw _unreachable;
    } on TimeoutException {
      throw _unreachable;
    } on http.ClientException {
      throw _unreachable;
    }
  }
}
