import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'skill.dart';
import 'skill_archive_backend.dart';

export 'skill.dart';

const _maxDownloadBytes = 10 * 1024 * 1024;
const _maxFileReadBytes = 64 * 1024;
const _lockName = 'skills-lock.json';
const _timeout = Duration(seconds: 60);
const _skipDirs = {'node_modules', '.git', 'dist', 'build', '__pycache__'};

/// Installs skills from GitHub archives and direct links, `npx skills`-style, and keeps them
/// in one folder with a lock file. Skills are prompt text: nothing in them is ever executed.
class SkillManager extends ChangeNotifier {
  SkillManager({
    required Directory root,
    http.Client? httpClient,
    String? Function()? githubToken,
    SkillArchiveBackend? archives,
  })  : root = root,
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _githubToken = githubToken,
        _archives = archives;

  /// `<app support>/skills`.
  static Future<SkillManager> open({http.Client? httpClient}) async {
    final support = await getApplicationSupportDirectory();
    return SkillManager(
      root: Directory('${support.path}/skills'),
      httpClient: httpClient,
    );
  }

  final Directory root;
  final http.Client _http;
  final bool _ownsHttp;
  final String? Function()? _githubToken;
  final SkillArchiveBackend? _archives;
  SkillArchiveBackend get _backend => _archives ?? SkillArchiveBackend.defaultBackend();

  final Map<String, _LockEntry> _lock = {};
  final Map<String, Skill> _installed = {};
  final Map<String, String> _bodies = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _loaded = false;
  Future<void> _queue = Future<void>.value();

  /// Fires after the installed list or a skill changes.
  Stream<void> get changes => _changes.stream;

  List<Skill> get installed {
    final list = _installed.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(list);
  }

  /// Reads the lock file and the installed skills. Safe to call again.
  Future<void> load() async {
    _lock.clear();
    _installed.clear();
    _bodies.clear();
    final file = File('${root.path}/$_lockName');
    if (await file.exists()) {
      try {
        final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final skills = (data['skills'] as Map?) ?? const {};
        for (final e in skills.entries) {
          _lock[e.key as String] = _LockEntry.fromJson(e.value as Map<String, dynamic>);
        }
      } catch (_) {
        // Refuse to write over a lock file we cannot read: that would drop every entry.
        throw const SkillException('The skills lock file is damaged, so skills cannot be changed. Remove skills-lock.json to start over.');
      }
    }
    for (final entry in _lock.entries) {
      final dir = '${root.path}/${entry.key}';
      final bytes = await _readIfExists('$dir/SKILL.md');
      if (bytes == null) continue;
      final doc = parseSkillDocument(utf8.decode(bytes, allowMalformed: true));
      if (doc == null) continue;
      _installed[entry.key] = Skill(
        name: entry.key,
        description: doc.description,
        source: entry.value.source,
        ref: entry.value.ref,
        dir: dir,
      );
      _bodies[entry.key] = doc.body;
    }
    _loaded = true;
    _notify();
  }

  /// Offers in a source, without installing anything.
  Future<List<SkillOffer>> list(String source) async {
    final s = _parseSource(source);
    final fetched = await _fetch(s);
    final found = _discover(fetched.files, s.subpath);
    if (found.isEmpty) throw SkillException('No skills found in ${s.display}.');
    return [for (final x in found) SkillOffer(name: x.name, description: x.description, path: x.dir)];
  }

  /// Installs skills from [source]. With several skills, no [names] and not [all], throws
  /// [SkillChoiceNeeded] with the offers and installs nothing.
  Future<List<Skill>> add(String source, {List<String> names = const [], bool all = false}) =>
      _locked(() async {
        final s = _parseSource(source);
        final wanted = [...names, ...s.skillNames];
        final fetched = await _fetch(s, resolveCommit: true);
        final found = _discover(fetched.files, s.subpath);
        if (found.isEmpty) throw SkillException('No skills found in ${s.display}.');

        final List<_Found> chosen;
        if (all || wanted.contains('*')) {
          chosen = found;
        } else if (wanted.isNotEmpty) {
          chosen = _select(found, wanted, s.display);
        } else if (found.length == 1) {
          chosen = found;
        } else {
          throw SkillChoiceNeeded(s.display, [
            for (final x in found) SkillOffer(name: x.name, description: x.description, path: x.dir),
          ]);
        }

        final installed = <Skill>[];
        for (final x in chosen) {
          installed.add(await _install(x, fetched, x.installName!));
        }
        return installed;
      });

