import 'dart:async';

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../runtime/agent_runtime.dart';
import '../voice/voice_page.dart';
import 'agent_settings_page.dart';
import 'chat_bubbles.dart';
import 'composer.dart';
import 'confirm_sheet.dart';
import 'model_picker.dart';

enum _Menu { newChat, settings }

/// The "Ask" chat: a reverse list so the newest row sits at the bottom and the view stays
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
  final _draft = TextEditingController();

  /// True once the reader has scrolled away from the newest row.
  final _awayFromLatest = ValueNotifier<bool>(false);

  /// Rows that have been on screen. Only a row seen for the first time plays its arrival.
  final Set<String> _shown = {};
  bool _sheetOpen = false;

  AgentRuntime get _runtime => widget.flute.agent;

  @override
  void initState() {
    super.initState();
    _shown.addAll(_runtime.items.map((item) => item.id));
    _scroll.addListener(_onScroll);
    widget.flute.confirm.addListener(_onConfirmChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onConfirmChanged());
  }

  @override
  void dispose() {
    widget.flute.confirm.removeListener(_onConfirmChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _draft.dispose();
    _awayFromLatest.dispose();
    super.dispose();
  }

  void _onScroll() {
    final away = _scroll.hasClients && _scroll.offset > 160;
    if (_awayFromLatest.value != away) _awayFromLatest.value = away;
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
    _toLatest();
  }

  /// Suggestions put their text in the box; the person reads it and sends.
  void _fill(String prompt) {
    HapticFeedback.selectionClick();
    _draft.value = TextEditingValue(text: prompt, selection: TextSelection.collapsed(offset: prompt.length));
  }

  void _toLatest() {
    if (!_scroll.hasClients) return;
    unawaited(_scroll.animateTo(0, duration: motion(context, 240), curve: Curves.easeOutCubic));
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
                      ? _EmptyState(onPick: _fill)
                      : _messageList(items, busy),
                ),
                Composer(
                  busy: busy,
                  hints: _runtime.slashHints,
                  onSend: _send,
                  onStop: _runtime.cancel,
                  controller: _draft,
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
      title: const Text('Ask', style: TextStyle(fontWeight: FontWeight.w300)),
      actions: [
        IconButton(
          tooltip: 'Voice',
          icon: const Icon(Icons.mic_none),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => VoicePage(agent: widget.flute.agent, voice: widget.flute.voice),
            ),
          ),
        ),
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
    return Stack(
      children: [
        Positioned.fill(
          child: ListView.builder(
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
          ),
        ),
        Positioned(
          right: 16,
          bottom: 12,
          child: ValueListenableBuilder<bool>(
            valueListenable: _awayFromLatest,
            builder: (_, away, _) => _JumpToLatest(visible: away, onPressed: _toLatest),
          ),
        ),
      ],
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

/// Shows the model in use. Long names truncate so the app bar keeps room for its other buttons.
class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Model: $label',
      excludeSemantics: true,
      child: SizedBox(
        height: 48,
        child: Center(
          child: Material(
            color: FluteColors.surface,
            shape: const StadiumBorder(side: BorderSide(color: FluteColors.line)),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
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
        ),
      ),
    );
  }
}

/// A round button over the list that appears once the reader has scrolled up.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.visible, required this.onPressed});

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          duration: motion(context, 180),
          opacity: visible ? 1 : 0,
          child: AnimatedScale(
            duration: motion(context, 240),
            curve: Curves.easeOutBack,
            scale: visible ? 1 : 0.8,
            child: Material(
              color: FluteColors.surfaceHigh,
              shape: const CircleBorder(side: BorderSide(color: FluteColors.line)),
              child: Tooltip(
                message: 'Jump to latest',
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onPressed();
                  },
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.arrow_downward_rounded, size: 20, color: FluteColors.text),
                  ),
                ),
              ),
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

/// The first screen: what Flute does and four things to try. A suggestion fills the box.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});

  final ValueChanged<String> onPick;

  static const _suggestions = [
    (icon: Icons.timer_outlined, text: 'Start 25 min of focus'),
    (icon: Icons.event_outlined, text: "What's on my calendar today?"),
    (icon: Icons.brush_outlined, text: 'Draw a duck in a raincoat'),
    (icon: Icons.travel_explore, text: 'Search the latest Flutter release'),
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
              'I can control the launcher, check your calendar, draw pictures and search the web. '
              'I ask before I change anything.',
              textAlign: TextAlign.center,
              style: TextStyle(color: FluteColors.muted, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final suggestion in _suggestions)
                  ActionChip(
                    avatar: Icon(suggestion.icon, size: 16, color: FluteColors.muted),
                    label: Text(suggestion.text, style: const TextStyle(fontSize: 13.5)),
                    backgroundColor: FluteColors.surface,
                    side: const BorderSide(color: FluteColors.line),
                    onPressed: () => onPick(suggestion.text),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
