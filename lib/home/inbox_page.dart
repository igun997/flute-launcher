import 'package:material_ui/material_ui.dart';

import '../app/flute.dart';
import '../email/email_models.dart';
import '../email/email_widgets.dart';
import '../native/flute_native.dart';
import '../widgets/sky_ink.dart';

enum InboxFilter {
  all('All'),
  chat('Chats'),
  mail('Mail');

  const InboxFilter(this.label);
  final String label;
}

/// One row of the unified inbox: a chat conversation or an email.
class InboxItem {
  const InboxItem({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.source,
    this.package,
    this.unread = false,
  });

  /// 'whatsapp', 'sms' or 'mail'.
  final String kind;
  final String title;
  final String subtitle;
  final DateTime time;

  /// Where it came from, for the small tag: WhatsApp, SMS or the mail account's label.
  final String source;
  final String? package;
  final bool unread;

  bool get isMail => kind == 'mail';
}

/// Latest message per conversation (newest conversation first).
List<RecentMessage> latestPerConversation(List<RecentMessage> all) {
  final seen = <String>{};
  final out = <RecentMessage>[];
  final sorted = [...all]..sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
  for (final m in sorted) {
    if (seen.add(m.conversationKey)) out.add(m);
  }
  return out;
}

/// Number of distinct conversations.
int inboxChatCount(List<RecentMessage> all) => latestPerConversation(all).length;

/// Chats and mail merged into one feed, newest first. [accountLabels] maps an email account id
/// to the label shown on its rows.
List<InboxItem> buildInbox({
  required List<RecentMessage> messages,
  required List<EmailPreview> emails,
  required Map<String, String> accountLabels,
  InboxFilter filter = InboxFilter.all,
}) {
  final items = <InboxItem>[
    if (filter != InboxFilter.mail)
      for (final m in latestPerConversation(messages))
        InboxItem(
          kind: m.source,
          title: m.sender,
          subtitle: m.text,
          time: DateTime.fromMillisecondsSinceEpoch(m.timestampMs),
          source: m.source == 'whatsapp' ? 'WhatsApp' : 'SMS',
          package: m.package,
        ),
    if (filter != InboxFilter.chat)
      for (final e in emails)
        InboxItem(
          kind: 'mail',
          title: e.from,
          subtitle: e.subject,
          time: e.date,
          source: accountLabels[e.accountId] ?? 'Mail',
          unread: !e.seen,
        ),
  ]..sort((a, b) => b.time.compareTo(a.time));
  return items;
}

String ago(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// Everything that arrived, in one place: WhatsApp and SMS from notifications and every
/// connected mailbox.
class InboxPage extends StatefulWidget {
  const InboxPage({super.key, required this.flute});
  final Flute flute;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  InboxFilter _filter = InboxFilter.all;

  static const _mailApps = [
    'com.google.android.gm',
    'com.larksuite.suite',
    'com.ss.android.lark',
    'com.microsoft.office.outlook',
  ];

  Future<void> _refresh() async {
    final f = widget.flute;
    await Future.wait([f.refreshMessages(), f.email.refresh(force: true)]);
  }

  void _open(InboxItem item) {
    final pkg = item.package;
    if (pkg != null) {
      FluteNative.launchApp(pkg);
      return;
    }
    for (final p in _mailApps) {
      if (widget.flute.repo.byPackage(p) != null) {
        FluteNative.launchApp(p);
        return;
      }
    }
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => const EmailAccountsSheet());
  }

  @override
  Widget build(BuildContext context) {
    final flute = widget.flute;
    return SafeArea(
      child: DefaultTextStyle.merge(
        style: TextStyle(color: SkyInk.of(context).ink, shadows: [Shadow(color: SkyInk.of(context).shadow, blurRadius: 8)]),
        child: ListenableBuilder(
          listenable: Listenable.merge([flute.messages, flute.notificationAccess, flute.email]),
          builder: (context, _) {
            final accounts = {for (final a in flute.email.accounts) a.id: a.label};
            final items = buildInbox(
              messages: flute.messages.value,
              emails: flute.email.summary.latest,
              accountLabels: accounts,
              filter: _filter,
            );
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Inbox', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w300)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => const EmailAccountsSheet(),
                        ),
                        child: Text(accounts.isEmpty ? 'Connect mail' : 'Mail accounts'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final f in InboxFilter.values)
                        ChoiceChip(label: Text(f.label), selected: _filter == f, onSelected: (_) => setState(() => _filter = f)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (!flute.notificationAccess.value && _filter != InboxFilter.mail)
                    InkWell(
                      onTap: FluteNative.openNotificationAccessSettings,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('Allow notification access to see WhatsApp and SMS here.', style: TextStyle(color: SkyInk.of(context).warn, fontSize: 14)),
                      ),
                    ),
                  Expanded(
                    child: items.isEmpty
                        ? Center(child: Text('Nothing new', style: TextStyle(color: SkyInk.of(context).inkSoft)))
                        : RefreshIndicator(
                            onRefresh: _refresh,
                            child: ListView.builder(
                              padding: const EdgeInsets.only(bottom: 24),
                              itemCount: items.length,
                              itemBuilder: (context, i) => _Row(item: items[i], onTap: () => _open(items[i])),
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.item, required this.onTap});
  final InboxItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: item.unread ? FontWeight.w600 : FontWeight.w400),
                  ),
                  const SizedBox(height: 2),
                  Text(item.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: SkyInk.of(context).inkSoft, fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(ago(item.time), style: TextStyle(color: SkyInk.of(context).inkSoft, fontSize: 12)),
                const SizedBox(height: 2),
                Text(item.source, style: TextStyle(color: item.isMail ? SkyInk.of(context).warn : SkyInk.of(context).accent, fontSize: 11, letterSpacing: 0.4)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
