import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/skills/skill_commands.dart';
import 'package:focus_launcher/agent/skills/skill_manager.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/agent/skills/skill_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _skillMd(String name, String description, String body) =>
    '---\nname: $name\ndescription: $description\n---\n$body';

/// A GitHub-style archive: every entry sits under `repo-main/`.
Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    final data = utf8.encode(e.value);
    archive.addFile(ArchiveFile('repo-main/${e.key}', data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, String> _repo({String betaBody = 'Beta body.\n', String betaDesc = 'Beta skill'}) => {
      'skills/alpha/SKILL.md': _skillMd('alpha', 'Alpha skill', 'Alpha body.\n'),
      'skills/beta/SKILL.md': _skillMd('beta', betaDesc, betaBody),
      'skills/beta/references/notes.md': 'Some notes.',
    };

http.Client _clientServing(Uint8List Function() zip, {Map<String, Object?>? search}) {
  return MockClient((request) async {
    if (request.url.host == 'codeload.github.com') {
      return http.Response.bytes(zip(), 200);
    }
    if (request.url.host == 'skills.sh') {
      return http.Response(jsonEncode(search ?? {'skills': []}), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('', 404);
  });
}

void main() {
  late Directory tmp;
  late Directory root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('skills_test_');
    root = Directory('${tmp.path}/skills');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('parses SKILL.md frontmatter and strips it from the body', () {
    final doc = parseSkillDocument(_skillMd('pdf-tools', 'Work with PDFs', '# Steps\nDo it.\n'));
    expect(doc, isNotNull);
    expect(doc!.name, 'pdf-tools');
    expect(doc.description, 'Work with PDFs');
    expect(doc.body, '# Steps\nDo it.\n');
  });

  test('rejects SKILL.md without a description or with broken YAML', () {
    expect(parseSkillDocument('---\nname: x\n---\nbody'), isNull);
    expect(parseSkillDocument('---\nname: [unclosed\n---\nbody'), isNull);
    expect(parseSkillDocument('no frontmatter at all'), isNull);
  });

  test('list shows the skills in a repository without installing them', () async {
    final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
    final offers = await m.list('octo/tools');
    expect(offers.map((o) => o.name), ['alpha', 'beta']);
    expect(offers.map((o) => o.path), ['skills/alpha', 'skills/beta']);
    expect(m.installed, isEmpty);
  });

  test('several skills and no choice: nothing installs, the offers come back', () async {
    final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
    await m.load();
    await expectLater(
      m.add('octo/tools'),
      throwsA(isA<SkillChoiceNeeded>().having((e) => e.offers.length, 'offers', 2)),
    );
    expect(m.installed, isEmpty);
    expect(root.existsSync(), isFalse);
  });

  test('installs one named skill, writes the lock file, and exposes it in the catalogue', () async {
    final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
    await m.load();
    final installed = await m.add('octo/tools', names: ['Beta']);
    expect(installed.map((s) => s.name), ['beta']);
    expect(installed.single.source, 'octo/tools');
    expect(File('${root.path}/beta/references/notes.md').readAsStringSync(), 'Some notes.');
    expect(File('${root.path}/beta/SKILL.md').existsSync(), isTrue);

    final lock = jsonDecode(File('${root.path}/skills-lock.json').readAsStringSync()) as Map<String, dynamic>;
    final entry = (lock['skills'] as Map)['beta'] as Map<String, dynamic>;
    expect(entry['source'], 'octo/tools');
    expect(entry['skillPath'], 'skills/beta');
    expect(entry['contentHash'], isA<String>());

    expect(m.catalogue(), '- beta: Beta skill');
    expect(m.bodyOf('beta'), 'Beta body.\n');
  });

  test('`@skill` in the source selects the skill; `all` installs every skill', () async {
    final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
    await m.load();
    final one = await m.add('octo/tools@alpha');
    expect(one.map((s) => s.name), ['alpha']);
    await m.add('octo/tools', all: true);
    expect(m.installed.map((s) => s.name), ['alpha', 'beta']);
    expect(m.catalogue(), '- alpha: Alpha skill\n- beta: Beta skill');
  });

  test('a single skill installs without a choice', () async {
    final single = {'SKILL.md': _skillMd('solo', 'Only one', 'Body.\n')};
    final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(single)));
    await m.load();
    final out = await m.add('octo/tools');
    expect(out.map((s) => s.name), ['solo']);
  });

  test('a direct SKILL.md link installs one skill', () async {
    final client = MockClient((request) async {
      return http.Response(_skillMd('my-skill', 'From a link', 'Hi.\n'), 200);
    });
    final m = SkillManager(root: root, httpClient: client);
    await m.load();
    final out = await m.add('https://example.com/skills/my-skill/SKILL.md');
    expect(out.single.name, 'my-skill');
    expect(out.single.source, 'https://example.com/skills/my-skill/SKILL.md');
  });

  test('update reinstalls only when the source changed; check reports it first', () async {
    var current = _zip(_repo());
    final m = SkillManager(root: root, httpClient: _clientServing(() => current));
    await m.load();
    await m.add('octo/tools', names: ['beta']);
    expect(await m.check(), isEmpty);

    current = _zip(_repo(betaBody: 'New beta body.\n', betaDesc: 'Beta v2'));
    expect(await m.check(), ['beta']);

    final updated = await m.update();
    expect(updated.map((s) => s.name), ['beta']);
    expect(m.bodyOf('beta'), 'New beta body.\n');
    expect(m.installed.single.description, 'Beta v2');
    expect(await m.check(), isEmpty);
    expect(await m.update(), isEmpty);
  });

  test('remove deletes the folder and the lock entry, and survives a reload', () async {
    final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
    await m.load();
    await m.add('octo/tools', all: true);
    await m.remove('beta');
    expect(Directory('${root.path}/beta').existsSync(), isFalse);

    final reloaded = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
    await reloaded.load();
    expect(reloaded.installed.map((s) => s.name), ['alpha']);
    await expectLater(reloaded.remove('../etc'), throwsA(isA<SkillException>()));
  });

  test('a path that climbs out of the archive is refused and nothing is installed', () async {
    final evil = _zip({'../evil/SKILL.md': _skillMd('evil', 'Bad', 'x')});
    final m = SkillManager(root: root, httpClient: _clientServing(() => evil));
    await m.load();
    await expectLater(
      m.add('octo/tools'),
      throwsA(isA<SkillException>().having((e) => e.message, 'message', contains('unsafe'))),
    );
    expect(m.installed, isEmpty);
  });

  test('downloads above 10 MiB are refused', () async {
    final client = MockClient((request) async => http.Response.bytes(Uint8List(11 * 1024 * 1024), 200));
    final m = SkillManager(root: root, httpClient: client);
    await m.load();
    await expectLater(
      m.add('octo/tools'),
      throwsA(isA<SkillException>().having((e) => e.message, 'message', contains('10 MiB'))),
    );
  });

  test('content that declares more than 25 MiB is refused before it is read', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('repo-main/SKILL.md', _skillMd('big', 'Big', 'x')))
      ..addFile(ArchiveFile('repo-main/data.bin', 26 * 1024 * 1024, Uint8List(26 * 1024 * 1024)));
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));
    final m = SkillManager(root: root, httpClient: _clientServing(() => zip));
    await m.load();
    await expectLater(
      m.add('octo/tools'),
      throwsA(isA<SkillException>().having((e) => e.message, 'message', contains('25 MiB'))),
    );
  });

  test('readFile returns skill files and refuses paths outside the folder', () async {
    final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
    await m.load();
    await m.add('octo/tools', names: ['beta']);
    expect(await m.readFile('beta', 'references/notes.md'), 'Some notes.');
    expect(await m.readFile('beta', 'references/missing.md'), isNull);
    expect(await m.readFile('nope', 'SKILL.md'), isNull);
    await expectLater(m.readFile('beta', '../alpha/SKILL.md'), throwsA(isA<SkillException>()));
    await expectLater(m.readFile('beta', '/etc/passwd'), throwsA(isA<SkillException>()));
  });

  test('a damaged lock file stops changes instead of overwriting it', () async {
    root.createSync(recursive: true);
    File('${root.path}/skills-lock.json').writeAsStringSync('{not json');
    final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
    await expectLater(m.load(), throwsA(isA<SkillException>()));
    expect(File('${root.path}/skills-lock.json').readAsStringSync(), '{not json');
  });

  group('chat commands', () {
    SkillCommands commandsFor(SkillManager m) => SkillCommands(m);

    test('recognises the command forms', () {
      expect(SkillCommands.matches('npx skills add owner/repo'), isTrue);
      expect(SkillCommands.matches('skills ls'), isTrue);
      expect(SkillCommands.matches('/skills find react'), isTrue);
      expect(SkillCommands.matches('skillset add'), isFalse);
      expect(SkillCommands.matches('please run skills add'), isFalse);
    });

    test('add --list shows offers; plain add asks for --all or --skill', () async {
      final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
      await m.load();
      final c = commandsFor(m);
      final listed = await c.run('skills add octo/tools --list');
      expect(listed, contains('**alpha**'));
      expect(listed, contains('**beta**'));

      final asked = await c.run('npx skills add octo/tools');
      expect(asked, contains('--all'));
      expect(asked, contains('--skill <name>'));
      expect(m.installed, isEmpty);
    });

    test('add with --skill and a quoted name, then ls and remove', () async {
      final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
      await m.load();
      final c = commandsFor(m);
      final added = await c.run('skills add octo/tools --skill "Beta"');
      expect(added, startsWith('Installed 1 skill from `octo/tools`'));
      expect(added, contains('**beta**'));

      expect(await c.run('skills ls'), contains('**beta**'));
      expect(await c.run('skills remove beta'), 'Removed skill: beta.');
      expect(await c.run('skills ls'), startsWith('No skills installed'));
    });

    test('check and update report in plain words', () async {
      var current = _zip(_repo());
      final m = SkillManager(root: root, httpClient: _clientServing(() => current));
      await m.load();
      final c = commandsFor(m);
      await c.run('skills add octo/tools --all');
      expect(await c.run('skills check'), 'All installed skills are up to date.');

      current = _zip(_repo(betaBody: 'changed\n'));
      expect(await c.run('skills check'), contains('Updates available for: beta.'));
      expect(await c.run('skills update'), 'Updated 1 skill: beta.');
    });

    test('find prints the skills.sh results like the CLI', () async {
      final m = SkillManager(
        root: root,
        httpClient: _clientServing(
          () => _zip(_repo()),
          search: {
            'skills': [
              {'id': 'octo/tools/beta', 'name': 'beta', 'installs': 1500, 'source': 'octo/tools'},
            ],
          },
        ),
      );
      await m.load();
      final out = await commandsFor(m).run('skills find beta');
      expect(out, contains('`octo/tools@beta`'));
      expect(out, contains('1.5K installs'));
      expect(out, contains('https://skills.sh/octo/tools/beta'));
      expect(await commandsFor(m).run('skills find'), contains('Usage'));
    });

    test('bad input gets a readable answer', () async {
      final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
      await m.load();
      final c = commandsFor(m);
      expect(await c.run('skills add "unterminated'), contains('quote'));
      expect(await c.run('skills bogus'), contains('Unknown command'));
      expect(await c.run('skills add octo/tools --frobnicate'), contains('Unknown option'));
      expect(await c.run('skills'), contains('Skill commands'));
    });
  });

  group('agent tools', () {
    test('no tools until a skill is installed; then load and read-file', () async {
      final m = SkillManager(root: root, httpClient: _clientServing(() => _zip(_repo())));
      await m.load();
      final tools = SkillTools(m);
      expect(tools.tools, isEmpty);

      await m.add('octo/tools', names: ['beta']);
      expect(tools.tools.map((t) => t.name), ['skill_load', 'skill_read_file']);
      expect(tools.tools.every((t) => t.risk == ToolRisk.read), isTrue);

      final load = tools.tools.firstWhere((t) => t.name == 'skill_load');
      final loaded = await load.run({'name': 'beta'});
      expect(loaded.isError, isFalse);
      expect(loaded.text, startsWith('# beta'));
      expect(loaded.text, contains('Beta body.'));
      expect((await load.run({'name': 'gamma'})).isError, isTrue);

      final read = tools.tools.firstWhere((t) => t.name == 'skill_read_file');
      expect((await read.run({'name': 'beta', 'path': 'references/notes.md'})).text, 'Some notes.');
      expect((await read.run({'name': 'beta', 'path': '../alpha/SKILL.md'})).isError, isTrue);
    });
  });
}
