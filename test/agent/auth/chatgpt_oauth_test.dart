import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/chatgpt_oauth.dart';
import 'package:focus_launcher/agent/auth/loopback_server.dart';
import 'package:focus_launcher/agent/auth/pkce.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'test_support.dart';

const _host = 'urn:uuid:6f1c1a0e-2b8e-4d6a-9c55-0f0e1d2c3b4a';

ChatGptOAuth _oauth(FakeOpenAuth fake) =>
    ChatGptOAuth(httpClient: fake.client, openBrowser: fake.openBrowser);

ChatGptSession _session({Duration expiresIn = const Duration(minutes: 30)}) => ChatGptSession(
      clientId: 'oaiapp_test',
      subject: 'user-123',
      email: 'user@example.com',
      idToken: 'id.tok.en',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      scopes: const [ChatGptOAuth.planScope],
      expiresAt: DateTime.now().toUtc().add(expiresIn),
    );

void main() {
  group('authorize URL', () {
    final oauth = ChatGptOAuth(
      httpClient: MockClient((_) async => http.Response('', 500)),
      openBrowser: (_) async => true,
    );

    test('a new registration carries every required parameter', () {
      final uri = oauth.authorizeUri(
        clientId: ChatGptOAuth.dynamicClientId,
        hostId: _host,
        redirectUri: 'http://127.0.0.1:1455/auth/callback',
        state: 'st',
        nonce: 'no',
        codeChallenge: 'ch',
        appName: ChatGptOAuth.appName,
      );
      expect(uri.scheme, 'https');
      expect(uri.host, 'auth.openai.com');
      expect(uri.path, '/api/accounts/authorize');
      expect(uri.queryParameters, {
        'client_id': 'dynamic_agent_client',
        'agent_name_hint': 'Flute',
        'ext_agent_host_id': _host,
        'response_type': 'code',
        'redirect_uri': 'http://127.0.0.1:1455/auth/callback',
        'scope': 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
        'resource': 'https://api.openai.com/v1',
        'state': 'st',
        'nonce': 'no',
        'code_challenge_method': 'S256',
        'code_challenge': 'ch',
      });
    });

    test('reauthorisation uses the issued client and the hints, without the app name', () {
      final uri = oauth.authorizeUri(
        clientId: 'oaiapp_saved',
        hostId: _host,
        redirectUri: 'http://127.0.0.1:54321/auth/callback',
        state: 's',
        nonce: 'n',
        codeChallenge: 'c',
        idTokenHint: 'id.tok.en',
        loginHint: 'user@example.com',
      );
      expect(uri.queryParameters['client_id'], 'oaiapp_saved');
      expect(uri.queryParameters['id_token_hint'], 'id.tok.en');
      expect(uri.queryParameters['login_hint'], 'user@example.com');
      expect(uri.queryParameters.containsKey('agent_name_hint'), isFalse);
    });
  });

  group('sign-in', () {
    test('exchanges the code with PKCE and returns the verified session', () async {
      final fake = FakeOpenAuth();
      final loopback = await LoopbackServer.start(path: '/auth/callback');
      addTearDown(loopback.close);

      final session = await _oauth(fake).signIn(hostId: _host, loopback: loopback);

      expect(session.clientId, 'oaiapp_test');
      expect(session.subject, 'user-123');
      expect(session.email, 'user@example.com');
      expect(session.hasTokens, isTrue);
      expect(session.scopes, contains(ChatGptOAuth.planScope));

      final authorize = fake.authorizeUrls.single.queryParameters;
      final form = fake.tokenForms.single;
      expect(form['grant_type'], 'authorization_code');
      expect(form['client_id'], 'oaiapp_test');
      expect(form['redirect_uri'], loopback.redirectUri().toString());
      expect(form['resource'], ChatGptOAuth.resource);
      expect(Pkce.challengeFor(form['code_verifier']!), authorize['code_challenge']);
      expect(form.containsKey('client_secret'), isFalse);
    });

    test('a callback with another state is refused before any code is exchanged', () async {
      final fake = FakeOpenAuth()
        ..callbackFor = (_) => {'code': 'stolen', 'state': 'forged', 'client_id': 'oaiapp_test'};
      final loopback = await LoopbackServer.start(path: '/auth/callback');
      addTearDown(loopback.close);

      await expectLater(
        _oauth(fake).signIn(hostId: _host, loopback: loopback),
        throwsA(isA<LlmException>()),
      );
      expect(fake.tokenForms, isEmpty);
    });

    test('declining plan use stops the attempt with a message', () async {
      final fake = FakeOpenAuth()
        ..callbackFor = (url) => {
              'error': 'access_denied',
              'state': url.queryParameters['state']!,
            };
      final loopback = await LoopbackServer.start(path: '/auth/callback');
      addTearDown(loopback.close);

      await expectLater(
        _oauth(fake).signIn(hostId: _host, loopback: loopback),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', contains('declined'))),
      );
      expect(fake.tokenForms, isEmpty);
    });

    test('a grant without chatgpt.tokens.use.direct is refused', () async {
      final fake = FakeOpenAuth(grantedScope: 'openid profile email offline_access');
      final loopback = await LoopbackServer.start(path: '/auth/callback');
      addTearDown(loopback.close);

      await expectLater(
        _oauth(fake).signIn(hostId: _host, loopback: loopback),
        throwsA(isA<LlmException>()
            .having((e) => e.message, 'message', startsWith('ChatGPT plan use was not allowed'))),
      );
    });
  });

  group('refresh', () {
    test('rotates the access and refresh tokens together and keeps the registration', () async {
      final fake = FakeOpenAuth();
      final renewed = await _oauth(fake).refresh(_session(expiresIn: const Duration(minutes: 1)));

      final form = fake.tokenForms.single;
      expect(form['grant_type'], 'refresh_token');
      expect(form['client_id'], 'oaiapp_test');
      expect(form['refresh_token'], 'refresh-1');
      expect(form['resource'], ChatGptOAuth.resource);
      expect(form.containsKey('scope'), isFalse);

      expect(renewed.accessToken, 'access-2');
      expect(renewed.refreshToken, 'refresh-2');
      expect(renewed.clientId, 'oaiapp_test');
      expect(renewed.email, 'user@example.com');
      expect(renewed.expiresAt!.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 50))),
          isTrue);
    });

    test('a revoked refresh token is reported as a 401 with its code', () async {
      final fake = FakeOpenAuth()
        ..onRefresh = (_) => jsonReply({'error': 'refresh_token_reused'}, status: 400);

      await expectLater(
        _oauth(fake).refresh(_session()),
        throwsA(isA<LlmException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.code, 'code', 'refresh_token_reused')),
      );
    });

    test('a network failure is not reported as a revoked session', () async {
      final oauth = ChatGptOAuth(
        httpClient: MockClient((_) async => throw const SocketException('offline')),
        openBrowser: (_) async => true,
      );

      await expectLater(
        oauth.refresh(_session()),
        throwsA(isA<LlmException>().having((e) => e.code, 'code', isNull)),
      );
    });
  });
}
