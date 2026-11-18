import 'agent_tool.dart';
import 'calendar_backend.dart';
import 'tool_support.dart';

const _deniedMessage =
    'Calendar access was denied. Turn it on in Settings > Apps > Flute > Permissions.';

/// The calendar tools. [backend] is the device calendar; [now] is injectable for tests.
List<AgentTool> calendarTools({required CalendarBackend backend, Clock? now}) {
  final labels = RecentLabels();
  final clock = now ?? DateTime.now;
  return [
    CalendarListCalendarsTool(backend, labels),
    CalendarListEventsTool(backend, labels, clock),
    CalendarCreateEventTool(backend, labels),
    CalendarUpdateEventTool(backend, labels),
    CalendarDeleteEventTool(backend, labels),
  ];
}

abstract class _CalendarTool extends BuiltinTool {
  _CalendarTool(this.backend, this.labels)
    : super(subject: 'Calendar', access: backend.ensureAccess, deniedMessage: _deniedMessage);

  final CalendarBackend backend;
  final RecentLabels labels;

  @override
  String get source => 'calendar';
}

String _label(CalendarEvent event) =>
    "'${event.title}' (${rangeText(event.start, event.end, allDay: event.allDay)})";

String _eventLine(CalendarEvent event) {
  final location = event.location;
  final where = location == null ? '' : ' | at ${clip(location, 80)}';
  final calendar = event.calendarId ?? 'unknown';
  final range = rangeText(event.start, event.end, allDay: event.allDay);
  return '- ${event.id ?? ''} | ${event.title} | $range | calendar $calendar$where';
}

/// Start and exclusive end for a new event. An all-day [end] is the last day, inclusive.
({DateTime start, DateTime end}) _newSpan(Map<String, dynamic> args, bool allDay) {
  final startAt = requireWhen(args, 'start');
  final endAt = optionalWhen(args, 'end');
  if (allDay) {
    final first = dayStart(startAt);
    final last = endAt == null ? first : dayStart(endAt);
    if (last.isBefore(first)) throw const ToolError('end must be on or after the start day.');
    return (start: first, end: addDays(last, 1));
  }
  final end = endAt ?? startAt.add(const Duration(hours: 1));
  if (end.isBefore(startAt)) throw const ToolError('end must not be before start.');
  return (start: startAt, end: end);
}

/// The end an event keeps when its start or its all-day flag changes but its end does not: the
/// same length, in the same kind (timed or all-day).
DateTime _keptEnd(CalendarEvent old, DateTime start, bool allDay) {
  if (allDay) {
    final days = old.allDay ? dayDiff(old.start, old.end) : 1;
    return addDays(start, days < 1 ? 1 : days);
  }
  if (old.allDay) return start.add(const Duration(hours: 1));
  final length = old.end.difference(old.start);
  return start.add(length.isNegative ? const Duration(hours: 1) : length);
}

class CalendarListCalendarsTool extends _CalendarTool {
  CalendarListCalendarsTool(super.backend, super.labels);

  @override
  String get name => 'calendar_list_calendars';

  @override
  String get description =>
      'List the calendars on this device: id, name, account. Pass an id as calendarId when creating '
      'an event.';

  @override
  Map<String, dynamic> get parameters => objectSchema({});

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String describeCall(Map<String, dynamic> args) => 'List calendars';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final calendars = await backend.calendars();
    if (calendars.isEmpty) return const ToolResult('No calendars on this device.');
    return ToolResult([
      for (final c in calendars)
        [
          '- ${c.id} | ${c.name}',
          if (c.account != null) 'account ${c.account}',
          if (c.isPrimary) 'primary',
          if (c.readOnly) 'read-only',
        ].join(' | '),
    ].join('\n'));
  }
}

class CalendarListEventsTool extends _CalendarTool {
  CalendarListEventsTool(super.backend, super.labels, this._now);

  final Clock _now;

  @override
  String get name => 'calendar_list_events';

