import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../auth/loopback_server.dart';
import '../auth/pkce.dart';
import 'mcp_server_config.dart';

/// A sign-in or token problem the person can act on. [requiresSignIn] means the saved session
/// can no longer be used and the person must sign in again.
class McpOAuthException implements Exception {
  const McpOAuthException(this.message, {this.requiresSignIn = false});

  final String message;
  final bool requiresSignIn;

  @override
  String toString() => message;
}

/// The OAuth session of one server. It is stored only in the SecretStore, never in prefs or logs.
class McpOAuthRecord {
  const McpOAuthRecord({
    required this.clientId,
    required this.tokenEndpoint,
    required this.resource,
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.revocationEndpoint,
  });

  final String clientId;
  final Uri tokenEndpoint;
  final Uri? revocationEndpoint;
  final String resource;
  final String accessToken;
  final String? refreshToken;

  /// Null when the server did not say how long the access token lasts.
  final DateTime? expiresAt;

  /// True while the access token can still be used without refreshing it first.
  bool isFresh(DateTime now) {
    final expiry = expiresAt;
    return expiry == null || now.add(const Duration(seconds: 60)).isBefore(expiry);
  }

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'tokenEndpoint': tokenEndpoint.toString(),
        if (revocationEndpoint != null) 'revocationEndpoint': revocationEndpoint.toString(),
        'resource': resource,
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
      };

  factory McpOAuthRecord.fromJson(Map<String, dynamic> j) {
    final revocation = j['revocationEndpoint'] as String?;
    final expiry = j['expiresAt'] as String?;
    return McpOAuthRecord(
      clientId: j['clientId'] as String,
      tokenEndpoint: Uri.parse(j['tokenEndpoint'] as String),
      revocationEndpoint: revocation == null ? null : Uri.parse(revocation),
      resource: j['resource'] as String,
      accessToken: j['accessToken'] as String,
      refreshToken: j['refreshToken'] as String?,
      expiresAt: expiry == null ? null : DateTime.parse(expiry),
    );
  }
}

/// The endpoints of the authorization server that guards an MCP server.
class McpAuthServerMetadata {
  const McpAuthServerMetadata({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.registrationEndpoint,
    this.revocationEndpoint,
  });

  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri? registrationEndpoint;
  final Uri? revocationEndpoint;
}

/// What discovery learned from a 401 challenge and the metadata it points to.
class McpOAuthDiscovery {
  const McpOAuthDiscovery({required this.resource, required this.server, this.scope});

  /// The MCP endpoint as sent in the `resource` parameter (RFC 8707).
  final String resource;
  final McpAuthServerMetadata server;

  /// Space-separated scopes to request, or null when the server names none.
  final String? scope;
}

enum McpProbeOutcome { noAuth, oauth, askUser }

/// The answer of probing a server before it is saved.
class McpProbe {
  const McpProbe.noAuth()
      : outcome = McpProbeOutcome.noAuth,
        message = null,
        discovery = null;

  const McpProbe.oauth(McpOAuthDiscovery this.discovery)
      : outcome = McpProbeOutcome.oauth,
        message = null;

  /// [message] explains in plain words why browser sign-in is not offered.
  const McpProbe.askUser(String this.message)
      : outcome = McpProbeOutcome.askUser,
        discovery = null;

  final McpProbeOutcome outcome;
  final String? message;
  final McpOAuthDiscovery? discovery;
}

/// Maps the unauthenticated answer of a server, and whether OAuth discovery worked, to the add flow.
McpProbeOutcome decideProbe({required int status, required bool oauthDiscovered}) {
  if (status >= 200 && status < 300) return McpProbeOutcome.noAuth;
  if (status == 401 && oauthDiscovered) return McpProbeOutcome.oauth;
  return McpProbeOutcome.askUser;
}

/// OAuth 2.1 for remote MCP servers: discovery (RFC 9728 and RFC 8414), dynamic registration
/// (RFC 7591), PKCE authorization, and token exchange and refresh.
class McpOAuth {
  McpOAuth({required http.Client httpClient, required Future<bool> Function(Uri url) openBrowser})
      : _http = httpClient,
        _openBrowser = openBrowser;

  final http.Client _http;
  final Future<bool> Function(Uri url) _openBrowser;

