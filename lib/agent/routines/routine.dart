/// A routine: a saved prompt the model runs on its own on a trigger, reporting by notification.
///
/// Times are local wall-clock times. Daily and weekly routines are built from calendar fields
/// (never by adding 24 hours), so they keep their clock time across daylight-saving changes.
/// Interval routines count elapsed minutes.
library;

const int minIntervalMinutes = 15;
const int maxIntervalMinutes = 7 * 24 * 60;
const int routineResultLimit = 4000;

enum RoutineTrigger { daily, weekly, interval }

class Routine {
  Routine({
    required this.id,
    required this.name,
    required this.prompt,
    required this.trigger,
    this.minuteOfDay = 8 * 60,
    Set<int> weekdays = const {1, 2, 3, 4, 5, 6, 7},
    this.everyMinutes = 60,
    this.enabled = true,
    this.allowWrites = false,
    this.speak = false,
    this.modelOverride,
    this.lastRun,
    this.lastResult,
  }) : weekdays = Set.unmodifiable(weekdays);

  /// Empty for a routine that is not saved yet: the store assigns the id.
  final String id;
  final String name;
  final String prompt;
  final RoutineTrigger trigger;

  /// Minutes after midnight, 0..1439. Used by daily and weekly routines.
  final int minuteOfDay;

  /// ISO weekdays, Monday = 1 .. Sunday = 7. Used by weekly routines.
  final Set<int> weekdays;

  /// Minutes between runs. Used by interval routines.
  final int everyMinutes;
  final bool enabled;

  /// False by default: a routine only reads. True lets it change things, except sandbox code and deletions.
  final bool allowWrites;

  /// Speak a one-sentence summary when the screen is on.
  final bool speak;

  /// Provider model id for this routine only; null uses the chat model.
  final String? modelOverride;
  final DateTime? lastRun;
  final String? lastResult;

  Routine copyWith({
    String? id,
    String? name,
    String? prompt,
    RoutineTrigger? trigger,
    int? minuteOfDay,
    Set<int>? weekdays,
    int? everyMinutes,
    bool? enabled,
    bool? allowWrites,
    bool? speak,
    String? modelOverride,
    bool clearModelOverride = false,
    DateTime? lastRun,
    String? lastResult,
  }) =>
      Routine(
        id: id ?? this.id,
        name: name ?? this.name,
        prompt: prompt ?? this.prompt,
        trigger: trigger ?? this.trigger,
        minuteOfDay: minuteOfDay ?? this.minuteOfDay,
        weekdays: weekdays ?? this.weekdays,
        everyMinutes: everyMinutes ?? this.everyMinutes,
        enabled: enabled ?? this.enabled,
        allowWrites: allowWrites ?? this.allowWrites,
        speak: speak ?? this.speak,
        modelOverride: clearModelOverride ? null : (modelOverride ?? this.modelOverride),
        lastRun: lastRun ?? this.lastRun,
        lastResult: lastResult ?? this.lastResult,
      );

  /// Null when the routine can be saved; otherwise the sentence to show the person.
  String? validationError() {
    if (name.trim().isEmpty) return 'Give the routine a name.';
    if (name.length > 80) return 'Keep the name under 80 characters.';
    if (prompt.trim().isEmpty) return 'Write what the routine should do.';
    if (prompt.length > 4000) return 'Keep the prompt under 4000 characters.';
    if (minuteOfDay < 0 || minuteOfDay > 1439) return 'Choose a time between 00:00 and 23:59.';
    if (trigger == RoutineTrigger.weekly &&
        (weekdays.isEmpty || weekdays.any((d) => d < 1 || d > 7))) {
      return 'Choose at least one day of the week.';
    }
    if (trigger == RoutineTrigger.interval) {
      if (everyMinutes < minIntervalMinutes) return 'An interval must be at least $minIntervalMinutes minutes.';
      if (everyMinutes > maxIntervalMinutes) return 'An interval can be at most 7 days.';
    }
    final model = modelOverride;
    if (model != null && model.length > 200) return 'The model name is too long.';
    return null;
  }

  /// The next time this routine should fire, strictly after [now]; null when it is paused or has
  /// no days. An interval routine that has run uses its last run plus the interval, and once
  /// overdue fires at [now] (once, not for every missed slot).
  DateTime? nextFire(DateTime now) {
    if (!enabled) return null;
    switch (trigger) {
      case RoutineTrigger.daily:
        return _nextOnDaysAfter(now, const {1, 2, 3, 4, 5, 6, 7});
      case RoutineTrigger.weekly:
        return _nextOnDaysAfter(now, weekdays);
      case RoutineTrigger.interval:
        final every = Duration(minutes: everyMinutes);
        final last = lastRun;
        if (last == null) return now.add(every);
        final next = last.add(every);
        return next.isAfter(now) ? next : now;
    }
  }

