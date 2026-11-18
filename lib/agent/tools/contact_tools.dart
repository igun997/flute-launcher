import 'agent_tool.dart';
import 'contacts_backend.dart';
import 'tool_support.dart';

const _deniedMessage =
    'Contacts access was denied. Turn it on in Settings > Apps > Flute > Permissions.';

/// The contact tools. Searches run on the device; every write asks the user first.
List<AgentTool> contactTools(ContactsBackend backend) {
  final labels = RecentLabels();
  return [
    ContactsSearchTool(backend, labels),
    ContactsGetTool(backend, labels),
    ContactsCreateTool(backend, labels),
    ContactsUpdateTool(backend, labels),
    ContactsDeleteTool(backend, labels),
  ];
}

abstract class _ContactTool extends BuiltinTool {
  _ContactTool(this.backend, this.labels)
    : super(subject: 'Contacts', access: backend.ensureAccess, deniedMessage: _deniedMessage);

  final ContactsBackend backend;
  final RecentLabels labels;

  @override
  String get source => 'contacts';
}

String _label(ContactInfo contact) => "'${contact.name}'";

String _contactLine(ContactInfo contact) {
  final parts = [
    '- ${contact.id ?? ''} | ${contact.name}',
    if (contact.phones.isNotEmpty) contact.phones.join(', '),
    if (contact.emails.isNotEmpty) contact.emails.join(', '),
  ];
  return parts.join(' | ');
}

String _digits(String text) => text.replaceAll(RegExp(r'\D'), '');

/// Name, company, numbers and emails contain the query (case-insensitive). A query with at least
/// three digits also matches numbers whose digits contain it, so "0812" finds "+62 812 …".
bool _matches(ContactInfo contact, String query) {
  final text = [
    contact.name,
    contact.company ?? '',
    ...contact.emails,
    ...contact.phones,
  ].join('\n').toLowerCase();
  if (text.contains(query.toLowerCase())) return true;
  final digits = _digits(query);
  return digits.length >= 3 && contact.phones.any((p) => _digits(p).contains(digits));
}

class ContactsSearchTool extends _ContactTool {
  ContactsSearchTool(super.backend, super.labels);

  @override
  String get name => 'contacts_search';

  @override
  String get description =>
      'Find contacts by name, company, phone number or email. With no query, list contacts in '
      'name order. Returns id, name, numbers and emails. Use contacts_get for the full record.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'query': stringProp(
      'Text to look for in names, companies, numbers and emails. Leave out to list contacts.',
    ),
    'limit': intProp('How many matches to list (default 25, max 100).'),
  });

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String describeCall(Map<String, dynamic> args) {
    final query = argString(args, 'query') ?? '';
    return query.isEmpty ? 'List contacts' : 'Search contacts for "$query"';
  }

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final query = argString(args, 'query') ?? '';
    final all = (await backend.all()).toList();
    final matches = (query.isEmpty ? all : all.where((c) => _matches(c, query)))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (matches.isEmpty) {
      return ToolResult(
        query.isEmpty ? 'No contacts on this device.' : 'No contacts match "$query".',
      );
    }
    final limit = listLimit(args);
    final shown = matches.take(limit).toList();
    for (final contact in shown) {
      final id = contact.id;
      if (id != null) labels.remember(id, _label(contact));
    }
    final header = matches.length > shown.length
        ? '${matches.length} contacts, showing the first ${shown.length}:'
        : '${matches.length} contact(s):';
    return ToolResult([header, for (final c in shown) _contactLine(c)].join('\n'));
  }
}

class ContactsGetTool extends _ContactTool {
  ContactsGetTool(super.backend, super.labels);

  @override
  String get name => 'contacts_get';

  @override
  String get description => 'Read one contact in full: name, numbers, emails, company and note.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'id': stringProp('The contact id from contacts_search.'),
  }, required: const ['id']);

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Read contact ${labels.describe(argString(args, 'id') ?? '')}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final id = requireArg(args, 'id');
    final contact = await backend.get(id) ?? (throw ToolError('No contact with id $id.'));
    labels.remember(id, _label(contact));
    return ToolResult([
      'id: $id',
      'name: ${contact.name}',
      if (contact.phones.isNotEmpty) 'phones: ${contact.phones.join(', ')}',
      if (contact.emails.isNotEmpty) 'emails: ${contact.emails.join(', ')}',
      if (contact.company != null) 'company: ${contact.company}',
      if (contact.note != null) 'note: ${clip(contact.note!, 1000)}',
    ].join('\n'));
  }
}

