import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../llm/llm_types.dart';
import '../llm/model_info.dart';
import 'chatgpt_oauth.dart';
import 'loopback_server.dart';
import 'openrouter_oauth.dart';
import 'secret_store.dart';

const _profilesKey = 'agent.profiles';
const _activeKey = 'agent.active';
const _hostIdKey = 'agent.siwc.hostId';
const _chatGptBaseUrl = 'https://api.openai.com/v1';
const _openRouterBaseUrl = 'https://openrouter.ai/api/v1';
const _chatGptPort = 1455;

/// A ChatGPT access token this close to expiry is renewed before use.
const _refreshWindow = Duration(minutes: 2);

String _apiKeySecret(String id) => 'agent.key.$id';
String _chatGptSecret(String id) => 'agent.chatgpt.$id';

/// The providers the agent can talk to, their credentials and the active choice. Profiles and
/// preferences live in SharedPreferences; keys and OAuth sessions only in [SecretStore].
class ProviderStore extends ChangeNotifier {
  ProviderStore({
    required SharedPreferences prefs,
    required SecretStore secrets,
    http.Client? httpClient,
    Future<bool> Function(Uri url)? openBrowser,
  })  : _prefs = prefs,
        _secrets = secrets,
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null {
    final launch = openBrowser ?? _launchExternally;
    _chatGpt = ChatGptOAuth(httpClient: _http, openBrowser: launch);
    _openRouter = OpenRouterOAuth(httpClient: _http, openBrowser: launch);
  }

  final SharedPreferences _prefs;
  final SecretStore _secrets;
  final http.Client _http;
  final bool _ownsHttp;
  late final ChatGptOAuth _chatGpt;
  late final OpenRouterOAuth _openRouter;

  List<ProviderProfile> _profiles = const [];
  String? _activeId;
  final Map<String, String> _accountLabels = {};

  /// Serialises token work per profile, so a rotating refresh token is never used twice.
  final Map<String, Future<void>> _tokenQueue = {};

  bool _signingIn = false;
  bool _cancelRequested = false;
  LoopbackServer? _loopback;

  Future<void> load() async {
    _profiles = _decodeProfiles(_prefs.getString(_profilesKey));
    _activeId = _prefs.getString(_activeKey);
    if (_find(_activeId) == null) {
      _activeId = _profiles.isEmpty ? null : _profiles.first.id;
    }
    _accountLabels.clear();
    for (final profile in _profiles) {
      if (profile.auth != ProviderAuth.chatgptOAuth) continue;
      final email = (await _readSession(profile.id))?.email;
      if (email != null) _accountLabels[profile.id] = email;
    }
    notifyListeners();
  }

  List<ProviderProfile> get profiles => List.unmodifiable(_profiles);

  ProviderProfile? get active => _find(_activeId);

  bool get signingIn => _signingIn;

  /// The ChatGPT account's email, once known. Null for every other profile.
  String? accountLabel(String id) => _accountLabels[id];

  Future<ProviderProfile> addApiKeyProfile({
    required String label,
    required String baseUrl,
    required String apiKey,
  }) async {
    final profile = ProviderProfile(
      id: _newId(),
      label: _cleanLabel(label),
      kind: ProviderKind.openaiCompatible,
      auth: ProviderAuth.apiKey,
      baseUrl: _normalizeBaseUrl(baseUrl),
    );
    await _secrets.write(_apiKeySecret(profile.id), _cleanKey(apiKey));
    await _save(profile, activate: true);
    return profile;
  }

  /// Signs in with OpenRouter. Reuses the OpenRouter profile when there is one.
  Future<ProviderProfile> signInWithOpenRouter() => _guardSignIn(() async {
        final existing = _firstOfAuth(ProviderAuth.openrouterOAuth);
        final loopback = await _listen(path: '/callback');
        _adopt(loopback);
        final key = await _openRouter.signIn(loopback: loopback);
        _throwIfCancelled();
        final profile = existing ??
            ProviderProfile(
              id: _newId(),
              label: 'OpenRouter',
              kind: ProviderKind.openaiCompatible,
              auth: ProviderAuth.openrouterOAuth,
              baseUrl: _openRouterBaseUrl,
            );
        await _secrets.write(_apiKeySecret(profile.id), key);
        await _save(profile, activate: true);
        return profile;
      });

  /// Signs in with ChatGPT. Reuses the ChatGPT profile when there is one: its saved registration is
  /// reauthorised, and a different account is refused rather than overwriting the saved one.
  Future<ProviderProfile> signInWithChatGpt() => _guardSignIn(() async {
        final existing = _firstOfAuth(ProviderAuth.chatgptOAuth);
        final previous = existing == null ? null : await _readSession(existing.id);
        final hostId = await _hostId();
        final loopback = await _listen(preferredPort: _chatGptPort, path: '/auth/callback');
        _adopt(loopback);
        final session = await _chatGpt.signIn(
          hostId: hostId,
          loopback: loopback,
          previous: previous,
        );
        _throwIfCancelled();
        final profile = existing ??
            ProviderProfile(
              id: _newId(),
              label: 'ChatGPT plan',
              kind: ProviderKind.chatgptPlan,
              auth: ProviderAuth.chatgptOAuth,
              baseUrl: _chatGptBaseUrl,
            );
        await _writeSession(profile.id, session);
        await _save(profile, activate: true);
        return profile;
      });