  @override
  String get description =>
      'List calendar events overlapping a time range, earliest first. "from" defaults to the start '
      'of today and "to" to 7 days after "from". Ranges over 366 days are cut. Returns the id each '
      'event needs for calendar_update_event and calendar_delete_event.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'from': stringProp(
      'Local start: ISO 8601 such as 2026-11-20T09:00, or a date such as 2026-11-20. Default today.',
    ),
    'to': stringProp(
      'Local end: ISO 8601 date-time, or a date (the whole day is included). Default 7 days after from.',
    ),
    'calendarId': stringProp('Only this calendar (an id from calendar_list_calendars).'),
    'limit': intProp('How many events to list (default 50, max 200).'),
  });

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String describeCall(Map<String, dynamic> args) => 'List calendar events';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final from = optionalWhen(args, 'from') ?? dayStart(_now());
    final toText = argString(args, 'to') ?? '';
    final typedTo = optionalWhen(args, 'to');
    if (typedTo != null && typedTo.isBefore(from)) throw const ToolError('to must be after from.');
    var to = typedTo ?? addDays(from, 7);
    // A plain date means that whole day, so "to" is inclusive.
    if (typedTo != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(toText)) {
      to = addDays(typedTo, 1);
    }
    if (to.isBefore(from)) throw const ToolError('to must be after from.');
    final latest = addDays(from, 366);
    final clamped = to.isAfter(latest);
    if (clamped) to = latest;
    final clampNote = clamped
        ? '\nThe range is longer than 366 days, so it was cut to ${isoLocal(to)}.'
        : '';
    final calendarId = argString(args, 'calendarId');
    final events = await backend.events(
      start: from,
      end: to,
      calendarIds: calendarId == null || calendarId.isEmpty ? null : [calendarId],
    );
    if (events.isEmpty) {
      return ToolResult('No events from ${isoLocal(from)} to ${isoLocal(to)}.$clampNote');
    }
    final requested = argInt(args, 'limit') ?? 50;
    final limit = requested < 1 ? 1 : (requested > 200 ? 200 : requested);
    final shown = events.take(limit).toList();
    for (final event in shown) {
      final id = event.id;
      if (id != null) labels.remember(id, _label(event));
    }
    final header = events.length > shown.length
        ? '${events.length} events match, showing the first ${shown.length}. '
              'The list was cut: narrow the range or raise limit (max 200).'
        : '${events.length} event(s) match:';
    return ToolResult(
      [header, for (final event in shown) _eventLine(event)].join('\n') + clampNote,
    );
  }
}

class CalendarCreateEventTool extends _CalendarTool {
  CalendarCreateEventTool(super.backend, super.labels);

  @override
  String get name => 'calendar_create_event';

  @override
  String get description =>
      'Create a calendar event. Times are local ISO 8601 ("2026-11-20T14:00"); without an end a timed '
      'event lasts one hour. For all-day events give dates ("2026-11-20") and set allDay; then end is '
      'the last day, inclusive, and defaults to the start day. Use calendar_list_calendars for calendarId.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'title': stringProp('Event title.'),
    'start': stringProp('Local ISO 8601 start.'),
    'end': stringProp('Local ISO 8601 end (timed), or last day (all-day). Optional.'),
    'allDay': boolProp('True for an all-day event.'),
    'location': stringProp('Place. Optional.'),
    'description': stringProp('Notes. Optional.'),
    'calendarId': stringProp('Calendar id. Optional: the default calendar.'),
  }, required: const ['title', 'start']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) {
    final title = argString(args, 'title') ?? '';
    final start = parseWhen(argString(args, 'start') ?? '');
    if (start == null) return "Create calendar event '$title'";
    final allDay = argBool(args, 'allDay') ?? false;
    final location = argString(args, 'location');
    final where = location == null || location.isEmpty ? '' : ' at ${clip(location, 60)}';
    return "Create calendar event '$title' on ${whenText(start, allDay: allDay)}$where";
  }

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final title = requireArg(args, 'title');
    final allDay = argBool(args, 'allDay') ?? false;
    final span = _newSpan(args, allDay);
    final calendarId = argString(args, 'calendarId');
    final event = CalendarEvent(
      calendarId: calendarId == null || calendarId.isEmpty ? null : calendarId,
      title: title,
      start: span.start,
      end: span.end,
      allDay: allDay,
      location: textOr(args, 'location', null),
      description: textOr(args, 'description', null),
    );
    final id = await backend.createEvent(event);
    labels.remember(id, _label(event));
    final range = rangeText(event.start, event.end, allDay: allDay);
    return ToolResult('Created event "$title" (id $id) on $range.');
  }
}