class ContactsCreateTool extends _ContactTool {
  ContactsCreateTool(super.backend, super.labels);

  @override
  String get name => 'contacts_create';

  @override
  String get description =>
      'Add a contact. Give the full name and any numbers, emails, company or note. Returns its id.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'name': stringProp('Full name, e.g. "Ana Putri".'),
    'phones': stringListProp('Phone numbers, with country code if known.'),
    'emails': stringListProp('Email addresses.'),
    'company': stringProp('Company or organisation. Optional.'),
    'note': stringProp('A note about the contact. Optional.'),
  }, required: const ['name']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) {
    final name = argString(args, 'name') ?? '';
    final details = [
      ...?argStrings(args, 'phones'),
      ...?argStrings(args, 'emails'),
    ];
    final suffix = details.isEmpty ? '' : ' (${details.join(', ')})';
    return "Add contact '$name'$suffix";
  }

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final name = requireArg(args, 'name');
    final contact = ContactInfo(
      name: name,
      phones: argStrings(args, 'phones') ?? const [],
      emails: argStrings(args, 'emails') ?? const [],
      company: textOr(args, 'company', null),
      note: textOr(args, 'note', null),
    );
    final id = await backend.create(contact);
    labels.remember(id, _label(contact));
    return ToolResult('Added contact "$name" (id $id).');
  }
}

class ContactsUpdateTool extends _ContactTool {
  ContactsUpdateTool(super.backend, super.labels);

  @override
  String get name => 'contacts_update';

  @override
  String get description =>
      'Change a contact. Fields left out keep their value. Phones and emails, when given, replace the '
      'whole list. An empty company or note clears it.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'id': stringProp('The contact id.'),
    'name': stringProp('New full name.'),
    'phones': stringListProp('The complete list of phone numbers.'),
    'emails': stringListProp('The complete list of email addresses.'),
    'company': stringProp('Company; "" clears it.'),
    'note': stringProp('Note; "" clears it.'),
  }, required: const ['id']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) {
    final id = argString(args, 'id') ?? '';
    final parts = <String>[];
    final name = argString(args, 'name');
    if (name != null && name.isNotEmpty) parts.add("name '$name'");
    final phones = argStrings(args, 'phones');
    if (phones != null) parts.add('phones ${phones.isEmpty ? 'cleared' : phones.join(', ')}');
    final emails = argStrings(args, 'emails');
    if (emails != null) parts.add('emails ${emails.isEmpty ? 'cleared' : emails.join(', ')}');
    if (args.containsKey('company')) {
      final company = argString(args, 'company') ?? '';
      parts.add(company.isEmpty ? 'company cleared' : 'company $company');
    }
    if (args.containsKey('note')) {
      final note = argString(args, 'note') ?? '';
      parts.add(note.isEmpty ? 'note cleared' : 'note ${clip(note, 60)}');
    }
    final what = parts.isEmpty ? '' : ': ${parts.join(', ')}';
    return 'Update contact ${labels.describe(id)}$what';
  }

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final id = requireArg(args, 'id');
    final current = await backend.get(id) ?? (throw ToolError('No contact with id $id.'));
    final name = argString(args, 'name');
    if (name != null && name.isEmpty) throw const ToolError('name cannot be empty.');
    final updated = ContactInfo(
      id: id,
      name: name ?? current.name,
      phones: argStrings(args, 'phones') ?? current.phones,
      emails: argStrings(args, 'emails') ?? current.emails,
      company: textOr(args, 'company', current.company),
      note: textOr(args, 'note', current.note),
    );
    await backend.update(updated);
    labels.remember(id, _label(updated));
    return ToolResult('Updated contact "${updated.name}".');
  }
}

class ContactsDeleteTool extends _ContactTool {
  ContactsDeleteTool(super.backend, super.labels);

  @override
  String get name => 'contacts_delete';

  @override
  String get description =>
      'Delete a contact for good. Get the id from contacts_search.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'id': stringProp('The contact id.'),
  }, required: const ['id']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Delete contact ${labels.describe(argString(args, 'id') ?? '')}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final id = requireArg(args, 'id');
    // Looked up before deleting, so the result says whose contact was removed.
    final contact = await backend.get(id) ?? (throw ToolError('No contact with id $id.'));
    await backend.delete(id);
    labels.forget(id);
    return ToolResult('Deleted contact "${contact.name}".');
  }
}
