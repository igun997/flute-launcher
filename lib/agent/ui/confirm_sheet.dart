import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../tools/agent_tool.dart';
import 'chat_bubbles.dart' show toolSourceIcon, toolSourceLabel;
import 'confirm_controller.dart';

/// Shows the write waiting for an answer. It cannot be dismissed by tapping outside, and back
/// denies. It closes by itself once the queue is empty and stays up while more requests wait.
Future<void> showConfirmSheet(BuildContext context, ConfirmController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ConfirmSheet(controller: controller),
  );
}

class ConfirmSheet extends StatefulWidget {
  const ConfirmSheet({super.key, required this.controller});

  final ConfirmController controller;

  @override
  State<ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<ConfirmSheet> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (widget.controller.pending == null) {
      // Pop after this frame so the route's PopScope has already been told it may close.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.pending == null) Navigator.of(context).pop();
      });
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.controller.pending;
    return PopScope(
      canPop: request == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.controller.resolve(ConfirmDecision.deny);
      },
      child: request == null
          ? const SizedBox.shrink()
          : _ConfirmBody(request: request, onDecide: widget.controller.resolve),
    );
  }
}

class _ConfirmBody extends StatelessWidget {
  const _ConfirmBody({required this.request, required this.onDecide});

  final ConfirmRequest request;
  final ValueChanged<ConfirmDecision> onDecide;

  @override
  Widget build(BuildContext context) {
    final tool = request.tool;
    final args = request.arguments.entries.where((e) => e.value != null).toList();
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: FluteColors.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(toolSourceIcon(tool.source), color: FluteColors.accent, size: 19),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Allow this change?', style: TextStyle(color: FluteColors.muted, fontSize: 12)),
                      Text(
                        '${toolSourceLabel(tool.source)} · ${tool.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(request.summary, style: const TextStyle(fontSize: 17, height: 1.35)),
            if (args.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: FluteColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: FluteColors.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in args)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 96,
                              child: Text(e.key, style: const TextStyle(color: FluteColors.muted, fontSize: 12.5)),
                            ),
                            Expanded(
                              child: Text(
                                _display(e.value),
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5, height: 1.35),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => onDecide(ConfirmDecision.allowOnce),
              child: const Text('Allow once'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => onDecide(ConfirmDecision.allowForSession),
              child: const Text('Allow for this chat'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => onDecide(ConfirmDecision.deny),
              child: const Text('Deny', style: TextStyle(color: FluteColors.muted)),
            ),
          ],
        ),
      ),
    );
  }

  static String _display(Object? value) {
    final text = switch (value) {
      String s => s,
      num() || bool() => value.toString(),
      _ => _json(value),
    };
    return text.length > 400 ? '${text.substring(0, 400)}...' : text;
  }

  static String _json(Object? value) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }
}
