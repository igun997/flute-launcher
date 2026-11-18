import 'dart:async';
import 'dart:io';

import 'package:flutter_animate/flutter_animate.dart';
import 'package:gpt_markdown/gpt_markdown.dart'
    show CodeBlockStyle, GptMarkdown, GptMarkdownStyleSheet, HeadingStyle, InlineCodeStyle, LinkStyle, TableStyle;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../../app/theme.dart';
import '../runtime/agent_runtime.dart';

/// Chat rows: user bubbles, Markdown replies, reasoning, tool cards and small pieces shared with
/// the composer.

/// A short UI transition, instant when the system asks for reduced motion.
Duration motion(BuildContext context, int milliseconds) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : Duration(milliseconds: milliseconds);

/// Plays the arrival of a new row. Skipped when the system asks for reduced motion.
Widget enterMessage(BuildContext context, Widget child) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  return child
      .animate()
      .fadeIn(duration: 160.ms, curve: Curves.easeOut)
      .slideY(begin: 0.06, end: 0, duration: 160.ms, curve: Curves.easeOutCubic);
}

IconData toolSourceIcon(String source) {
  if (source.startsWith('mcp:')) return Icons.hub_outlined;
  return switch (source) {
    'calendar' => Icons.event_outlined,
    'contacts' => Icons.person_outline,
    'notes' => Icons.sticky_note_2_outlined,
    'time' => Icons.schedule,
    'skills' => Icons.auto_awesome_outlined,
    _ => Icons.build_outlined,
  };
}

String toolSourceLabel(String source) {
  if (source.startsWith('mcp:')) return source.substring(4);
  return switch (source) {
    'calendar' => 'Calendar',
    'contacts' => 'Contacts',
    'notes' => 'Notes',
    'time' => 'Time',
    'skills' => 'Skill',
    _ => source,
  };
}

const _markdownSheet = GptMarkdownStyleSheet(
  link: LinkStyle(color: FluteColors.accent),
  heading: HeadingStyle(showDivider: false),
  inlineCode: InlineCodeStyle(
    color: FluteColors.text,
    backgroundColor: FluteColors.surfaceHigh,
    borderRadius: Radius.circular(6),
    padding: EdgeInsets.symmetric(horizontal: 4),
  ),
  codeBlock: CodeBlockStyle(
    backgroundColor: FluteColors.surface,
    borderColor: FluteColors.line,
    borderRadius: Radius.circular(12),
    textColor: FluteColors.text,
    fontSize: 13,
  ),
  table: TableStyle(
    borderColor: FluteColors.line,
    headerBackground: FluteColors.surfaceHigh,
    borderRadius: Radius.circular(10),
  ),
);

/// Opens http, https and mail links outside the app. Other schemes are ignored.
Future<void> _openLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !const {'http', 'https', 'mailto'}.contains(uri.scheme)) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No app can open it; the link stays as text.
  }
}

/// Markdown as the model wrote it: code blocks with a copy button, tables, links, LaTeX.
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown(this.text, {super.key, this.muted = false});

  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      text,
      style: TextStyle(
        color: muted ? FluteColors.muted : FluteColors.text,
        fontSize: muted ? 13.5 : 15.5,
        height: 1.45,
      ),
      styleSheet: _markdownSheet,
      onLinkTap: (url, _) => _openLink(url),
    );
  }
}

class UserMessage extends StatelessWidget {
  const UserMessage({super.key, required this.item});

  final UserItem item;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.82;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final a in item.attachments) AttachmentThumb(attachment: a, size: 96)],
                ),
              ),
            if (item.text.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  color: FluteColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(item.text, style: const TextStyle(fontSize: 15.5, height: 1.4)),
              ),
          ],
        ),
      ),
    );
  }
}

class AssistantMessage extends StatelessWidget {
  const AssistantMessage({super.key, required this.item, this.clock});

  final AssistantItem item;

  /// Time source for the live stats line; tests inject a fixed one.
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final hasText = item.text.isNotEmpty;
    final hasReasoning = item.reasoning.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasReasoning)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ThinkingBlock(text: item.reasoning, live: item.streaming && !hasText),
          ),
        if (hasText)
          // The caret is a character, not an animation: it costs nothing between tokens.
          ChatMarkdown(item.streaming ? '${item.text} \u258D' : item.text)
        else if (item.streaming && !hasReasoning)
          const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: TypingDots()),
        if (item.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(item.error!, style: const TextStyle(color: FluteColors.warn, fontSize: 13.5, height: 1.4)),
          ),
        // Nothing generated (empty or error-only turn): no stats.
        if (hasText || hasReasoning)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _GenerationStats(item: item, clock: clock ?? DateTime.now),
          ),
      ],
    );
  }
}

/// Speed, token count, duration and time to first token. Ticks (4 Hz) only while the turn streams.
class _GenerationStats extends StatefulWidget {
  const _GenerationStats({required this.item, required this.clock});

  final AssistantItem item;
  final DateTime Function() clock;

  @override
  State<_GenerationStats> createState() => _GenerationStatsState();
}

class _GenerationStatsState extends State<_GenerationStats> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_GenerationStats oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (!widget.item.streaming) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final now = widget.clock();
    final parts = <String>[];
    final speed = item.tokensPerSecond(now);
    if (speed != null) parts.add('${speed.round()} tok/s');
    parts.add('${item.tokensEstimated ? '~' : ''}${item.shownOutputTokens} tokens');
    final elapsed = item.elapsed(now);
    if (elapsed != null) parts.add(_formatSeconds(elapsed));
    final firstToken = item.streaming ? null : item.timeToFirstToken;
    if (firstToken != null) parts.add('first token ${_formatSeconds(firstToken)}');
    return Text(
      parts.join(' · '),
      style: const TextStyle(color: FluteColors.muted, fontSize: 12, height: 1.3),
    );
  }
}

