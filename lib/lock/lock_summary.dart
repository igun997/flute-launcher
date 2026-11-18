import '../email/email_models.dart';
import '../native/flute_native.dart';

/// Most conversations named or previewed on the lock screen.
const lockMaxConversations = 3;

/// Most unread mail subjects shown on the lock screen, and only when previews are on.
const lockMaxMailSubjects = 2;

const _nameMaxChars = 40;
const _previewMaxChars = 90;
const _subjectMaxChars = 80;
const _separator = '  ·  ';

/// One conversation line, shown only when previews are on.
class LockPreviewRow {
  const LockPreviewRow({required this.sender, required this.text});

  final String sender;
  final String text;
}

/// What the locked screen may show before unlock, derived from captured data.
class LockSummary {
  const LockSummary({
    required this.chatCount,
    required this.unreadMail,
    required this.senderLine,
    required this.previews,
  });

  /// Conversations with a captured message: one per conversation, not one per message.
  final int chatCount;
  final int unreadMail;

  /// Sender names of the newest conversations, comma separated. Empty when there are none.
  final String senderLine;

  /// Message text rows. Always empty unless previews are on.
  final List<LockPreviewRow> previews;

  bool get hasContent => chatCount > 0 || unreadMail > 0;

  /// `3 messages  ·  2 emails`, `1 email`, or `Nothing new`.
  String get countLine {
    final parts = [
      if (chatCount > 0) _count(chatCount, 'message'),
      if (unreadMail > 0) _count(unreadMail, 'email'),
    ];
    return parts.isEmpty ? 'Nothing new' : parts.join(_separator);
  }

  static String _count(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';
}

/// Builds the lock screen summary. Message text leaves this function only when [previews] is
/// true; otherwise the result carries counts and sender names and nothing else from a message.
LockSummary summarize({
  required List<RecentMessage> messages,
  required int unreadMail,
  required bool previews,
}) {
  final conversations = _latestPerConversation(messages);
  final shown = conversations.take(lockMaxConversations).toList(growable: false);
  return LockSummary(
    chatCount: conversations.length,
    unreadMail: unreadMail < 0 ? 0 : unreadMail,
    senderLine: [for (final m in shown) _senderName(m)].join(', '),
    previews: previews
        ? [
            for (final m in shown)
              LockPreviewRow(sender: _senderName(m), text: _oneLine(m.text, max: _previewMaxChars)),
          ]
        : const [],
  );
}

/// Up to [lockMaxMailSubjects] subjects of unread mail, newest first. Empty unless [previews] is true.
List<String> mailSubjectLines({required List<EmailPreview> latest, required bool previews}) {
  if (!previews) return const [];
  final unseen = latest.where((m) => !m.seen).toList()..sort((a, b) => b.date.compareTo(a.date));
  return [
    for (final m in unseen.take(lockMaxMailSubjects))
      _oneLine(m.subject, max: _subjectMaxChars, fallback: '(no subject)'),
  ];
}

/// Newest message per conversation, newest conversation first.
List<RecentMessage> _latestPerConversation(List<RecentMessage> all) {
  final newestFirst = [...all]..sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
  final seen = <String>{};
  return [
    for (final m in newestFirst)
      if (seen.add(m.conversationKey)) m,
  ];
}

/// Sender name, or the conversation title (the part of `package|title` after the first bar) when
/// the notification carried no sender.
String _senderName(RecentMessage m) {
  final sender = _oneLine(m.sender, max: _nameMaxChars);
  if (sender.isNotEmpty) return sender;
  final bar = m.conversationKey.indexOf('|');
  final title = bar < 0 ? m.conversationKey : m.conversationKey.substring(bar + 1);
  return _oneLine(title, max: _nameMaxChars, fallback: 'Unknown');
}

/// Collapses whitespace to one line and cuts it to [max] characters with an ellipsis.
String _oneLine(String raw, {required int max, String fallback = ''}) {
  final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return fallback;
  if (flat.length <= max) return flat;
  return '${flat.substring(0, max - 1).trimRight()}…';
}
