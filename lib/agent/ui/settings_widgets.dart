import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../llm/llm_types.dart';
import 'chat_bubbles.dart' show motion;

/// Error text: readable on the dark surfaces and calmer than red.
const settingsAlert = Color(0xFFE39A8C);

const settingsMuted = TextStyle(color: FluteColors.muted, fontSize: 12);

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

/// Bottom padding for settings pages: clears the navigation bar and lets the last field scroll above
/// the keyboard.
EdgeInsets settingsPagePadding(BuildContext context) => EdgeInsets.fromLTRB(
      24,
      8,
      24,
      MediaQuery.paddingOf(context).bottom + MediaQuery.viewInsetsOf(context).bottom + 24,
    );

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

/// A settings sub-page: back button, a title, and a scroll view that clears the bottom inset.
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
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w300)),
        ),
        body: ListView(
          padding: settingsPagePadding(context),
          children: children,
        ),
      );
}

/// One row on the agent settings hub: icon, title, a live one-line status and a chevron.
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
  Widget build(BuildContext context) => Semantics(
        button: true,
        excludeSemantics: true,
        label: '$title, $status',
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Icon(icon, size: 22, color: FluteColors.softText),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: const TextStyle(color: FluteColors.text, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: settingsMuted.copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right, color: FluteColors.muted),
                ],
              ),
            ),
          ),
        ),
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

class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: settingsMuted.copyWith(fontSize: 11, letterSpacing: 1.2)),
      );
}

class ErrorLine extends StatelessWidget {
  const ErrorLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
          liveRegion: true,
          child: _Appear(
            child: Text(text, style: const TextStyle(color: settingsAlert, fontSize: 13)),
          ),
        ),
      );
}

class ProgressLine extends StatelessWidget {
  const ProgressLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _Appear(
          child: Row(
            children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(color: FluteColors.softText, fontSize: 13))),
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: FluteColors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check, size: 12, color: FluteColors.accent),
              const SizedBox(width: 4),
              Text(text, style: const TextStyle(color: FluteColors.accent, fontSize: 12)),
            ],
          ),
        ),
      );
}

class SettingsTag extends StatelessWidget {
  const SettingsTag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: FluteColors.warn.withValues(alpha: 0.6)),
        ),
        child: Text(text, style: const TextStyle(color: FluteColors.warn, fontSize: 11)),
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
      backgroundColor: FluteColors.surface,
      title: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w400)),
      content: Text(message, style: const TextStyle(color: FluteColors.softText, fontSize: 14)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: settingsAlert, foregroundColor: FluteColors.bg),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return sure == true;
}

/// A tappable surface in the settings style (tile radius 16, line border).
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: FluteColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: FluteColors.line),
            ),
            child: child,
          ),
        ),
      );
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
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w400)),
                const SizedBox(height: 16),
                ...children,
              ],
            ),
          ),
        ),
      );
}
