import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/home/mode_sheet.dart';

void main() {
  final now = DateTime(2026, 11, 19, 12);

  group('timerRemaining', () {
    test('no timer when there is no end time', () {
      expect(timerRemaining(null, now), isNull);
    });

    test('no timer once the end time has passed', () {
      expect(timerRemaining(now, now), isNull);
      expect(timerRemaining(now.subtract(const Duration(seconds: 1)), now), isNull);
    });

    test('time left is the gap to the end time', () {
      expect(timerRemaining(now.add(const Duration(minutes: 10)), now), const Duration(minutes: 10));
    });
  });

  group('presetForRemaining', () {
    test('no timer selects Until I change it (null)', () {
      expect(presetForRemaining(null), isNull);
    });

    test('picks the smallest preset that still covers the time left', () {
      expect(presetForRemaining(const Duration(minutes: 10)), const Duration(minutes: 25));
      expect(presetForRemaining(const Duration(minutes: 25)), const Duration(minutes: 25));
      expect(presetForRemaining(const Duration(minutes: 26)), const Duration(hours: 1));
      expect(presetForRemaining(const Duration(minutes: 59)), const Duration(hours: 1));
      expect(presetForRemaining(const Duration(minutes: 90)), const Duration(hours: 2));
      expect(presetForRemaining(const Duration(hours: 4)), const Duration(hours: 4));
    });

    test('more than the longest preset selects the longest', () {
      expect(presetForRemaining(const Duration(hours: 5)), const Duration(hours: 4));
    });

    test('an expired-looking zero left selects the shortest preset', () {
      expect(presetForRemaining(Duration.zero), const Duration(minutes: 25));
    });
  });
}
