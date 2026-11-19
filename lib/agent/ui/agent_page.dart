import 'dart:async';

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_animate/flutter_animate.dart';
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

  void _openVoice() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VoicePage(agent: widget.flute.agent, voice: widget.flute.voice),
      ),
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
                  onVoice: _openVoice,
                  controller: _draft,
                  header: _ModelChip(
                    label: _runtime.model ?? 'Choose model',
                    onTap: () => showModelPicker(context, flute: flute),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Back, the title and one overflow menu. Everything else lives in the thumb zone.
  PreferredSizeWidget _appBar() {
    return AppBar(
      backgroundColor: FluteColors.bg,
      scrolledUnderElevation: 0,
      leading: IconButton(
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back),
        onPressed: widget.onClose,
      ),
      title: const Text('Ask'),
      actions: [
        PopupMenuButton<_Menu>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert),
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
        const SizedBox(width: FluteSpace.xs),
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
            padding: const EdgeInsets.fromLTRB(FluteSpace.lg, FluteSpace.md, FluteSpace.lg, FluteSpace.md),
            itemCount: items.length + extra,
            itemBuilder: (context, index) {
              if (index < extra) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: FluteSpace.lg),
                  child: Align(alignment: Alignment.centerLeft, child: TypingDots()),
                );
              }
              final item = items[items.length - 1 - (index - extra)];
              return _Row(key: ValueKey(item.id), item: item, arrive: _shown.add(item.id));
            },
          ),
        ),
        Positioned(
          right: FluteSpace.lg,
          bottom: FluteSpace.md,
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
    final content = Padding(
      padding: const EdgeInsets.only(bottom: FluteSpace.lg),
      child: _itemWidget(widget.item),
    );
    return RepaintBoundary(child: _arrive ? enterMessage(context, content) : content);
  }
}

Widget _itemWidget(ChatItem item) => switch (item) {
      UserItem() => UserMessage(item: item),
      AssistantItem() => AssistantMessage(item: item),
      ToolItem() => ToolCard(item: item),
      NoticeItem() => NoticeMessage(item: item),
    };

/// The model in use, as a quiet pill above the dock. Long names truncate. The tap area is 48 dp.
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
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: FluteRadius.pillAll,
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.only(left: FluteSpace.md, right: FluteSpace.sm),
                  decoration: fluteSurface(color: FluteColors.surface, radius: FluteRadius.pill),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FluteText.caption.copyWith(fontSize: 12.5, color: FluteColors.textSecondary),
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
      ),
    );
  }
}

/// A pill over the list that appears once the reader has scrolled up. Neutral, never accent.
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
              color: FluteColors.surfaceTop,
              shape: const StadiumBorder(side: BorderSide(color: FluteColors.line)),
              child: Tooltip(
                message: 'Jump to latest',
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onPressed();
                  },
                  child: const SizedBox(
                    height: 48,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: FluteSpace.lg),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.arrow_downward_rounded, size: 18, color: FluteColors.text),
                          SizedBox(width: FluteSpace.sm),
                          Text('Latest', style: FluteText.label),
                        ],
                      ),
                    ),
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
      margin: const EdgeInsets.fromLTRB(FluteSpace.lg, FluteSpace.sm, FluteSpace.lg, 0),
      padding: const EdgeInsets.fromLTRB(FluteSpace.lg, FluteSpace.md, FluteSpace.sm, FluteSpace.md),
      decoration: BoxDecoration(
        color: FluteColors.surface,
        borderRadius: FluteRadius.lgAll,
        border: Border.all(color: FluteColors.warn.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: FluteColors.warn),
          const SizedBox(width: FluteSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Add a provider to start', style: FluteText.label),
                if (problem.isNotEmpty) Text(problem, style: FluteText.caption),
              ],
            ),
          ),
          TextButton(onPressed: onSettings, child: const Text('Agent settings')),
        ],
      ),
    );
  }
}

/// Plays [child] in after [index] steps, so the greeting, the line and the list arrive one by one.
Widget _reveal(BuildContext context, int index, Widget child) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  return child
      .animate(delay: (index * 90).ms)
      .fadeIn(duration: 320.ms, curve: Curves.easeOut)
      .slideY(begin: 0.04, end: 0, duration: 320.ms, curve: Curves.easeOutCubic);
}

String _greeting(DateTime now) => switch (now.hour) {
      < 12 => 'Good morning',
      < 18 => 'Good afternoon',
      _ => 'Good evening',
    };

/// The first screen: a greeting, one calm line and four things to try as a list. A suggestion fills the box.
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(FluteSpace.xl, FluteSpace.xxl, FluteSpace.xl, FluteSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _reveal(context, 0, Text(_greeting(DateTime.now()), style: FluteText.display)),
          const SizedBox(height: FluteSpace.sm),
          _reveal(
            context,
            1,
            Text(
              'I can search, draw, check your calendar and change the launcher. I ask before I change anything.',
              style: FluteText.body.copyWith(color: FluteColors.textSecondary),
            ),
          ),
          const SizedBox(height: FluteSpace.xxl),
          _reveal(
            context,
            2,
            Material(
              color: FluteColors.surface,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: FluteRadius.lgAll,
                side: const BorderSide(color: FluteColors.line),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < _suggestions.length; i++) ...[
                    if (i > 0) const Divider(height: 1, thickness: 1, indent: 64, color: FluteColors.line),
                    _SuggestionRow(
                      icon: _suggestions[i].icon,
                      text: _suggestions[i].text,
                      onTap: () => onPick(_suggestions[i].text),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.icon, required this.text, required this.onTap});

  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(FluteSpace.lg, FluteSpace.md, FluteSpace.md, FluteSpace.md),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: FluteColors.surfaceHigh, borderRadius: FluteRadius.smAll),
              child: Icon(icon, size: 18, color: FluteColors.textSecondary),
            ),
            const SizedBox(width: FluteSpace.md),
            Expanded(child: Text(text, style: FluteText.label)),
            const Icon(Icons.chevron_right, size: 20, color: FluteColors.muted),
          ],
        ),
      ),
    );
  }
}
