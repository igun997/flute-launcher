import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// A note the user (or the agent, with approval) wrote. Times are stored in UTC.
class Note {
  const Note({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;

  Note copyWith({String? title, String? body, DateTime? updatedAt}) => Note(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: json['id'] as String,
    title: json['title'] as String,
    body: json['body'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
  );
}

/// Notes in one JSON file in the app's support directory: `{"notes": [...]}`.
/// Every operation is serialised, so concurrent calls never interleave a read and a write. Writes
/// go to a temporary file that then replaces the real one.
class NotesStore {
  NotesStore({File? file}) : _file = file;

  File? _file;
  Future<void> _queue = Future<void>.value();

  /// Every note, most recently updated first.
  Future<List<Note>> all() => _serial(() async {
    final notes = await _read();
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return notes;
  });

  Future<Note?> find(String id) => _serial(() async {
    for (final note in await _read()) {
      if (note.id == id) return note;
    }
    return null;
  });

  Future<Note> create({required String title, required String body}) =>
      _serial(() async {
        final now = DateTime.now().toUtc();
        final note = Note(
          id: const Uuid().v4(),
          title: title,
          body: body,
          createdAt: now,
          updatedAt: now,
        );
        final notes = await _read();
        notes.add(note);
        await _write(notes);
        return note;
      });

  /// Null when no note has [id]. Fields left null keep their value.
  Future<Note?> update(String id, {String? title, String? body}) =>
      _serial(() async {
        final notes = await _read();
        final index = notes.indexWhere((n) => n.id == id);
        if (index < 0) return null;
        final updated = notes[index].copyWith(
          title: title,
          body: body,
          updatedAt: DateTime.now().toUtc(),
        );
        notes[index] = updated;
        await _write(notes);
        return updated;
      });

  /// False when no note has [id].
  Future<bool> delete(String id) => _serial(() async {
    final notes = await _read();
    final before = notes.length;
    notes.removeWhere((n) => n.id == id);
    if (notes.length == before) return false;
    await _write(notes);
    return true;
  });

  /// Runs [action] after every earlier operation has finished. A failed operation does not block
  /// the ones queued after it.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/notes.json');
  }

  Future<List<Note>> _read() async {
    final file = await _resolveFile();
    if (!await file.exists()) return <Note>[];
    final text = await file.readAsString();
    if (text.trim().isEmpty) return <Note>[];
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final list = (decoded['notes'] as List<dynamic>?) ?? const [];
    return [
      for (final item in list) Note.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<void> _write(List<Note> notes) async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({'notes': [for (final note in notes) note.toJson()]}),
      flush: true,
    );
    await temp.rename(file.path);
  }
}
