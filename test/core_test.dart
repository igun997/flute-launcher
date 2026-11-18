import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/core/category_engine.dart';
import 'package:focus_launcher/core/models.dart';

void main() {
  group('Schedule.covers', () {
    const workdays = {1, 2, 3, 4, 5};

    test('daytime window respects weekday and bounds', () {
      const s = Schedule(modeId: 'work', days: workdays, startMinute: 9 * 60, endMinute: 17 * 60);
      expect(s.covers(DateTime(2026, 11, 18, 9, 0)), isTrue); // Wednesday
      expect(s.covers(DateTime(2026, 11, 18, 16, 59)), isTrue);
      expect(s.covers(DateTime(2026, 11, 18, 17, 0)), isFalse);
      expect(s.covers(DateTime(2026, 11, 21, 10, 0)), isFalse); // Saturday
    });

    test('overnight window belongs to the day it starts on', () {
      const s = Schedule(modeId: 'sleep', days: {5}, startMinute: 22 * 60, endMinute: 6 * 60); // Fridays
      expect(s.covers(DateTime(2026, 11, 20, 23, 0)), isTrue); // Friday night
      expect(s.covers(DateTime(2026, 11, 21, 5, 59)), isTrue); // Saturday early morning
      expect(s.covers(DateTime(2026, 11, 21, 23, 0)), isFalse); // Saturday night
      expect(s.covers(DateTime(2026, 11, 20, 5, 0)), isFalse); // Friday early morning
    });

    test('JSON round trip', () {
      const s = Schedule(modeId: 'focus', days: {2, 4}, startMinute: 600, endMinute: 660);
      final back = Schedule.fromJson(s.toJson());
      expect(back.modeId, 'focus');
      expect(back.days, {2, 4});
      expect(back.startMinute, 600);
      expect(back.endMinute, 660);
    });
  });

  group('CategoryEngine', () {
    final engine = CategoryEngine({'com.whatsapp': AppCategory.chat, 'com.bca': AppCategory.banking});

    test('override beats the bundled map', () {
      final e = CategoryEngine({'com.whatsapp': AppCategory.chat}, {'com.whatsapp': AppCategory.work});
      expect(e.categorize('com.whatsapp', 'WhatsApp'), AppCategory.work);
    });

    test('bundled map beats Android category', () {
      expect(engine.categorize('com.bca', 'BCA', androidCategory: 0), AppCategory.banking);
    });

    test('Android category used when the package is unknown', () {
      expect(engine.categorize('com.x.y', 'Thing', androidCategory: 0), AppCategory.games);
      expect(engine.categorize('com.x.y', 'Thing', androidCategory: 4), AppCategory.social);
    });

    test('keyword heuristics, then Other', () {
      expect(engine.categorize('id.co.somebank.mobile', 'Some Bank'), AppCategory.banking);
      expect(engine.categorize('com.zzz.qqq', 'Zzz'), AppCategory.other);
    });
  });

  group('Mode', () {
    test('focus hides social but keeps work visible', () {
      expect(Mode.focus.ruleFor(AppCategory.social), Rule.hide);
      expect(Mode.focus.ruleFor(AppCategory.work), Rule.show);
      expect(Mode.free.ruleFor(AppCategory.games), Rule.show);
    });
  });

  group('categorizeAll', () {
    final apps = [
      (package: 'com.whatsapp', label: 'WhatsApp', androidCategory: -1),
      (package: 'com.x.y', label: 'Thing', androidCategory: 0),
      (package: 'id.co.somebank.mobile', label: 'Some Bank', androidCategory: -1),
      (package: 'com.zzz.qqq', label: 'Zzz', androidCategory: -1),
    ];

    test('gives the same answers as one app at a time, with or without a batch helper', () async {
      final plain = CategoryEngine({'com.whatsapp': AppCategory.chat});
      final one = [for (final a in apps) plain.categorize(a.package, a.label, androidCategory: a.androidCategory)];
      expect(await plain.categorizeAll(apps), one);

      var asked = <(String, String)>[];
      final batched = CategoryEngine({'com.whatsapp': AppCategory.chat}, null, (list) async {
        asked = list;
        return [0, 255]; // banking rule, no match
      });
      expect(await batched.categorizeAll(apps), one);
      // Only the apps that need guessing are sent; known and Android-categorized ones are not.
      expect(asked.map((e) => e.$1), ['id.co.somebank.mobile', 'com.zzz.qqq']);
    });

    test('a failing or mismatched batch helper falls back to the local guess', () async {
      final broken = CategoryEngine({}, null, (list) async => throw StateError('no rust'));
      expect((await broken.categorizeAll(apps))[2], AppCategory.banking);
      final short = CategoryEngine({}, null, (list) async => [0]);
      expect((await short.categorizeAll(apps))[3], AppCategory.other);
    });
  });
}