  /// Sets the clock time on the first day at or after [now] (offset 0..8) that is after [now] and
  /// on one of [days]. Calendar fields only, so DST never shifts the clock time.
  DateTime? _nextOnDaysAfter(DateTime now, Set<int> days) {
    if (days.isEmpty) return null;
    final hour = minuteOfDay ~/ 60;
    final minute = minuteOfDay % 60;
    for (var offset = 0; offset <= 8; offset++) {
      final candidate = DateTime(now.year, now.month, now.day + offset, hour, minute);
      if (candidate.isAfter(now) && days.contains(candidate.weekday)) return candidate;
    }
    return null;
  }

  /// Human summary, e.g. "Every day at 07:30", "Weekdays at 08:00", "Every 90 min".
  String describeTrigger() {
    final at = formatMinuteOfDay(minuteOfDay);
    switch (trigger) {
      case RoutineTrigger.daily:
        return 'Every day at $at';
      case RoutineTrigger.weekly:
        return '${_dayList(weekdays)} at $at';
      case RoutineTrigger.interval:
        return 'Every ${_intervalText(everyMinutes)}';
    }
  }

  /// The routine as the native scheduler needs it. [nextAt] is the first fire time to arm.
  Map<String, Object?> scheduleItem(DateTime? nextAt) => {
        'id': id,
        'trigger': trigger.name,
        'minuteOfDay': minuteOfDay,
        'weekdays': weekdays.toList()..sort(),
        'everyMinutes': everyMinutes,
        'enabled': enabled,
        'nextAtMs': nextAt?.millisecondsSinceEpoch,
      };

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'prompt': prompt,
        'trigger': trigger.name,
        'minuteOfDay': minuteOfDay,
        'weekdays': weekdays.toList()..sort(),
        'everyMinutes': everyMinutes,
        'enabled': enabled,
        'allowWrites': allowWrites,
        'speak': speak,
        'modelOverride': modelOverride,
        'lastRun': lastRun?.toIso8601String(),
        'lastResult': lastResult,
      };

  factory Routine.fromJson(Map<String, Object?> json) {
    final trigger = RoutineTrigger.values.asNameMap()[json['trigger']] ?? RoutineTrigger.daily;
    final weekdays = ((json['weekdays'] as List?) ?? const [])
        .whereType<num>()
        .map((d) => d.toInt())
        .toSet();
    final lastRunText = json['lastRun'] as String?;
    return Routine(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      trigger: trigger,
      minuteOfDay: (json['minuteOfDay'] as num?)?.toInt() ?? 8 * 60,
      weekdays: weekdays.isEmpty && trigger != RoutineTrigger.weekly ? const {1, 2, 3, 4, 5, 6, 7} : weekdays,
      everyMinutes: (json['everyMinutes'] as num?)?.toInt() ?? 60,
      enabled: json['enabled'] as bool? ?? true,
      allowWrites: json['allowWrites'] as bool? ?? false,
      speak: json['speak'] as bool? ?? false,
      modelOverride: json['modelOverride'] as String?,
      lastRun: lastRunText == null ? null : DateTime.tryParse(lastRunText),
      lastResult: json['lastResult'] as String?,
    );
  }
}

/// One finished (or skipped) run of a routine. Kept newest first, the last 20 per routine.
class RoutineRun {
  const RoutineRun({
    required this.id,
    required this.routineId,
    required this.startedAt,
    required this.endedAt,
    required this.ok,
    this.skipped = false,
    this.error,
    this.result = '',
    this.inputTokens,
    this.outputTokens,
    this.tokensPerSecond,
    this.tokensEstimated = false,
    this.manual = false,
  });

  final String id;
  final String routineId;
  final DateTime startedAt;
  final DateTime endedAt;
  final bool ok;

  /// Not run at all: no provider or model, or the routine was paused when its time came.
  /// Skipped runs do not count as failures.
  final bool skipped;
  final String? error;

  /// The model's final answer, trimmed to [routineResultLimit].
  final String result;
  final int? inputTokens;
  final int? outputTokens;
  final double? tokensPerSecond;

  /// True when output tokens were counted from characters because the provider sent no usage.
  final bool tokensEstimated;

  /// Started by hand ("Run now", "Run again") rather than by its schedule.
  final bool manual;

  String get status => skipped ? 'skipped' : (ok ? 'ok' : 'error');

  /// A failure that counts toward pausing the routine.
  bool get failed => !ok && !skipped;

  /// What the notification and the history show: the answer, or why there is none.
  String get summary => ok ? result : (error ?? (skipped ? 'Skipped.' : 'Failed.'));

  static String trimResult(String text) => text.length <= routineResultLimit
      ? text
      : '${text.substring(0, routineResultLimit - 1)}…';

