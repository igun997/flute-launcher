import 'dart:convert';

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../tools/agent_tool.dart';
import 'chat_bubbles.dart' show motion, toolSourceIcon, toolSourceLabel;
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
      child: AnimatedSize(
        duration: motion(context, 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: motion(context, 200),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: request == null
              ? const SizedBox.shrink(key: ValueKey('none'))
              : _ConfirmBody(
                  key: ObjectKey(request),
                  request: request,
                  onDecide: widget.controller.resolve,
                ),
        ),
      ),
    );
  }
}

/// What the sheet says about one request, split for reading.
@visibleForTesting
class ConfirmView {
  const ConfirmView({required this.headline, this.body, this.details = const []});

  /// The first line of the tool's summary.
  final String headline;

  /// Longer text the action works on, such as code. Shown whole in a block.
  final String? body;

  /// Arguments that the headline and body do not already state, in the tool's order.
  final List<MapEntry<String, Object?>> details;

  /// The details open by themselves only for one short value.
  bool get detailsOpenByDefault => details.length == 1 && !_isBlock(details.single.value);
}

/// Splits [request] into the headline, the body and the arguments still worth showing. Empty, null
/// and default-looking values are dropped, and so is any value the headline or body already states.
@visibleForTesting
ConfirmView confirmView(ConfirmRequest request) {
  final summary = request.summary.trim();
  final cut = summary.indexOf('\n');
  final headline = cut < 0 ? summary : summary.substring(0, cut).trim();
  final tail = cut < 0 ? '' : summary.substring(cut + 1).trim();

  final schema = _Schema(request.tool.parameters);
  final candidates = [
    for (final e in request.arguments.entries)
      if (!schema.isDefaultLooking(e.key, e.value)) e,
  ];

  // The summary previews the body, often cut short. Show the whole argument it came from instead,
  // so the text appears once and in full.
  String? sourceKey;
  String? body;
  if (tail.isNotEmpty) {
    final preview = _squash(tail).replaceFirst(RegExp(r'\.\.\.$'), '');
    for (final e in candidates) {
      final value = e.value;
      if (value is String && preview.isNotEmpty && _squash(value).startsWith(preview)) {
        sourceKey = e.key;
        body = value.trim();
        break;
      }
    }
    body ??= tail;
  }

  final stated = _squash('$headline ${body ?? ''}');
  return ConfirmView(
    headline: headline,
    body: body,
    details: [
      for (final e in candidates)
        if (e.key != sourceKey && !_alreadyStated(e.value, stated)) e,
    ],
  );
}

/// The tool's parameter schema, read for defaults and required names.
class _Schema {
  _Schema(Map<String, dynamic> parameters)
      : _props = _map(parameters['properties']),
        _required = _names(parameters['required']);

  final Map<Object?, Object?> _props;
  final Set<String> _required;

  bool isDefaultLooking(String key, Object? value) {
    if (value == null) return true;
    if (value is String) return value.trim().isEmpty;
    if (value is Iterable) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    final prop = _props[key];
    final hasDefault = prop is Map && prop.containsKey('default');
    final defaultValue = prop is Map ? prop['default'] : null;
    if (hasDefault && value == defaultValue) return true;
    final zeroish = value == 0 || value == false;
    return zeroish && !hasDefault && !_required.contains(key);
  }

  static Map<Object?, Object?> _map(Object? value) => value is Map ? value.cast<Object?, Object?>() : const {};

  static Set<String> _names(Object? value) => value is List ? value.whereType<String>().toSet() : const {};
}

/// A string argument the headline or body already spells out is not shown again.
bool _alreadyStated(Object? value, String stated) {
  if (value is! String) return false;
  final text = _squash(value);
  return text.length >= 3 && stated.contains(text);
}

