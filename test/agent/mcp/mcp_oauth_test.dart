import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/loopback_server.dart';
import 'package:focus_launcher/agent/auth/pkce.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/mcp/mcp_oauth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../auth/test_support.dart';

const _mcpUrl = 'https://mcp.example.com/mcp';
const _protectedMeta = 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp';
const _bareProtectedMeta = 'https://mcp.example.com/.well-known/oauth-protected-resource';
const _issuer = 'https://auth.example.com';
const _rfc8414 = 'https://auth.example.com/.well-known/oauth-authorization-server';
const _oidc = 'https://auth.example.com/.well-known/openid-configuration';
const _registerUrl = 'https://auth.example.com/register';
const _tokenUrl = 'https://auth.example.com/token';
const _revokeUrl = 'https://auth.example.com/revoke';

const _authServerJson = {
  'issuer': _issuer,
  'authorization_endpoint': 'https://auth.example.com/authorize',
  'token_endpoint': _tokenUrl,
  'registration_endpoint': _registerUrl,
  'revocation_endpoint': _revokeUrl,
};

final _server = McpAuthServerMetadata(
  authorizationEndpoint: Uri.parse('https://auth.example.com/authorize?tenant=acme'),
  tokenEndpoint: Uri.parse(_tokenUrl),
);

typedef _Route = http.Response Function(http.Request request);

/// Answers by full URL. Anything without a route is a 404. Every request is recorded in [seen].
http.Client _http(Map<String, _Route> routes, [List<http.Request>? seen]) =>
    MockClient((request) async {
      seen?.add(request);
      final route = routes[request.url.toString()];
      return route == null ? http.Response('not found', 404) : route(request);
    });

/// A server that asks for browser sign-in through resource metadata, with a working auth server.
Map<String, _Route> _discoveryRoutes({Map<String, _Route> extra = const {}}) => {
      _mcpUrl: (_) => http.Response('', 401,
          headers: {'www-authenticate': 'Bearer resource_metadata="$_protectedMeta"'}),
      _protectedMeta: (_) => jsonReply({
            'resource': _mcpUrl,
            'authorization_servers': [_issuer],
            'scopes_supported': ['mcp.read'],
          }),
      _rfc8414: (_) => jsonReply(_authServerJson),
      ...extra,
    };

McpOAuth _oauth(http.Client client, {Future<bool> Function(Uri url)? openBrowser}) =>
    McpOAuth(httpClient: client, openBrowser: openBrowser ?? (_) async => false);

McpOAuthRecord _record({
  String? refresh = 'rt-old',
  DateTime? expiresAt,
  bool withRevocation = true,
}) =>
    McpOAuthRecord(
      clientId: 'client-1',
      tokenEndpoint: Uri.parse(_tokenUrl),
      revocationEndpoint: withRevocation ? Uri.parse(_revokeUrl) : null,
      resource: _mcpUrl,
      accessToken: 'at-old',
      refreshToken: refresh,
      expiresAt: expiresAt,
    );

Map<String, _Route> _registerRoute() => {
      _registerUrl: (_) => jsonReply({'client_id': 'client-1'}, status: 201),
    };

