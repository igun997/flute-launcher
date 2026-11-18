import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/secret_store.dart';
import 'daytona_provider.dart';
import 'instabox_provider.dart';
import 'local_wasm_provider.dart';
import 'sandbox_provider.dart';
import 'sandbox_settings.dart';

/// Owns the single sandbox session shared by agent runs.
///
/// The session opens lazily on first use, closes after [idleTimeout] without
/// activity, closes when a run ends (or after keep-warm minutes), and closes
/// when the app pauses. Failed closes are kept and retried.
class SandboxManager extends ChangeNotifier {
  SandboxManager({
    required SharedPreferences prefs,
    required SecretStore secrets,
    http.Client? httpClient,
    bool watchAppLifecycle = true,
  }) : _settings = SandboxSettings(prefs: prefs, secrets: secrets),
       _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null {
    _local = LocalWasmProvider(
      directory: _runtimeDirectory,
      runtime: const RustWasmRuntime(),
      client: _client,
    );
    if (watchAppLifecycle) {
      _lifecycle = AppLifecycleListener(onPause: () => unawaited(shutdown()));
    }
  }

  static const idleTimeout = Duration(seconds: 90);
  static const retryDelay = Duration(seconds: 30);

  static const _remoteIds = ['instabox', 'daytona'];
  static const _labels = {
    'instabox': 'Instabox',
    'daytona': 'Daytona',
    'local': 'Local Python',
  };

  final SandboxSettings _settings;
  final http.Client _client;
  final bool _ownsClient;
  late final LocalWasmProvider _local;
  AppLifecycleListener? _lifecycle;

  final Map<String, String> _keys = {};

  SandboxSession? _session;
  Future<SandboxSession>? _opening;
  String? _activeId;
  final List<SandboxSession> _unclosed = [];
  String? _stopError;
  int _generation = 0;
  Timer? _idleTimer;
  Timer? _retryTimer;
  bool _disposed = false;

