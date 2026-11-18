import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/email/email_models.dart';
import 'package:focus_launcher/home/inbox_page.dart';
import 'package:focus_launcher/native/flute_native.dart';

RecentMessage msg(String source, String sender, String text, int ts, {String? key}) => RecentMessage(
      id: '$sender$ts',
      source: source,
      package: source == 'whatsapp' ? 'com.whatsapp' : 'com.google.android.apps.messaging',
      sender: sender,
      text: text,
      timestampMs: ts,
      conversationKey: key ?? '$source:$sender',
    );

EmailPreview mail(String from, String subject, int ts, {bool seen = false}) => EmailPreview(
      accountId: 'a1',
      from: from,
      subject: subject,
      date: DateTime.fromMillisecondsSinceEpoch(ts),
      seen: seen,
      uid: '$ts',
    );

void main() {
  final messages = [
    msg('whatsapp', 'Ayu', 'first', 1000),
    msg('whatsapp', 'Ayu', 'latest from Ayu', 5000),
    msg('sms', 'BCA', 'OTP 123', 3000),
  ];
  final emails = [mail('Boss', 'Report', 4000), mail('News', 'Digest', 500, seen: true)];

  test('one row per conversation, newest first, chats and mail merged', () {
    final items = buildInbox(messages: messages, emails: emails, accountLabels: {'a1': 'Lark'});
    expect(items.map((i) => i.title), ['Ayu', 'Boss', 'BCA', 'News']);
    expect(items.first.subtitle, 'latest from Ayu');
    expect(items.map((i) => i.source), ['WhatsApp', 'Lark', 'SMS', 'Lark']);
  });

  test('filters keep only chats or only mail', () {
    final chats = buildInbox(messages: messages, emails: emails, accountLabels: const {}, filter: InboxFilter.chat);
    expect(chats.every((i) => !i.isMail), isTrue);
    expect(chats, hasLength(2));
    final mails = buildInbox(messages: messages, emails: emails, accountLabels: const {}, filter: InboxFilter.mail);
    expect(mails.every((i) => i.isMail), isTrue);
    expect(mails.first.source, 'Mail'); // unknown account falls back
    expect(mails.first.unread, isTrue);
    expect(mails.last.unread, isFalse);
  });

  test('chat count counts conversations, not messages', () {
    expect(inboxChatCount(messages), 2);
    expect(inboxChatCount(const []), 0);
  });

  test('ago formats minutes, hours and days', () {
    final now = DateTime(2026, 11, 18, 12);
    expect(ago(now.subtract(const Duration(seconds: 20)), now: now), 'now');
    expect(ago(now.subtract(const Duration(minutes: 7)), now: now), '7m');
    expect(ago(now.subtract(const Duration(hours: 3)), now: now), '3h');
    expect(ago(now.subtract(const Duration(days: 2)), now: now), '2d');
  });
}
