import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../../rust/rust_core.dart';
import 'skill.dart';

/// Limits every backend and the manager's tar and gzip path share.
const skillMaxExtractedBytes = 25 * 1024 * 1024;
const skillMaxFiles = 1000;
const skillTooLargeMessage = 'The extracted content is larger than 25 MiB.';

/// An unpacked archive: regular files and symbolic or hard link names. Names are exactly as
/// stored in the archive; no path is rewritten and directories are not listed.
class RawArchive {
  RawArchive(this.files, this.symlinks);

  final Map<String, Uint8List> files;
  final Set<String> symlinks;
}

/// Where zip unpacking and hashing run. Policy (top folder, unsafe paths, symlinks, lock) stays in
/// the manager; a backend only unpacks and hashes.
abstract class SkillArchiveBackend {
  /// Unpacks a zip. Throws [SkillException] for damaged, oversized or unsafe archives.
  Future<RawArchive> unzip(Uint8List zip);

  /// SHA-256 of [data], lowercase hex.
  Future<String> sha256(Uint8List data);

  /// The Rust backend once the Rust core is started, the Dart one otherwise.
  static SkillArchiveBackend defaultBackend() =>
      RustCore.instance.isStarted ? const RustSkillArchiveBackend() : const DartSkillArchiveBackend();
}

class DartSkillArchiveBackend implements SkillArchiveBackend {
  const DartSkillArchiveBackend();

  @override
  Future<RawArchive> unzip(Uint8List zip) async {
    try {
      return readArchiveEntries(ZipDecoder().decodeBytes(zip).files);
    } on SkillException {
      rethrow;
    } on ArchiveLimitException {
      throw const SkillException(skillTooLargeMessage);
    } on Exception {
      throw const SkillException('The download is not a valid archive.');
    }
  }

  @override
  Future<String> sha256(Uint8List data) async => crypto.sha256.convert(data).toString();
}

class RustSkillArchiveBackend implements SkillArchiveBackend {
  const RustSkillArchiveBackend();

  @override
  Future<RawArchive> unzip(Uint8List zip) async {
    try {
      final r = await RustCore.instance.unzip(
        zip,
        maxTotalBytes: skillMaxExtractedBytes,
        maxFiles: skillMaxFiles,
      );
      return RawArchive(r.files, r.symlinks);
    } on RustException catch (e) {
      throw SkillException(e.message.isEmpty ? 'The download is not a valid archive.' : e.message);
    }
  }

  @override
  Future<String> sha256(Uint8List data) => RustCore.instance.sha256(data);
}

/// Reads archive entries with the size checks done before any content is decompressed.
/// Decoder failures are the caller's to map to a message.
RawArchive readArchiveEntries(List<ArchiveFile> entries) {
  if (entries.length > skillMaxFiles) {
    throw const SkillException('The download has more than 1000 files.');
  }
  var declared = 0;
  for (final e in entries) {
    if (!e.isFile || e.isSymbolicLink || e.isHardLink) continue;
    declared += e.size;
    if (declared > skillMaxExtractedBytes) throw const SkillException(skillTooLargeMessage);
  }

  final files = <String, Uint8List>{};
  final symlinks = <String>{};
  var total = 0;
  for (final e in entries) {
    if (e.isSymbolicLink || e.isHardLink) {
      symlinks.add(e.name);
      continue;
    }
    if (!e.isFile) continue;
    final bytes = e.content;
    total += bytes.length;
    if (total > skillMaxExtractedBytes) throw const SkillException(skillTooLargeMessage);
    files[e.name] = bytes;
  }
  return RawArchive(files, symlinks);
}