  static const _timeout = Duration(seconds: 30);
  static const _protocolVersion = '2025-06-18';
  static const _formHeaders = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'Accept': 'application/json',
  };
  static final _challengeParam = RegExp(r'([A-Za-z_]+)=(?:"([^"]*)"|([^,\s]*))');

  /// Sends an unauthenticated `initialize` and works out how the server wants to be signed in to.
  Future<McpProbe> probe(Uri mcpUrl) async {
    final response = await _initialize(mcpUrl);
    McpOAuthDiscovery? discovery;
    String? reason;
    if (response.statusCode == 401) {
      try {
        discovery = await discover(mcpUrl, challenge: response.headers['www-authenticate'] ?? '');
      } on McpOAuthException catch (e) {
        reason = e.message;
      }
    }
    switch (decideProbe(status: response.statusCode, oauthDiscovered: discovery != null)) {
      case McpProbeOutcome.noAuth:
        return const McpProbe.noAuth();
      case McpProbeOutcome.oauth:
        return McpProbe.oauth(discovery!);
      case McpProbeOutcome.askUser:
        return McpProbe.askUser(reason ??
            'The server answered with HTTP ${response.statusCode}. Check the address, or add it with a token.');
    }
  }

  /// Finds the authorization server of [mcpUrl]. [challenge] is the `WWW-Authenticate` header of its
  /// 401 answer; when omitted, the server is asked again without credentials.
  Future<McpOAuthDiscovery> discover(Uri mcpUrl, {String? challenge}) async {
    final header = challenge ?? await _unauthenticatedChallenge(mcpUrl);
    final params = _challengeParams(header);

    final resourceMetadata = params['resource_metadata'];
    final resourceUrls = [
      if (resourceMetadata != null && Uri.tryParse(resourceMetadata) != null)
        Uri.parse(resourceMetadata),
      ..._wellKnownCandidates(mcpUrl, 'oauth-protected-resource'),
    ];
    final resourceDoc = await _firstJson(resourceUrls);
    final servers = resourceDoc?['authorization_servers'];
    if (servers is! List || servers.isEmpty || servers.first is! String) {
      throw const McpOAuthException(
          'This server does not describe how to sign in. Use a token instead.');
    }
    final issuer = Uri.tryParse(servers.first as String);
    if (issuer == null || !issuer.hasScheme) {
      throw const McpOAuthException(
          'This server names a sign-in address that cannot be read. Use a token instead.');
    }
    final server = await _authServerMetadata(issuer);
    final scope = params['scope'] ?? _scopesOf(resourceDoc?['scopes_supported']);
    return McpOAuthDiscovery(resource: _canonical(mcpUrl), server: server, scope: scope);
  }

  /// Full browser sign-in. [loopback] receives the redirect; the caller owns and closes it.
  /// Throws [McpOAuthException] for problems the person can act on, [TimeoutException] when
  /// the browser never returns, and [StateError] when the listener is closed first.
  Future<McpOAuthRecord> signIn({required Uri mcpUrl, required LoopbackServer loopback}) async {
    final discovery = await discover(mcpUrl);
    final server = discovery.server;
    final redirect = loopback.redirectUri();
    final clientId = await _register(server, redirect);

    final pkce = Pkce.generate();
    final state = Pkce.randomUrlSafe();
    final authorize = authorizeUri(
      server: server,
      clientId: clientId,
      redirectUri: redirect,
      codeChallenge: pkce.challenge,
      state: state,
      resource: discovery.resource,
      scope: discovery.scope,
    );
    if (!await _openBrowser(authorize)) {
      throw const McpOAuthException('Could not open the browser. Check that a browser is installed.');
    }

    final query = await loopback.waitForCallback();
    final error = query['error'];
    if (error != null) {
      throw McpOAuthException('Sign-in was not completed (${_short(error)}).');
    }
    if (query['state'] != state) {
      throw const McpOAuthException('Sign-in could not be checked. Try again.');
    }
    final code = query['code'];
    if (code == null || code.isEmpty) {
      throw const McpOAuthException('The browser did not return a sign-in code. Try again.');
    }

    final response = await _send(
      () => _http.post(server.tokenEndpoint, headers: _formHeaders, body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirect.toString(),
        'client_id': clientId,
        'code_verifier': pkce.verifier,
        'resource': discovery.resource,
      }),
      server.tokenEndpoint,
    );
    return _recordFrom(
      _tokenBody(response, refreshing: false),
      clientId: clientId,
      tokenEndpoint: server.tokenEndpoint,
      revocationEndpoint: server.revocationEndpoint,
      resource: discovery.resource,
    );
  }

  /// Exchanges the refresh token for a new access token. The server may rotate the refresh token.
  /// Throws [McpOAuthException] with requiresSignIn when the server rejects the refresh token.
  Future<McpOAuthRecord> refresh(McpOAuthRecord record) async {
    final refreshToken = record.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const McpOAuthException('Your sign-in expired. Sign in again.', requiresSignIn: true);
    }
    final response = await _send(
      () => _http.post(record.tokenEndpoint, headers: _formHeaders, body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': record.clientId,
        'resource': record.resource,
      }),
      record.tokenEndpoint,
    );
    return _recordFrom(
      _tokenBody(response, refreshing: true),
      clientId: record.clientId,
      tokenEndpoint: record.tokenEndpoint,
      revocationEndpoint: record.revocationEndpoint,
      resource: record.resource,
      previousRefresh: refreshToken,
    );
  }

  /// Best-effort revocation at sign-out. Failures are ignored; the local sign-out still happens.
  Future<void> revoke(McpOAuthRecord record) async {
    final endpoint = record.revocationEndpoint;
    if (endpoint == null) return;
    final refreshToken = record.refreshToken;
    try {
      await _http
          .post(endpoint, headers: _formHeaders, body: {
            'token': refreshToken ?? record.accessToken,
            'token_type_hint': refreshToken != null ? 'refresh_token' : 'access_token',
            'client_id': record.clientId,
          })
          .timeout(_timeout);
    } catch (_) {
      // The server may be unreachable; the session is dropped locally either way.
    }
  }

  Uri authorizeUri({
    required McpAuthServerMetadata server,
    required String clientId,
    required Uri redirectUri,
    required String codeChallenge,
    required String state,
    required String resource,
    String? scope,
  }) =>
      server.authorizationEndpoint.replace(queryParameters: {
        ...server.authorizationEndpoint.queryParameters,
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri.toString(),
        'state': state,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'resource': resource,
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      });

  Future<http.Response> _initialize(Uri mcpUrl) => _send(
        () => _http.post(
          mcpUrl,
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': {
              'protocolVersion': _protocolVersion,
              'capabilities': <String, dynamic>{},
              'clientInfo': {'name': 'Flute', 'version': '1.0.0'},
            },
          }),
        ),
        mcpUrl,
      );

  Future<String> _unauthenticatedChallenge(Uri mcpUrl) async {
    final response = await _initialize(mcpUrl);
    if (response.statusCode != 401) {
      throw const McpOAuthException('This server does not ask for sign-in.');
    }
    return response.headers['www-authenticate'] ?? '';
  }

  Future<McpAuthServerMetadata> _authServerMetadata(Uri issuer) async {
    final doc = await _firstJson(_authServerUrls(issuer));
    final authorize = _httpsUri(doc?['authorization_endpoint']);
    final token = _httpsUri(doc?['token_endpoint']);
    if (authorize == null || token == null) {
      throw const McpOAuthException(
          'The sign-in details of this server could not be read. Use a token instead.');
    }
    return McpAuthServerMetadata(
      authorizationEndpoint: authorize,
      tokenEndpoint: token,
      registrationEndpoint: _httpsUri(doc?['registration_endpoint']),
      revocationEndpoint: _httpsUri(doc?['revocation_endpoint']),
    );
  }

  /// Registers Flute as a public client for this sign-in. Registration is repeated at every
  /// sign-in because the loopback port changes with it.
  Future<String> _register(McpAuthServerMetadata server, Uri redirect) async {
    final endpoint = server.registrationEndpoint;
    if (endpoint == null) {
      throw const McpOAuthException(
          'This server does not let Flute register itself. Use a token instead.');
    }
    final response = await _send(
      () => _http.post(
        endpoint,
        headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode({
          'client_name': 'Flute',
          'redirect_uris': [redirect.toString()],
          'grant_types': ['authorization_code', 'refresh_token'],
          'response_types': ['code'],
          'token_endpoint_auth_method': 'none',
        }),
      ),
      endpoint,
    );
    final id = _jsonObject(response)?['client_id'];
    if (response.statusCode < 200 || response.statusCode >= 300 || id is! String || id.isEmpty) {
      throw const McpOAuthException(
          'This server would not register Flute. Use a token instead.');
    }
    return id;
  }

  Map<String, dynamic> _tokenBody(http.Response response, {required bool refreshing}) {
    final body = _jsonObject(response);
    final access = body?['access_token'];
    if (response.statusCode < 200 || response.statusCode >= 300 || access is! String || access.isEmpty) {
      if (refreshing) {
        throw const McpOAuthException('Your sign-in expired. Sign in again.', requiresSignIn: true);
      }
      throw const McpOAuthException('The server refused the sign-in. Try signing in again.');
    }
    return body!;
  }

  McpOAuthRecord _recordFrom(
    Map<String, dynamic> body, {
    required String clientId,
    required Uri tokenEndpoint,
    required Uri? revocationEndpoint,
    required String resource,
    String? previousRefresh,
  }) {
    final refresh = body['refresh_token'];
    final expiresIn = body['expires_in'];
    return McpOAuthRecord(
      clientId: clientId,
      tokenEndpoint: tokenEndpoint,
      revocationEndpoint: revocationEndpoint,
      resource: resource,
      accessToken: body['access_token'] as String,
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : previousRefresh,
      expiresAt: expiresIn is num
          ? DateTime.now().toUtc().add(Duration(seconds: expiresIn.toInt()))
          : null,
    );
  }

  Future<Map<String, dynamic>?> _firstJson(List<Uri> urls) async {
    for (final url in urls) {
      try {
        final response = await _send(
          () => _http.get(url, headers: const {'Accept': 'application/json'}),
          url,
        );
        if (response.statusCode != 200) continue;
        final doc = _jsonObject(response);
        if (doc != null) return doc;
      } on McpOAuthException {
        // Try the next candidate; the caller reports when none works.
      }
    }
    return null;
  }

  Future<http.Response> _send(Future<http.Response> Function() request, Uri target) async {
    try {
      return await request().timeout(_timeout);
    } on SocketException {
      throw McpOAuthException('Cannot reach ${target.host}. Check your connection.');
    } on TimeoutException {
      throw McpOAuthException('${target.host} did not answer in time.');
    } on http.ClientException {
      throw McpOAuthException('Cannot reach ${target.host}. Check your connection.');
    }
  }

  static Map<String, dynamic>? _jsonObject(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static Map<String, String> _challengeParams(String header) => {
        for (final m in _challengeParam.allMatches(header))
          m.group(1)!.toLowerCase(): m.group(2) ?? m.group(3) ?? '',
      };

  static String? _scopesOf(Object? scopes) {
    if (scopes is! List) return null;
    final names = [for (final s in scopes) if (s is String && s.isNotEmpty) s];
    return names.isEmpty ? null : names.join(' ');
  }

  static Uri? _httpsUri(Object? value) {
    if (value is! String) return null;
    try {
      return validateMcpUrl(value);
    } on FormatException {
      return null;
    }
  }

  static String _short(String value) => value.length > 60 ? value.substring(0, 60) : value;

  static String _trimSlash(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// RFC 9728: the metadata lives at the well-known path with the resource path appended, and
  /// at the bare well-known path.
  static List<Uri> _wellKnownCandidates(Uri base, String name) {
    final path = _trimSlash(base.path);
    return [
      if (path.isNotEmpty) _withPath(base, '/.well-known/$name$path'),
      _withPath(base, '/.well-known/$name'),
    ];
  }

  /// RFC 8414 first, then OpenID Connect discovery.
  static List<Uri> _authServerUrls(Uri issuer) {
    final path = _trimSlash(issuer.path);
    return [
      _withPath(issuer, '/.well-known/oauth-authorization-server$path'),
      _withPath(issuer, '$path/.well-known/openid-configuration'),
    ];
  }

  static Uri _withPath(Uri base, String path) => Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: path,
      );

  static String _canonical(Uri uri) => Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
        query: uri.hasQuery ? uri.query : null,
      ).toString();
}
