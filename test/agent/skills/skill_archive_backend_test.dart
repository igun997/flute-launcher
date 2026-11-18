import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/skills/skill_archive_backend.dart';
import 'package:focus_launcher/agent/skills/skill_manager.dart';
import 'package:focus_launcher/rust/rust_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _betaMd = '---\nname: beta\ndescription: Beta skill\n---\nBeta body.\n';

/// A GitHub-style archive as stored: every entry under `repo-main/`.
Map<String, String> _repoFiles() => {
      'repo-main/skills/beta/SKILL.md': _betaMd,
      'repo-main/skills/beta/references/notes.md': 'Notes.',
    };

Map<String, Uint8List> _bytesOf(Map<String, String> files) => {
      for (final e in files.entries) e.key: Uint8List.fromList(utf8.encode(e.value)),
    };

Uint8List _zipOf(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.string(e.key, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

http.Client _client(Uint8List zip) => MockClient((request) async {
      if (request.url.host == 'codeload.github.com') return http.Response.bytes(zip, 200);
      return http.Response('', 404);
    });

Future<RawArchive> Function(Uint8List) _serve(RawArchive raw) => (_) async => raw;

String _lockHash(Directory root, String name) {
  final data = jsonDecode(File('${root.path}/skills-lock.json').readAsStringSync()) as Map<String, dynamic>;
  return ((data['skills'] as Map)[name] as Map)['contentHash'] as String;
}

/// Hands the manager whatever [unzipWith] returns (or the Dart backend's result) and counts calls.
class _FakeArchives implements SkillArchiveBackend {
  _FakeArchives({this.unzipWith});

  final Future<RawArchive> Function(Uint8List zip)? unzipWith;
  final SkillArchiveBackend _dart = const DartSkillArchiveBackend();
  int unzips = 0;
  int hashes = 0;

  @override
  Future<RawArchive> unzip(Uint8List zip) {
    unzips++;
    return unzipWith?.call(zip) ?? _dart.unzip(zip);
  }

  @override
  Future<String> sha256(Uint8List data) {
    hashes++;
    return _dart.sha256(data);
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('skill_backend_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the default backend is Dart while the Rust core is not started', () {
    expect(RustCore.instance.isStarted, isFalse);
    expect(SkillArchiveBackend.defaultBackend(), isA<DartSkillArchiveBackend>());
  });

  test('the Dart backend hashes with plain sha256', () async {
    expect(
      await const DartSkillArchiveBackend().sha256(Uint8List.fromList(utf8.encode('abc'))),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('unzip keeps the names stored in the archive', () async {
    final raw = await const DartSkillArchiveBackend().unzip(_zipOf(_repoFiles()));
    expect(raw.files.keys.toSet(), _repoFiles().keys.toSet());
    expect(raw.symlinks, isEmpty);
  });

  test('the manager unpacks and hashes through the injected backend, with the same lock hash', () async {
    final zip = _zipOf(_repoFiles());
    final fake = _FakeArchives();
    final withFake = SkillManager(
      root: Directory('${tmp.path}/fake'),
      httpClient: _client(zip),
      archives: fake,
    );
    await withFake.load();
    await withFake.add('octo/tools', names: ['beta']);
    expect(fake.unzips, greaterThan(0));
    expect(fake.hashes, greaterThan(0));

    final plain = SkillManager(
      root: Directory('${tmp.path}/plain'),
      httpClient: _client(zip),
      archives: const DartSkillArchiveBackend(),
    );
    await plain.load();
    await plain.add('octo/tools', names: ['beta']);
    expect(_lockHash(Directory('${tmp.path}/fake'), 'beta'), _lockHash(Directory('${tmp.path}/plain'), 'beta'));
  });

  test('check goes through the backend for hashing', () async {
    final raw = RawArchive(_bytesOf(_repoFiles()), {});
    final fake = _FakeArchives(unzipWith: _serve(raw));
    final m = SkillManager(root: Directory('${tmp.path}/skills'), httpClient: _client(Uint8List(0)), archives: fake);
    await m.load();
    await m.add('octo/tools', names: ['beta']);
    final before = fake.hashes;
    expect(await m.check(), isEmpty);
    expect(fake.hashes, greaterThan(before));
  });

  test('a traversal name returned by a backend is refused by the policy', () async {
    final raw = RawArchive({...(_bytesOf(_repoFiles())), 'repo-main/../evil.md': Uint8List(1)}, {});
    final m = SkillManager(
      root: Directory('${tmp.path}/skills'),
      httpClient: _client(Uint8List(0)),
      archives: _FakeArchives(unzipWith: _serve(raw)),
    );
    await m.load();
    await expectLater(
      m.add('octo/tools', names: ['beta']),
      throwsA(isA<SkillException>().having((e) => e.message, 'message', contains('unsafe path'))),
    );
  });

  test('a symbolic link inside the skill folder is refused whatever the backend returns', () async {
    final raw = RawArchive(_bytesOf(_repoFiles()), {'repo-main/skills/beta/link'});
    final m = SkillManager(
      root: Directory('${tmp.path}/skills'),
      httpClient: _client(Uint8List(0)),
      archives: _FakeArchives(unzipWith: _serve(raw)),
    );
    await m.load();
    await expectLater(
      m.add('octo/tools', names: ['beta']),
      throwsA(isA<SkillException>().having((e) => e.message, 'message', contains('symbolic link'))),
    );
  });

  test('a symbolic link outside the skill folder is set aside and the install succeeds', () async {
    final raw = RawArchive(_bytesOf(_repoFiles()), {'repo-main/other/link'});
    final m = SkillManager(
      root: Directory('${tmp.path}/skills'),
      httpClient: _client(Uint8List(0)),
      archives: _FakeArchives(unzipWith: _serve(raw)),
    );
    await m.load();
    final installed = await m.add('octo/tools', names: ['beta']);
    expect(installed.map((s) => s.name), ['beta']);
  });

  test('backslash names from a backend are normalised before the top folder is removed', () async {
    final raw = RawArchive(
      _bytesOf({
        'repo-main\\skills\\beta\\SKILL.md': _betaMd,
      }),
      {},
    );
    final m = SkillManager(
      root: Directory('${tmp.path}/skills'),
      httpClient: _client(Uint8List(0)),
      archives: _FakeArchives(unzipWith: _serve(raw)),
    );
    await m.load();
    final installed = await m.add('octo/tools', names: ['beta']);
    expect(installed.map((s) => s.name), ['beta']);
  });

  test('more than 1000 entries from a backend are refused', () async {
    final raw = RawArchive(_bytesOf(_repoFiles()), {for (var i = 0; i < 1001; i++) 'repo-main/l$i'});
    final m = SkillManager(
      root: Directory('${tmp.path}/skills'),
      httpClient: _client(Uint8List(0)),
      archives: _FakeArchives(unzipWith: _serve(raw)),
    );
    await m.load();
    await expectLater(
      m.add('octo/tools', names: ['beta']),
      throwsA(isA<SkillException>().having((e) => e.message, 'message', contains('more than 1000'))),
    );
  });

  test('content over 25 MiB from a backend is refused', () async {
    final files = {
      ..._bytesOf(_repoFiles()),
      'repo-main/skills/beta/big.bin': Uint8List(26 * 1024 * 1024),
    };
    final m = SkillManager(
      root: Directory('${tmp.path}/skills'),
      httpClient: _client(Uint8List(0)),
      archives: _FakeArchives(unzipWith: _serve(RawArchive(files, {}))),
    );
    await m.load();
    await expectLater(
      m.add('octo/tools', names: ['beta']),
      throwsA(isA<SkillException>().having((e) => e.message, 'message', contains('25 MiB'))),
    );
  });
}