String _squash(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

const _maxShownChars = 8000;

String _clip(String text) => text.length > _maxShownChars ? '${text.substring(0, _maxShownChars)}...' : text;

String _valueText(Object? value) {
  final text = switch (value) {
    String s => s.trim(),
    num() || bool() => '$value',
    _ => _json(value),
  };
  return _clip(text);
}

/// Long or multi-line values are shown as a block; short ones sit beside their name.
bool _isBlock(Object? value) {
  final text = _valueText(value);
  return text.contains('\n') || text.length > 120;
}

String _json(Object? value) {
  try {
    final compact = jsonEncode(value);
    return compact.length > 120 ? const JsonEncoder.withIndent('  ').convert(value) : compact;
  } catch (_) {
    return value.toString();
  }
}

class _ConfirmBody extends StatefulWidget {
  const _ConfirmBody({super.key, required this.request, required this.onDecide});

  final ConfirmRequest request;
  final ValueChanged<ConfirmDecision> onDecide;

  @override
  State<_ConfirmBody> createState() => _ConfirmBodyState();
}

class _ConfirmBodyState extends State<_ConfirmBody> {
  late final ConfirmView _view = confirmView(widget.request);
  late bool _detailsOpen = _view.detailsOpenByDefault;

  void _decide(ConfirmDecision decision) {
    if (decision != ConfirmDecision.deny) HapticFeedback.lightImpact();
    widget.onDecide(decision);
  }

  @override
  Widget build(BuildContext context) {
    final tool = widget.request.tool;
    final view = _view;
    final body = view.body;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(FluteSpace.lg, FluteSpace.xs, FluteSpace.lg, FluteSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: FluteColors.surfaceTop, borderRadius: FluteRadius.mdAll),
                  child: Icon(toolSourceIcon(tool.source), color: FluteColors.textSecondary, size: 20),
                ),
                const SizedBox(width: FluteSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tool.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: FluteText.label),
                      Text(
                        toolSourceLabel(tool.source),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FluteText.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: FluteSpace.lg),
            Text(view.headline, maxLines: 6, overflow: TextOverflow.ellipsis, style: FluteText.title),
            if (body != null) ...[
              const SizedBox(height: FluteSpace.md),
              _CodeBlock(text: body),
            ],
            if (view.details.isNotEmpty) _details(context, view.details),
            const SizedBox(height: FluteSpace.xl),
            FilledButton(
              onPressed: () => _decide(ConfirmDecision.allowOnce),
              child: const Text('Allow once'),
            ),
            const SizedBox(height: FluteSpace.sm),
            OutlinedButton(
              onPressed: () => _decide(ConfirmDecision.allowForSession),
              child: const Text('Allow for this chat'),
            ),
            TextButton(
              onPressed: () => _decide(ConfirmDecision.deny),
              style: TextButton.styleFrom(foregroundColor: FluteColors.textSecondary),
              child: const Text('Deny'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _details(BuildContext context, List<MapEntry<String, Object?>> details) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _detailsOpen,
          child: InkWell(
            borderRadius: FluteRadius.smAll,
            onTap: () => setState(() => _detailsOpen = !_detailsOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  const Text('Details', style: TextStyle(color: FluteColors.muted, fontSize: 14)),
                  AnimatedRotation(
                    turns: _detailsOpen ? 0.5 : 0,
                    duration: motion(context, 200),
                    curve: Curves.easeOutCubic,
                    child: const Icon(Icons.expand_more, size: 20, color: FluteColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: motion(context, 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _detailsOpen
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final e in details)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ArgRow(name: e.key, value: e.value),
                      ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// One argument: its name beside a short value, or above a block for long and multi-line values.
class _ArgRow extends StatelessWidget {
  const _ArgRow({required this.name, required this.value});

  final String name;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    final label = name.replaceAll('_', ' ');
    const labelStyle = TextStyle(color: FluteColors.muted, fontSize: 12.5);
    if (_isBlock(value)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: labelStyle),
          const SizedBox(height: 6),
          _CodeBlock(text: _valueText(value)),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 104, child: Text(label, style: labelStyle)),
        Expanded(
          child: Text(_valueText(value), style: const TextStyle(fontSize: 14, height: 1.35)),
        ),
      ],
    );
  }
}

/// Monospace text in a box that scrolls past a fixed height.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FluteColors.surfaceHigh,
        borderRadius: FluteRadius.mdAll,
        border: Border.all(color: FluteColors.line),
      ),
      child: SingleChildScrollView(
        child: Text(
          _clip(text),
          style: const TextStyle(
            fontFamily: 'monospace',
            color: FluteColors.text,
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
