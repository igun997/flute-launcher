import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../auth/secret_store.dart';

/// Persisted sandbox choices. API keys live in the secret store; everything
/// else lives in preferences.
class SandboxSettings {
  SandboxSettings({required SharedPreferences prefs, required SecretStore secrets})
    : _prefs = prefs,
      _secrets = secrets;

  static const maxKeepWarmMinutes = 60;

  static const _preferredKey = 'sandbox.preferred';
  static const _keepWarmKey = 'sandbox.keepWarmMinutes';

  final SharedPreferences _prefs;
  final SecretStore _secrets;

  String? get preferredId => _prefs.getString(_preferredKey);

  Future<void> setPreferred(String? id) async {
    if (id == null) {
      await _prefs.remove(_preferredKey);
    } else {
      await _prefs.setString(_preferredKey, id);
    }
  }

  int get keepWarmMinutes =>
      math.min(math.max(_prefs.getInt(_keepWarmKey) ?? 0, 0), maxKeepWarmMinutes);

  Future<void> setKeepWarmMinutes(int minutes) => _prefs.setInt(
    _keepWarmKey,
    math.min(math.max(minutes, 0), maxKeepWarmMinutes),
  );

  String? apiUrl(String providerId) => _prefs.getString('sandbox.$providerId.apiUrl');

  Future<void> setApiUrl(String providerId, String? url) async {
    final key = 'sandbox.$providerId.apiUrl';
    if (url == null || url.trim().isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, url.trim());
    }
  }

  String? existingSandboxId(String providerId) =>
      _prefs.getString('sandbox.$providerId.existing');

  Future<void> setExistingSandboxId(String providerId, String? id) async {
    final key = 'sandbox.$providerId.existing';
    if (id == null || id.trim().isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, id.trim());
    }
  }

  Future<String?> apiKey(String providerId) => _secrets.read(_keyName(providerId));

  Future<void> saveApiKey(String providerId, String key) =>
      _secrets.write(_keyName(providerId), key.trim());

  Future<void> removeApiKey(String providerId) => _secrets.delete(_keyName(providerId));

  static String _keyName(String providerId) => 'sandbox_${providerId}_key';
}
