/// Core domain types: categories, app entries, modes and rules.
library;

enum AppCategory {
  banking('Banking'),
  work('Work'),
  chat('Chat'),
  social('Social'),
  media('Media'),
  games('Games'),
  shopping('Shopping'),
  travel('Travel'),
  tools('Tools'),
  other('Other');

  const AppCategory(this.label);
  final String label;

  static AppCategory? fromName(String? name) {
    for (final c in AppCategory.values) {
      if (c.name == name) return c;
    }
    return null;
  }
}

/// What a mode does to every app of a category.
enum Rule {
  /// Listed normally.
  show,

  /// Not listed in the app list; still reachable through search.
  hide,

  /// Listed, but opening it goes through the pause screen.
  lock,
}

class FluteApp {
  const FluteApp({required this.package, required this.label, required this.category, this.isSystem = false});
  final String package;
  final String label;
  final AppCategory category;
  final bool isSystem;
}

class Mode {
  const Mode({required this.id, required this.name, required this.tagline, required this.rules, this.dnd = false});
  final String id;
  final String name;
  final String tagline;
  final Map<AppCategory, Rule> rules;

  /// Turns on alarms-only Do Not Disturb while this mode is active.
  final bool dnd;

  Rule ruleFor(AppCategory c) => rules[c] ?? Rule.show;

  static const free = Mode(
    id: 'free',
    name: 'Free',
    tagline: 'Everything available',
    rules: {},
  );

  static const work = Mode(
    id: 'work',
    name: 'Work',
    tagline: 'Social, media and games pause first',
    rules: {
      AppCategory.social: Rule.lock,
      AppCategory.media: Rule.lock,
      AppCategory.games: Rule.lock,
      AppCategory.shopping: Rule.hide,
    },
  );

  static const focus = Mode(
    id: 'focus',
    name: 'Focus',
    tagline: 'Only work, banking and essentials',
    rules: {
      AppCategory.social: Rule.hide,
      AppCategory.media: Rule.hide,
      AppCategory.games: Rule.hide,
      AppCategory.shopping: Rule.hide,
      AppCategory.travel: Rule.lock,
      AppCategory.chat: Rule.lock,
      AppCategory.other: Rule.lock,
    },
  );

  static const sleep = Mode(
    id: 'sleep',
    name: 'Sleep',
    tagline: 'Wind down, alarms only, nothing pulls you in',
    dnd: true,
    rules: {
      AppCategory.social: Rule.hide,
      AppCategory.media: Rule.hide,
      AppCategory.games: Rule.hide,
      AppCategory.shopping: Rule.hide,
      AppCategory.work: Rule.lock,
      AppCategory.chat: Rule.lock,
      AppCategory.travel: Rule.lock,
    },
  );

  static const all = [free, work, focus, sleep];

  static Mode byId(String? id) => all.firstWhere((m) => m.id == id, orElse: () => free);
}

/// A recurring window during which [modeId] applies automatically.
class Schedule {
  const Schedule({required this.modeId, required this.days, required this.startMinute, required this.endMinute});

  final String modeId;

  /// DateTime weekday numbers, 1 = Monday .. 7 = Sunday.
  final Set<int> days;
  final int startMinute;
  final int endMinute;

  /// True when [t] falls inside the window. Windows may wrap past midnight; the
  /// weekday refers to the day the window starts on.
  bool covers(DateTime t) {
    final m = t.hour * 60 + t.minute;
    if (startMinute <= endMinute) {
      return days.contains(t.weekday) && m >= startMinute && m < endMinute;
    }
    if (m >= startMinute) return days.contains(t.weekday);
    final prev = t.weekday == 1 ? 7 : t.weekday - 1;
    return m < endMinute && days.contains(prev);
  }

  /// When the window that covers [t] ends. Only meaningful while [covers] is true.
  DateTime endsAt(DateTime t) {
    final m = t.hour * 60 + t.minute;
    final wraps = startMinute > endMinute;
    final day = DateTime(t.year, t.month, t.day);
    final endDay = wraps && m >= startMinute ? day.add(const Duration(days: 1)) : day;
    return DateTime(endDay.year, endDay.month, endDay.day, endMinute ~/ 60, endMinute % 60);
  }

  Map<String, Object?> toJson() => {
        'mode': modeId,
        'days': days.toList()..sort(),
        'start': startMinute,
        'end': endMinute,
      };

  factory Schedule.fromJson(Map<String, Object?> j) => Schedule(
        modeId: j['mode'] as String,
        days: ((j['days'] as List?) ?? const []).cast<int>().toSet(),
        startMinute: j['start'] as int,
        endMinute: j['end'] as int,
      );
}
