import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/email/email_merge.dart';
import 'package:focus_launcher/email/email_models.dart';

final DateTime _base = DateTime.utc(2025, 1, 1, 9);

EmailPreview _preview(String accountId, String uid, int minute) {
  return EmailPreview(
    accountId: accountId,
    from: 'sender',
    subject: 'subject $uid',
    date: _base.add(Duration(minutes: minute)),
    seen: false,
    uid: uid,
  );
}

void main() {
  group('mergeEmailSummary', () {
    test('no results means never fetched and nothing to show', () {
      final summary = mergeEmailSummary(const []);

      expect(summary.unread, 0);
      expect(summary.latest, isEmpty);
      expect(summary.error, isNull);
      expect(summary.fetchedAt, emailNeverFetched);
    });

    test('sums unread counts across accounts', () {
      final summary = mergeEmailSummary([
        EmailAccountResult(
          accountId: 'a',
          label: 'A',
          fetchedAt: _base,
          unread: 3,
        ),
        EmailAccountResult(
          accountId: 'b',
          label: 'B',
          fetchedAt: _base,
          unread: 4,
        ),
      ]);

      expect(summary.unread, 7);
      expect(summary.error, isNull);
    });

    test('keeps the newest previews across accounts, capped at the limit', () {
      // Account a holds even minutes, account b odd minutes, 0..15 in total.
      final a = [
        for (var i = 0; i < 8; i++) _preview('a', 'a$i', 2 * i),
      ];
      final b = [
        for (var i = 0; i < 8; i++) _preview('b', 'b$i', 2 * i + 1),
      ];

      final summary = mergeEmailSummary([
        EmailAccountResult(
          accountId: 'a',
          label: 'A',
          fetchedAt: _base,
          latest: a,
        ),
        EmailAccountResult(
          accountId: 'b',
          label: 'B',
          fetchedAt: _base,
          latest: b,
        ),
      ]);

      expect(summary.latest.length, emailLatestLimit);
      expect(
        summary.latest.map((p) => p.uid).toList(),
        ['b7', 'a7', 'b6', 'a6', 'b5', 'a5', 'b4', 'a4', 'b3', 'a3'],
      );
    });

    test('ties break by account id, then uid', () {
      final summary = mergeEmailSummary([
        EmailAccountResult(
          accountId: 'b',
          label: 'B',
          fetchedAt: _base,
          latest: [_preview('b', 'u2', 5), _preview('b', 'u1', 5)],
        ),
        EmailAccountResult(
          accountId: 'a',
          label: 'A',
          fetchedAt: _base,
          latest: [_preview('a', 'u9', 5)],
        ),
      ]);

      expect(
        summary.latest.map((p) => '${p.accountId}/${p.uid}').toList(),
        ['a/u9', 'b/u1', 'b/u2'],
      );
    });

    test('a failed account is reported while good accounts still show', () {
      final good = DateTime.utc(2025, 1, 1, 10);
      final summary = mergeEmailSummary([
        EmailAccountResult(
          accountId: 'a',
          label: 'A',
          fetchedAt: good,
          unread: 2,
          latest: [_preview('a', 'a1', 1)],
        ),
        EmailAccountResult(
          accountId: 'b',
          label: 'B',
          fetchedAt: _base,
          error: 'Sign-in failed.',
        ),
      ]);

      expect(summary.unread, 2);
      expect(summary.latest.single.uid, 'a1');
      expect(summary.error, 'B: Sign-in failed.');
    });

    test('joins several errors with a separator', () {
      final summary = mergeEmailSummary([
        EmailAccountResult(
          accountId: 'a',
          label: 'A',
          fetchedAt: _base,
          error: 'Timed out.',
        ),
        EmailAccountResult(
          accountId: 'b',
          label: 'B',
          fetchedAt: _base,
          error: 'Sign-in failed.',
        ),
      ]);

      expect(summary.error, 'A: Timed out.; B: Sign-in failed.');
    });

    test('fetchedAt is the latest completed fetch', () {
      final early = DateTime.utc(2025, 1, 1, 8);
      final late = DateTime.utc(2025, 1, 1, 12);
      final summary = mergeEmailSummary([
        EmailAccountResult(accountId: 'a', label: 'A', fetchedAt: early),
        EmailAccountResult(accountId: 'b', label: 'B', fetchedAt: late),
      ]);

      expect(summary.fetchedAt, late);
    });
  });
}
