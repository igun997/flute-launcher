import 'package:device_calendar_plus/device_calendar_plus.dart';

import 'tool_support.dart';

/// A calendar on the device.
class CalendarInfo {
  const CalendarInfo({
    required this.id,
    required this.name,
    this.account,
    this.readOnly = false,
    this.isPrimary = false,
  });

  final String id;
  final String name;
  final String? account;
  final bool readOnly;
  final bool isPrimary;
}

/// An event, or one occurrence of a recurring event, in local time.
///
/// [id] is the instance id that updates and deletes take. For all-day events [start] is midnight of
/// the first day and [end] is exclusive: midnight after the last day.
class CalendarEvent {
  const CalendarEvent({
    this.id,
    this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location,
    this.description,
  });

  final String? id;

  /// The calendar it belongs to; for a new event, the calendar to create it in (null: default).
  final String? calendarId;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String? location;
  final String? description;
}

/// The device calendar, as the tools need it. Implemented by [DeviceCalendarBackend]; tests use a
/// fake. Failures the person should read are thrown as [ToolError].
abstract class CalendarBackend {
  Future<bool> hasAccess();

  /// Shows the system dialog when access is missing. True when granted.
  Future<bool> requestAccess();

  /// Access is held, or was just granted.
  Future<bool> ensureAccess() async => await hasAccess() || await requestAccess();

  Future<List<CalendarInfo>> calendars();

  /// Events overlapping `[start, end)`, sorted by start. Null or empty [calendarIds]: all calendars.
  Future<List<CalendarEvent>> events({
    required DateTime start,
    required DateTime end,
    List<String>? calendarIds,
  });

  /// The event (or occurrence) with [id], or null.
  Future<CalendarEvent?> event(String id);

  /// Returns the new event's id.
  Future<String> createEvent(CalendarEvent event);

  /// Writes every field of [event]; [CalendarEvent.id] must be set.
  Future<void> updateEvent(CalendarEvent event);

  Future<void> deleteEvent(String id);
}

/// [CalendarBackend] over device_calendar_plus.
class DeviceCalendarBackend extends CalendarBackend {
  DeviceCalendarBackend({DeviceCalendar? calendar})
    : _calendar = calendar ?? DeviceCalendar.instance;

  final DeviceCalendar _calendar;

  @override
  Future<bool> hasAccess() async =>
      (await _calendar.hasPermissions()) == CalendarPermissionStatus.granted;

  @override
  Future<bool> requestAccess() async =>
      (await _calendar.requestPermissions()) == CalendarPermissionStatus.granted;

  @override
  Future<List<CalendarInfo>> calendars() => _guard(() async => [
    for (final c in await _calendar.listCalendars())
      CalendarInfo(
        id: c.id,
        name: c.name,
        account: c.accountName,
        readOnly: c.readOnly,
        isPrimary: c.isPrimary,
      ),
  ]);

  @override
  Future<List<CalendarEvent>> events({
    required DateTime start,
    required DateTime end,
    List<String>? calendarIds,
  }) => _guard(() async => [
    for (final e in await _calendar.listEvents(
      start,
      end,
      calendarIds: calendarIds,
    ))
      _fromPlugin(e),
  ]);

  @override
  Future<CalendarEvent?> event(String id) => _guard(() async {
    final event = await _calendar.getEvent(id);
    return event == null ? null : _fromPlugin(event);
  });

  @override
  Future<String> createEvent(CalendarEvent event) => _guard(
    () => _calendar.createEvent(
      calendarId: event.calendarId,
      title: event.title,
      startDate: event.start,
      endDate: event.end,
      isAllDay: event.allDay,
      description: event.description,
      location: event.location,
    ),
  );

  @override
  Future<void> updateEvent(CalendarEvent event) {
    final id = event.id;
    if (id == null) throw ArgumentError.value(event, 'event', 'Missing event id');
    return _guard(
      () => _calendar.updateEvent(
        instanceId: id,
        title: event.title,
        startDate: event.start,
        endDate: event.end,
        isAllDay: event.allDay,
        description: _patch(event.description),
        location: _patch(event.location),
      ),
    );
  }

  @override
  Future<void> deleteEvent(String id) =>
      _guard(() => _calendar.deleteEvent(instanceId: id));
}

CalendarEvent _fromPlugin(Event event) => CalendarEvent(
  id: event.instanceId,
  calendarId: event.calendarId,
  title: event.title,
  start: event.startDate,
  end: event.endDate,
  allDay: event.isAllDay,
  location: _nonBlank(event.location),
  description: _nonBlank(event.description),
);

Patch<String> _patch(String? value) =>
    value == null ? Patch<String>.clear() : Patch<String>.set(value);

String? _nonBlank(String? value) =>
    value == null || value.trim().isEmpty ? null : value;

/// Turns the plugin's exceptions into messages the model can read, keeping the platform text out.
Future<T> _guard<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on DeviceCalendarException catch (e) {
    throw ToolError(_messageFor(e.errorCode));
  }
}

String _messageFor(DeviceCalendarError code) => switch (code) {
  DeviceCalendarError.permissionDenied => 'Calendar access was denied.',
  DeviceCalendarError.notFound => 'That calendar event no longer exists.',
  DeviceCalendarError.readOnly => 'That calendar is read-only.',
  DeviceCalendarError.invalidArguments => 'The calendar rejected those values.',
  _ => 'The calendar could not complete the request (${code.name}).',
};
