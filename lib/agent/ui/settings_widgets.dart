import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../llm/llm_types.dart';

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
        child: Text(text, style: const TextStyle(color: settingsAlert, fontSize: 13)),
      );
}

class ProgressLine extends StatelessWidget {
  const ProgressLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(color: FluteColors.softText, fontSize: 13))),
          ],
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