String _formatSeconds(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

/// The model's reasoning, folded away by default.
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({super.key, required this.text, required this.live});

  final String text;

  /// Still thinking: no answer text yet.
  final bool live;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lightbulb_outline, size: 15, color: FluteColors.muted),
                const SizedBox(width: 6),
                Text(
                  widget.live ? 'Thinking' : 'Thought',
                  style: const TextStyle(color: FluteColors.muted, fontSize: 13),
                ),
                Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: FluteColors.muted),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: motion(context, 180),
          curve: Curves.easeOut,
          alignment: Alignment.topLeft,
          child: _open
              ? Container(
                  margin: const EdgeInsets.only(top: 4, bottom: 4),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  decoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: FluteColors.line, width: 2)),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(
                      child: Text(
                        widget.text,
                        style: const TextStyle(color: FluteColors.muted, fontSize: 13.5, height: 1.4),
                      ),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// Three dots that breathe while a reply is on its way. Static when motion is reduced.
class TypingDots extends StatelessWidget {
  const TypingDots({super.key});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      height: 16,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.5),
              child: _dot(still, i),
            ),
        ],
      ),
    );
  }

  Widget _dot(bool still, int index) {
    final dot = Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(color: FluteColors.muted, shape: BoxShape.circle),
    );
    if (still) return dot;
    return dot
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fade(begin: 0.25, end: 1, duration: 450.ms, delay: (index * 150).ms, curve: Curves.easeInOut);
  }
}

class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.item});

  final ToolItem item;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final output = item.output;
    final expandable = output != null && output.trim().isNotEmpty;
    return Material(
      color: FluteColors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: FluteColors.line),
      ),
      child: InkWell(
        onTap: expandable ? () => setState(() => _open = !_open) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(toolSourceIcon(item.source), size: 18, color: FluteColors.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, height: 1.3),
                        ),
                        Text(
                          '${toolSourceLabel(item.source)} · ${item.toolName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: FluteColors.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StateChip(state: item.state),
                ],
              ),
              AnimatedSize(
                duration: motion(context, 180),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: _open && output != null && expandable
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 180),
                          child: SingleChildScrollView(
                            child: Text(
                              output,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                color: FluteColors.muted,
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final ToolState state;

  @override
  Widget build(BuildContext context) {
    final spec = _spec(state);
    return AnimatedSwitcher(
      duration: motion(context, 180),
      switchInCurve: Curves.easeOut,
      child: Container(
        key: ValueKey(state),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: spec.color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state == ToolState.running)
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: spec.color),
              )
            else if (spec.icon != null)
              Icon(spec.icon, size: 12, color: spec.color),
            const SizedBox(width: 4),
            Text(spec.label, style: TextStyle(fontSize: 11, color: spec.color)),
          ],
        ),
      ),
    );
  }

  static ({String label, Color color, IconData? icon}) _spec(ToolState state) => switch (state) {
        ToolState.waiting => (label: 'Needs OK', color: FluteColors.warn, icon: Icons.front_hand_outlined),
        ToolState.running => (label: 'Running', color: FluteColors.accent, icon: null),
        ToolState.done => (label: 'Done', color: FluteColors.accent, icon: Icons.check),
        ToolState.denied => (label: 'Denied', color: FluteColors.muted, icon: Icons.block),
        ToolState.failed => (label: 'Failed', color: FluteColors.warn, icon: Icons.error_outline),
      };
}

/// A picture, or a labelled tile for video and other files. [onRemove] adds the close button.
class AttachmentThumb extends StatelessWidget {
  const AttachmentThumb({super.key, required this.attachment, this.size = 64, this.onRemove});

  final Attachment attachment;
  final double size;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final tile = switch (attachment.kind) {
      AttachmentKind.image => ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(attachment.path),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: 256,
            errorBuilder: (_, _, _) => _FileTile(name: attachment.name, size: size, icon: Icons.broken_image_outlined),
          ),
        ),
      AttachmentKind.video => _FileTile(name: attachment.name, size: size, icon: Icons.play_arrow_rounded, badge: true),
      AttachmentKind.file => _FileTile(name: attachment.name, size: size, icon: Icons.insert_drive_file_outlined),
    };
    final remove = onRemove;
    if (remove == null) return tile;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        tile,
        Positioned(
          top: -6,
          right: -6,
          child: Material(
            color: FluteColors.bg,
            shape: const CircleBorder(side: BorderSide(color: FluteColors.line)),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: remove,
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close, size: 14, color: FluteColors.text),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.name, required this.size, required this.icon, this.badge = false});

  final String name;
  final double size;
  final IconData icon;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: FluteColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: FluteColors.line),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (badge)
            Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(color: FluteColors.bg, shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: FluteColors.text),
            )
          else
            Icon(icon, size: 22, color: FluteColors.muted),
          const SizedBox(height: 4),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10.5, color: FluteColors.muted, height: 1.2),
          ),
        ],
      ),
    );
  }
}

/// A status line from the runtime, such as a finished command or a notice.
class NoticeMessage extends StatelessWidget {
  const NoticeMessage({super.key, required this.item});

  final NoticeItem item;

  @override
  Widget build(BuildContext context) => ChatMarkdown(item.text, muted: true);
}