void main() {
  group('decideProbe', () {
    test('a 2xx answer needs no sign-in', () {
      expect(decideProbe(status: 200, oauthDiscovered: false), McpProbeOutcome.noAuth);
      expect(decideProbe(status: 204, oauthDiscovered: true), McpProbeOutcome.noAuth);
    });

    test('a 401 with discovered OAuth offers browser sign-in', () {
      expect(decideProbe(status: 401, oauthDiscovered: true), McpProbeOutcome.oauth);
    });

    test('a 401 without discovered OAuth asks the person', () {
      expect(decideProbe(status: 401, oauthDiscovered: false), McpProbeOutcome.askUser);
    });

    test('any other status asks the person, even when OAuth was discovered', () {
      expect(decideProbe(status: 500, oauthDiscovered: true), McpProbeOutcome.askUser);
      expect(decideProbe(status: 403, oauthDiscovered: false), McpProbeOutcome.askUser);
    });
  });

  group('probe', () {
    test('reports noAuth for a server that answers without sign-in', () async {
      final oauth = _oauth(_http({
        _mcpUrl: (_) => jsonReply({'jsonrpc': '2.0', 'id': 1, 'result': {}}),
      }));

      final probe = await oauth.probe(Uri.parse(_mcpUrl));

      expect(probe.outcome, McpProbeOutcome.noAuth);
      expect(probe.discovery, isNull);
    });

    test('offers browser sign-in when a 401 points at resource metadata', () async {
      final oauth = _oauth(_http(_discoveryRoutes()));

      final probe = await oauth.probe(Uri.parse(_mcpUrl));

      expect(probe.outcome, McpProbeOutcome.oauth);
      expect(probe.discovery!.resource, _mcpUrl);
      expect(probe.discovery!.server.tokenEndpoint, Uri.parse(_tokenUrl));
    });

    test('asks the person in plain words when a 401 describes no sign-in', () async {
      final oauth = _oauth(_http({
        _mcpUrl: (_) => http.Response('', 401),
      }));

      final probe = await oauth.probe(Uri.parse(_mcpUrl));

      expect(probe.outcome, McpProbeOutcome.askUser);
      expect(probe.message, isNotEmpty);
      expect(probe.discovery, isNull);
    });

    test('asks the person for any other status', () async {
      final oauth = _oauth(_http({
        _mcpUrl: (_) => http.Response('', 500),
      }));

      final probe = await oauth.probe(Uri.parse(_mcpUrl));

      expect(probe.outcome, McpProbeOutcome.askUser);
      expect(probe.message, contains('500'));
    });
  });

  group('discovery', () {
    test('Simular Box: path-suffixed resource metadata, scope from the challenge, dynamic registration', () async {
      const mcp = 'https://mcp.box.simular.ai/mcp';
      const meta = 'https://mcp.box.simular.ai/.well-known/oauth-protected-resource/mcp';
      final oauth = _oauth(_http({
        // The bare well-known path answers 404 on this server; only the path-suffixed one works.
        meta: (_) => jsonReply({
              'authorization_servers': ['https://mcp.box.simular.ai'],
              'bearer_methods_supported': ['header'],
              'resource': mcp,
              'resource_name': 'box',
              'scopes_supported': ['boxes', 'connect'],
            }),
        'https://mcp.box.simular.ai/.well-known/oauth-authorization-server': (_) => jsonReply({
              'issuer': 'https://mcp.box.simular.ai',
              'authorization_endpoint': 'https://mcp.box.simular.ai/cb/oauth/authorize',
              'token_endpoint': 'https://mcp.box.simular.ai/oauth/token',
              'registration_endpoint': 'https://mcp.box.simular.ai/oauth/register',
              'revocation_endpoint': 'https://mcp.box.simular.ai/oauth/revoke',
              'code_challenge_methods_supported': ['S256'],
              'token_endpoint_auth_methods_supported': ['none', 'private_key_jwt'],
              'scopes_supported': ['boxes', 'connect', 'openid', 'email'],
            }),
      }));

      final discovery = await oauth.discover(
        Uri.parse(mcp),
        challenge: 'Bearer resource_metadata="$meta", scope="boxes connect"',
      );

      expect(discovery.resource, mcp);
      expect(discovery.scope, 'boxes connect');
      expect(discovery.server.authorizationEndpoint.path, '/cb/oauth/authorize');
      expect(discovery.server.tokenEndpoint.path, '/oauth/token');
      expect(discovery.server.registrationEndpoint, Uri.parse('https://mcp.box.simular.ai/oauth/register'));
    });

    test('reads the challenge and the metadata it points to', () async {
      final oauth = _oauth(_http(_discoveryRoutes()));

      final discovery = await oauth.discover(
        Uri.parse(_mcpUrl),
        challenge: 'Bearer resource_metadata="$_protectedMeta", scope="mcp.write"',
      );

      expect(discovery.resource, _mcpUrl);
      expect(discovery.server.authorizationEndpoint.path, '/authorize');
      expect(discovery.server.tokenEndpoint, Uri.parse(_tokenUrl));
      expect(discovery.server.registrationEndpoint, Uri.parse(_registerUrl));
      expect(discovery.scope, 'mcp.write');
    });

    test('takes the scope from the metadata when the challenge names none', () async {
      final oauth = _oauth(_http(_discoveryRoutes()));

      final discovery = await oauth.discover(Uri.parse(_mcpUrl));

      expect(discovery.scope, 'mcp.read');
    });

    test('falls back to the bare well-known path when the path-suffixed one is missing', () async {
      final seen = <http.Request>[];
      final oauth = _oauth(_http({
        _mcpUrl: (_) => http.Response('', 401),
        _bareProtectedMeta: (_) => jsonReply({
              'resource': _mcpUrl,
              'authorization_servers': [_issuer],
            }),
        _rfc8414: (_) => jsonReply(_authServerJson),
      }, seen));

      final discovery = await oauth.discover(Uri.parse(_mcpUrl));

      expect(discovery.server.tokenEndpoint, Uri.parse(_tokenUrl));
      final urls = seen.map((r) => r.url.toString());
      expect(urls, contains(_bareProtectedMeta));
    });

    test('tries the path-suffixed well-known path first', () async {
      final seen = <http.Request>[];
      final oauth = _oauth(_http({
        _mcpUrl: (_) => http.Response('', 401),
        _protectedMeta: (_) => jsonReply({
              'resource': _mcpUrl,
              'authorization_servers': [_issuer],
            }),
        _bareProtectedMeta: (_) => jsonReply({
              'resource': _mcpUrl,
              'authorization_servers': [_issuer],
            }),
        _rfc8414: (_) => jsonReply(_authServerJson),
      }, seen));

      await oauth.discover(Uri.parse(_mcpUrl));

      final urls = seen.map((r) => r.url.toString()).toList();
      expect(urls, contains(_protectedMeta));
      expect(urls, isNot(contains(_bareProtectedMeta)));
    });

    test('uses OIDC discovery when the OAuth authorization server metadata is missing', () async {
      final routes = _discoveryRoutes()..remove(_rfc8414);
      routes[_oidc] = (_) => jsonReply(_authServerJson);
      final oauth = _oauth(_http(routes));

      final discovery = await oauth.discover(
        Uri.parse(_mcpUrl),
        challenge: 'Bearer resource_metadata="$_protectedMeta"',
      );

      expect(discovery.server.tokenEndpoint, Uri.parse(_tokenUrl));
    });

    test('says plainly when the server does not describe how to sign in', () async {
      final oauth = _oauth(_http({
        _mcpUrl: (_) => http.Response('', 401),
        _protectedMeta: (_) => jsonReply({'resource': _mcpUrl}),
        _bareProtectedMeta: (_) => jsonReply({'resource': _mcpUrl}),
      }));

      await expectLater(
        oauth.discover(Uri.parse(_mcpUrl)),
        throwsA(isA<McpOAuthException>().having(
          (e) => e.message,
          'message',
          'This server does not describe how to sign in. Use a token instead.',
        )),
      );
    });

    test('refuses a server that does not ask for sign-in', () async {
      final oauth = _oauth(_http({
        _mcpUrl: (_) => jsonReply({'jsonrpc': '2.0', 'id': 1, 'result': {}}),
      }));

      await expectLater(
        oauth.discover(Uri.parse(_mcpUrl)),
        throwsA(isA<McpOAuthException>().having(
          (e) => e.message,
          'message',
          'This server does not ask for sign-in.',
        )),
      );
    });
  });

  group('authorizeUri', () {
    test('keeps the endpoint query and adds the PKCE, state and resource parameters', () {
      final uri = _oauth(_http({})).authorizeUri(
        server: _server,
        clientId: 'client-1',
        redirectUri: Uri.parse('http://127.0.0.1:4321/callback'),
        codeChallenge: 'challenge-1',
        state: 'state-1',
        resource: _mcpUrl,
        scope: 'mcp.read',
      );

      final q = uri.queryParameters;
      expect(uri.path, '/authorize');
      expect(q['tenant'], 'acme');
      expect(q['response_type'], 'code');
      expect(q['client_id'], 'client-1');
      expect(q['redirect_uri'], 'http://127.0.0.1:4321/callback');
      expect(q['state'], 'state-1');
      expect(q['code_challenge'], 'challenge-1');
      expect(q['code_challenge_method'], 'S256');
      expect(q['resource'], _mcpUrl);
      expect(q['scope'], 'mcp.read');
    });

    test('leaves scope out when none is named', () {
      final uri = _oauth(_http({})).authorizeUri(
        server: _server,
        clientId: 'client-1',
        redirectUri: Uri.parse('http://127.0.0.1:4321/callback'),
        codeChallenge: 'challenge-1',
        state: 'state-1',
        resource: _mcpUrl,
      );

      expect(uri.queryParameters.containsKey('scope'), isFalse);
    });

    test('leaves scope out when it is empty', () {
      final uri = _oauth(_http({})).authorizeUri(
        server: _server,
        clientId: 'client-1',
        redirectUri: Uri.parse('http://127.0.0.1:4321/callback'),
        codeChallenge: 'challenge-1',
        state: 'state-1',
        resource: _mcpUrl,
        scope: '',
      );

      expect(uri.queryParameters.containsKey('scope'), isFalse);
    });
  });

  group('signIn', () {
    test('registers, signs in with PKCE, and stores the session it receives', () async {
      final loopback = await LoopbackServer.start(path: '/callback');
      addTearDown(loopback.close);
      final seen = <http.Request>[];
      late Uri authorize;
      final oauth = _oauth(
        _http(
          _discoveryRoutes(extra: {
            ..._registerRoute(),
            _tokenUrl: (_) => jsonReply({
                  'access_token': 'at-1',
                  'refresh_token': 'rt-1',
                  'expires_in': 3600,
                  'token_type': 'Bearer',
                }),
          }),
          seen,
        ),
        openBrowser: (url) async {
          authorize = url;
          unawaited(followRedirect(
            Uri.parse(url.queryParameters['redirect_uri']!),
            {'code': 'code-1', 'state': url.queryParameters['state']!},
          ));
          return true;
        },
      );

      final record = await oauth.signIn(mcpUrl: Uri.parse(_mcpUrl), loopback: loopback);

      final registration = jsonDecode(
        seen.singleWhere((r) => r.url.toString() == _registerUrl).body,
      ) as Map<String, dynamic>;
      expect(registration['client_name'], 'Flute');
      expect(registration['redirect_uris'], [loopback.redirectUri().toString()]);
      expect(registration['token_endpoint_auth_method'], 'none');
      expect(registration['grant_types'], containsAll(['authorization_code', 'refresh_token']));
      expect(registration['response_types'], ['code']);

      final q = authorize.queryParameters;
      expect(q['client_id'], 'client-1');
      expect(q['code_challenge_method'], 'S256');
      expect(q['resource'], _mcpUrl);
      expect(q['redirect_uri'], loopback.redirectUri().toString());
      expect(q['scope'], 'mcp.read');

      final form = Uri.splitQueryString(
        seen.singleWhere((r) => r.url.toString() == _tokenUrl).body,
      );
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'code-1');
      expect(form['client_id'], 'client-1');
      expect(form['redirect_uri'], loopback.redirectUri().toString());
      expect(form['resource'], _mcpUrl);
      expect(Pkce.challengeFor(form['code_verifier']!), q['code_challenge']);

      expect(record.clientId, 'client-1');
      expect(record.accessToken, 'at-1');
      expect(record.refreshToken, 'rt-1');
      expect(record.resource, _mcpUrl);
      expect(record.tokenEndpoint, Uri.parse(_tokenUrl));
      expect(record.isFresh(DateTime.now()), isTrue);
    });

    test('refuses a callback whose state does not match the request', () async {
      final loopback = await LoopbackServer.start(path: '/callback');
      addTearDown(loopback.close);
      final oauth = _oauth(
        _http(_discoveryRoutes(extra: _registerRoute())),
        openBrowser: (url) async {
          unawaited(followRedirect(
            Uri.parse(url.queryParameters['redirect_uri']!),
            {'code': 'code-1', 'state': 'not-the-state'},
          ));
          return true;
        },
      );

      await expectLater(
        oauth.signIn(mcpUrl: Uri.parse(_mcpUrl), loopback: loopback),
        throwsA(isA<McpOAuthException>().having(
          (e) => e.message,
          'message',
          'Sign-in could not be checked. Try again.',
        )),
      );
    });

    test('says so when the browser cannot be opened', () async {
      final loopback = await LoopbackServer.start(path: '/callback');
      addTearDown(loopback.close);
      final oauth = _oauth(
        _http(_discoveryRoutes(extra: _registerRoute())),
        openBrowser: (_) async => false,
      );

      await expectLater(
        oauth.signIn(mcpUrl: Uri.parse(_mcpUrl), loopback: loopback),
        throwsA(isA<McpOAuthException>().having(
          (e) => e.message,
          'message',
          'Could not open the browser. Check that a browser is installed.',
        )),
      );
    });

    test('says so when the server refuses the code', () async {
      final loopback = await LoopbackServer.start(path: '/callback');
      addTearDown(loopback.close);
      final oauth = _oauth(
        _http(_discoveryRoutes(extra: {
          ..._registerRoute(),
          _tokenUrl: (_) => jsonReply({'error': 'invalid_grant'}, status: 400),
        })),
        openBrowser: (url) async {
          unawaited(followRedirect(
            Uri.parse(url.queryParameters['redirect_uri']!),
            {'code': 'stale-code', 'state': url.queryParameters['state']!},
          ));
          return true;
        },
      );

      await expectLater(
        oauth.signIn(mcpUrl: Uri.parse(_mcpUrl), loopback: loopback),
        throwsA(isA<McpOAuthException>().having(
          (e) => e.message,
          'message',
          'The server refused the sign-in. Try signing in again.',
        )),
      );
    });
  });

  group('refresh', () {
    test('rotates both tokens when the server returns new ones', () async {
      final seen = <http.Request>[];
      final oauth = _oauth(_http({
        _tokenUrl: (_) => jsonReply({
              'access_token': 'at-2',
              'refresh_token': 'rt-2',
              'expires_in': 3600,
            }),
      }, seen));

      final next = await oauth.refresh(_record());

      expect(next.accessToken, 'at-2');
      expect(next.refreshToken, 'rt-2');
      expect(next.clientId, 'client-1');
      expect(next.resource, _mcpUrl);
      expect(next.revocationEndpoint, Uri.parse(_revokeUrl));

      final form = Uri.splitQueryString(seen.single.body);
      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], 'rt-old');
      expect(form['client_id'], 'client-1');
      expect(form['resource'], _mcpUrl);
    });

    test('keeps the old refresh token when the server does not rotate it', () async {
      final oauth = _oauth(_http({
        _tokenUrl: (_) => jsonReply({'access_token': 'at-2', 'expires_in': 3600}),
      }));

      final next = await oauth.refresh(_record());

      expect(next.accessToken, 'at-2');
      expect(next.refreshToken, 'rt-old');
    });

    test('asks the person to sign in again when the server refuses the refresh token', () async {
      final oauth = _oauth(_http({
        _tokenUrl: (_) => jsonReply({'error': 'invalid_grant'}, status: 400),
      }));

      await expectLater(
        oauth.refresh(_record()),
        throwsA(isA<McpOAuthException>().having((e) => e.requiresSignIn, 'requiresSignIn', isTrue)),
      );
    });

    test('asks the person to sign in again without calling the server when no refresh token is held',
        () async {
      final seen = <http.Request>[];
      final oauth = _oauth(_http({}, seen));

      await expectLater(
        oauth.refresh(_record(refresh: null)),
        throwsA(isA<McpOAuthException>()
            .having((e) => e.requiresSignIn, 'requiresSignIn', isTrue)
            .having((e) => e.message, 'message', 'Your sign-in expired. Sign in again.')),
      );
      expect(seen, isEmpty);
    });
  });

  group('revoke', () {
    test('does nothing when the server names no revocation endpoint', () async {
      final seen = <http.Request>[];
      final oauth = _oauth(_http({}, seen));

      await oauth.revoke(_record(withRevocation: false));

      expect(seen, isEmpty);
    });

    test('posts to the revocation endpoint', () async {
      final seen = <http.Request>[];
      final oauth = _oauth(_http({
        _revokeUrl: (_) => http.Response('', 200),
      }, seen));

      await oauth.revoke(_record());

      expect(seen, hasLength(1));
      expect(seen.single.method, 'POST');
      expect(seen.single.url.toString(), _revokeUrl);
    });

    test('is best effort: a server error or a dropped connection is not thrown', () async {
      final oauth = _oauth(_http({
        _revokeUrl: (_) => http.Response('', 500),
      }));
      await oauth.revoke(_record());

      final offline = _oauth(_http({
        _revokeUrl: (_) => throw http.ClientException('offline'),
      }));
      await offline.revoke(_record());
    });
  });

  group('McpOAuthRecord', () {
    test('survives a JSON round trip through the secret store', () async {
      final store = MemorySecretStore();
      final record = _record(expiresAt: DateTime.utc(2030, 1, 1));

      await store.write('agent.mcp.oauth.github', jsonEncode(record.toJson()));
      final stored = await store.read('agent.mcp.oauth.github');
      final back = McpOAuthRecord.fromJson(jsonDecode(stored!) as Map<String, dynamic>);

      expect(back.clientId, 'client-1');
      expect(back.tokenEndpoint, Uri.parse(_tokenUrl));
      expect(back.revocationEndpoint, Uri.parse(_revokeUrl));
      expect(back.resource, _mcpUrl);
      expect(back.accessToken, 'at-old');
      expect(back.refreshToken, 'rt-old');
      expect(back.expiresAt, DateTime.utc(2030, 1, 1));

      await store.delete('agent.mcp.oauth.github');
      expect(await store.read('agent.mcp.oauth.github'), isNull);
    });

    test('a session without an expiry is always fresh', () {
      expect(_record().isFresh(DateTime.now()), isTrue);
    });

    test('a token expiring within a minute is not fresh', () {
      final now = DateTime.now().toUtc();
      expect(_record(expiresAt: now.add(const Duration(seconds: 30))).isFresh(now), isFalse);
    });

    test('a token that lasts well beyond a minute is fresh', () {
      final now = DateTime.now().toUtc();
      expect(_record(expiresAt: now.add(const Duration(minutes: 10))).isFresh(now), isTrue);
    });
  });
}