  static Future<Directory> _runtimeDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/sandbox');
  }

  /// Loads saved keys. Call once at startup.
  Future<void> load() async {
    _keys.clear();
    for (final id in _remoteIds) {
      final key = await _settings.apiKey(id);
      if (key != null && key.isNotEmpty) _keys[id] = key;
    }
    _notify();
  }

  List<SandboxProviderStatus> get providers => [
    for (final id in _remoteIds)
      SandboxProviderStatus(
        id: id,
        label: _labels[id]!,
        needsKey: true,
        hasKey: _keys.containsKey(id),
      ),
    SandboxProviderStatus(
      id: 'local',
      label: _labels['local']!,
      needsKey: false,
      hasKey: false,
    ),
  ];

  String? get preferredProviderId => _settings.preferredId;

  Future<void> setPreferred(String? id) async {
    await _settings.setPreferred(id);
    _notify();
  }

  int get keepWarmMinutes => _settings.keepWarmMinutes;

  Future<void> setKeepWarmMinutes(int minutes) async {
    await _settings.setKeepWarmMinutes(minutes);
    _notify();
  }

  String? apiUrl(String providerId) => _settings.apiUrl(providerId);

  String? existingSandbox(String providerId) =>
      _settings.existingSandboxId(providerId);

  Future<void> setExistingSandbox(String providerId, String? id) async {
    final trimmed = id?.trim();
    await _settings.setExistingSandboxId(
      providerId,
      trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
    _notify();
  }

  bool get running => _session != null;

  /// Message from the last failed stop, or null when everything closed.
  String? get stopError => _stopError;

  /// Checks [key] with the provider, then stores it along with [apiUrl].
  Future<void> saveKey(String providerId, String key, {String? apiUrl}) async {
    _requireRemote(providerId);
    final trimmedKey = key.trim();
    if (trimmedKey.isEmpty) {
      throw const SandboxException('Enter an API key.');
    }
    final rawUrl = apiUrl?.trim();
    final url = rawUrl == null || rawUrl.isEmpty ? null : rawUrl;
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw const SandboxException('The API address must start with https://.');
      }
    }
    await _verify(providerId, trimmedKey, url);
    await _settings.saveApiKey(providerId, trimmedKey);
    await _settings.setApiUrl(providerId, url);
    _keys[providerId] = trimmedKey;
    _notify();
  }

  Future<void> removeKey(String providerId) async {
    _requireRemote(providerId);
    if (_activeId == providerId) await shutdown();
    await _settings.removeApiKey(providerId);
    await _settings.setApiUrl(providerId, null);
    await _settings.setExistingSandboxId(providerId, null);
    _keys.remove(providerId);
    if (_settings.preferredId == providerId) await _settings.setPreferred(null);
    _notify();
  }

  Future<bool> localInstalled() => _local.isInstalled();

  Future<void> downloadLocal({void Function(double fraction)? onProgress}) async {
    await _local.download(onProgress: onProgress);
    _notify();
  }

  Future<void> deleteLocal() async {
    await _local.delete();
    _notify();
  }

  /// Returns the shared session, opening it on first use.
  Future<SandboxSession> session() async {
    final current = _session;
    if (current != null) {
      _armIdle();
      return current;
    }
    final pending = _opening;
    if (pending != null) return pending;

    final generation = _generation;
    final opening = _open();
    _opening = opening;
    try {
      final session = await opening;
      if (generation != _generation) {
        _unclosed.add(session);
        unawaited(_closePending());
        throw const SandboxException('Sandbox start was cancelled.');
      }
      _session = session;
      _armIdle();
      _notify();
      return session;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  /// Called when an agent run finishes. Closes now, or after keep-warm minutes.
  void endRun() {
    if (_session == null) return;
    final minutes = _settings.keepWarmMinutes;
    if (minutes <= 0) {
      unawaited(shutdown());
      return;
    }
    _idleTimer?.cancel();
    _idleTimer = Timer(Duration(minutes: minutes), () => unawaited(shutdown()));
  }

  /// Closes the session. Safe to call repeatedly.
  Future<void> shutdown() async {
    _generation++;
    _idleTimer?.cancel();
    _idleTimer = null;
    final open = _session;
    _session = null;
    if (open != null) _unclosed.add(open);
    await _closePending();
  }

  /// Runs a trivial script to check the setup and reports the elapsed time.
  Future<Duration> selfTest() async {
    final watch = Stopwatch()..start();
    final session = await this.session();
    try {
      final result = await session.runPython(
        'print(1+1)',
        timeout: const Duration(seconds: 30),
      );
      if (result.exitCode != 0 || result.stdout.trim() != '2') {
        throw SandboxException('Self-test failed (exit ${result.exitCode}).');
      }
    } finally {
      endRun();
    }
    return watch.elapsed;
  }

  Future<SandboxSession> _open() async {
    final id = _chooseProviderId();
    _activeId = id;
    final SandboxProvider provider;
    if (id == 'local') {
      provider = _local;
    } else {
      final key = _keys[id];
      if (key == null) {
        throw SandboxException('Add a ${_labels[id]} API key in Settings.');
      }
      provider = _remote(id, key);
    }
    return provider.open(existingId: _settings.existingSandboxId(id));
  }

  String _chooseProviderId() {
    final preferred = _settings.preferredId;
    if (preferred == 'local') return 'local';
    if (preferred != null && _keys.containsKey(preferred)) return preferred;
    for (final id in _remoteIds) {
      if (_keys.containsKey(id)) return id;
    }
    return 'local';
  }

  SandboxProvider _remote(String id, String key) {
    final url = _settings.apiUrl(id);
    return switch (id) {
      'instabox' => InstaboxProvider(apiKey: key, client: _client, baseUrl: url),
      'daytona' => DaytonaProvider(apiKey: key, client: _client, baseUrl: url),
      _ => throw SandboxException('Unknown sandbox provider: $id.'),
    };
  }

  Future<void> _verify(String id, String key, String? url) async {
    switch (id) {
      case 'instabox':
        await InstaboxProvider(apiKey: key, client: _client, baseUrl: url)
            .verifyKey();
      case 'daytona':
        await DaytonaProvider(apiKey: key, client: _client, baseUrl: url)
            .verifyKey();
      default:
        throw SandboxException('Unknown sandbox provider: $id.');
    }
  }

  void _requireRemote(String id) {
    if (!_remoteIds.contains(id)) {
      throw SandboxException('Unknown sandbox provider: $id.');
    }
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () => unawaited(shutdown()));
  }

  Future<void> _closePending() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    final batch = List<SandboxSession>.of(_unclosed);
    _unclosed.clear();
    for (final session in batch) {
      try {
        await session.close();
      } catch (e) {
        _unclosed.add(session);
        _stopError = e is SandboxException
            ? e.message
            : 'Could not stop the sandbox. It will be retried.';
      }
    }
    if (_unclosed.isEmpty) {
      _stopError = null;
    } else {
      _retryTimer = Timer(retryDelay, () => unawaited(_closePending()));
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _idleTimer?.cancel();
    _retryTimer?.cancel();
    _lifecycle?.dispose();
    shutdown().whenComplete(() {
      if (_ownsClient) _client.close();
    });
    super.dispose();
  }
}