  /// Searches skills.sh, the same index as `npx skills find`.
  Future<List<SkillOffer>> find(String query, {String? owner}) async {
    final q = query.trim();
    if (q.isEmpty) throw const SkillException('Type what to search for, such as "react".');
    final uri = Uri.https('skills.sh', '/api/search', {
      'q': q,
      if (owner != null && owner.isNotEmpty) 'owner': owner,
    });
    final http.Response response;
    try {
      response = await _http.get(uri).timeout(_timeout);
    } on TimeoutException {
      throw const SkillException('skills.sh did not answer in time.');
    } on Exception {
      throw const SkillException('Could not reach skills.sh.');
    }
    if (response.statusCode != 200) {
      throw SkillException('skills.sh search failed (HTTP ${response.statusCode}).');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = ((data['skills'] as List?) ?? const []).whereType<Map>();
    return [
      for (final m in items)
        if (_clean(m['name']).isNotEmpty)
          SkillOffer(
            name: _clean(m['name']),
            description: _formatInstalls(m['installs']),
            path: _clean(m['source']),
            url: 'https://skills.sh/${_clean(m['id'])}',
          ),
    ];
  }

  /// Names of installed skills whose source has a different content hash.
  Future<List<String>> check() => _locked(() async {
        final cache = <String, _Fetched>{};
        final outdated = <String>[];
        for (final entry in _lock.entries) {
          final fetched = await _fetchFor(entry.value, cache, resolveCommit: false);
          final x = _loadFound(fetched.files, entry.value.skillPath, entry.key);
          if (x == null) {
            throw SkillException('${entry.key} is no longer in ${entry.value.source}.');
          }
          if ((await _hashFiles(_filesUnder(fetched.files, x.dir))) != entry.value.contentHash) {
            outdated.add(entry.key);
          }
        }
        return outdated;
      });

  /// Reinstalls skills whose source changed. [names] limits the update; empty means all.
  Future<List<Skill>> update([List<String> names = const []]) => _locked(() async {
        for (final n in names) {
          if (!_lock.containsKey(n)) throw SkillException('No installed skill named $n.');
        }
        final targets = names.isEmpty ? _lock.keys.toList() : names;
        final cache = <String, _Fetched>{};
        final updated = <Skill>[];
        for (final name in targets) {
          final entry = _lock[name]!;
          final fetched = await _fetchFor(entry, cache, resolveCommit: true);
          final x = _loadFound(fetched.files, entry.skillPath, name);
          if (x == null) throw SkillException('$name is no longer in ${entry.source}.');
          final hash = await _hashFiles(_filesUnder(fetched.files, x.dir));
          if (hash == entry.contentHash && Directory('${root.path}/$name').existsSync()) continue;
          updated.add(await _install(x, fetched, name));
        }
        return updated;
      });

  Future<void> remove(String name) => _locked(() async {
        if (installNameFor(name) != name || !_lock.containsKey(name)) {
          throw SkillException('No installed skill named $name.');
        }
        final dir = Directory('${root.path}/$name');
        if (await dir.exists()) await dir.delete(recursive: true);
        _lock.remove(name);
        await _saveLock();
        _installed.remove(name);
        _bodies.remove(name);
        _notify();
      });

  /// `- name: description` lines for the system prompt, or '' when nothing is installed.
  String catalogue() {
    if (_installed.isEmpty) return '';
    return installed.map((s) => '- ${s.name}: ${_oneLine(s.description, 300)}').join('\n');
  }

  /// The SKILL.md body without frontmatter, or null when the skill is not installed.
  String? bodyOf(String name) => _bodies[name];

  /// A file inside an installed skill, by a relative path. At most 64 KB. Null when missing.
  /// Throws [SkillException] for paths that leave the skill folder.
  Future<String?> readFile(String name, String relativePath) async {
    final skill = _installed[name];
    if (skill == null) return null;
    final rel = _safeRelative(relativePath);
    final file = File('${skill.dir}/$rel');
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
      return null;
    }
    final skillRoot = await Directory(skill.dir).resolveSymbolicLinks();
    final resolved = await file.resolveSymbolicLinks();
    if (!resolved.startsWith('$skillRoot/')) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, _maxFileReadBytes + 1)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    final truncated = bytes.length > _maxFileReadBytes;
    final text = utf8.decode(
      truncated ? bytes.sublist(0, _maxFileReadBytes) : bytes,
      allowMalformed: true,
    );
    return truncated ? '$text\n...(truncated)' : text;
  }

  @override
  void dispose() {
    unawaited(_changes.close());
    if (_ownsHttp) _http.close();
    super.dispose();
  }

  // ---- queue and state ----

  Future<T> _locked<T>(Future<T> Function() op) {
    final run = _queue.then((_) async {
      if (!_loaded) await load();
      return op();
    });
    _queue = run.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return run;
  }

  void _notify() {
    notifyListeners();
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _saveLock() async {
    await root.create(recursive: true);
    final file = File('${root.path}/$_lockName');
    final tmp = File('${file.path}.tmp');
    final data = {
      'version': 1,
      'skills': {for (final e in _lock.entries) e.key: e.value.toJson()},
    };
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);
    await tmp.rename(file.path);
  }

  Future<Skill> _install(_Found x, _Fetched fetched, String installName) async {
    final files = _filesUnder(fetched.files, x.dir);
    if (fetched.symlinks.any((l) => x.dir.isEmpty || l == x.dir || l.startsWith('${x.dir}/'))) {
      throw SkillException('${x.name} contains a symbolic link, which is not allowed.');
    }
    final hash = await _hashFiles(files);
    final target = Directory('${root.path}/$installName');
    final staging = Directory('${root.path}/.staging-${Uuid().v4()}');
    await staging.create(recursive: true);
    try {
      for (final e in files.entries) {
        final file = File('${staging.path}/${e.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(e.value, flush: true);
      }
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final previous = _lock[installName];
    _lock[installName] = _LockEntry(
      source: fetched.source,
      sourceType: fetched.sourceType,
      sourceUrl: fetched.sourceUrl,
      ref: fetched.ref,
      commit: fetched.commit,
      skillPath: x.dir,
      contentHash: hash,
      installedAt: previous?.installedAt ?? now,
      updatedAt: now,
    );
    await _saveLock();
    final skill = Skill(
      name: installName,
      description: x.description,
      source: fetched.source,
      ref: fetched.ref,
      dir: target.path,
    );
    _installed[installName] = skill;
    _bodies[installName] = x.body;
    _notify();
    return skill;
  }

  List<_Found> _select(List<_Found> found, List<String> wanted, String display) {
    final picked = <_Found>[];
    final missing = <String>[];
    for (final w in wanted) {
      final key = w.trim().toLowerCase();
      final hits = found.where((x) => x.name.toLowerCase() == key || x.installName == installNameFor(w));
      if (hits.isEmpty) {
        missing.add(w);
      } else {
        for (final h in hits) {
          if (!picked.contains(h)) picked.add(h);
        }
      }
    }
    if (missing.isNotEmpty) {
      throw SkillException(
        'No skill named ${missing.join(', ')} in $display. Available: ${found.map((x) => x.name).join(', ')}.',
      );
    }
    return picked;
  }

  Future<_Fetched> _fetchFor(_LockEntry entry, Map<String, _Fetched> cache, {required bool resolveCommit}) {
    final key = '${entry.sourceUrl}#${entry.ref ?? ''}';
    final cached = cache[key];
    if (cached != null) return Future.value(cached);
    final source = entry.sourceType == 'github'
        ? _Source.github(
            owner: entry.source.split('/').first,
            repo: entry.source.split('/').last,
            ref: entry.ref,
          )
        : _Source.download(Uri.parse(entry.sourceUrl));
    return _fetch(source, resolveCommit: resolveCommit).then((f) => cache[key] = f);
  }

  // ---- fetching ----

  Future<_Fetched> _fetch(_Source s, {bool resolveCommit = false}) async {
    if (!s.isGitHub) return _fetchDownload(s.url!);
    final ref = s.ref ?? 'HEAD';
    final encoded = ref.split('/').map(Uri.encodeComponent).join('/');
    final bytes = await _get(
      Uri.parse('https://codeload.github.com/${s.owner}/${s.repo}/zip/$encoded'),
      headers: _authHeaders(),
    );
    final archive = await _decodeZip(bytes);
    return _Fetched(
      files: archive.files,
      symlinks: archive.symlinks,
      sourceType: 'github',
      source: '${s.owner}/${s.repo}',
      sourceUrl: 'https://github.com/${s.owner}/${s.repo}',
      ref: s.ref,
      commit: resolveCommit ? await _resolveCommit(s.owner!, s.repo!, ref) : null,
    );
  }

  Future<_Fetched> _fetchDownload(Uri url) async {
    final bytes = await _get(url);
    if (_isZip(bytes)) {
      final archive = await _decodeZip(bytes);
      return _Fetched.download(url, archive.files, archive.symlinks);
    }
    if (_isGzip(bytes)) {
      final archive = _decodeTar(_gunzip(bytes));
      return _Fetched.download(url, archive.files, archive.symlinks);
    }
    if (_isTar(bytes)) {
      final archive = _decodeTar(bytes);
      return _Fetched.download(url, archive.files, archive.symlinks);
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (parseSkillDocument(text) != null) {
      return _Fetched.download(url, {'SKILL.md': bytes}, const {});
    }
    throw const SkillException('That link is not a skill archive or a SKILL.md file.');
  }

  Future<Uint8List> _get(Uri url, {Map<String, String> headers = const {}}) async {
    final request = http.Request('GET', url)..headers.addAll(headers);
    final http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(_timeout);
    } on TimeoutException {
      throw SkillException('Downloading from ${url.host} timed out.');
    } on Exception {
      throw SkillException('Could not reach ${url.host}.');
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw SkillException(_statusMessage(response.statusCode, url));
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (out.length + chunk.length > _maxDownloadBytes) {
        throw const SkillException('The download is larger than 10 MiB.');
      }
      out.add(chunk);
    }
    return out.takeBytes();
  }

  static String _statusMessage(int code, Uri url) {
    if (code == 404) {
      return 'Nothing was found at ${url.host}. Check the address; private GitHub repositories need a token.';
    }
    return 'The server at ${url.host} answered HTTP $code.';
  }

  Map<String, String> _authHeaders() {
    final token = _githubToken?.call();
    if (token == null || token.isEmpty) return const {};
    return {'Authorization': 'token $token'};
  }

  Future<String?> _resolveCommit(String owner, String repo, String ref) async {
    try {
      final response = await _http
          .get(
            Uri.parse('https://api.github.com/repos/$owner/$repo/commits/${Uri.encodeComponent(ref)}'),
            headers: {'Accept': 'application/vnd.github.sha', ..._authHeaders()},
          )
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      final sha = response.body.trim();
      return RegExp(r'^[0-9a-f]{40}$').hasMatch(sha) ? sha : null;
    } on Exception {
      return null;
    }
  }

  Future<Uint8List?> _readIfExists(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  // ---- archives ----

  Future<RawArchive> _decodeZip(Uint8List bytes) async => _collect(await _backend.unzip(bytes));

  static RawArchive _decodeTar(Uint8List bytes) {
    try {
      return _collect(readArchiveEntries(TarDecoder().decodeBytes(bytes, verify: true).files));
    } on SkillException {
      rethrow;
    } on Exception {
      throw const SkillException('The download is not a valid tar archive.');
    }
  }

  static Uint8List _gunzip(Uint8List bytes) {
    try {
      return GZipDecoder().decodeBytes(bytes, maxOutputSize: skillMaxExtractedBytes);
    } on ArchiveLimitException {
      throw const SkillException(skillTooLargeMessage);
    } on Exception {
      throw const SkillException('The download is not a valid gzip file.');
    }
  }

  /// The manager's policy over what a backend unpacked: file count, unsafe names, the single top
  /// folder (GitHub's `repo-<sha>/`) removed, symlinks set aside, total size. Names are normalised here.
  static RawArchive _collect(RawArchive raw) {
    if (raw.files.length + raw.symlinks.length > skillMaxFiles) {
      throw const SkillException('The download has more than 1000 files.');
    }
    final names = [for (final n in [...raw.files.keys, ...raw.symlinks]) n.replaceAll('\\', '/')];
    for (final name in names) {
      if (name.startsWith('/') ||
          name.contains('\u0000') ||
          RegExp(r'^[a-zA-Z]:').hasMatch(name) ||
          name.split('/').contains('..')) {
        throw const SkillException('The download contains an unsafe path, so nothing was installed.');
      }
    }
    final tops = {for (final n in names) n.contains('/') ? n.split('/').first : ''};
    final stripTop = tops.length == 1 && tops.first.isNotEmpty;

    String rel(String name) {
      final n = name.replaceAll('\\', '/');
      if (!stripTop) return n;
      final slash = n.indexOf('/');
      return slash < 0 ? '' : n.substring(slash + 1);
    }

    final files = <String, Uint8List>{};
    for (final e in raw.files.entries) {
      final r = rel(e.key);
      if (r.isEmpty || r.endsWith('/')) continue;
      files[r] = e.value;
    }
    final links = <String>{};
    for (final name in raw.symlinks) {
      final r = rel(name);
      if (r.isNotEmpty) links.add(r);
    }
    var total = 0;
    for (final bytes in files.values) {
      total += bytes.length;
      if (total > skillMaxExtractedBytes) throw const SkillException(skillTooLargeMessage);
    }
    return RawArchive(files, links);
  }

  static bool _isZip(Uint8List b) => b.length >= 4 && b[0] == 0x50 && b[1] == 0x4b && b[2] == 0x03 && b[3] == 0x04;

  static bool _isGzip(Uint8List b) => b.length >= 2 && b[0] == 0x1f && b[1] == 0x8b;

  static bool _isTar(Uint8List b) =>
      b.length > 262 && String.fromCharCodes(b.sublist(257, 262)) == 'ustar';

  // ---- discovery ----

  /// Finds skill folders: the base folder itself, its children, and the usual containers
  /// (`skills/`, `skills/.curated`, `skills/.experimental`, `skills/.system`, `.agents/skills`,
  /// `.claude/skills`) down three levels. Falls back to a full search when none is found.
  static List<_Found> _discover(Map<String, Uint8List> files, String? subpath) {
    final base = subpath ?? '';
    final dirs = <String>{''};
    for (final p in files.keys) {
      var i = p.lastIndexOf('/');
      while (i > 0) {
        final d = p.substring(0, i);
        if (!dirs.add(d)) break;
        i = d.lastIndexOf('/');
      }
    }
    final children = <String, List<String>>{};
    for (final d in dirs) {
      if (d.isEmpty) continue;
      final i = d.lastIndexOf('/');
      children.putIfAbsent(i < 0 ? '' : d.substring(0, i), () => []).add(d);
    }
    bool hasSkill(String d) => files.containsKey(d.isEmpty ? 'SKILL.md' : '$d/SKILL.md');

    void visit(String dir, int depth, int maxDepth, List<String> out) {
      if (hasSkill(dir)) {
        out.add(dir);
        return;
      }
      if (depth >= maxDepth) return;
      for (final c in children[dir] ?? const <String>[]) {
        if (_skipDirs.contains(c.split('/').last)) continue;
        visit(c, depth + 1, maxDepth, out);
      }
    }

    final found = <String>[];
    if (hasSkill(base)) {
      found.add(base);
    } else {
      String join(String rel) => base.isEmpty ? rel : '$base/$rel';
      for (final (root, depth) in [
        (base, 1),
        (join('skills'), 3),
        (join('skills/.curated'), 3),
        (join('skills/.experimental'), 3),
        (join('skills/.system'), 3),
        (join('.agents/skills'), 3),
        (join('.claude/skills'), 3),
      ]) {
        visit(root, 0, depth, found);
      }
      if (found.isEmpty) visit(base, 0, 6, found);
    }

    final seen = <String>{};
    final out = <_Found>[];
    for (final dir in found.toSet()) {
      final x = _loadFound(files, dir, null);
      if (x == null || x.installName == null || !seen.add(x.installName!)) continue;
      out.add(x);
    }
    return out;
  }

  /// The skill at [dir], or null when there is no valid SKILL.md there. [installName] is only
  /// used for update checks, where the lock key decides the folder.
  static _Found? _loadFound(Map<String, Uint8List> files, String dir, String? installName) {
    final bytes = files[dir.isEmpty ? 'SKILL.md' : '$dir/SKILL.md'];
    if (bytes == null) return null;
    final doc = parseSkillDocument(utf8.decode(bytes, allowMalformed: true));
    if (doc == null) return null;
    return _Found(dir: dir, doc: doc, installNameOverride: installName);
  }

  static Map<String, Uint8List> _filesUnder(Map<String, Uint8List> files, String dir) {
    final prefix = dir.isEmpty ? '' : '$dir/';
    return {
      for (final e in files.entries)
        if (e.key.startsWith(prefix) && e.key.length > prefix.length) e.key.substring(prefix.length): e.value,
    };
  }

  Future<String> _hashFiles(Map<String, Uint8List> files) async {
    final paths = files.keys.toList()..sort();
    final out = BytesBuilder(copy: false);
    for (final p in paths) {
      final content = files[p]!;
      out.add(utf8.encode(p));
      out.addByte(0);
      out.add(utf8.encode('${content.length}'));
      out.addByte(0);
      out.add(content);
    }
    return _backend.sha256(out.takeBytes());
  }

  // ---- source parsing ----

  static final _shorthand = RegExp(r'^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?(?:/([^@]+?))?(?:@(.+))?$');

  _Source _parseSource(String raw) {
    var input = raw.trim();
    if (input.startsWith('github:')) input = input.substring('github:'.length);
    if (input.isEmpty) throw const SkillException('Give a GitHub repository, such as owner/repo.');
    if (input.startsWith('http://') || input.startsWith('https://')) {
      return _parseUrl(input);
    }
    if (input.contains(':') || input.startsWith('.') || input.startsWith('/') || input.startsWith('~')) {
      throw const SkillException('Only GitHub repositories and direct archive or SKILL.md links work on this device.');
    }

    String? fragment;
    final hash = input.indexOf('#');
    if (hash >= 0) {
      fragment = input.substring(hash + 1);
      input = input.substring(0, hash);
    }
    final m = _shorthand.firstMatch(input);
    if (m == null) {
      throw SkillException('Could not read "$raw". Use owner/repo, owner/repo@skill, or a GitHub link.');
    }
    final skillNames = <String>[];
    String? ref;
    void applyAt(String value) {
      if (_isVersionPin(value)) {
        ref = value;
      } else {
        skillNames.add(value);
      }
    }

    final at = m.group(4);
    if (at != null && at.isNotEmpty) applyAt(at);
    if (fragment != null && fragment.isNotEmpty) {
      final at2 = fragment.indexOf('@');
      final refPart = at2 < 0 ? fragment : fragment.substring(0, at2);
      if (refPart.isNotEmpty) ref = Uri.decodeComponent(refPart);
      if (at2 >= 0 && at2 < fragment.length - 1) skillNames.add(Uri.decodeComponent(fragment.substring(at2 + 1)));
    }
    return _Source.github(
      owner: m.group(1)!,
      repo: m.group(2)!,
      ref: ref,
      subpath: m.group(3) == null ? null : _safeSubpath(m.group(3)!),
      skillNames: skillNames,
    );
  }

  _Source _parseUrl(String input) {
    final uri = Uri.tryParse(input);
    if (uri == null || uri.host.isEmpty) throw SkillException('Could not read "$input".');
    if (uri.scheme != 'https') throw const SkillException('Use an https:// link.');
    final host = uri.host.toLowerCase();
    if (host == 'github.com' || host == 'www.github.com') {
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.length >= 2) {
        if (segs.length >= 3 && {'archive', 'raw', 'releases'}.contains(segs[2])) {
          return _Source.download(uri);
        }
        final owner = segs[0];
        final repo = segs[1].replaceAll(RegExp(r'\.git$'), '');
        if (segs.length >= 4 && segs[2] == 'tree') {
          final rest = segs.sublist(4).join('/');
          return _Source.github(
            owner: owner,
            repo: repo,
            ref: Uri.decodeComponent(segs[3]),
            subpath: rest.isEmpty ? null : _safeSubpath(rest),
          );
        }
        return _Source.github(owner: owner, repo: repo);
      }
      throw SkillException('Could not read "$input".');
    }
    if (host.endsWith('gitlab.com') || uri.path.endsWith('.git')) {
      throw const SkillException('Only GitHub repositories and direct archive or SKILL.md links work on this device.');
    }
    return _Source.download(uri);
  }

  static bool _isVersionPin(String value) =>
      RegExp(r'^v?\d+(\.\d+)+([-+][0-9A-Za-z.+-]*)?$').hasMatch(value) ||
      RegExp(r'^[0-9a-f]{40}$').hasMatch(value);

  static String _safeSubpath(String raw) {
    final p = raw.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    if (p.split('/').contains('..')) throw const SkillException('The folder path leaves the repository.');
    return p;
  }

  static String _safeRelative(String raw) {
    final p = raw.replaceAll('\\', '/').trim();
    if (p.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(p) || p.contains('\u0000')) {
      throw const SkillException('Use a path inside the skill folder.');
    }
    final parts = p.split('/').where((s) => s.isNotEmpty && s != '.').toList();
    if (parts.isEmpty || parts.contains('..')) throw const SkillException('Use a path inside the skill folder.');
    return parts.join('/');
  }

  /// The installed folder name for a skill name, or null when nothing usable is left.
  static String? installNameFor(String name) {
    var s = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
    s = s.replaceAll(RegExp(r'^[.-]+|[.-]+$'), '');
    if (s.length > 64) s = s.substring(0, 64).replaceAll(RegExp(r'[.-]+$'), '');
    if (s.isEmpty || s == _lockName) return null;
    return s;
  }

  static String _clean(Object? v) =>
      v is String ? v.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim() : '';

  static String _oneLine(String s, int max) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > max ? '${flat.substring(0, max)}...' : flat;
  }

  static String _formatInstalls(Object? v) {
    if (v is! num || v <= 0) return '';
    final n = v.toInt();
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1).replaceAll('.0', '')}M installs';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1).replaceAll('.0', '')}K installs';
    return '$n install${n == 1 ? '' : 's'}';
  }
}

