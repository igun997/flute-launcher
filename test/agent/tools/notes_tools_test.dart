import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/agent/tools/notes_store.dart';
import 'package:focus_launcher/agent/tools/notes_tools.dart';

void main() {
  late Directory dir;
  late NotesStore store;
  late Map<String, AgentTool> tools;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('notes_tools_test');
    store = NotesStore(file: File('${dir.path}/notes.json'));
    tools = {for (final tool in notesTools(store)) tool.name: tool};
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<ToolResult> call(String name, Map<String, dynamic> args) => tools[name]!.run(args);

  /// The id in a "(id …)" or "- id | …" line the tools return.
  String idIn(String text) {
    final match = RegExp(r'id ([0-9a-f-]{36})|- ([0-9a-f-]{36}) \|').firstMatch(text);
    return (match?.group(1) ?? match?.group(2))!;
  }

  test('create, read and list round trip through the tools', () async {
    final created = await call('notes_create', {
      'title': 'Groceries',
      'body': 'milk, eggs, bread',
    });
    expect(created.isError, isFalse);
    final id = idIn(created.text);

    final read = await call('notes_read', {'id': id});
    expect(read.text, contains('Title: Groceries'));
    expect(read.text, endsWith('milk, eggs, bread'));

    final listed = await call('notes_list', {});
    expect(listed.text, contains('1 note(s), newest first:'));
    expect(listed.text, contains('| Groceries |'));
    expect(listed.text, isNot(contains('milk')), reason: 'the list shows titles, not bodies');
  });

  test('search matches the title and the body, case-insensitively', () async {
    await call('notes_create', {'title': 'Trip', 'body': 'Book the Bali flights'});
    await call('notes_create', {'title': 'Shopping', 'body': 'socks'});

    final byBody = await call('notes_search', {'query': 'bali'});
    expect(byBody.text, contains('| Trip |'));
    expect(byBody.text, isNot(contains('Shopping')));

    final none = await call('notes_search', {'query': 'zebra'});
    expect(none.text, 'No notes match "zebra".');
  });

  test('update changes only the fields given and an empty body clears it', () async {
    final id = idIn((await call('notes_create', {'title': 'Draft', 'body': 'v1'})).text);

    final renamed = await call('notes_update', {'id': id, 'title': 'Final'});
    expect(renamed.isError, isFalse);
    var read = await call('notes_read', {'id': id});
    expect(read.text, contains('Title: Final'));
    expect(read.text, endsWith('v1'));

    await call('notes_update', {'id': id, 'body': ''});
    read = await call('notes_read', {'id': id});
    expect(read.text, endsWith('\n\n'));
  });

  test('update with an empty title is refused', () async {
    final id = idIn((await call('notes_create', {'title': 'Keep'})).text);
    final result = await call('notes_update', {'id': id, 'title': '  '});
    expect(result.isError, isTrue);
    expect(result.text, 'title cannot be empty.');
  });

  test('delete names the note it removed and then the note is gone', () async {
    final id = idIn((await call('notes_create', {'title': 'Old list'})).text);
    final deleted = await call('notes_delete', {'id': id});
    expect(deleted.text, 'Deleted note "Old list".');

    final again = await call('notes_read', {'id': id});
    expect(again.isError, isTrue);
    expect(again.text, 'No note with id $id.');
  });

  test('describeCall names a note shown earlier, and otherwise its id', () async {
    final id = idIn((await call('notes_create', {'title': 'Groceries'})).text);
    final delete = tools['notes_delete']!;
    expect(delete.describeCall({'id': 'ghost'}), 'Delete note with id ghost');

    await call('notes_list', {});
    expect(delete.describeCall({'id': id}), "Delete note 'Groceries'");
    expect(tools['notes_create']!.describeCall({'title': 'Trip'}), "Create note 'Trip'");
  });

  test('a damaged notes file is reported as an error without its content', () async {
    await File('${dir.path}/notes.json').writeAsString('{"secret": "do not echo"');
    final result = await call('notes_list', {});
    expect(result.isError, isTrue);
    expect(result.text, 'Notes request failed (FormatException).');
    expect(result.text, isNot(contains('secret')));
  });

  test('reads and searches are read tools, writes are write tools', () {
    for (final name in ['notes_list', 'notes_search', 'notes_read']) {
      expect(tools[name]!.risk, ToolRisk.read, reason: name);
    }
    for (final name in ['notes_create', 'notes_update', 'notes_delete']) {
      expect(tools[name]!.risk, ToolRisk.write, reason: name);
      expect(tools[name]!.source, 'notes');
    }
  });
}
