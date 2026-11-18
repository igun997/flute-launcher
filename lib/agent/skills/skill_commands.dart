import 'skill_manager.dart';

/// Runs `npx skills`-style commands typed in the chat and returns markdown for the reply.
///
/// Supported: `add`, `list|ls`, `find|search`, `check`, `update`, `remove|rm`, `help`.
/// Flags: `-s/--skill`, `-l/--list`, `--all`, `--owner` (find), and `-y`, `-g`, `--copy`, `-a` (accepted, no effect).
class SkillCommands {
  SkillCommands(this._skills);

  final SkillManager _skills;

  static final _prefix = RegExp(r'^\s*(?:npx\s+(?:-y\s+)?skills(?:@\S+)?|skills|/skills)(?=\s|$)');

  /// True for `npx skills ...`, `skills ...` and `/skills ...`.
  static bool matches(String input) => _prefix.hasMatch(input);

  Future<String> run(String input) async {
    try {
      final tokens = _tokenize(input.replaceFirst(_prefix, ''));
      final args = _parse(tokens);
      switch (args.command) {
        case 'add':
          return await _add(args);
        case 'list':
        case 'ls':
          return _listInstalled();
        case 'find':
        case 'search':
          return await _find(args);
        case 'check':
          return await _check();
        case 'update':
          return await _update(args.positional);
        case 'remove':
        case 'rm':
          return await _remove(args);
        case 'help':
          return _help;
        case 'init':
        case 'use':
        case 'sync':
        case 'experimental_sync':
          return 'The `${args.command}` command is not available in Flute. Use `skills add`, `skills find`, `skills update` or `skills remove`.';
        default:
          return 'Unknown command `${args.command}`.\n\n$_help';
      }
    } on SkillChoiceNeeded catch (e) {
      return _choice(e);
    } on SkillException catch (e) {
      return 'Could not finish: ${e.message}';
    } catch (e) {
      return 'Could not finish: $e';
    }
  }

  // ---- commands ----

  Future<String> _add(_Args args) async {
    if (args.positional.isEmpty) return 'Give a source, such as `skills add owner/repo`.';
    if (args.positional.length > 1) {
      return 'Use one source at a time. To pick skills by name, use `--skill <name>`.';
    }
    final source = args.positional.first;
    if (args.list) {
      final offers = await _skills.list(source);
      return _offers(offers, 'Skills in `$source`');
    }
    final installed = await _skills.add(source, names: args.skills, all: args.all);
    final buffer = StringBuffer('Installed ${installed.length} skill${installed.length == 1 ? '' : 's'} from `$source`:\n\n');
    for (final s in installed) {
      buffer.writeln('- **${s.name}**: ${s.description}');
    }
    buffer.write('\nThe agent can use them from now on.');
    return buffer.toString();
  }

  String _choice(SkillChoiceNeeded e) {
    final source = e.source;
    final buffer = StringBuffer(_offers(e.offers, 'Found ${e.offers.length} skills in `$source`'));
    buffer
      ..writeln()
      ..writeln()
      ..writeln('Nothing was installed yet. Install all with `skills add $source --all`, or pick by name with `skills add $source --skill <name>`.');
    return buffer.toString();
  }

  String _listInstalled() {
    final list = _skills.installed;
    if (list.isEmpty) {
      return 'No skills installed. Find some with `skills find <topic>` or add one with `skills add owner/repo`.';
    }
    return 'Installed skills (${list.length}):\n\n'
        '${list.map((s) => '- **${s.name}**: ${s.description} (`${s.source}`)').join('\n')}';
  }

  Future<String> _find(_Args args) async {
    final query = args.positional.join(' ');
    if (query.isEmpty) return 'Usage: `skills find <query>`';
    final offers = await _skills.find(query, owner: args.owner);
    if (offers.isEmpty) return 'No skills found for "$query".';
    final buffer = StringBuffer('Install with `skills add <owner/repo@skill>`\n\n');
    for (final o in offers) {
      final id = o.path.isEmpty ? o.name : '${o.path}@${o.name}';
      final installs = o.description.isEmpty ? '' : ' · ${o.description}';
      buffer.writeln('- `$id`$installs');
      if (o.url != null) buffer.writeln('  ${o.url}');
    }
    return buffer.toString();
  }

