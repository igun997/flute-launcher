const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "Friday, 20 November 2026, 14:05 (UTC+07:00)".
String describeNow(DateTime now) {
  final off = now.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final h = off.inHours.abs();
  final m = off.inMinutes.abs() % 60;
  return '${_weekdays[now.weekday - 1]}, ${now.day} ${_months[now.month - 1]} ${now.year}, '
      '${_two(now.hour)}:${_two(now.minute)} (UTC$sign${_two(h)}:${_two(m)})';
}

/// The system prompt for one turn. Kept short: it is paid for on every request.
String buildInstructions({required DateTime now, String skillCatalogue = ''}) {
  final b = StringBuffer()
    ..writeln('You are Flute, a calm assistant inside the user\'s Android home screen.')
    ..writeln('Answer briefly and plainly. Use Markdown only when it helps (lists, code, tables).')
    ..writeln('The current date and time is ${describeNow(now)}. Resolve "today", "tomorrow" and weekdays from it.')
    ..writeln()
    ..writeln('Tools: use them when the user asks about their calendar, contacts, notes or a connected service.')
    ..writeln('Look things up before changing them, and never invent ids. Every change is shown to the user for '
        'approval first; if they decline, do not retry the same action, ask what they want instead.')
    ..writeln('After a tool result, tell the user what you found or did in one or two sentences.');
  final catalogue = skillCatalogue.trim();
  if (catalogue.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Skills are instruction packs the user installed. When one clearly matches the request, call '
          'skill_load with its name first and follow it. Installed skills:')
      ..writeln(catalogue);
  }
  return b.toString().trimRight();
}
