import '../llm/model_info.dart';

/// One provider and one of its image models.
class ImageTarget {
  const ImageTarget(this.profileId, this.model);

  final String profileId;
  final String model;

  @override
  bool operator ==(Object other) =>
      other is ImageTarget && other.profileId == profileId && other.model == model;

  @override
  int get hashCode => Object.hash(profileId, model);
}

/// Which models of the active provider can draw. Providers rarely say so in `/models`, so this
/// combines what they do say with the names image models are known by.
class ImageModels {
  const ImageModels._();

  static const _nameParts = [
    'gpt-image',
    'dall-e',
    'dalle',
    'imagen',
    'flux',
    'sdxl',
    'stable-diffusion',
    'nano-banana',
    'flash-image',
    '-image-',
  ];

  /// Image models a multi-provider gateway serves without listing them. Offered only when the
  /// gateway lists other models of the same provider prefix, so a plain OpenAI key never gets a
  /// `cx/` model proposed.
  static const _gatewayKnown = [
    (prefix: 'cx/', id: 'cx/gpt-image-2'),
    (prefix: 'gemini/', id: 'gemini/gemini-3.1-flash-image-preview'),
    (prefix: 'gemini/', id: 'gemini/gemini-2.5-flash-image'),
  ];

  /// At most this many provider/model pairs are tried for one picture.
  static const maxAttempts = 5;

  static bool looksLikeImageModel(ModelInfo model) {
    if (model.generatesImages == false) return false;
    if (model.generatesImages == true) return true;
    final id = model.id.toLowerCase();
    if (id.contains('embed')) return false;
    return _nameParts.any(id.contains) || id.endsWith('-image') || id.endsWith('/image');
  }

  /// Model ids to try, best first. [preferred] goes first when the user chose one.
  static List<String> candidates(List<ModelInfo> catalog, {String? preferred}) {
    final found = <String>[];
    void add(String id) {
      if (!found.contains(id)) found.add(id);
    }

    if (preferred != null && preferred.isNotEmpty) add(preferred);
    final listed = [
      for (final m in catalog)
        if (looksLikeImageModel(m)) m.id,
    ]..sort((a, b) => _rank(a).compareTo(_rank(b)));
    listed.forEach(add);
    for (final known in _gatewayKnown) {
      if (catalog.any((m) => m.id.startsWith(known.prefix))) add(known.id);
    }
    return found;
  }

  /// The order to try for one picture across providers. [catalogs] maps a profile id to its model
  /// list, in the order providers should be searched (the active one first). Targets in [first]
  /// (the model the assistant asked for, then the one the user chose) come before everything else.
  static List<ImageTarget> plan(
    Map<String, List<ModelInfo>> catalogs, {
    List<ImageTarget> first = const [],
  }) {
    final targets = <ImageTarget>[];
    void add(ImageTarget target) {
      if (!targets.contains(target)) targets.add(target);
    }

    first.forEach(add);
    for (final entry in catalogs.entries) {
      for (final model in candidates(entry.value)) {
        add(ImageTarget(entry.key, model));
      }
    }
    return targets;
  }

  /// The target for a model the assistant named. [provider] narrows it to one provider (label or
  /// id, any case). A model counts as available when the provider lists it or it is one of the
  /// image models [candidates] knows for that provider. Null when nothing matches.
  static ImageTarget? find(
    Map<String, List<ModelInfo>> catalogs,
    Map<String, String> labels,
    String model, {
    String? provider,
  }) {
    final wantModel = model.trim().toLowerCase();
    final wantProvider = provider?.trim().toLowerCase();
    if (wantModel.isEmpty) return null;
    for (final entry in catalogs.entries) {
      final label = (labels[entry.key] ?? '').toLowerCase();
      if (wantProvider != null &&
          wantProvider.isNotEmpty &&
          wantProvider != label &&
          wantProvider != entry.key.toLowerCase()) {
        continue;
      }
      final ids = {
        for (final m in entry.value) m.id,
        ...candidates(entry.value),
      };
      for (final id in ids) {
        if (id.toLowerCase() == wantModel) return ImageTarget(entry.key, id);
      }
    }
    // A loose name such as "gemini" or "gpt image": every word must occur in an image model's id.
    final words = wantModel.split(RegExp(r'[^a-z0-9.]+')).where((w) => w.isNotEmpty).toList();
    for (final entry in catalogs.entries) {
      final label = (labels[entry.key] ?? '').toLowerCase();
      if (wantProvider != null &&
          wantProvider.isNotEmpty &&
          wantProvider != label &&
          wantProvider != entry.key.toLowerCase()) {
        continue;
      }
      for (final id in candidates(entry.value)) {
        final lower = id.toLowerCase();
        if (words.every(lower.contains)) return ImageTarget(entry.key, id);
      }
    }
    return null;
  }

  static int _rank(String id) {
    final lower = id.toLowerCase();
    if (lower.contains('gpt-image')) return 0;
    if (lower.contains('gemini') || lower.contains('imagen')) return 1;
    return 2;
  }
}
