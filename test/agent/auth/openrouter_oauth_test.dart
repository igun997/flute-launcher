import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/loopback_server.dart';
import 'package:focus_launcher/agent/auth/openrouter_oauth.dart';
import 'package:focus_launcher/agent/auth/pkce.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'test_support.dart';

void main() {
  test('the authorize URL carries PKCE, the callback and a key label', () {
    final oauth = OpenRouterOAuth(
      httpClient: MockClient((_) async => http.Response('', 500)),
      openBrowser: (_) async => true,
    );
    final uri = oauth.authorizeUri(
      callbackUrl: 'http://localhost:51423/callback',
      codeChallenge: 'ch',
      state: 'st',
    );
    expect(uri.host, 'openrouter.ai');
    expect(uri.path, '/auth');
    expect(uri.queryParameters, {
      'callback_url': 'http://localhost:51423/callback',
      'code_challenge': 'ch',
      'code_challenge_method': 'S256',
      'state': 'st',
      'key_label': 'Flute',
    });
  });

  test('the browser code and verifier exchange for a key', () async {
    final fake = FakeOpenAuth();
    final loopback = await LoopbackServer.start(path: '/callback');
    addTearDown(loopback.close);

    final key = await OpenRouterOAuth(httpClient: fake.client, openBrowser: fake.openBrowser)
        .signIn(loopback: loopback);

    expect(key, 'sk-or-test');
    final body = fake.openRouterBodies.single;
    expect(body['code'], 'code-1');
    expect(body['code_challenge_method'], 'S256');
    expect(Pkce.challengeFor(body['code_verifier'] as String),
        fake.authorizeUrls.single.queryParameters['code_challenge']);
    expect(fake.authorizeUrls.single.queryParameters['callback_url'],
        loopback.redirectUri(host: 'localhost').toString());
  });

  test('an expired code is refused with its status and no key is returned', () async {
    final fake = FakeOpenAuth()
      ..onOpenRouterKeys = (_) => http.Response('{"error":"expired"}', 403);
    final loopback = await LoopbackServer.start(path: '/callback');
    addTearDown(loopback.close);

    await expectLater(
      OpenRouterOAuth(httpClient: fake.client, openBrowser: fake.openBrowser)
          .signIn(loopback: loopback),
      throwsA(isA<LlmException>()
          .having((e) => e.statusCode, 'statusCode', 403)
          .having((e) => e.message, 'message', contains('expired'))),
    );
  });
}
