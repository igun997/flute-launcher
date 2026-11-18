import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/core/app_repository.dart';
import 'package:focus_launcher/core/category_engine.dart';
import 'package:focus_launcher/core/mode_engine.dart';
import 'package:focus_launcher/lock/lock_settings.dart';
import 'package:focus_launcher/pets/pet_settings.dart';
import 'package:focus_launcher/agent/tools/builtin_tools.dart';
import 'package:focus_launcher/agent/tools/notes_store.dart';
import 'package:focus_launcher/agent/tools/time_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Tool names without the launcher group, which has its own tests.
List<String> _namesOf(List<AgentTool> tools) => [for (final t in tools) if (!t.name.startsWith('launcher_')) t.name];

void main() {
  late Directory dir;
  late SharedPreferences prefs;
  late FakeCalendarBackend calendar;
  late FakeContactsBackend contacts;
  late BuiltinTools builtins;

  BuiltinTools openBuiltins() => BuiltinTools(
    prefs: prefs,
    modes: ModeEngine(prefs),
    apps: AppRepository(prefs, CategoryEngine({})),
    lock: LockSettings(prefs),
    pets: PetSettings(prefs),
    notes: NotesStore(file: File('${dir.path}/notes.json')),
    calendar: calendar,
    contacts: contacts,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('builtin_tools_test');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    calendar = FakeCalendarBackend(granted: false, grantWhenAsked: true);
    contacts = FakeContactsBackend(granted: false, grantWhenAsked: false);
    builtins = openBuiltins();
  });

  tearDown(() async {
    builtins.dispose();
    await dir.delete(recursive: true);
  });

  test('notes default to on; calendar and contacts default to off', () {
    expect(builtins.isEnabled('notes'), isTrue);
    expect(builtins.isEnabled('calendar'), isFalse);
    expect(builtins.isEnabled('contacts'), isFalse);
  });

  test('the time tool is always offered; a group is offered only while on', () async {
    expect(_namesOf(builtins.tools), [
      'current_time',
      'notes_list',
      'notes_search',
      'notes_read',
      'notes_create',
      'notes_update',
      'notes_delete',
    ]);

    await builtins.setEnabled('calendar', true);
    expect(_namesOf(builtins.tools), contains('calendar_create_event'));
    expect(_namesOf(builtins.tools), isNot(contains('contacts_search')));

    await builtins.setEnabled('notes', false);
    expect(_namesOf(builtins.tools), isNot(contains('notes_list')));
    expect(_namesOf(builtins.tools).first, 'current_time');
  });

  test('a change to a group is announced once, and not for a no-op', () async {
    var announced = 0;
    final sub = builtins.changes.listen((_) => announced++);
    addTearDown(sub.cancel);

    await builtins.setEnabled('contacts', true);
    await builtins.setEnabled('contacts', true);
    await builtins.setEnabled('contacts', false);
    await Future<void>.delayed(Duration.zero);

    expect(announced, 2);
    expect(builtins.isEnabled('contacts'), isFalse);
  });

  test('the choice is stored under agent.tools.<group> and read back', () async {
    await builtins.setEnabled('calendar', true);
    expect(prefs.getBool('agent.tools.calendar'), isTrue);

    final reopened = openBuiltins();
    addTearDown(reopened.dispose);
    expect(reopened.isEnabled('calendar'), isTrue);
  });

  test('an unknown group is rejected', () async {
    expect(() => builtins.isEnabled('email'), throwsArgumentError);
    await expectLater(builtins.setEnabled('email', true), throwsArgumentError);
    expect(() => builtins.requestPermission('email'), throwsArgumentError);
  });

  test('notes need no permission; calendar and contacts report and request theirs', () async {
    expect(await builtins.hasPermission('notes'), isTrue);
    expect(await builtins.requestPermission('notes'), isTrue);

    expect(await builtins.hasPermission('calendar'), isFalse);
    expect(await builtins.requestPermission('calendar'), isTrue);
    expect(calendar.accessRequests, 1);
    expect(await builtins.hasPermission('calendar'), isTrue);

    expect(await builtins.requestPermission('contacts'), isFalse);
    expect(contacts.accessRequests, 1);
  });

  test('tool objects are kept between reads, so remembered labels survive', () {
    final first = builtins.tools;
    final second = builtins.tools;
    expect(first, hasLength(second.length));
    for (var i = 0; i < first.length; i++) {
      expect(identical(first[i], second[i]), isTrue, reason: first[i].name);
    }
  });

  group('current_time', () {
    test('reports the clock it is given, with the weekday', () async {
      final tool = timeTools(now: () => DateTime(2026, 11, 20, 14, 5, 9)).single;
      expect(tool.risk, ToolRisk.read);
      final result = await tool.run({});
      expect(result.isError, isFalse);
      expect(result.text, startsWith('2026-11-20T14:05:09, Friday (UTC'));
    });
  });
}
