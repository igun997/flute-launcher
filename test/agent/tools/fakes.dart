import 'package:focus_launcher/agent/tools/calendar_backend.dart';
import 'package:focus_launcher/agent/tools/contacts_backend.dart';

/// An in-memory calendar. Counts access requests, so tests can check the permission was asked once.
class FakeCalendarBackend extends CalendarBackend {
  FakeCalendarBackend({this.granted = true, this.grantWhenAsked = true, List<CalendarInfo>? calendars})
    : _calendars =
          calendars ??
          const [
            CalendarInfo(
              id: 'cal-1',
              name: 'Personal',
              account: 'me@example.com',
              isPrimary: true,
            ),
          ];

  bool granted;
  final bool grantWhenAsked;
  final List<CalendarInfo> _calendars;
  final List<CalendarEvent> stored = [];
  int accessRequests = 0;
  int _nextId = 1;

  @override
  Future<bool> hasAccess() async => granted;

  @override
  Future<bool> requestAccess() async {
    accessRequests++;
    if (grantWhenAsked) granted = true;
    return granted;
  }

  @override
  Future<List<CalendarInfo>> calendars() async => _calendars;

  @override
  Future<List<CalendarEvent>> events({
    required DateTime start,
    required DateTime end,
    List<String>? calendarIds,
  }) async {
    final found = stored
        .where(
          (e) =>
              e.start.isBefore(end) &&
              e.end.isAfter(start) &&
              (calendarIds == null || calendarIds.isEmpty || calendarIds.contains(e.calendarId)),
        )
        .toList();
    found.sort((a, b) => a.start.compareTo(b.start));
    return found;
  }

  @override
  Future<CalendarEvent?> event(String id) async {
    for (final e in stored) {
      if (e.id == id) return e;
    }
    return null;
  }

  @override
  Future<String> createEvent(CalendarEvent event) async {
    final id = 'ev${_nextId++}';
    stored.add(
      CalendarEvent(
        id: id,
        calendarId: event.calendarId ?? 'cal-1',
        title: event.title,
        start: event.start,
        end: event.end,
        allDay: event.allDay,
        location: event.location,
        description: event.description,
      ),
    );
    return id;
  }

  @override
  Future<void> updateEvent(CalendarEvent event) async {
    final index = stored.indexWhere((e) => e.id == event.id);
    if (index < 0) throw StateError('no such event');
    stored[index] = event;
  }

  @override
  Future<void> deleteEvent(String id) async {
    stored.removeWhere((e) => e.id == id);
  }
}

/// In-memory contacts keyed by id. Counts access requests like [FakeCalendarBackend].
class FakeContactsBackend extends ContactsBackend {
  FakeContactsBackend({this.granted = true, this.grantWhenAsked = true});

  bool granted;
  final bool grantWhenAsked;
  final Map<String, ContactInfo> stored = {};
  int accessRequests = 0;
  int _nextId = 1;

  @override
  Future<bool> hasAccess() async => granted;

  @override
  Future<bool> requestAccess() async {
    accessRequests++;
    if (grantWhenAsked) granted = true;
    return granted;
  }

  @override
  Future<List<ContactInfo>> all() async => stored.values.toList();

  @override
  Future<ContactInfo?> get(String id) async => stored[id];

  @override
  Future<String> create(ContactInfo contact) async {
    final id = 'c${_nextId++}';
    stored[id] = ContactInfo(
      id: id,
      name: contact.name,
      phones: contact.phones,
      emails: contact.emails,
      company: contact.company,
      note: contact.note,
    );
    return id;
  }

  @override
  Future<void> update(ContactInfo contact) async {
    final id = contact.id;
    if (id == null || !stored.containsKey(id)) throw StateError('no such contact');
    stored[id] = contact;
  }

  @override
  Future<void> delete(String id) async {
    stored.remove(id);
  }
}
