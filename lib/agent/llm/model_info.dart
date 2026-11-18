/// What a provider's `/models` endpoint says about one model.
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.name,
    this.ownedBy,
    this.contextLength,
    this.acceptsImages,
    this.promptPricePerMillion,
  });

  /// The value to send as `model`.
  final String id;

  /// A readable name; falls back to [id].
  final String name;
  final String? ownedBy;
  final int? contextLength;

  /// Null when the provider does not say.
  final bool? acceptsImages;
  final double? promptPricePerMillion;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (ownedBy != null) 'ownedBy': ownedBy,
        if (contextLength != null) 'contextLength': contextLength,
        if (acceptsImages != null) 'acceptsImages': acceptsImages,
        if (promptPricePerMillion != null) 'promptPricePerMillion': promptPricePerMillion,
      };

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? j['id'] as String,
        ownedBy: j['ownedBy'] as String?,
        contextLength: (j['contextLength'] as num?)?.toInt(),
        acceptsImages: j['acceptsImages'] as bool?,
        promptPricePerMillion: (j['promptPricePerMillion'] as num?)?.toDouble(),
      );
}

/// Which wire a provider speaks.
enum ProviderKind {
  /// `POST {baseUrl}/chat/completions`, `GET {baseUrl}/models`, `Authorization: Bearer <key>`.
  /// Covers the gateway, OpenRouter, OpenAI keys, Ollama, and anything that copies OpenAI.
  openaiCompatible,

  /// ChatGPT plan usage through Sign in with ChatGPT: `POST {baseUrl}/responses` with
  /// `store:false`, `stream:true`, `GET {baseUrl}/models` (shape `{models:[{slug,display_name}]}`).
  chatgptPlan,
}

/// How the profile gets its credential.
enum ProviderAuth { apiKey, openrouterOAuth, chatgptOAuth }

class ProviderProfile {
  const ProviderProfile({
    required this.id,
    required this.label,
    required this.kind,
    required this.auth,
    required this.baseUrl,
    this.model,
  });

  final String id;
  final String label;
  final ProviderKind kind;
  final ProviderAuth auth;

  /// Without a trailing slash, includes the version segment: `https://host/v1`.
  final String baseUrl;

  /// The selected model id, or null until one is picked.
  final String? model;

  ProviderProfile copyWith({String? label, String? baseUrl, String? model}) => ProviderProfile(
        id: id,
        label: label ?? this.label,
        kind: kind,
        auth: auth,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'kind': kind.name,
        'auth': auth.name,
        'baseUrl': baseUrl,
        if (model != null) 'model': model,
      };

  factory ProviderProfile.fromJson(Map<String, dynamic> j) => ProviderProfile(
        id: j['id'] as String,
        label: j['label'] as String,
        kind: ProviderKind.values.byName(j['kind'] as String),
        auth: ProviderAuth.values.byName(j['auth'] as String),
        baseUrl: j['baseUrl'] as String,
        model: j['model'] as String?,
      );
}