  /// Closes the listener so the pending sign-in ends with a cancel error.
  void cancelSignIn() {
    if (!_signingIn) return;
    _cancelRequested = true;
    unawaited(_loopback?.close());
  }

  Future<void> setActive(String id) async {
    _require(id);
    _activeId = id;
    await _persist();
    notifyListeners();
  }

  Future<void> setModel(String id, String model) async {
    final current = _require(id);
    final chosen = model.trim();
    if (chosen.isEmpty) throw const LlmException('Choose a model.');
    await _save(current.copyWith(model: chosen));
  }

  /// Changes the name, and for key profiles the address and key. An empty [apiKey] keeps the stored
  /// key. Signed-in accounts can only be renamed.
  Future<void> updateApiKeyProfile(
    String id, {
    String? label,
    String? baseUrl,
    String? apiKey,
  }) async {
    final current = _require(id);
    if (current.auth != ProviderAuth.apiKey && (baseUrl != null || apiKey != null)) {
      throw const LlmException('Only the name of a signed-in account can be changed.');
    }
    final updated = current.copyWith(
      label: label == null ? null : _cleanLabel(label),
      baseUrl: baseUrl == null ? null : _normalizeBaseUrl(baseUrl),
    );
    final key = apiKey?.trim();
    if (key != null && key.isNotEmpty) {
      await _secrets.write(_apiKeySecret(id), key);
    }
    await _save(updated);
  }

  /// Removes the profile and its secrets. A ChatGPT session is revoked at OpenAI first, best effort.
  Future<void> remove(String id) => _queued<void>(id, () async {
        final profile = _find(id);
        if (profile == null) return;
        if (profile.auth == ProviderAuth.chatgptOAuth) {
          final session = await _readSession(id);
          if (session != null) await _chatGpt.revoke(session);
        }
        await _secrets.delete(_apiKeySecret(id));
        await _secrets.delete(_chatGptSecret(id));
        _profiles = [for (final p in _profiles) if (p.id != id) p];
        _accountLabels.remove(id);
        if (_activeId == id) _activeId = _profiles.isEmpty ? null : _profiles.first.id;
        await _persist();
        notifyListeners();
      });

  /// The bearer token for a request to [id]: the API key, or a ChatGPT access token renewed when it is
  /// within two minutes of expiry. Throws a 401 [LlmException] when the session is gone.
  Future<String> tokenFor(String id) async {
    final profile = _find(id);
    if (profile == null) {
      throw const LlmException(
          'That provider is no longer set up. Choose another in Agent settings.',
          statusCode: 401);
    }
    if (profile.auth == ProviderAuth.chatgptOAuth) {
      return _queued<String>(id, () => _chatGptToken(id));
    }
    final key = await _secrets.read(_apiKeySecret(id));
    if (key == null || key.isEmpty) {
      throw LlmException(
          'The key for ${profile.label} is missing. Edit it in Agent settings and add it again.',
          statusCode: 401);
    }
    return key;
  }

  @override
  void dispose() {
    if (_ownsHttp) _http.close();
    super.dispose();
  }

  Future<String> _chatGptToken(String id) async {
    final session = await _readSession(id);
    final access = session?.accessToken;
    final expires = session?.expiresAt;
    final refresh = session?.refreshToken;
    if (session == null || access == null || expires == null || refresh == null) {
      throw _signedOut();
    }
    if (expires.difference(DateTime.now().toUtc()) > _refreshWindow) return access;
    try {
      final renewed = await _chatGpt.refresh(session);
      await _writeSession(id, renewed);
      final token = renewed.accessToken;
      if (token == null) throw _signedOut();
      return token;
    } on LlmException catch (error) {
      final code = error.code;
      if (code != null && ChatGptOAuth.revokedRefreshCodes.contains(code)) {
        await _writeSession(id, session.withoutTokens());
        throw _signedOut();
      }
      rethrow;
    }
  }

  /// Runs [work] after any earlier work for [id] has finished.
  Future<T> _queued<T>(String id, Future<T> Function() work) {
    final previous = _tokenQueue[id] ?? Future<void>.value();
    final run = previous.then<T>((_) => work());
    final settled = run.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    _tokenQueue[id] = settled;
    unawaited(settled.whenComplete(() {
      if (identical(_tokenQueue[id], settled)) _tokenQueue.remove(id);
    }));
    return run;
  }