  Future<String> _check() async {
    final outdated = await _skills.check();
    if (outdated.isEmpty) return 'All installed skills are up to date.';
    return 'Updates available for: ${outdated.join(', ')}.\n\nRun `skills update` to install them.';
  }

  Future<String> _update(List<String> names) async {
    final updated = await _skills.update(names);
    if (updated.isEmpty) return 'Everything is up to date.';
    return 'Updated ${updated.length} skill${updated.length == 1 ? '' : 's'}: '
        '${updated.map((s) => s.name).join(', ')}.';
  }

  Future<String> _remove(_Args args) async {
    final names = args.all ? _skills.installed.map((s) => s.name).toList() : args.positional;
    if (names.isEmpty) {
      return 'Name the skills to remove, such as `skills remove <name>`, or use `skills remove --all`.';
    }
    for (final name in names) {
      await _skills.remove(name);
    }
    return 'Removed ${names.length == 1 ? 'skill' : '${names.length} skills'}: ${names.join(', ')}.';
  }

  static String _offers(List<SkillOffer> offers, String heading) {
    final buffer = StringBuffer('$heading:\n\n');
    for (final o in offers) {
      buffer.writeln('- **${o.name}**: ${o.description}');
    }
    return buffer.toString().trimRight();
  }

  static const _help = '''Skill commands (type them in the chat):

- `skills add owner/repo` installs the skills in a GitHub repository
- `skills add owner/repo --list` lists them without installing
- `skills add owner/repo --skill <name>` or `--all` picks which to install
- `skills add owner/repo@<name>` or `owner/repo#<branch-or-tag>` picks a skill or a version
- `skills find <query> [--owner <owner>]` searches skills.sh
- `skills list` shows installed skills
- `skills check` and `skills update [name...]` look for newer versions
- `skills remove <name...>` or `skills remove --all` removes skills''';

  // ---- parsing ----

  static List<String> _tokenize(String input) {
    final out = <String>[];
    final buf = StringBuffer();
    var inToken = false;
    String? quote;
    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else {
          buf.write(c);
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        inToken = true;
        continue;
      }
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        if (inToken) {
          out.add(buf.toString());
          buf.clear();
          inToken = false;
        }
        continue;
      }
      buf.write(c);
      inToken = true;
    }
    if (quote != null) throw const SkillException('A quote is not closed.');
    if (inToken) out.add(buf.toString());
    return out;
  }

  static _Args _parse(List<String> tokens) {
    final command = tokens.isEmpty ? 'help' : tokens.first;
    final rest = tokens.isEmpty ? <String>[] : tokens.sublist(1);
    final args = _Args(command);
    var i = 0;
    while (i < rest.length) {
      final t = rest[i];
      switch (t) {
        case '-s':
        case '--skill':
          args.skills.add(_valueAfter(rest, i));
          i++;
        case '-l':
        case '--list':
          args.list = true;
        case '--all':
          args.all = true;
        case '--owner':
          args.owner = _valueAfter(rest, i);
          i++;
        case '-a':
        case '--agent':
          _valueAfter(rest, i);
          i++;
        case '-y':
        case '--yes':
        case '-g':
        case '--global':
        case '--copy':
          break;
        case '-h':
        case '--help':
          return _Args('help');
        default:
          if (t.startsWith('-') && t.length > 1) throw SkillException('Unknown option $t.');
          args.positional.add(t);
      }
      i++;
    }
    return args;
  }

  static String _valueAfter(List<String> tokens, int flagIndex) {
    if (flagIndex + 1 >= tokens.length) throw SkillException('${tokens[flagIndex]} needs a value.');
    return tokens[flagIndex + 1];
  }
}

class _Args {
  _Args(this.command);

  final String command;
  final List<String> positional = [];
  final List<String> skills = [];
  bool list = false;
  bool all = false;
  String? owner;
}
