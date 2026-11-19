import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../tools/agent_tool.dart';

/// Keeps the files a sandbox run produced, in the app's own storage, so the chat can show them and
/// the user can open, share or save them after the sandbox is gone.
class SandboxOutputs {
  SandboxOutputs({Future<Directory> Function()? directory}) : _directory = directory ?? _defaultDirectory;

  /// One file is refused above this size; the chat is not a file transfer service.
  static const maxFileBytes = 20 * 1024 * 1024;
  static const maxFilesPerRun = 8;
  static const _keep = 100;

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/outputs');
  }

  static const _mimes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'svg': 'image/svg+xml',
    'pdf': 'application/pdf',
    'csv': 'text/csv',
    'tsv': 'text/tab-separated-values',
    'txt': 'text/plain',
    'log': 'text/plain',
    'md': 'text/markdown',
    'json': 'application/json',
    'xml': 'application/xml',
    'html': 'text/html',
    'htm': 'text/html',
    'zip': 'application/zip',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'mp4': 'video/mp4',
  };

  /// The type from the extension; unknown extensions are plain binary.
  static String mimeFor(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'application/octet-stream';
    return _mimes[name.substring(dot + 1).toLowerCase()] ?? 'application/octet-stream';
  }

  /// The last path segment with anything unsafe replaced, never empty and never longer than 80.
  static String safeName(String path) {
    final base = path.split('/').where((p) => p.isNotEmpty).lastOrNull ?? 'file';
    var clean = base.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_').replaceAll(RegExp(r'^\.+'), '_');
    if (clean.length > 80) {
      final dot = clean.lastIndexOf('.');
      final ext = dot > 0 && clean.length - dot <= 10 ? clean.substring(dot) : '';
      clean = clean.substring(0, 80 - ext.length) + ext;
    }
    return clean.isEmpty ? 'file' : clean;
  }

  /// Stores [bytes] as a new file named after [path] and returns what the chat needs to show it.
  Future<ToolFile> save(String path, List<int> bytes) async {
    if (bytes.length > maxFileBytes) {
      throw FileSystemException('The file is larger than ${maxFileBytes ~/ (1024 * 1024)} MB.');
    }
    final dir = await _directory();
    await dir.create(recursive: true);
    final name = safeName(path);
    final stored = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$name');
    await stored.writeAsBytes(bytes, flush: true);
    await _prune(dir);
    return ToolFile(path: stored.path, name: name, mime: mimeFor(name), bytes: bytes.length);
  }

  Future<void> _prune(Directory dir) async {
    final files = <File>[
      await for (final e in dir.list()) if (e is File) e,
    ];
    if (files.length <= _keep) return;
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final old in files.take(files.length - _keep)) {
      try {
        await old.delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }
}
