import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../runtime/agent_runtime.dart';
import 'agent_settings_page.dart';
import 'chat_bubbles.dart';
import 'composer.dart';
import 'confirm_sheet.dart';
import 'model_picker.dart';

enum _Menu { newChat, settings }

/// The "Ask Flute" chat: a reverse list so the newest row sits at the bottom and the view stays
/// pinned there until the person scrolls up.
class AgentPage extends StatefulWidget {
  const AgentPage({super.key, required this.flute, required this.onClose});

  final Flute flute;
  final VoidCallback onClose;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  final _scroll = ScrollController();

  /// Rows that have been on screen. Only a row seen for the first time plays its arrival.
  final Set<String> _shown = {};
  bool _sheetOpen = false;

  AgentRuntime get _runtime => widget.flute.agent;

  @override
  void initState() {
    super.initState();
    _shown.addAll(_runtime.items.map((item) => item.id));
    widget.flute.confirm.addListener(_onConfirmChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onConfirmChanged());
  }

  @override
  void dispose() {
    widget.flute.confirm.removeListener(_onConfirmChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onConfirmChanged() {
    if (!mounted || _sheetOpen || widget.flute.confirm.pending == null) return;
    _sheetOpen = true;
    showConfirmSheet(context, widget.flute.confirm).whenComplete(() {
      if (!mounted) return;
      _sheetOpen = false;
      _onConfirmChanged();
    });
  }

  void _send(String text, List<Attachment> attachments) {
    unawaited(_runtime.send(text, attachments: attachments));
    if (_scroll.hasClients) {
      unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic));
    }
  }

  void _newChat() {
    _runtime.newChat();
    widget.flute.confirm.reset();
  }

  void _openSettings() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => AgentSettingsPage(flute: widget.flute)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final flute = widget.flute;
    return ListenableBuilder(
      listenable: Listenable.merge([_runtime, flute.providers]),
      builder: (context, _) {
        final items = _runtime.items;
        final busy = _runtime.busy;
        final setupProblem = _runtime.setupProblem;
        return Scaffold(
          backgroundColor: FluteColors.bg,
          appBar: _appBar(),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (setupProblem != null) _SetupBanner(problem: setupProblem, onSettings: _openSettings),
                Expanded(
                  child: items.isEmpty && !busy
                      ? _EmptyState(onPick: (prompt) => _send(prompt, const []))
                      : _messageList(items, busy),
                ),
                Composer(
                  busy: busy,
                  hints: _runtime.slashHints,
                  onSend: _send,
                  onStop: _runtime.cancel,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar() {
    return AppBar(
      backgroundColor: FluteColors.bg,
      scrolledUnderElevation: 0,
      leading: IconButton(
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back),
        onPressed: widget.onClose,
      ),
      title: const Text('Ask Flute', style: TextStyle(fontWeight: FontWeight.w300)),
      actions: [
        _ModelChip(
          label: _runtime.model ?? 'Choose model',
          onTap: () => showModelPicker(context, flute: widget.flute),
        ),
        PopupMenuButton<_Menu>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert),
          color: FluteColors.surfaceHigh,
          onSelected: (menu) {
            switch (menu) {
              case _Menu.newChat:
                _newChat();
              case _Menu.settings:
                _openSettings();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem<_Menu>(value: _Menu.newChat, child: const Text('New chat')),
            PopupMenuItem<_Menu>(value: _Menu.settings, child: const Text('Settings')),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _messageList(List<ChatItem> items, bool busy) {
    final last = items.isEmpty ? null : items.last;
    // The reply's own caret or dots show while it streams; otherwise dots say "still working".
    final showTyping = busy && !(last is AssistantItem && last.streaming);
    final extra = showTyping ? 1 : 0;
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: items.length + extra,
      itemBuilder: (context, index) {
        if (index < extra) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Align(alignment: Alignment.centerLeft, child: TypingDots()),
          );
        }
        final item = items[items.length - 1 - (index - extra)];
        return _Row(key: ValueKey(item.id), item: item, arrive: _shown.add(item.id));
      },
    );
  }
}

/// One chat row. Its arrival is decided once, when the row first appears, so its widget tree
/// keeps the same shape while the reply streams into it.
class _Row extends StatefulWidget {
  const _Row({super.key, required this.item, required this.arrive});

  final ChatItem item;
  final bool arrive;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  late final bool _arrive = widget.arrive;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: const EdgeInsets.only(bottom: 14), child: _itemWidget(widget.item));
    return RepaintBoundary(child: _arrive ? enterMessage(context, content) : content);
  }
}

Widget _itemWidget(ChatItem item) => switch (item) {
      UserItem() => UserMessage(item: item),
      AssistantItem() => AssistantMessage(item: item),
      ToolItem() => ToolCard(item: item),
      NoticeItem() => NoticeMessage(item: item),
    };

class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Material(
        color: FluteColors.surface,
        shape: const StadiumBorder(side: BorderSide(color: FluteColors.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 5, 8, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const Icon(Icons.expand_more, size: 16, color: FluteColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.problem, required this.onSettings});

  final String problem;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: FluteColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FluteColors.warn.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: FluteColors.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Add a provider to start', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                if (problem.isNotEmpty)
                  Text(problem, style: const TextStyle(color: FluteColors.muted, fontSize: 12.5)),
              ],
            ),
          ),
          TextButton(onPressed: onSettings, child: const Text('Agent settings')),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});

  final ValueChanged<String> onPick;

  static const _prompts = [
    "What's on my calendar today?",
    'Make a note: buy milk and eggs',
    'What time is it in Tokyo?',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('What can I help with?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w300)),
            const SizedBox(height: 10),
            const Text(
              'I can read and change your calendar, contacts and notes, and use the tools and skills you add. '
              'I ask before I change anything.',
              textAlign: TextAlign.center,
              style: TextStyle(color: FluteColors.muted, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 24),
            for (final prompt in _prompts)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _PromptTile(text: prompt, onTap: () => onPick(prompt)),
              ),
          ],
        ),
      ),
    );
  }
}

class _PromptTile extends StatelessWidget {
  const _PromptTile({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FluteColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: FluteColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Expanded(child: Text(text, style: const TextStyle(fontSize: 14.5))),
              const Icon(Icons.north_east, size: 16, color: FluteColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}
