import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/notes_store.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('notes_store_test');
    file = File('${dir.path}/notes.json');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('a note survives a restart of the store', () async {
    final created = await NotesStore(file: file).create(title: 'Groceries', body: 'milk, eggs');

    final reopened = await NotesStore(file: file).find(created.id);
    expect(reopened, isNotNull);
    expect(reopened!.title, 'Groceries');
    expect(reopened.body, 'milk, eggs');
    expect(reopened.createdAt, created.createdAt);
  });

  test('update changes only the given fields and moves updatedAt forward', () async {
    final store = NotesStore(file: file);
    final note = await store.create(title: 'A', body: 'one');
    await Future<void>.delayed(const Duration(milliseconds: 2));

    final updated = await store.update(note.id, body: 'two');
    expect(updated, isNotNull);
    expect(updated!.title, 'A');
    expect(updated.body, 'two');
    expect(updated.createdAt, note.createdAt);
    expect(updated.updatedAt.isAfter(note.updatedAt), isTrue);
  });

  test('update and delete report a missing note', () async {
    final store = NotesStore(file: file);
    expect(await store.update('missing', title: 'x'), isNull);
    expect(await store.delete('missing'), isFalse);
  });

  test('delete removes the note from disk', () async {
    final store = NotesStore(file: file);
    final note = await store.create(title: 'Gone', body: '');
    expect(await store.delete(note.id), isTrue);
    expect(await NotesStore(file: file).all(), isEmpty);
  });

  test('all() lists the most recently updated note first', () async {
    final store = NotesStore(file: file);
    final first = await store.create(title: 'first', body: '');
    await store.create(title: 'second', body: '');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await store.update(first.id, title: 'first, edited');

    final titles = (await store.all()).map((n) => n.title).toList();
    expect(titles, ['first, edited', 'second']);
  });

  test('concurrent writes all land and none is lost', () async {
    final store = NotesStore(file: file);
    await Future.wait([
      for (var i = 0; i < 25; i++) store.create(title: 'note $i', body: 'body $i'),
    ]);

    expect(await store.all(), hasLength(25));
    expect(await NotesStore(file: file).all(), hasLength(25));
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('a damaged file is an error and is never overwritten', () async {
    await file.writeAsString('{not json');
    final store = NotesStore(file: file);

    await expectLater(store.create(title: 'New', body: ''), throwsFormatException);
    expect(await file.readAsString(), '{not json');
  });
}