  Map<String, Object?> toJson() => {
        'id': id,
        'routineId': routineId,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'ok': ok,
        'skipped': skipped,
        'error': error,
        'result': result,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'tokensPerSecond': tokensPerSecond,
        'tokensEstimated': tokensEstimated,
        'manual': manual,
      };

  factory RoutineRun.fromJson(Map<String, Object?> json) => RoutineRun(
        id: json['id'] as String? ?? '',
        routineId: json['routineId'] as String? ?? '',
        startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        endedAt: DateTime.tryParse(json['endedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        ok: json['ok'] as bool? ?? false,
        skipped: json['skipped'] as bool? ?? false,
        error: json['error'] as String?,
        result: json['result'] as String? ?? '',
        inputTokens: (json['inputTokens'] as num?)?.toInt(),
        outputTokens: (json['outputTokens'] as num?)?.toInt(),
        tokensPerSecond: (json['tokensPerSecond'] as num?)?.toDouble(),
        tokensEstimated: json['tokensEstimated'] as bool? ?? false,
        manual: json['manual'] as bool? ?? false,
      );
}

/// A time a routine is due, for the calendar.
class RoutineOccurrence {
  const RoutineOccurrence({required this.routineId, required this.at});
  final String routineId;
  final DateTime at;
}

/// Upcoming fires of the enabled [routines] in [from, to), earliest first, at most [limit].
///
/// Daily and weekly times come from each routine's clock time. Interval routines step by their
/// interval from the last run (or from [from] when they never ran).
List<RoutineOccurrence> occurrencesBetween(
  List<Routine> routines,
  DateTime from,
  DateTime to, {
  int limit = 500,
}) {
  final out = <RoutineOccurrence>[];
  if (!to.isAfter(from) || limit <= 0) return out;
  final justBefore = from.subtract(const Duration(microseconds: 1));
  for (final routine in routines) {
    if (!routine.enabled) continue;
    final isInterval = routine.trigger == RoutineTrigger.interval;
    final every = Duration(minutes: routine.everyMinutes);
    DateTime? at = isInterval ? _firstIntervalAtOrAfter(routine, from) : routine.nextFire(justBefore);
    var count = 0;
    while (at != null && at.isBefore(to) && count < limit) {
      out.add(RoutineOccurrence(routineId: routine.id, at: at));
      count++;
      at = isInterval ? at.add(every) : routine._nextOnDaysAfter(at, _daysOf(routine));
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  if (out.length > limit) out.removeRange(limit, out.length);
  return out;
}

Set<int> _daysOf(Routine routine) => routine.trigger == RoutineTrigger.weekly
    ? routine.weekdays
    : const {1, 2, 3, 4, 5, 6, 7};

DateTime _firstIntervalAtOrAfter(Routine routine, DateTime from) {
  final every = Duration(minutes: routine.everyMinutes);
  final last = routine.lastRun;
  if (last == null) return from.add(every);
  final steps = (from.difference(last).inMicroseconds / every.inMicroseconds).floor();
  var at = last.add(every * steps);
  while (at.isBefore(from)) {
    at = at.add(every);
  }
  return at;
}

/// "07:30", zero-padded.
String formatMinuteOfDay(int minuteOfDay) {
  final h = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
  final m = (minuteOfDay % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

/// Parses "7:30" or "07:30"; null when it is not a clock time.
int? parseClockMinutes(String text) {
  final match = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*$').firstMatch(text);
  if (match == null) return null;
  final h = int.parse(match.group(1)!);
  final m = int.parse(match.group(2)!);
  if (h > 23 || m > 59) return null;
  return h * 60 + m;
}

/// "Today 07:30", "Tomorrow 07:30", "Mon 07:30", or "2026-11-30 07:30" further away.
String formatRoutineTime(DateTime at, DateTime now) {
  final days = DateTime.utc(at.year, at.month, at.day).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  final clock = formatMinuteOfDay(at.hour * 60 + at.minute);
  final String day;
  if (days == 0) {
    day = 'Today';
  } else if (days == 1) {
    day = 'Tomorrow';
  } else if (days == -1) {
    day = 'Yesterday';
  } else if (days > 1 && days < 7) {
    day = _weekdayShort[at.weekday - 1];
  } else {
    day = '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  }
  return '$day $clock';
}

const _weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Day names for the weekday chips and descriptions.
const weekdayShort = _weekdayShort;

String _dayList(Set<int> days) {
  if (days.length == 7) return 'Every day';
  if (days.length == 5 && days.containsAll(const {1, 2, 3, 4, 5})) return 'Weekdays';
  if (days.length == 2 && days.containsAll(const {6, 7})) return 'Weekends';
  final sorted = days.toList()..sort();
  return sorted.map((d) => _weekdayShort[d - 1]).join(', ');
}

String _intervalText(int minutes) {
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (rest == 0) return hours == 1 ? '1 hour' : '$hours hours';
  return '$hours h $rest min';
}
