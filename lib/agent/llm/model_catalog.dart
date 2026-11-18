import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'llm_types.dart';
import 'model_info.dart';
import 'wire_support.dart';

/// Lists the models a provider offers, searches them, and keeps a cache per profile.
class ModelCatalog {
  /// `GET {baseUrl}/models`. Accepts the OpenAI, OpenRouter, ChatGPT plan, plain-list and
  /// Ollama-style shapes. Sorted by name, one entry per id.
  static Future<List<ModelInfo>> fetch({
    required ProviderKind kind,
    required String baseUrl,
    required String token,
    http.Client? httpClient,
  }) async {
    final host = hostOf(baseUrl);
    final client = httpClient ?? http.Client();
    try {
      final response = await _get(
        client,
        Uri.parse('${normaliseBaseUrl(baseUrl)}/models'),
        token: token,
        host: host,
      );
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode >= 400) {
        throw httpFailure(
          status: response.statusCode,
          body: body,
          host: host,
          secret: token,
          kind: kind,
        );
      }
      return _parseList(decodeJson(body, host));
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Case-insensitive. Every whitespace-separated token must occur in the id, name or owner.
  /// Ranking: id starts with the query, id contains it, name contains it; then by name.
  static List<ModelInfo> search(List<ModelInfo> all, String query) {
    final q = query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (q.isEmpty) return List.of(all);
    final tokens = q.split(' ');
    final matches = all.where((model) {
      final fields = [model.id, model.name, model.ownedBy ?? ''].map((s) => s.toLowerCase());
      return tokens.every((token) => fields.any((field) => field.contains(token)));
    }).toList();

    int tier(ModelInfo model) {
      final id = model.id.toLowerCase();
      if (id.startsWith(q)) return 0;
      if (id.contains(q)) return 1;
      if (model.name.toLowerCase().contains(q)) return 2;
      return 3;
    }

    matches.sort((a, b) {
      final byTier = tier(a).compareTo(tier(b));
      return byTier != 0 ? byTier : _byName(a, b);
    });
    return matches;
  }

  /// The cached list for [profileId], or null when none is stored or the cache is damaged.
  static List<ModelInfo>? loadCache(SharedPreferences prefs, String profileId) {
    final raw = prefs.getString(_cacheKey(profileId));
    if (raw == null) return null;
    try {
      return [
        for (final item in jsonDecode(raw) as List)
          ModelInfo.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } catch (_) {
      // A damaged cache is the same as no cache: the list is fetched again.
      return null;
    }
  }

  static Future<void> saveCache(
    SharedPreferences prefs,
    String profileId,
    List<ModelInfo> models,
  ) async {
    await prefs.setString(
      _cacheKey(profileId),
      jsonEncode([for (final model in models) model.toJson()]),
    );
  }

  static String _cacheKey(String profileId) => 'agent.models.$profileId';

  static Future<http.Response> _get(
    http.Client client,
    Uri uri, {
    required String token,
    required String host,
  }) async {
    try {
      return await client.get(uri, headers: {
        'Accept': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      }).timeout(llmConnectTimeout);
    } catch (error) {
      if (isNetworkError(error)) throw unreachable(host);
      rethrow;
    }
  }

  static List<ModelInfo> _parseList(Object? decoded) {
    final items = switch (decoded) {
      List list => list,
      Map map when map['data'] is List => map['data'] as List,
      Map map when map['models'] is List => map['models'] as List,
      _ => null,
    };
    if (items == null) {
      throw const LlmException('The provider sent a model list in a format Flute does not know.');
    }
    final byId = <String, ModelInfo>{};
    for (final item in items) {
      final model = item is Map ? _parseItem(item) : null;
      if (model != null) byId.putIfAbsent(model.id, () => model);
    }
    return byId.values.toList()..sort(_byName);
  }

  /// One model entry. Null when the entry is hidden or has no id.
  static ModelInfo? _parseItem(Map<dynamic, dynamic> item) {
    final visibility = item['visibility'];
    if (visibility is String && visibility != 'list') return null;
    final id = textOf(item['id']) ??
        textOf(item['slug']) ??
        textOf(item['model']) ??
        textOf(item['name']);
    if (id == null) return null;
    final architecture =
        item['architecture'] is Map ? item['architecture'] as Map : const <dynamic, dynamic>{};
    final pricing = item['pricing'] is Map ? item['pricing'] as Map : const <dynamic, dynamic>{};
    final promptPerToken = numOf(pricing['prompt']);
    final context = intOf(item['context_length']) ?? intOf(item['context_window']);
    return ModelInfo(
      id: id,
      name: textOf(item['display_name']) ?? textOf(item['name']) ?? id,
      ownedBy: textOf(item['owned_by']),
      contextLength: context != null && context > 0 ? context : null,
      acceptsImages: _acceptsImages(architecture, item),
      // Negative prices mean "varies" on OpenRouter; they are not a price.
      promptPricePerMillion:
          promptPerToken != null && promptPerToken >= 0 ? promptPerToken * 1e6 : null,
    );
  }

  static bool? _acceptsImages(Map<dynamic, dynamic> architecture, Map<dynamic, dynamic> item) {
    final inputs = architecture['input_modalities'] ?? item['input_modalities'];
    if (inputs is List) return inputs.contains('image');
    // OpenRouter also describes it as "text+image->text".
    final modality = textOf(architecture['modality']);
    if (modality != null) return modality.split('->').first.contains('image');
    return null;
  }

  static int _byName(ModelInfo a, ModelInfo b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  }
}
