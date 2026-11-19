import '../llm/model_info.dart';

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

  /// At most this many models are tried for one picture.
  static const maxAttempts = 3;

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

  static int _rank(String id) {
    final lower = id.toLowerCase();
    if (lower.contains('gpt-image')) return 0;
    if (lower.contains('gemini') || lower.contains('imagen')) return 1;
    return 2;
  }
}