/// Where a skill comes from: a GitHub repository, or one direct download.
class _Source {
  _Source.github({
    required String owner,
    required String repo,
    this.ref,
    this.subpath,
    this.skillNames = const [],
  })  : owner = owner,
        repo = repo,
        url = null,
        isGitHub = true;

  _Source.download(Uri url)
      : owner = null,
        repo = null,
        url = url,
        ref = null,
        subpath = null,
        skillNames = const [],
        isGitHub = false;

  final bool isGitHub;
  final String? owner;
  final String? repo;
  final Uri? url;
  final String? ref;
  final String? subpath;

  /// Names given after `@` in the source, merged with the names the caller passed.
  final List<String> skillNames;

  String get display => isGitHub ? '$owner/$repo' : url.toString();
}

class _Fetched {
  _Fetched({
    required this.files,
    required this.symlinks,
    required this.sourceType,
    required this.source,
    required this.sourceUrl,
    this.ref,
    this.commit,
  });

  _Fetched.download(Uri url, Map<String, Uint8List> files, Set<String> symlinks)
      : this(
          files: files,
          symlinks: symlinks,
          sourceType: 'download',
          source: url.toString(),
          sourceUrl: url.toString(),
        );

  final Map<String, Uint8List> files;
  final Set<String> symlinks;
  final String sourceType;
  final String source;
  final String sourceUrl;
  final String? ref;
  final String? commit;
}

