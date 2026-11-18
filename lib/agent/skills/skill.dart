import 'package:yaml/yaml.dart';

/// An installed skill: a folder with a `SKILL.md`, used as prompt text only.
class Skill {
  const Skill({
    required this.name,
    required this.description,
    required this.source,
    required this.dir,
    this.ref,
  });

  /// The installed name: the folder name and the key in the lock file.
  final String name;
  final String description;

  /// `owner/repo` for GitHub, or the download URL.
  final String source;

  /// Branch, tag or commit the skill was installed from, when pinned.
  final String? ref;

  /// Absolute path of the skill folder.
  final String dir;
}

/// A skill found in a source but not installed.
class SkillOffer {
  const SkillOffer({required this.name, required this.description, required this.path, this.url});

  final String name;
  final String description;

  /// Folder inside the repository (`skills/foo`, empty for the root). For `find` results: `owner/repo`.
  final String path;

  /// The skills.sh page, for `find` results.
  final String? url;
}

/// A failure the person should read.
class SkillException implements Exception {
  const SkillException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The source holds several skills and none was chosen. Install with names or `all`.
class SkillChoiceNeeded extends SkillException {
  const SkillChoiceNeeded(this.source, this.offers)
      : super('The source has several skills; choose which to install.');

  final String source;
  final List<SkillOffer> offers;
}

/// A parsed `SKILL.md`: frontmatter `name` and `description`, and the markdown body.
class SkillDocument {
  const SkillDocument({required this.name, required this.description, required this.body});

  final String name;
  final String description;
  final String body;
}

final _frontmatter = RegExp(r'^\uFEFF?---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$');

/// Returns null when the frontmatter is missing, unparseable, or lacks a non-empty name or description.
SkillDocument? parseSkillDocument(String raw) {
  final match = _frontmatter.firstMatch(raw);
  if (match == null) return null;
  final Object? data;
  try {
    data = loadYaml(match.group(1)!);
  } on YamlException {
    return null;
  }
  if (data is! YamlMap) return null;
  final name = data['name'];
  final description = data['description'];
  if (name is! String || description is! String) return null;
  final cleanName = name.trim();
  final cleanDescription = description.trim();
  if (cleanName.isEmpty || cleanDescription.isEmpty) return null;
  return SkillDocument(
    name: cleanName,
    description: cleanDescription,
    body: match.group(2)!.trimLeft(),
  );
}