class CalendarUpdateEventTool extends _CalendarTool {
  CalendarUpdateEventTool(super.backend, super.labels);

  @override
  String get name => 'calendar_update_event';

  @override
  String get description =>
      'Change one event (or one occurrence) by id from calendar_list_events. Only the fields given change. '
      'Give start alone to move an event and keep its length. An empty location or description clears it.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'id': stringProp('Event id from calendar_list_events.'),
    'title': stringProp('New title.'),
    'start': stringProp('New local ISO 8601 start.'),
    'end': stringProp('New local ISO 8601 end (timed), or last day (all-day).'),
    'allDay': boolProp('Switch between all-day and timed.'),
    'location': stringProp('New place; "" clears it.'),
    'description': stringProp('New notes; "" clears them.'),
  }, required: const ['id']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) {
    final id = argString(args, 'id') ?? '';
    final allDay = argBool(args, 'allDay');
    final parts = <String>[];
    final title = argString(args, 'title');
    if (title != null && title.isNotEmpty) parts.add("title '$title'");
    final start = parseWhen(argString(args, 'start') ?? '');
    if (start != null) parts.add('start ${whenText(start, allDay: allDay ?? false)}');
    final end = parseWhen(argString(args, 'end') ?? '');
    if (end != null) parts.add('end ${whenText(end, allDay: allDay ?? false)}');
    if (allDay != null) parts.add(allDay ? 'all-day' : 'timed');
    if (args.containsKey('location')) {
      final location = argString(args, 'location') ?? '';
      parts.add(location.isEmpty ? 'no location' : "location '${clip(location, 60)}'");
    }
    if (args.containsKey('description')) parts.add('notes changed');
    final what = parts.isEmpty ? '' : ': ${parts.join(', ')}';
    return 'Update calendar event ${labels.describe(id)}$what';
  }

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final id = requireArg(args, 'id');
    final old = await backend.event(id) ?? (throw ToolError('No calendar event with id $id.'));
    final title = argString(args, 'title');
    if (title != null && title.isEmpty) throw const ToolError('title cannot be empty.');
    final allDay = argBool(args, 'allDay') ?? old.allDay;
    final startAt = optionalWhen(args, 'start');
    final endAt = optionalWhen(args, 'end');

    final base = startAt ?? old.start;
    final start = allDay ? dayStart(base) : base;
    final end = endAt == null
        ? _keptEnd(old, start, allDay)
        : (allDay ? addDays(dayStart(endAt), 1) : endAt);
    if (allDay ? !end.isAfter(start) : end.isBefore(start)) {
      throw ToolError(
        allDay ? 'end must be on or after the start day.' : 'end must not be before start.',
      );
    }

    final updated = CalendarEvent(
      id: id,
      calendarId: old.calendarId,
      title: title ?? old.title,
      start: start,
      end: end,
      allDay: allDay,
      location: textOr(args, 'location', old.location),
      description: textOr(args, 'description', old.description),
    );
    await backend.updateEvent(updated);
    labels.remember(id, _label(updated));
    final range = rangeText(updated.start, updated.end, allDay: allDay);
    return ToolResult('Updated event "${updated.title}" on $range.');
  }
}

class CalendarDeleteEventTool extends _CalendarTool {
  CalendarDeleteEventTool(super.backend, super.labels);

  @override
  String get name => 'calendar_delete_event';

  @override
  String get description =>
      'Delete one event (or one occurrence of a recurring event) by id from calendar_list_events. '
      'This cannot be undone.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'id': stringProp('Event id from calendar_list_events.'),
  }, required: const ['id']);

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Delete calendar event ${labels.describe(argString(args, 'id') ?? '')}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final id = requireArg(args, 'id');
    // Looked up before deleting, so the result says what was removed.
    final event = await backend.event(id) ?? (throw ToolError('No calendar event with id $id.'));
    await backend.deleteEvent(id);
    labels.forget(id);
    final range = rangeText(event.start, event.end, allDay: event.allDay);
    return ToolResult('Deleted event "${event.title}" on $range.');
  }
}