class _Found {
  _Found({required this.dir, required SkillDocument doc, String? installNameOverride})
      : name = doc.name,
        description = doc.description,
        body = doc.body,
        installName = installNameOverride ?? SkillManager.installNameFor(doc.name);

  /// Folder inside the source; empty for the root.
  final String dir;
  final String name;
  final String description;
  final String body;
  final String? installName;
}

class _LockEntry {
  const _LockEntry({
    required this.source,
    required this.sourceType,
    required this.sourceUrl,
    required this.skillPath,
    required this.contentHash,
    required this.installedAt,
    required this.updatedAt,
    this.ref,
    this.commit,
  });

  final String source;
  final String sourceType;
  final String sourceUrl;
  final String? ref;
  final String? commit;
  final String skillPath;
  final String contentHash;
  final String installedAt;
  final String updatedAt;

  Map<String, dynamic> toJson() => {
        'source': source,
        'sourceType': sourceType,
        'sourceUrl': sourceUrl,
        if (ref != null) 'ref': ref,
        if (commit != null) 'commit': commit,
        'skillPath': skillPath,
        'contentHash': contentHash,
        'installedAt': installedAt,
        'updatedAt': updatedAt,
      };

  factory _LockEntry.fromJson(Map<String, dynamic> j) => _LockEntry(
        source: j['source'] as String,
        sourceType: j['sourceType'] as String,
        sourceUrl: j['sourceUrl'] as String,
        ref: j['ref'] as String?,
        commit: j['commit'] as String?,
        skillPath: j['skillPath'] as String,
        contentHash: j['contentHash'] as String,
        installedAt: j['installedAt'] as String,
        updatedAt: j['updatedAt'] as String,
      );
}