  Future<T> _guardSignIn<T>(Future<T> Function() body) async {
    if (_signingIn) throw const LlmException('Finish the sign-in in your browser first.');
    _signingIn = true;
    _cancelRequested = false;
    notifyListeners();
    try {
      return await body();
    } catch (error, stack) {
      if (_cancelRequested) throw const LlmException('Sign-in was cancelled.');
      if (error is LlmException) rethrow;
      if (error is TimeoutException) throw const LlmException('Sign-in timed out. Try again.');
      if (error is SocketException || error is http.ClientException) {
        throw const LlmException('Cannot reach the sign-in server. Check your connection.');
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      final loopback = _loopback;
      _loopback = null;
      _signingIn = false;
      _cancelRequested = false;
      await loopback?.close();
      notifyListeners();
    }
  }

  void _adopt(LoopbackServer loopback) {
    _loopback = loopback;
    // A cancel that arrived while the listener was starting must not leave the wait open.
    _throwIfCancelled();
  }

  void _throwIfCancelled() {
    if (_cancelRequested) throw const LlmException('Sign-in was cancelled.');
  }

  /// Port [preferredPort] first when given; any free port when it is taken.
  Future<LoopbackServer> _listen({int preferredPort = 0, required String path}) async {
    if (preferredPort != 0) {
      try {
        return await LoopbackServer.start(port: preferredPort, path: path);
      } on SocketException {
        // Another app holds the port. The redirect URI then uses the free port.
      }
    }
    try {
      return await LoopbackServer.start(path: path);
    } on SocketException {
      throw const LlmException('Could not start the sign-in listener on this device.');
    }
  }

  /// This install's `ext_agent_host_id`: created once, reused for every ChatGPT sign-in.
  Future<String> _hostId() async {
    final stored = _prefs.getString(_hostIdKey);
    if (stored != null && stored.startsWith('urn:uuid:')) return stored;
    final hostId = 'urn:uuid:${_newId()}';
    await _prefs.setString(_hostIdKey, hostId);
    return hostId;
  }

  Future<ChatGptSession?> _readSession(String id) async =>
      ChatGptSession.decode(await _secrets.read(_chatGptSecret(id)));

  Future<void> _writeSession(String id, ChatGptSession session) async {
    await _secrets.write(_chatGptSecret(id), jsonEncode(session.toJson()));
    final email = session.email;
    if (email == null) {
      _accountLabels.remove(id);
    } else {
      _accountLabels[id] = email;
    }
  }

  /// Inserts or replaces [profile], optionally making it active, then persists and notifies.
  Future<void> _save(ProviderProfile profile, {bool activate = false}) async {
    final next = [..._profiles];
    final index = next.indexWhere((p) => p.id == profile.id);
    if (index < 0) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    _profiles = next;
    if (activate) _activeId = profile.id;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _profilesKey,
      jsonEncode([for (final p in _profiles) p.toJson()]),
    );
    final active = _activeId;
    if (active == null) {
      await _prefs.remove(_activeKey);
    } else {
      await _prefs.setString(_activeKey, active);
    }
  }

  ProviderProfile _require(String id) {
    final profile = _find(id);
    if (profile == null) {
      throw const LlmException('That provider no longer exists. Refresh Agent settings.');
    }
    return profile;
  }

  ProviderProfile? _find(String? id) {
    if (id == null) return null;
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  ProviderProfile? _firstOfAuth(ProviderAuth auth) {
    for (final profile in _profiles) {
      if (profile.auth == auth) return profile;
    }
    return null;
  }

  static List<ProviderProfile> _decodeProfiles(String? raw) {
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [for (final item in list) ProviderProfile.fromJson(item as Map<String, dynamic>)];
    } catch (_) {
      return const [];
    }
  }

  static LlmException _signedOut() =>
      const LlmException('Sign in with ChatGPT again.', statusCode: 401);

  static String _newId() => const Uuid().v4();

  static String _cleanLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) throw const LlmException('Give the provider a name.');
    return trimmed;
  }

  static String _cleanKey(String apiKey) {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) throw const LlmException('Enter the API key.');
    return trimmed;
  }

  static Future<bool> _launchExternally(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

/// Trims and checks a provider address. https everywhere; plain http only on this device or a local
/// network, where self-hosted gateways usually run.
String _normalizeBaseUrl(String raw) {
  var url = raw.trim();
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const LlmException(
        'Enter the full address, such as https://api.example.com/v1.');
  }
  if (uri.scheme == 'https') return url;
  if (uri.scheme == 'http' && _isLocalAddress(uri.host)) return url;
  throw const LlmException(
      'Use an https:// address. Plain http works only on this device or your local network.');
}

bool _isLocalAddress(String host) {
  if (host == 'localhost' || host == '::1') return true;
  final octets = host.split('.').map(int.tryParse).toList();
  if (octets.length != 4 || octets.any((o) => o == null || o < 0 || o > 255)) return false;
  final first = octets[0]!;
  final second = octets[1]!;
  return first == 127 || first == 10 || first == 100 || (first == 192 && second == 168);
}
