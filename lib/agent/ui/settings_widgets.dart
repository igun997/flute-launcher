import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../llm/llm_types.dart';
import 'chat_bubbles.dart' show motion;

/// Error text. Alias of [FluteColors.danger]; new code should use the token.
const settingsAlert = FluteColors.danger;

/// Secondary text. Alias of [FluteText.caption]; new code should use the token.
const settingsMuted = FluteText.caption;

/// A sentence the user can read. [LlmException] messages are written to be safe to show; network
/// and unknown failures get a plain line instead of raw error text.
String readableError(Object error) {
  if (error is LlmException) return error.message;
  if (error is TimeoutException) return 'That took too long. Check your connection and try again.';
  if (error is SocketException || error is http.ClientException) {
    return 'Cannot reach the server. Check your connection.';
  }
  if (error is FormatException) return error.message;
  if (error is Exception) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length > 200 ? '${text.substring(0, 200)}...' : text;
  }
  return 'Something went wrong. Please try again.';
}

/// Gutters for settings pages: [FluteSpace.lg] at the sides. Clears the navigation bar and lets the
/// last field scroll above the keyboard.
EdgeInsets settingsPagePadding(BuildContext context) => EdgeInsets.fromLTRB(
      FluteSpace.lg,
      FluteSpace.sm,
      FluteSpace.lg,
      MediaQuery.paddingOf(context).bottom + MediaQuery.viewInsetsOf(context).bottom + FluteSpace.xl,
    );

/// The children with [gap] between each pair. Pages put [FluteSpace.xl] between sections.
List<Widget> settingsSpaced(List<Widget> children, {double gap = FluteSpace.xl}) => [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        children[i],
      ],
    ];

/// Opens a settings page with a short fade and slide. Instant when the system asks for reduced motion.
Route<T> settingsRoute<T>(BuildContext context, WidgetBuilder builder) => PageRouteBuilder<T>(
      transitionDuration: motion(context, 300),
      reverseTransitionDuration: motion(context, 240),
      pageBuilder: (routeContext, _, __) => builder(routeContext),
      transitionsBuilder: (routeContext, animation, secondary, child) {
        if (MediaQuery.disableAnimationsOf(routeContext)) return child;
        final enter = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final exit = CurvedAnimation(parent: secondary, curve: Curves.easeInCubic);
        return FadeTransition(
          opacity: enter,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero).animate(enter),
            child: FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0).animate(exit),
              child: child,
            ),
          ),
        );
      },
    );

/// A settings sub-page: back button, a title, and a scroll view of [children] with [FluteSpace.xl]
/// between them.
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: FluteColors.bg,
        appBar: AppBar(
          backgroundColor: FluteColors.bg,
          scrolledUnderElevation: 0,
          title: Text(title),
        ),
        body: ListView(
          padding: settingsPagePadding(context),
          children: settingsSpaced(children),
        ),
      );
}

/// A titled block on a page: an overline label, then its [children] with [FluteSpace.md] between,
/// then an optional caption [footer].
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, this.title, this.footer, required this.children});
  final String? title;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) SettingsLabel(title!),
          ...settingsSpaced(children, gap: FluteSpace.md),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(top: FluteSpace.sm),
              child: Text(footer!, style: FluteText.caption),
            ),
        ],
      );
}

/// A `surface` card with hairline dividers between its [children], inset past [indent].
/// Use it for a set of rows or controls that belong together.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children, this.indent = FluteSpace.lg});
  final List<Widget> children;
  final double indent;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: FluteRadius.lgAll,
        child: DecoratedBox(
          decoration: fluteSurface(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, indent: indent, color: FluteColors.line),
                children[i],
              ],
            ],
          ),
        ),
      );
}

/// Overline label above a section. Printed in capitals.
class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: FluteSpace.sm),
        child: Text(text.toUpperCase(), style: FluteText.overline),
      );
}

/// Press feedback for a tappable surface: a subtle scale (and a tint when [tint] is on), then a
/// selection haptic on tap. Reduced motion keeps the tint and drops the scale.
class SettingsPressable extends StatefulWidget {
  const SettingsPressable({
    super.key,
    required this.onTap,
    required this.child,
    this.semanticsLabel,
    this.tint = true,
  });
  final VoidCallback onTap;
  final Widget child;

  /// Set when this surface is a button on its own: its children are read as this one label.
  final String? semanticsLabel;

  /// Whether the pressed state tints the background. Off where the child paints its own fill.
  final bool tint;

  @override
  State<SettingsPressable> createState() => _SettingsPressableState();
}

class _SettingsPressableState extends State<SettingsPressable> {
  bool _down = false;

  void _setDown(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  void _tap() {
    HapticFeedback.selectionClick();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final duration = motion(context, 140);
    final scale = _down && !MediaQuery.disableAnimationsOf(context) ? 0.985 : 1.0;
    Widget body = AnimatedContainer(
      duration: duration,
      curve: Curves.easeOut,
      color: widget.tint && _down ? FluteColors.surfaceHigh : Colors.transparent,
      child: AnimatedScale(
        scale: scale,
        duration: duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
    body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setDown(true),
      onTapUp: (_) => _setDown(false),
      onTapCancel: () => _setDown(false),
      onTap: _tap,
      child: body,
    );
    if (widget.semanticsLabel != null) {
      body = Semantics(button: true, label: widget.semanticsLabel, excludeSemantics: true, child: body);
    }
    return body;
  }
}

/// One row in a settings group: an optional leading widget, a title with an optional [subtitle]
/// under it, an optional [trailing] widget, and a chevron when it opens something.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.chevron = false,
    this.onTap,
    this.semanticsLabel,
  });
  final String title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: FluteSpace.lg, vertical: FluteSpace.md),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: FluteSpace.md)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: FluteText.heading.copyWith(fontWeight: FontWeight.w500, color: FluteColors.text),
                ),
                if (subtitle != null) ...[const SizedBox(height: FluteSpace.xs), subtitle!],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: FluteSpace.sm), trailing!],
          if (chevron)
            const Padding(
              padding: EdgeInsets.only(left: FluteSpace.sm),
              child: Icon(Icons.chevron_right, color: FluteColors.faint),
            ),
        ],
      ),
    );
    final tap = onTap;
    if (tap == null) return row;
    return SettingsPressable(onTap: tap, semanticsLabel: semanticsLabel, child: row);
  }
}

