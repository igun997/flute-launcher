import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/agent/tools/contact_tools.dart';
import 'package:focus_launcher/agent/tools/contacts_backend.dart';

import 'fakes.dart';

const _denied =
    'Contacts access was denied. Turn it on in Settings > Apps > Flute > Permissions.';

Map<String, AgentTool> _toolsFor(ContactsBackend backend) => {
  for (final tool in contactTools(backend)) tool.name: tool,
};

void main() {
  late FakeContactsBackend backend;
  late Map<String, AgentTool> tools;

  setUp(() {
    backend = FakeContactsBackend();
    tools = _toolsFor(backend);
  });

  Future<ToolResult> call(String name, Map<String, dynamic> args) => tools[name]!.run(args);

  Future<String> addAna() async {
    final result = await call('contacts_create', {
      'name': 'Ana Putri',
      'phones': ['+62 812 3456 7890'],
      'emails': ['ana@example.com'],
      'company': 'Kompas Studio',
      'note': 'Met at the meetup',
    });
    expect(result.isError, isFalse);
    return backend.stored.keys.single;
  }

  group('search', () {
    test('matches names case-insensitively and lists the numbers and emails', () async {
      await addAna();
      await call('contacts_create', {'name': 'Budi Santoso', 'phones': ['0811 000 111']});

      final result = await call('contacts_search', {'query': 'ANA'});
      expect(result.text, '1 contact(s):\n'
          '- c1 | Ana Putri | +62 812 3456 7890 | ana@example.com');
    });

    test('digits find a number written with a country code', () async {
      await addAna();
      final result = await call('contacts_search', {'query': '812345'});
      expect(result.text, contains('Ana Putri'));
    });

    test('a query that matches nothing says so', () async {
      final result = await call('contacts_search', {'query': 'nobody'});
      expect(result.isError, isFalse);
      expect(result.text, 'No contacts match "nobody".');
    });
  });

  test('contacts_get shows every field of the contact', () async {
    final id = await addAna();
    final result = await call('contacts_get', {'id': id});
    expect(result.text, 'id: $id\n'
        'name: Ana Putri\n'
        'phones: +62 812 3456 7890\n'
        'emails: ana@example.com\n'
        'company: Kompas Studio\n'
        'note: Met at the meetup');
  });

  test('an unknown id is an error', () async {
    final result = await call('contacts_get', {'id': 'c99'});
    expect(result.isError, isTrue);
    expect(result.text, 'No contact with id c99.');
  });

  test('create describes itself with the numbers and emails', () {
    expect(
      tools['contacts_create']!.describeCall({
        'name': 'Ana Putri',
        'phones': ['+62 812 3456 7890'],
        'emails': ['ana@example.com'],
      }),
      "Add contact 'Ana Putri' (+62 812 3456 7890, ana@example.com)",
    );
  });

  test('a contact needs a name', () async {
    final result = await call('contacts_create', {'phones': ['123']});
    expect(result.isError, isTrue);
    expect(result.text, 'name is required.');
    expect(backend.stored, isEmpty);
  });

  group('update', () {
    test('fields left out keep their value; phones replace the whole list', () async {
      final id = await addAna();
      final result = await call('contacts_update', {
        'id': id,
        'phones': ['+62 811 000 111', '+62 812 3456 7890'],
      });
      expect(result.isError, isFalse);
      final updated = backend.stored[id]!;
      expect(updated.name, 'Ana Putri');
      expect(updated.phones, ['+62 811 000 111', '+62 812 3456 7890']);
      expect(updated.emails, ['ana@example.com']);
      expect(updated.company, 'Kompas Studio');
    });

    test('an empty company clears it', () async {
      final id = await addAna();
      await call('contacts_update', {'id': id, 'company': ''});
      expect(backend.stored[id]!.company, isNull);
    });

    test('describeCall lists the fields being changed', () async {
      final id = await addAna();
      await call('contacts_search', {'query': 'Ana'});
      expect(
        tools['contacts_update']!.describeCall({'id': id, 'phones': <String>[]}),
        "Update contact 'Ana Putri': phones cleared",
      );
    });

    test('an unknown id is an error', () async {
      final result = await call('contacts_update', {'id': 'c42', 'name': 'Nobody'});
      expect(result.isError, isTrue);
      expect(result.text, 'No contact with id c42.');
    });
  });

  test('delete names the contact it removed', () async {
    final id = await addAna();
    final result = await call('contacts_delete', {'id': id});
    expect(result.isError, isFalse);
    expect(result.text, 'Deleted contact "Ana Putri".');
    expect(backend.stored, isEmpty);
  });

  test('access is requested once and a refusal is reported without touching contacts', () async {
    final refusing = FakeContactsBackend(granted: false, grantWhenAsked: false);
    final refusingTools = _toolsFor(refusing);

    final result = await refusingTools['contacts_search']!.run({'query': 'x'});
    expect(result.isError, isTrue);
    expect(result.text, _denied);
    expect(refusing.accessRequests, 1);

    final write = await refusingTools['contacts_create']!.run({'name': 'Ana'});
    expect(write.text, _denied);
    expect(refusing.stored, isEmpty);
  });

  test('a grant lets the call through', () async {
    final asking = FakeContactsBackend(granted: false, grantWhenAsked: true);
    final result = await _toolsFor(asking)['contacts_search']!.run({'query': 'x'});
    expect(result.isError, isFalse);
    expect(asking.granted, isTrue);
  });

  test('reads are read tools and every change is a write tool', () {
    for (final name in ['contacts_search', 'contacts_get']) {
      expect(tools[name]!.risk, ToolRisk.read, reason: name);
    }
    for (final name in ['contacts_create', 'contacts_update', 'contacts_delete']) {
      expect(tools[name]!.risk, ToolRisk.write, reason: name);
      expect(tools[name]!.source, 'contacts');
    }
  });
}
