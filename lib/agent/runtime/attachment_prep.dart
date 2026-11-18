import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../native/flute_native.dart';
import '../llm/llm_types.dart';
import 'agent_runtime.dart';

typedef VideoFrames = Future<List<Uint8List>> Function(String path, int count);
typedef ReadBytes = Future<Uint8List> Function(String path);

/// Turns what the user attached into message parts a model can read.
///
/// Images go as pictures (shrunk when huge). Video is sent as a few frames spread across the
/// clip, because chat APIs here take images, not video. PDFs go as files; text-like files are
/// inlined as text. Anything else is mentioned so the model does not pretend to have read it.
class AttachmentPrep {
  AttachmentPrep({VideoFrames? videoFrames, ReadBytes? readBytes})
      : _videoFrames = videoFrames ?? ((p, n) => FluteNative.extractVideoFrames(p, count: n)),
        _read = readBytes ?? ((p) => File(p).readAsBytes());

  final VideoFrames _videoFrames;
  final ReadBytes _read;

  static const videoFrameCount = 6;
  static const _maxImageBytes = 5 * 1024 * 1024;
  static const _maxPdfBytes = 20 * 1024 * 1024;
  static const _maxTextChars = 60000;

  static const _textExtensions = {
    'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml', 'log', 'html', 'htm', 'css',
    'js', 'ts', 'dart', 'kt', 'java', 'py', 'rb', 'go', 'rs', 'c', 'h', 'cpp', 'sh', 'sql', 'ini',
    'toml', 'gradle', 'properties', 'ics', 'vcf',
  };

  Future<List<Part>> prepare(String text, List<Attachment> attachments) async {
    final parts = <Part>[if (text.isNotEmpty) TextPart(text)];
    for (final a in attachments) {
      switch (a.kind) {
        case AttachmentKind.image:
          parts.addAll(await _image(a));
        case AttachmentKind.video:
          parts.addAll(await _video(a));
        case AttachmentKind.file:
          parts.addAll(await _file(a));
      }
    }
    return parts;
  }

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  static String imageMime(String name) => switch (_ext(name)) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => 'image/jpeg',
      };

  Future<List<Part>> _image(Attachment a) async {
    var bytes = await _read(a.path);
    var mime = imageMime(a.name);
    if (bytes.length > _maxImageBytes) {
      final small = await _shrink(bytes);
      if (small != null) {
        bytes = small;
        mime = 'image/png';
      }
    }
    return [ImagePart(bytes, mime: mime)];
  }

  Future<List<Part>> _video(Attachment a) async {
    List<Uint8List> frames;
    try {
      frames = await _videoFrames(a.path, videoFrameCount);
    } catch (_) {
      frames = const [];
    }
    if (frames.isEmpty) return [TextPart('(The video "${a.name}" could not be read.)')];
    return [
      TextPart('Video "${a.name}": ${frames.length} frames sampled evenly across the clip, in order.'),
      for (final f in frames) ImagePart(f),
    ];
  }

  Future<List<Part>> _file(Attachment a) async {
    final ext = _ext(a.name);
    if (ext == 'pdf') {
      final bytes = await _read(a.path);
      if (bytes.length > _maxPdfBytes) return [TextPart('(The PDF "${a.name}" is too large to send.)')];
      return [FilePart(bytes, name: a.name, mime: 'application/pdf')];
    }
    if (_textExtensions.contains(ext)) {
      final bytes = await _read(a.path);
      var body = utf8.decode(bytes, allowMalformed: true);
      var note = '';
      if (body.length > _maxTextChars) {
        body = body.substring(0, _maxTextChars);
        note = '\n(Cut after $_maxTextChars characters.)';
      }
      return [TextPart('File "${a.name}":\n```\n$body\n```$note')];
    }
    return [TextPart('(The file "${a.name}" was not read: this type is not supported.)')];
  }

  /// Best effort PNG at most 1568 px wide; null when the image cannot be decoded.
  Future<Uint8List?> _shrink(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1568);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