/// A settings row with a switch. The whole row toggles; [busy] shows a spinner and locks it.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.busy = false,
  });
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? subtitle;
  final Widget? leading;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final change = busy ? null : onChanged;
    void flip(bool next) {
      HapticFeedback.selectionClick();
      change?.call(next);
    }

    return SettingsRow(
      title: title,
      subtitle: subtitle,
      leading: leading,
      onTap: change == null ? null : () => flip(!value),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: FluteSpace.sm),
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          Switch(value: value, onChanged: change == null ? null : flip),
        ],
      ),
    );
  }
}

/// A 40 dp rounded square with an icon: the leading mark of a settings row.
class SettingsIconTile extends StatelessWidget {
  const SettingsIconTile({super.key, required this.icon, this.size = 40});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(color: FluteColors.surfaceHigh, borderRadius: FluteRadius.mdAll),
          child: Icon(icon, size: size / 2, color: FluteColors.textSecondary),
        ),
      );
}

/// A small status dot. Colour carries the state; the text beside it says what it is.
class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// The hub row for one area: icon tile, title, a one-line status and a chevron.
class SettingsHubRow extends StatelessWidget {
  const SettingsHubRow({
    super.key,
    required this.icon,
    required this.title,
    required this.status,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SettingsRow(
        leading: SettingsIconTile(icon: icon),
        title: title,
        subtitle: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: FluteText.caption),
        chevron: true,
        onTap: onTap,
        semanticsLabel: '$title, $status',
      );
}

/// Destructive action: a quiet text button in [FluteColors.danger]. Always behind [confirmRemove].
class SettingsDangerButton extends StatelessWidget {
  const SettingsDangerButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(foregroundColor: FluteColors.danger),
        child: Text(label),
      );
}

/// Fades and settles in when first shown. Instant under reduced motion.
class _Appear extends StatelessWidget {
  const _Appear({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: motion(context, 220),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * -4), child: child),
        ),
        child: child,
      );
}

/// Error text, read aloud when it appears.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: FluteSpace.sm),
        child: Semantics(
          liveRegion: true,
          child: _Appear(
            child: Text(
              text,
              style: FluteText.label.copyWith(fontWeight: FontWeight.w400, color: FluteColors.danger),
            ),
          ),
        ),
      );
}

/// A spinner with a line of text while something runs.
class ProgressLine extends StatelessWidget {
  const ProgressLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: FluteSpace.sm),
        child: _Appear(
          child: Row(
            children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: FluteSpace.sm),
              Expanded(
                child: Text(text, style: FluteText.caption.copyWith(color: FluteColors.softText)),
              ),
            ],
          ),
        ),
      );
}

/// A quiet confirmation such as "Saved". Use [SettingsTag] for warnings.
class CalmTag extends StatelessWidget {
  const CalmTag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => _Appear(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: FluteSpace.sm, vertical: FluteSpace.xs),
          decoration: BoxDecoration(color: FluteColors.accentSoft, borderRadius: FluteRadius.smAll),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check, size: 12, color: FluteColors.accent),
              const SizedBox(width: FluteSpace.xs),
              Flexible(
                child: Text(text, style: FluteText.caption.copyWith(color: FluteColors.accent)),
              ),
            ],
          ),
        ),
      );
}

/// A warning tag: an outlined amber label for something the user should notice.
class SettingsTag extends StatelessWidget {
  const SettingsTag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: FluteSpace.sm, vertical: FluteSpace.xs),
        decoration: BoxDecoration(
          borderRadius: FluteRadius.smAll,
          border: Border.all(color: FluteColors.warn.withValues(alpha: 0.6)),
        ),
        child: Text(text, style: FluteText.caption.copyWith(color: FluteColors.warn)),
      );
}

/// A quiet disclosure for long explanations: a "How it works" row that opens the text under it.
class SettingsHowItWorks extends StatefulWidget {
  const SettingsHowItWorks({super.key, required this.text});
  final String text;

  @override
  State<SettingsHowItWorks> createState() => _SettingsHowItWorksState();
}

class _SettingsHowItWorksState extends State<SettingsHowItWorks> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsPressable(
            tint: false,
            semanticsLabel: 'How it works',
            onTap: () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('How it works', style: FluteText.caption.copyWith(color: FluteColors.softText)),
                    Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: FluteColors.faint),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: motion(context, 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(bottom: FluteSpace.sm),
                    child: Text(widget.text, style: FluteText.caption.copyWith(height: 1.5)),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      );
}

/// Asks once before anything is removed. Resolves true only when the user presses [action].
Future<bool> confirmRemove(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'Remove',
}) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message, style: FluteText.body.copyWith(color: FluteColors.textSecondary)),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: FluteColors.textSecondary),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: FluteColors.danger),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return sure == true;
}

/// Bottom sheet body: title, then the form. Lifts itself above the keyboard.
class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(FluteSpace.lg, FluteSpace.sm, FluteSpace.lg, FluteSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: FluteText.title.copyWith(color: FluteColors.text)),
                const SizedBox(height: FluteSpace.lg),
                ...children,
              ],
            ),
          ),
        ),
      );
}
