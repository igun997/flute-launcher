import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/email/email_models.dart';
import 'package:focus_launcher/lock/lock_summary.dart';
import 'package:focus_launcher/native/flute_native.dart';

RecentMessage _msg({
  required String key,
  required String sender,
  required String text,
  required int at,
}) => RecentMessage(
  id: '$key@$at',
  source: 'whatsapp',
  package: 'com.whatsapp',
  sender: sender,
  text: text,
  timestampMs: at,
  conversationKey: key,
);

EmailPreview _mail(String subject, {bool seen = false, required int at}) => EmailPreview(
  accountId: 'acc',
  from: 'sender@example.com',
  subject: subject,
  date: DateTime.fromMillisecondsSinceEpoch(at),
  seen: seen,
  uid: '$at',
);

void main() {
  // Four conversations; Ana has two messages, so she must appear once, with her newest text.
  final messages = [
    _msg(key: 'com.whatsapp|Ana', sender: 'Ana', text: 'older ana secret', at: 1000),
    _msg(key: 'com.whatsapp|Budi', sender: 'Budi', text: 'budi secret', at: 2000),
    _msg(key: 'com.whatsapp|Ana', sender: 'Ana', text: 'newest ana secret', at: 3000),
    _msg(key: 'sms|+62812', sender: '', text: 'otp 123456', at: 500),
    _msg(key: 'com.whatsapp|Citra', sender: 'Citra', text: 'hi there', at: 1500),
  ];

  group('summarize with previews off', () {
    test('never carries message text anywhere in the summary', () {
      final s = summarize(messages: messages, unreadMail: 2, previews: false);
      final visible = [
        s.countLine,
        s.senderLine,
        for (final row in s.previews) ...[row.sender, row.text],
      ].join('\n');
      for (final m in messages) {
        expect(visible, isNot(contains(m.text)), reason: 'text of ${m.conversationKey} leaked');
      }
      expect(s.previews, isEmpty);
    });

    test('names up to three senders, newest conversation first', () {
      final s = summarize(messages: messages, unreadMail: 0, previews: false);
      expect(s.senderLine, 'Ana, Budi, Citra');
    });

    test('mail subjects are never returned', () {
      final latest = [_mail('Quarterly numbers', at: 2000), _mail('Lunch?', at: 3000)];
      expect(mailSubjectLines(latest: latest, previews: false), isEmpty);
    });
  });

  group('summarize with previews on', () {
    test('lists one row per conversation, newest first, capped at three', () {
      final s = summarize(messages: messages, unreadMail: 0, previews: true);
      expect([for (final r in s.previews) r.sender], ['Ana', 'Budi', 'Citra']);
      expect([for (final r in s.previews) r.text], ['newest ana secret', 'budi secret', 'hi there']);
    });

    test('keeps the newest text of a conversation, not the first one seen', () {
      final reversed = [...messages].reversed.toList();
      final s = summarize(messages: reversed, unreadMail: 0, previews: true);
      expect(s.previews.first.text, 'newest ana secret');
    });
  });

  group('conversation counts', () {
    test('count conversations, not raw messages', () {
      final s = summarize(messages: messages, unreadMail: 2, previews: false);
      expect(s.chatCount, 4);
      expect(s.countLine, '4 messages  ·  2 emails');
    });

    test('empty input reads as nothing new', () {
      final s = summarize(messages: const [], unreadMail: 0, previews: true);
      expect(s.countLine, 'Nothing new');
      expect(s.hasContent, isFalse);
      expect(s.senderLine, isEmpty);
      expect(s.previews, isEmpty);
    });

    test('singular nouns', () {
      final s = summarize(messages: [messages.first], unreadMail: 1, previews: false);
      expect(s.countLine, '1 message  ·  1 email');
    });

    test('mail only', () {
      final s = summarize(messages: const [], unreadMail: 3, previews: false);
      expect(s.countLine, '3 emails');
      expect(s.hasContent, isTrue);
    });

    test('negative unread count is treated as zero', () {
      final s = summarize(messages: const [], unreadMail: -4, previews: false);
      expect(s.unreadMail, 0);
      expect(s.countLine, 'Nothing new');
    });
  });

  group('text shaping', () {
    test('sender falls back to the conversation title when the notification has no sender', () {
      final s = summarize(messages: [messages[3]], unreadMail: 0, previews: true);
      expect(s.senderLine, '+62812');
      expect(s.previews.single.sender, '+62812');
    });

    test('preview text is one line and cut with an ellipsis', () {
      final long = 'line one\n\n   line   two ${'x' * 200}';
      final s = summarize(
        messages: [_msg(key: 'k|Dewi', sender: 'Dewi', text: long, at: 1)],
        unreadMail: 0,
        previews: true,
      );
      final text = s.previews.single.text;
      expect(text, startsWith('line one line two'));
      expect(text, isNot(contains('\n')));
      expect(text.length, lessThanOrEqualTo(90));
      expect(text, endsWith('…'));
    });
  });

  group('mailSubjectLines', () {
    test('unread only, newest first, at most two, blank subjects labelled', () {
      final latest = [
        _mail('Old unread', at: 1000),
        _mail('Read already', seen: true, at: 9000),
        _mail('   ', at: 5000),
        _mail('Newest unread', at: 7000),
      ];
      expect(mailSubjectLines(latest: latest, previews: true), ['Newest unread', '(no subject)']);
    });
  });
}
