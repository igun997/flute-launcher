import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../llm/llm_types.dart';
import 'loopback_server.dart';
import 'pkce.dart';

/// One ChatGPT account registration: the issued client ID and verified identity, plus the tokens while
/// the session is alive. Stored as one JSON record per profile in the secret store. After a revoked
/// session the tokens are dropped and the registration stays, so the next sign-in reuses it.
class ChatGptSession {
  const ChatGptSession({
    required this.clientId,
    required this.subject,
    this.email,
    this.idToken,
    this.accessToken,
    this.refreshToken,
    this.scopes = const [],
    this.expiresAt,
  });

  factory ChatGptSession.fromJson(Map<String, dynamic> j) => ChatGptSession(
        clientId: j['clientId'] as String,
        subject: j['subject'] as String,
        email: j['email'] as String?,
        idToken: j['idToken'] as String?,
        accessToken: j['accessToken'] as String?,
        refreshToken: j['refreshToken'] as String?,
        scopes: [for (final s in (j['scopes'] as List? ?? const [])) s as String],
        expiresAt: j['expiresAt'] == null ? null : DateTime.parse(j['expiresAt'] as String),
      );

  /// Null when [raw] is absent or unreadable.
  static ChatGptSession? decode(String? raw) {
    if (raw == null) return null;
    try {
      return ChatGptSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  final String clientId;
  final String subject;
  final String? email;
  final String? idToken;
  final String? accessToken;
  final String? refreshToken;
  final List<String> scopes;
  final DateTime? expiresAt;

  bool get hasTokens => accessToken != null && refreshToken != null && expiresAt != null;

  ChatGptSession withoutTokens() => ChatGptSession(
        clientId: clientId,
        subject: subject,
        email: email,
        idToken: idToken,
      );

  Map<String, dynamic> toJson() {
    final expires = expiresAt;
    return {
      'clientId': clientId,
      'subject': subject,
      if (email != null) 'email': email,
      if (idToken != null) 'idToken': idToken,
      if (accessToken != null) 'accessToken': accessToken,
      if (refreshToken != null) 'refreshToken': refreshToken,
      'scopes': scopes,
      if (expires != null) 'expiresAt': expires.toUtc().toIso8601String(),
    };
  }
}

/// Sign in with ChatGPT for a local open-source app, per
/// https://developers.openai.com/siwc/token-sharing-open-source
class ChatGptOAuth {
  ChatGptOAuth({
    required http.Client httpClient,
    required Future<bool> Function(Uri url) openBrowser,
  })  : _http = httpClient,
        _openBrowser = openBrowser;

  final http.Client _http;
  final Future<bool> Function(Uri url) _openBrowser;

  static const issuer = 'https://auth.openai.com';
  static const resource = 'https://api.openai.com/v1';
  static const dynamicClientId = 'dynamic_agent_client';
  static const appName = 'Flute';
  static const planScope = 'chatgpt.tokens.use.direct';
  static const scopes =
      'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct';

  /// Refresh errors meaning the session is gone for good. The tokens must be cleared.
  static const revokedRefreshCodes = {
    'invalid_grant',
    'invalid_refresh_token',
    'token_expired',
    'refresh_token_expired',
    'refresh_token_invalidated',
    'refresh_token_reused',
  };

  static final _tokenEndpoint = Uri.https('auth.openai.com', '/api/accounts/oauth/token');
  static final _discoveryEndpoint =
      Uri.https('auth.openai.com', '/.well-known/openid-configuration');
  static const _requestTimeout = Duration(seconds: 30);
  static const _unreachable =
      LlmException('Cannot reach ChatGPT. Check your connection.');

  Uri authorizeUri({
    required String clientId,
    required String hostId,
    required String redirectUri,
    required String state,
    required String nonce,
    required String codeChallenge,
    String? appName,
    String? idTokenHint,
    String? loginHint,
  }) {
    return Uri.https('auth.openai.com', '/api/accounts/authorize', {
      'client_id': clientId,
      if (appName != null) 'agent_name_hint': appName,
      'ext_agent_host_id': hostId,
      if (idTokenHint != null) 'id_token_hint': idTokenHint,
      if (loginHint != null) 'login_hint': loginHint,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': scopes,
      'resource': resource,
      'state': state,
      'nonce': nonce,
      'code_challenge_method': 'S256',
      'code_challenge': codeChallenge,
    });
  }

  /// Runs the browser flow on [loopback] (already listening) and returns the validated session.
  /// [previous] reauthorises a saved registration: same issued client ID, same account. Without it
  /// this is a new registration.
  Future<ChatGptSession> signIn({
    required String hostId,
    required LoopbackServer loopback,
    ChatGptSession? previous,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final pkce = Pkce.generate();
    final state = Pkce.randomUrlSafe();
    final nonce = Pkce.randomUrlSafe();
    final redirectUri = loopback.redirectUri().toString();
    final url = authorizeUri(
      clientId: previous?.clientId ?? dynamicClientId,
      hostId: hostId,
      redirectUri: redirectUri,
      state: state,
      nonce: nonce,
      codeChallenge: pkce.challenge,
      appName: previous == null ? appName : null,
      idTokenHint: previous?.idToken,
      loginHint: previous?.email,
    );
    if (!await _openBrowser(url)) {
      throw const LlmException('Could not open the browser for ChatGPT sign-in.');
    }
    final query = await loopback.waitForCallback(timeout: timeout);
    if (query['state'] != state) {
      throw const LlmException('The ChatGPT sign-in did not match this request. Try again.');
    }
    final error = query['error'];
    if (error == 'access_denied') {
      throw const LlmException(
          'ChatGPT sign-in was declined. Allow ChatGPT plan use to continue.');
    }
    if (error != null) throw LlmException('ChatGPT sign-in failed ($error).');
    final code = query['code'];
    if (code == null || code.isEmpty) {
      throw const LlmException('ChatGPT did not return a sign-in code. Try again.');
    }

    final clientId = _resolveClientId(previous, query['client_id']);
    final body = await _exchangeCode(
      code: code,
      verifier: pkce.verifier,
      redirectUri: redirectUri,
      clientId: clientId,
    );
    final idToken = body['id_token'];
    final access = body['access_token'];
    final refresh = body['refresh_token'];
    if (idToken is! String || access is! String || refresh is! String) {
      throw const LlmException('ChatGPT did not return a usable session. Try again.');
    }
    final identity = _verifyIdToken(idToken, clientId: clientId, nonce: nonce);
    if (previous != null && identity.subject != previous.subject) {
      throw const LlmException(
          'That ChatGPT account is not the one saved for this profile. Sign in with the saved '
          'account, or remove the ChatGPT profile first.');
    }
    final granted = _scopesOf(body['scope']);
    if (!granted.contains(planScope)) {
      throw const LlmException(
          'ChatGPT plan use was not allowed for this sign-in. Try again and allow ChatGPT plan use.');
    }
    return ChatGptSession(
      clientId: clientId,
      subject: identity.subject,
      email: identity.email,
      idToken: idToken,
      accessToken: access,
      refreshToken: refresh,
      scopes: granted,
      expiresAt: _expiresAt(body),
    );
  }

  /// Renews the access token. The rotated refresh token replaces the old one: the caller stores the
  /// returned session in one write. Revoked sessions throw a 401 whose [LlmException.code] is one of
  /// [revokedRefreshCodes]; other failures keep the session.
  Future<ChatGptSession> refresh(ChatGptSession session) async {
    final refreshToken = session.refreshToken;
    if (refreshToken == null) {
      throw const LlmException('Sign in with ChatGPT again.', statusCode: 401);
    }
    final response = await _postToken({
      'grant_type': 'refresh_token',
      'client_id': session.clientId,
      'refresh_token': refreshToken,
      'resource': resource,
    });
    if (response.statusCode != 200) {
      final code = _errorCode(response);
      if (code != null && revokedRefreshCodes.contains(code)) {
        throw LlmException('Sign in with ChatGPT again.', statusCode: 401, code: code);
      }
      throw _tokenFailure(response);
    }
    final body = _jsonObject(response);
    final access = body['access_token'];
    if (access is! String) {
      throw const LlmException('ChatGPT did not renew the session. Try again.');
    }
    final newRefresh = body['refresh_token'];
    final newIdToken = body['id_token'];
    final granted = _scopesOf(body['scope']);
    return ChatGptSession(
      clientId: session.clientId,
      subject: session.subject,
      email: session.email,
      idToken: newIdToken is String ? newIdToken : session.idToken,
      accessToken: access,
      refreshToken: newRefresh is String ? newRefresh : refreshToken,
      scopes: granted.isEmpty ? session.scopes : granted,
      expiresAt: _expiresAt(body),
    );
  }

  /// Ends the renewable session at OpenAI. Best effort, one attempt: signing out locally must not
  /// wait on the network. The user can still disconnect the app in ChatGPT settings.
  Future<void> revoke(ChatGptSession session) async {
    final refreshToken = session.refreshToken;
    if (refreshToken == null) return;
    try {
      final discovery = await _send(() => _http.get(_discoveryEndpoint));
      if (discovery.statusCode != 200) return;
      final advertised = _jsonObject(discovery)['revocation_endpoint'];
      final endpoint = advertised is String ? Uri.tryParse(advertised) : null;
      if (endpoint == null || endpoint.scheme != 'https') return;
      await _send(() => _http.post(endpoint, body: {
            'token': refreshToken,
            'token_type_hint': 'refresh_token',
            'client_id': session.clientId,
          }));
    } on LlmException {
      // Local sign-out still proceeds.
    }
  }

  String _resolveClientId(ChatGptSession? previous, String? issued) {
    if (previous == null) {
      if (issued == null || issued.isEmpty || issued == dynamicClientId) {
        throw const LlmException('ChatGPT did not finish registering Flute. Try again.');
      }
      return issued;
    }
    if (issued != null && issued.isNotEmpty && issued != previous.clientId) {
      throw const LlmException('ChatGPT returned a different registration. Try again.');
    }
    return previous.clientId;
  }

  Future<Map<String, dynamic>> _exchangeCode({
    required String code,
    required String verifier,
    required String redirectUri,
    required String clientId,
  }) async {
    final response = await _postToken({
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'code_verifier': verifier,
      'redirect_uri': redirectUri,
      'resource': resource,
    });
    if (response.statusCode != 200) {
      if (_errorCode(response) == 'invalid_grant') {
        throw const LlmException('The ChatGPT sign-in code expired. Try again.');
      }
      throw _tokenFailure(response);
    }
    return _jsonObject(response);
  }

  /// Checks the claims that bind the ID token to this attempt. The signature is not verified: the token
  /// came straight from the token endpoint over TLS and this app has no JWKS verifier. The
  /// issuer, audience, expiry, nonce and subject checks are the ones that matter for this flow.
  ({String subject, String? email}) _verifyIdToken(
    String idToken, {
    required String clientId,
    required String nonce,
  }) {
    final claims = _jwtPayload(idToken);
    if (claims == null || !_bindsTo(claims, clientId: clientId, nonce: nonce)) {
      throw const LlmException(
          'ChatGPT returned a sign-in that could not be verified. Try again.');
    }
    final email = claims['email'];
    return (subject: claims['sub'] as String, email: email is String ? email : null);
  }

  bool _bindsTo(Map<String, dynamic> claims, {required String clientId, required String nonce}) {
    final audience = claims['aud'];
    final exp = claims['exp'];
    final subject = claims['sub'];
    return claims['iss'] == issuer &&
        (audience == clientId || (audience is List && audience.contains(clientId))) &&
        exp is num &&
        DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true)
            .isAfter(DateTime.now().toUtc()) &&
        claims['nonce'] == nonce &&
        subject is String &&
        subject.isNotEmpty;
  }

  Map<String, dynamic>? _jwtPayload(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final segment = parts[1];
      final padded = segment.padRight((segment.length + 3) ~/ 4 * 4, '=');
      final value = jsonDecode(utf8.decode(base64Url.decode(padded)));
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  Future<http.Response> _postToken(Map<String, String> form) => _send(() => _http.post(
        _tokenEndpoint,
        headers: const {'Accept': 'application/json'},
        body: form,
      ));

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

  LlmException _tokenFailure(http.Response response) {
    final code = _errorCode(response);
    if (code == 'invalid_client') {
      return LlmException(
          'ChatGPT rejected the sign-in registration for Flute. Sign in again.',
          statusCode: response.statusCode,
          code: code);
    }
    if (response.statusCode == 429 || response.statusCode >= 500) {
      return LlmException('ChatGPT is busy right now. Try again in a moment.',
          statusCode: response.statusCode, code: code);
    }
    return LlmException('ChatGPT sign-in failed (HTTP ${response.statusCode}).',
        statusCode: response.statusCode, code: code);
  }

  Map<String, dynamic> _jsonObject(http.Response response) {
    try {
      final value = jsonDecode(response.body);
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      // Reported below.
    }
    throw const LlmException('ChatGPT sent an unreadable reply. Try again.');
  }

  String? _errorCode(http.Response response) {
    try {
      final value = jsonDecode(response.body);
      if (value is! Map) return null;
      final error = value['error'];
      if (error is String) return error;
      if (error is Map && error['code'] is String) return error['code'] as String;
    } on FormatException {
      return null;
    }
    return null;
  }

  List<String> _scopesOf(Object? raw) =>
      raw is String ? raw.split(' ').where((s) => s.isNotEmpty).toList() : const [];

  DateTime _expiresAt(Map<String, dynamic> body) {
    final seconds = body['expires_in'];
    final lifetime = seconds is num ? seconds.toInt() : 3600;
    return DateTime.now().toUtc().add(Duration(seconds: lifetime));
  }
}
