import 'agent_tool.dart';

/// Shared pieces of the built-in tools: argument readers, local date formatting, schema helpers,
/// the error type tools throw for expected failures, and the base class that checks access first.

/// An expected failure with a message the model can read (not found, bad argument, denied).
/// Thrown inside a tool; [BuiltinTool.run] turns it into [ToolResult.error].
class ToolError implements Exception {
  const ToolError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The current local time. Injected so tests run against a fixed clock.
typedef Clock = DateTime Function();

const int defaultListLimit = 25;
const int maxListLimit = 100;

/// A string argument, trimmed. Null when the key is absent or not a string; empty when blank.
String? argString(Map<String, dynamic> args, String key) {
  final value = args[key];
  return value is String ? value.trim() : null;
}

/// A required, non-empty string argument.
String requireArg(Map<String, dynamic> args, String key) {
  final value = argString(args, key);
  if (value == null || value.isEmpty) throw ToolError('$key is required.');
  return value;
}

/// For update arguments: an absent key keeps [current]; a blank string clears it (null).
String? textOr(Map<String, dynamic> args, String key, String? current) {
  final value = argString(args, key);
  if (value == null) return current;
  return value.isEmpty ? null : value;
}

bool? argBool(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is bool) return value;
  if (value is String) {
    final text = value.trim().toLowerCase();
    if (text == 'true') return true;
    if (text == 'false') return false;
  }
  return null;
}

int? argInt(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// A list of non-blank strings. A single string counts as a one-item list. Null when absent.
List<String>? argStrings(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is String) {
    final text = value.trim();
    return text.isEmpty ? const [] : [text];
  }
  if (value is List) {
    return [
      for (final item in value)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }
  return null;
}

/// Result cap for list tools: the argument `limit` clamped to 1..[maxListLimit].
int listLimit(Map<String, dynamic> args) {
  final limit = argInt(args, 'limit') ?? defaultListLimit;
  if (limit < 1) return 1;
  return limit > maxListLimit ? maxListLimit : limit;
}

/// A local date-time ("2026-11-20T14:00") or a date ("2026-11-20"). Null when unparseable.
/// Values with an offset or "Z" are converted to local time.
DateTime? parseWhen(String text) {
  final parsed = DateTime.tryParse(text.trim());
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

/// An optional date-time argument. Null when absent or blank; a [ToolError] when it does not parse.
DateTime? optionalWhen(Map<String, dynamic> args, String key) {
  final text = argString(args, key);
  if (text == null || text.isEmpty) return null;
  final parsed = parseWhen(text);
  if (parsed == null) {
    throw ToolError(
      '$key must be an ISO 8601 date-time such as 2026-11-20T14:00, or a date such as 2026-11-20.',
    );
  }
  return parsed;
}

/// A required date-time argument.
DateTime requireWhen(Map<String, dynamic> args, String key) {
  final value = optionalWhen(args, key);
  if (value == null) throw ToolError('$key is required (ISO 8601, e.g. 2026-11-20T14:00).');
  return value;
}

/// The day at local midnight.
DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

/// [d] moved by whole calendar days, keeping the time of day (DST-safe).
DateTime addDays(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);

/// Whole calendar days from [from] to [to] (negative when [to] is earlier).
int dayDiff(DateTime from, DateTime to) => DateTime.utc(to.year, to.month, to.day)
    .difference(DateTime.utc(from.year, from.month, from.day))
    .inDays;

String two(int n) => n.toString().padLeft(2, '0');

/// `2026-11-20`
String ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';

/// `14:05`
String hm(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

/// `2026-11-20T14:05`, local, as the tools take it back.
String isoLocal(DateTime d) => '${ymd(d)}T${hm(d)}';

const _shortDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// `Fri 2026-11-20 14:05`, or `Fri 2026-11-20` when [allDay].
String whenText(DateTime d, {required bool allDay}) {
  final day = '${_shortDays[d.weekday - 1]} ${ymd(d)}';
  return allDay ? day : '$day ${hm(d)}';
}

/// Human range for a stored event. An all-day [end] is exclusive, so the last shown day is the
/// day before it.
String rangeText(DateTime start, DateTime end, {required bool allDay}) {
  if (allDay) {
    final last = addDays(end, -1);
    if (dayDiff(start, last) <= 0) return whenText(start, allDay: true);
    return '${whenText(start, allDay: true)} to ${whenText(last, allDay: true)}';
  }
  if (dayDiff(start, end) == 0) {
    return '${whenText(start, allDay: false)}-${hm(end)}';
  }
  return '${whenText(start, allDay: false)} to ${whenText(end, allDay: false)}';
}

/// `UTC+07:00`
String offsetText(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  return 'UTC$sign${two(abs.inHours)}:${two(abs.inMinutes % 60)}';
}

/// Shortens [text] to at most [max] characters, ending with "..." when cut.
String clip(String text, int max) {
  final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (single.length <= max) return single;
  return '${single.substring(0, max - 3)}...';
}

Map<String, dynamic> objectSchema(
  Map<String, Map<String, dynamic>> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  if (required.isNotEmpty) 'required': required,
};

Map<String, dynamic> stringProp(String description) => {
  'type': 'string',
  'description': description,
};

Map<String, dynamic> intProp(String description) => {
  'type': 'integer',
  'description': description,
};

Map<String, dynamic> boolProp(String description) => {
  'type': 'boolean',
  'description': description,
};

Map<String, dynamic> stringListProp(String description) => {
  'type': 'array',
  'items': {'type': 'string'},
  'description': description,
};

/// Short labels for items the tools have shown, so a later update or delete can name its target.
/// `describeCall` is synchronous and cannot look items up, so an unseen id is described by id.
class RecentLabels {
  static const _limit = 500;
  final Map<String, String> _labels = {};

  void remember(String id, String label) {
    _labels.remove(id);
    _labels[id] = label;
    if (_labels.length > _limit) _labels.remove(_labels.keys.first);
  }

  void forget(String id) => _labels.remove(id);

  /// `'Dentist' (Fri 2026-11-20 14:00)`, or `with id abc` when the id has not been shown.
  String describe(String id) => _labels[id] ?? 'with id $id';
}

/// Base for the built-in tools. [run] checks access first (when [access] is set), then calls
/// [perform]. Expected failures come back as [ToolResult.error]; nothing is thrown past [run].
abstract class BuiltinTool extends AgentTool {
  BuiltinTool({required this.subject, this.access, this.deniedMessage});

  /// Names the source in failure messages: "Calendar", "Contacts", "Notes".
  final String subject;

  /// Asks for the permission when it is missing. Null when the tool needs none.
  final Future<bool> Function()? access;
  final String? deniedMessage;

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    try {
      final check = access;
      if (check != null && !await check()) {
        return ToolResult.error(deniedMessage ?? '$subject access was denied.');
      }
      return await perform(args);
    } on ToolError catch (e) {
      return ToolResult.error(e.message);
    } catch (e) {
      // The type only: messages can echo the user's own data.
      return ToolResult.error('$subject request failed (${e.runtimeType}).');
    }
  }

  Future<ToolResult> perform(Map<String, dynamic> args);
}
