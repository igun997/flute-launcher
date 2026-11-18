import 'agent_tool.dart';
import 'notes_store.dart';
import 'tool_support.dart';

/// The notes tools. Reads are free; every write asks the user first.
List<AgentTool> notesTools(NotesStore store) {
  final labels = RecentLabels();
  return [
    NotesListTool(store, labels),
    NotesSearchTool(store, labels),
    NotesReadTool(store, labels),
    NotesCreateTool(store, labels),
    NotesUpdateTool(store, labels),
    NotesDeleteTool(store, labels),
  ];
}

String _noteLine(Note note) {
  final updated = note.updatedAt.toLocal();
  return '- ${note.id} | ${note.title} | updated ${ymd(updated)} ${hm(updated)}';
}

/// Titles of the notes, newest first, capped by the limit.
ToolResult _listing(List<Note> notes, Map<String, dynamic> args, String empty) {
  if (notes.isEmpty) return ToolResult(empty);
  final limit = listLimit(args);
  final shown = notes.take(limit).toList();
  final header = notes.length > shown.length
      ? '${notes.length} notes, showing the newest ${shown.length}:'
      : '${notes.length} note(s), newest first:';
  return ToolResult([header, for (final note in shown) _noteLine(note)].join('\n'));
}

abstract class _NotesTool extends BuiltinTool {
  _NotesTool(this.store, this.labels)
    : super(subject: 'Notes');

  final NotesStore store;
  final RecentLabels labels;

  @override
  String get source => 'notes';
}

class NotesListTool extends _NotesTool {
  NotesListTool(super.store, super.labels);

  @override
  String get name => 'notes_list';

  @override
  String get description =>
      'List the user\'s notes, newest first: id, title and last update. Use notes_read for a body.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'limit': intProp('How many notes to list (default 25, max 100).'),
  });

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String describeCall(Map<String, dynamic> args) => 'List notes';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final notes = await store.all();
    for (final note in notes) {
      labels.remember(note.id, "'${note.title}'");
    }
    return _listing(notes, args, 'There are no notes yet.');
  }
}

class NotesSearchTool extends _NotesTool {
  NotesSearchTool(super.store, super.labels);

  @override
  String get name => 'notes_search';

  @override
  String get description =>
      'Find notes whose title or body contains the text (case-insensitive). Returns id and title.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'query': stringProp('Text to look for.'),
    'limit': intProp('How many matches to list (default 25, max 100).'),
  }, required: const ['query']);

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Search notes for "${argString(args, 'query') ?? ''}"';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final query = requireArg(args, 'query').toLowerCase();
    final matches = (await store.all()).where((note) {
      return note.title.toLowerCase().contains(query) ||
          note.body.toLowerCase().contains(query);
    }).toList();
    for (final note in matches) {
      labels.remember(note.id, "'${note.title}'");
    }
    return _listing(matches, args, 'No notes match "$query".');
  }
}

class NotesReadTool extends _NotesTool {
  NotesReadTool(super.store, super.labels);

  @override
  String get name => 'notes_read';

  @override
  String get description => 'Read one note in full: title, last update and body.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'id': stringProp('The note id from notes_list or notes_search.'),
  }, required: const ['id']);

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String describeCall(Map<String, dynamic> args) => 'Read note ${labels.describe(argString(args, 'id') ?? '')}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final id = requireArg(args, 'id');
    final note = await store.find(id) ?? (throw ToolError('No note with id $id.'));
    labels.remember(note.id, "'${note.title}'");
    final updated = note.updatedAt.toLocal();
    return ToolResult(
      'Title: ${note.title}\nUpdated: ${ymd(updated)} ${hm(updated)}\n\n${note.body}',
    );
  }
}

class NotesCreateTool extends _NotesTool {
  NotesCreateTool(super.store, super.labels);

  @override
  String get name => 'notes_create';

  @override
  String get description => 'Create a note with a title and an optional body. Returns its id.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'title': stringProp('Short title.'),
    'body': stringProp('The note text. Optional.'),
  }, required: const ['title']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) {
    final title = argString(args, 'title') ?? '';
    final body = argString(args, 'body') ?? '';
    final text = body.isEmpty ? '' : ': ${clip(body, 80)}';
    return "Create note '$title'$text";
  }

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final title = requireArg(args, 'title');
    final note = await store.create(title: title, body: argString(args, 'body') ?? '');
    labels.remember(note.id, "'${note.title}'");
    return ToolResult('Created note "${note.title}" (id ${note.id}).');
  }
}

class NotesUpdateTool extends _NotesTool {
  NotesUpdateTool(super.store, super.labels);

  @override
  String get name => 'notes_update';

  @override
  String get description =>
      'Change a note\'s title and/or body. Fields left out keep their value; an empty body clears it.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'id': stringProp('The note id.'),
    'title': stringProp('New title. Optional.'),
    'body': stringProp('New body. Optional; "" empties it.'),
  }, required: const ['id']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) {
    final id = argString(args, 'id') ?? '';
    final parts = <String>[];
    final title = argString(args, 'title');
    if (title != null && title.isNotEmpty) parts.add("title '$title'");
    final body = argString(args, 'body');
    if (body != null) parts.add(body.isEmpty ? 'body cleared' : 'body: ${clip(body, 80)}');
    final what = parts.isEmpty ? '' : ': ${parts.join(', ')}';
    return 'Update note ${labels.describe(id)}$what';
  }

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final id = requireArg(args, 'id');
    final title = argString(args, 'title');
    if (title != null && title.isEmpty) throw const ToolError('title cannot be empty.');
    final note = await store.update(id, title: title, body: argString(args, 'body'));
    if (note == null) throw ToolError('No note with id $id.');
    labels.remember(note.id, "'${note.title}'");
    return ToolResult('Updated note "${note.title}".');
  }
}

class NotesDeleteTool extends _NotesTool {
  NotesDeleteTool(super.store, super.labels);

  @override
  String get name => 'notes_delete';

  @override
  String get description => 'Delete a note for good. Get the id from notes_list or notes_search.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'id': stringProp('The note id.'),
  }, required: const ['id']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Delete note ${labels.describe(argString(args, 'id') ?? '')}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final id = requireArg(args, 'id');
    final note = await store.find(id) ?? (throw ToolError('No note with id $id.'));
    await store.delete(id);
    labels.forget(id);
    return ToolResult('Deleted note "${note.title}".');
  }
}
