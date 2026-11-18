import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/secret_store.dart';
import 'web_api.dart';

/// Web search provider choice and API keys. Keys live only in [SecretStore].
class WebSettings extends ChangeNotifier {
  WebSettings({
    required SharedPreferences prefs,
    required SecretStore secrets,
    http.Client? httpClient,
  }) : _prefs = prefs,
       _secrets = secrets,
       _api = WebApi(httpClient ?? http.Client());

  static const _providerPref = 'web.provider';

  final SharedPreferences _prefs;
  final SecretStore _secrets;
  final WebApi _api;
  final Map<WebProvider, String> _keys = {};
  WebProvider? _chosen;

  WebApi get api => _api;

  Future<void> load() async {
    _chosen = WebProvider.values.asNameMap()[_prefs.getString(_providerPref)];
    _keys.clear();
    for (final provider in WebProvider.values) {
      final key = await _secrets.read(provider.secretKey);
      if (key != null && key.isNotEmpty) _keys[provider] = key;
    }
    notifyListeners();
  }

  /// The chosen provider when it has a key, otherwise the first provider with a key.
  WebProvider? get provider {
    final chosen = _chosen;
    if (chosen != null && _keys.containsKey(chosen)) return chosen;
    for (final provider in WebProvider.values) {
      if (_keys.containsKey(provider)) return provider;
    }
    return null;
  }

  bool hasKey(WebProvider provider) => _keys.containsKey(provider);

  String? apiKey(WebProvider provider) => _keys[provider];

  Future<void> setProvider(WebProvider provider) async {
    _chosen = provider;
    await _prefs.setString(_providerPref, provider.name);
    notifyListeners();
  }

  /// Checks the key with one real search before storing it.
  Future<void> saveKey(WebProvider provider, String rawKey) async {
    final key = rawKey.trim();
    if (key.isEmpty) throw const FormatException('Paste an API key first.');
    await _api.search(provider, key, query: 'Flute connection check', maxResults: 1);
    await _secrets.write(provider.secretKey, key);
    _keys[provider] = key;
    await setProvider(provider);
  }

  Future<void> removeKey(WebProvider provider) async {
    await _secrets.delete(provider.secretKey);
    _keys.remove(provider);
    notifyListeners();
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }
}
