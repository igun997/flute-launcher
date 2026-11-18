import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/agent/tools/calendar_tools.dart';

import 'fakes.dart';

// 2026-11-19 is a Thursday, so 2026-11-20 is the Friday these tests use.
final _today = DateTime(2026, 11, 19, 9);

const _denied =
    'Calendar access was denied. Turn it on in Settings > Apps > Flute > Permissions.';

Map<String, AgentTool> _toolsFor(FakeCalendarBackend backend) => {
  for (final tool in calendarTools(backend: backend, now: () => _today)) tool.name: tool,
};

void main() {
  late FakeCalendarBackend backend;
  late Map<String, AgentTool> tools;

  setUp(() {
    backend = FakeCalendarBackend();
    tools = _toolsFor(backend);
  });

  Future<ToolResult> call(String name, Map<String, dynamic> args) => tools[name]!.run(args);

  group('listing calendars', () {
    test('shows id, name, account and primary flag', () async {
      final result = await call('calendar_list_calendars', {});
      expect(result.isError, isFalse);
      expect(result.text, '- cal-1 | Personal | account me@example.com | primary');
    });
  });

  group('creating events', () {
    test('a timed event without an end lasts one hour', () async {
      final result = await call('calendar_create_event', {
        'title': 'Dentist',
        'start': '2026-11-20T14:00',
      });
      expect(result.isError, isFalse);
      expect(result.text, startsWith('Created event "Dentist" (id ev1)'));
      final event = backend.stored.single;
      expect(event.start, DateTime(2026, 11, 20, 14));
      expect(event.end, DateTime(2026, 11, 20, 15));
      expect(event.allDay, isFalse);
    });

    test('an all-day end date is the last day, so the stored end is the day after', () async {
      final result = await call('calendar_create_event', {
        'title': 'Conference',
        'start': '2026-11-20',
        'end': '2026-11-21',
        'allDay': true,
      });
      expect(result.isError, isFalse);
      final event = backend.stored.single;
      expect(event.allDay, isTrue);
      expect(event.start, DateTime(2026, 11, 20));
      expect(event.end, DateTime(2026, 11, 22));
    });

    test('an all-day event without an end covers one day', () async {
      await call('calendar_create_event', {
        'title': 'Holiday',
        'start': '2026-11-20',
        'allDay': true,
      });
      expect(backend.stored.single.end, DateTime(2026, 11, 21));
    });

    test('an end before the start is refused and nothing is written', () async {
      final result = await call('calendar_create_event', {
        'title': 'Backwards',
        'start': '2026-11-20T14:00',
        'end': '2026-11-20T13:00',
      });
      expect(result.isError, isTrue);
      expect(result.text, 'end must not be before start.');
      expect(backend.stored, isEmpty);
    });

    test('an unreadable start names the field', () async {
      final result = await call('calendar_create_event', {
        'title': 'Vague',
        'start': 'tomorrow',
      });
      expect(result.isError, isTrue);
      expect(result.text, startsWith('start must be an ISO 8601 date-time'));
    });

    test('a missing title is refused', () async {
      final result = await call('calendar_create_event', {'start': '2026-11-20T14:00'});
      expect(result.isError, isTrue);
      expect(result.text, 'title is required.');
    });

    test('describeCall reads like the event', () {
      final tool = tools['calendar_create_event']!;
      expect(
        tool.describeCall({'title': 'Dentist', 'start': '2026-11-20T14:00'}),
        "Create calendar event 'Dentist' on Fri 2026-11-20 14:00",
      );
      expect(
        tool.describeCall({'title': 'Conference', 'start': '2026-11-20', 'allDay': true}),
        "Create calendar event 'Conference' on Fri 2026-11-20",
      );
    });
  });

  group('listing events', () {
    test('an all-day event shows its last day and the id to follow up with', () async {
      await call('calendar_create_event', {
        'title': 'Conference',
        'start': '2026-11-20',
        'end': '2026-11-21',
        'allDay': true,
      });
      final result = await call('calendar_list_events', {
        'from': '2026-11-20',
        'to': '2026-11-23',
      });
      expect(result.text, '1 event(s):\n'
          '- ev1 | Conference | Fri 2026-11-20 to Sat 2026-11-21 | calendar cal-1');
    });

    test('an empty range says so', () async {
      final result = await call('calendar_list_events', {
        'from': '2026-11-20T00:00',
        'to': '2026-11-21T00:00',
      });
      expect(result.isError, isFalse);
      expect(result.text, 'No events from 2026-11-20T00:00 to 2026-11-21T00:00.');
    });

    test('from defaults to the start of today and to to seven days later', () async {
      await call('calendar_create_event', {'title': 'Soon', 'start': '2026-11-25T10:00'});
      await call('calendar_create_event', {'title': 'Later', 'start': '2026-12-01T10:00'});
      final result = await call('calendar_list_events', {});
      expect(result.text, contains('Soon'));
      expect(result.text, isNot(contains('Later')));
    });

    test('the list is capped and the header says how many there are', () async {
      for (var i = 0; i < 30; i++) {
        await call('calendar_create_event', {'title': 'Event $i', 'start': '2026-11-20T09:00'});
      }
      final result = await call('calendar_list_events', {
        'from': '2026-11-20',
        'to': '2026-11-21',
        'limit': 5,
      });
      final rows = result.text.split('\n').where((line) => line.startsWith('- '));
      expect(rows, hasLength(5));
      expect(result.text.split('\n').first, '30 events, showing the first 5:');
    });

    test('a range ending before it starts is refused', () async {
      final result = await call('calendar_list_events', {
        'from': '2026-11-21',
        'to': '2026-11-20',
      });
      expect(result.isError, isTrue);
      expect(result.text, 'to must be after from.');
    });
  });

  group('updating events', () {
    test('moving the start keeps the length', () async {
      await call('calendar_create_event', {'title': 'Dentist', 'start': '2026-11-20T14:00'});
      final result = await call('calendar_update_event', {
        'id': 'ev1',
        'start': '2026-11-20T16:00',
      });
      expect(result.isError, isFalse);
      final event = backend.stored.single;
      expect(event.start, DateTime(2026, 11, 20, 16));
      expect(event.end, DateTime(2026, 11, 20, 17));
      expect(event.title, 'Dentist');
    });

    test('an empty location clears it and other fields stay', () async {
      await call('calendar_create_event', {
        'title': 'Lunch',
        'start': '2026-11-20T12:00',
        'location': 'Cafe',
        'description': 'Bring the plan',
      });
      await call('calendar_update_event', {'id': 'ev1', 'location': ''});
      final event = backend.stored.single;
      expect(event.location, isNull);
      expect(event.description, 'Bring the plan');
    });

    test('describeCall shows the values the change will write', () {
      expect(
        tools['calendar_update_event']!.describeCall({
          'id': 'ev1',
          'start': '2026-11-20T16:00',
          'location': 'Room 2',
        }),
        "Update calendar event with id ev1: start Fri 2026-11-20 16:00, location 'Room 2'",
      );
    });

    test('switching to all-day keeps the day', () async {
      await call('calendar_create_event', {'title': 'Workshop', 'start': '2026-11-20T09:00'});
      await call('calendar_update_event', {'id': 'ev1', 'allDay': true});
      final event = backend.stored.single;
      expect(event.allDay, isTrue);
      expect(event.start, DateTime(2026, 11, 20));
      expect(event.end, DateTime(2026, 11, 21));
    });

    test('an unknown id is an error', () async {
      final result = await call('calendar_update_event', {'id': 'nope', 'title': 'X'});
      expect(result.isError, isTrue);
      expect(result.text, 'No calendar event with id nope.');
    });
  });

  group('deleting events', () {
    test('names the event it removed', () async {
      await call('calendar_create_event', {'title': 'Dentist', 'start': '2026-11-20T14:00'});
      final result = await call('calendar_delete_event', {'id': 'ev1'});
      expect(result.isError, isFalse);
      expect(result.text, 'Deleted event "Dentist" on Fri 2026-11-20 14:00-15:00.');
      expect(backend.stored, isEmpty);
    });

    test('describeCall names an event shown earlier, and otherwise its id', () async {
      final tool = tools['calendar_delete_event']!;
      expect(tool.describeCall({'id': 'ev1'}), 'Delete calendar event with id ev1');

      await call('calendar_create_event', {'title': 'Dentist', 'start': '2026-11-20T14:00'});
      await call('calendar_list_events', {'from': '2026-11-20', 'to': '2026-11-21'});
      expect(
        tool.describeCall({'id': 'ev1'}),
        "Delete calendar event 'Dentist' (Fri 2026-11-20 14:00-15:00)",
      );
    });

    test('an unknown id is an error and nothing is deleted', () async {
      await call('calendar_create_event', {'title': 'Dentist', 'start': '2026-11-20T14:00'});
      final result = await call('calendar_delete_event', {'id': 'nope'});
      expect(result.isError, isTrue);
      expect(backend.stored, hasLength(1));
    });
  });

  group('permission', () {
    test('is requested once, and a refusal is reported as an error', () async {
      final refusing = FakeCalendarBackend(granted: false, grantWhenAsked: false);
      final refusingTools = _toolsFor(refusing);

      final result = await refusingTools['calendar_list_events']!.run({});
      expect(result.isError, isTrue);
      expect(result.text, _denied);
      expect(refusing.accessRequests, 1);

      final create = await refusingTools['calendar_create_event']!.run({
        'title': 'Dentist',
        'start': '2026-11-20T14:00',
      });
      expect(create.text, _denied);
      expect(refusing.stored, isEmpty);
    });

    test('a grant lets the call through', () async {
      final asking = FakeCalendarBackend(granted: false, grantWhenAsked: true);
      final result = await _toolsFor(asking)['calendar_list_calendars']!.run({});
      expect(result.isError, isFalse);
      expect(asking.accessRequests, 1);
      expect(asking.granted, isTrue);
    });

    test('granted access is not asked for again', () async {
      await call('calendar_list_calendars', {});
      expect(backend.accessRequests, 0);
    });
  });
}
