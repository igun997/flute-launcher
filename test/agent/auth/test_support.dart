import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Plays the browser's redirect to a loopback listener. A raw socket is used because flutter_test
/// replaces HttpClient with one that refuses requests.
Future<void> followRedirect(Uri redirect, Map<String, String> query) async {
  final uri = redirect.replace(queryParameters: query);
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, uri.port);
  socket.write('GET ${uri.path}?${uri.query} HTTP/1.1\r\n'
      'Host: ${uri.host}:${uri.port}\r\nConnection: close\r\n\r\n');
  await socket.flush();
  await socket.drain<void>();
  socket.destroy();
}

/// An unsigned ID token with the claims the sign-in checks.
String idTokenFor({
  required String clientId,
  required String nonce,
  String subject = 'user-123',
  String email = 'user@example.com',
}) {
  String segment(Map<String, Object> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final exp = DateTime.now().toUtc().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  final claims = <String, Object>{
    'iss': 'https://auth.openai.com',
    'aud': clientId,
    'sub': subject,
    'email': email,
    'nonce': nonce,
    'exp': exp,
  };
  return '${segment({'alg': 'none'})}.${segment(claims)}.unsigned';
}

http.Response jsonReply(Map<String, Object?> body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Plays OpenAI's auth server and OpenRouter, and the browser between them. `openBrowser` records the
/// authorize URL and redirects back to the loopback listener; the token endpoints answer as OpenAI
/// would for a clean sign-in unless a test overrides them.
class FakeOpenAuth {
  FakeOpenAuth({
    this.issuedClientId = 'oaiapp_test',
    this.subject = 'user-123',
    this.email = 'user@example.com',
    this.grantedScope =
        'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
  });

  final String issuedClientId;
  String subject;
  final String email;
  final String grantedScope;

  final List<Uri> authorizeUrls = [];
  final List<Map<String, String>> tokenForms = [];
  final List<Map<String, String>> revokeForms = [];
  final List<Map<String, dynamic>> openRouterBodies = [];

  /// Answers refresh requests. The default rotates both tokens.
  http.Response Function(Map<String, String> form)? onRefresh;

  /// Answers OpenRouter key exchanges. The default returns a key.
  http.Response Function(Map<String, dynamic> body)? onOpenRouterKeys;

  /// The query the browser sends back. The default carries the code and the request's state.
  Map<String, String> Function(Uri authorize)? callbackFor;

  late final http.Client client = MockClient(_route);

  Future<bool> openBrowser(Uri url) async {
    authorizeUrls.add(url);
    final redirect = Uri.parse(
        url.queryParameters['redirect_uri'] ?? url.queryParameters['callback_url']!);
    final query = callbackFor?.call(url) ??
        {
          'code': 'code-${authorizeUrls.length}',
          'state': url.queryParameters['state']!,
          'client_id': issuedClientId,
        };
    unawaited(followRedirect(redirect, query));
    return true;
  }

  Future<http.Response> _route(http.Request request) async {
    final path = request.url.path;
    if (request.url.host == 'openrouter.ai' && path == '/api/v1/auth/keys') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      openRouterBodies.add(body);
      return onOpenRouterKeys?.call(body) ?? jsonReply({'key': 'sk-or-test'});
    }
    if (path == '/api/accounts/oauth/token') {
      final form = Uri.splitQueryString(request.body);
      tokenForms.add(form);
      if (form['grant_type'] == 'refresh_token') {
        return onRefresh?.call(form) ??
            jsonReply({
              'access_token': 'access-2',
              'refresh_token': 'refresh-2',
              'token_type': 'Bearer',
              'expires_in': 3600,
              'scope': grantedScope,
            });
      }
      final authorize = authorizeUrls.last;
      return jsonReply({
        'access_token': 'access-1',
        'refresh_token': 'refresh-1',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'scope': grantedScope,
        'id_token': idTokenFor(
          clientId: issuedClientId,
          nonce: authorize.queryParameters['nonce']!,
          subject: subject,
          email: email,
        ),
      });
    }
    if (path == '/.well-known/openid-configuration') {
      return jsonReply({'revocation_endpoint': 'https://auth.openai.com/api/accounts/revoke'});
    }
    if (path == '/api/accounts/revoke') {
      revokeForms.add(Uri.splitQueryString(request.body));
      return http.Response('', 200);
    }
    return http.Response('not found', 404);
  }
}
