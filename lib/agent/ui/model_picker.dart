import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../llm/model_catalog.dart';
import '../llm/model_info.dart';
import 'chat_bubbles.dart' show motion;
import 'settings_widgets.dart';

const _catalogTimeout = Duration(seconds: 25);

/// Opens the model sheet for the active provider: the saved list at once, refreshed in the background.
Future<void> showModelPicker(BuildContext context, {required Flute flute}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ModelPicker(flute: flute),
  );
}

/// Fetches the models of [profile] with its current credential, saves them as the cache and returns them.
/// Throws [LlmException] or a network error; callers show [readableError].
Future<List<ModelInfo>> loadModels(Flute flute, ProviderProfile profile) async {
  final token = await flute.providers.tokenFor(profile.id);
  final models = await ModelCatalog.fetch(kind: profile.kind, baseUrl: profile.baseUrl, token: token)
      .timeout(_catalogTimeout);
  await ModelCatalog.saveCache(flute.prefs, profile.id, models);
  return models;
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.flute});
  final Flute flute;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  final _search = TextEditingController();
  ProviderProfile? _profile;
  List<ModelInfo> _models = const [];
  bool _refreshing = false;
  bool _selecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.flute.providers.active;
    _profile = profile;
    if (profile != null) {
      _models = ModelCatalog.loadCache(widget.flute.prefs, profile.id) ?? const [];
      _refreshing = true;
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final profile = _profile;
    if (profile == null) return;
    final hadCache = _models.isNotEmpty;
    try {
      final models = await loadModels(widget.flute, profile);
      if (!mounted) return;
      setState(() {
        _models = models;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        final reason = readableError(e);
        setState(() => _error = hadCache ? 'Could not refresh the list. $reason' : reason);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _retry() {
    setState(() {
      _refreshing = true;
      _error = null;
    });
    unawaited(_refresh());
  }

  Future<void> _select(ModelInfo model) async {
    final profile = _profile;
    if (profile == null || _selecting) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selecting = true;
      _error = null;
    });
    try {
      await widget.flute.providers.setModel(profile.id, model.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _selecting = false;
          _error = readableError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final profile = _profile;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        height: max(280.0, size.height * 0.8 - keyboard),
        child: profile == null
            ? Center(child: Text('Add a provider first.', style: FluteText.body.copyWith(color: FluteColors.muted)))
            : _body(profile),
      ),
    );
  }

  Widget _body(ProviderProfile profile) {
    final query = _search.text.trim();
    final shown = query.isEmpty ? _models : ModelCatalog.search(_models, query);
    final total = _models.length;
    final count = total == 0
        ? ''
        : query.isEmpty
            ? _countLabel(total)
            : '${shown.length} of ${_countLabel(total)}';
    final caption = [profile.label, if (count.isNotEmpty) count].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(FluteSpace.xl, FluteSpace.sm, FluteSpace.xl, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Choose a model', style: FluteText.title),
              const SizedBox(height: FluteSpace.xs),
              Text(caption, style: FluteText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(FluteSpace.lg, FluteSpace.lg, FluteSpace.lg, FluteSpace.sm),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search by name or id',
              prefixIcon: const Icon(Icons.search, size: 20, color: FluteColors.muted),
              isDense: true,
            ),
          ),
        ),
        // Progress and errors slide in and out instead of jumping the list below them.
        AnimatedSize(
          duration: motion(context, 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_refreshing || _selecting) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(FluteSpace.xl, FluteSpace.xs, FluteSpace.md, FluteSpace.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(_error!, style: FluteText.caption.copyWith(color: FluteColors.danger)),
                      ),
                      if (!_refreshing) TextButton(onPressed: _retry, child: const Text('Retry')),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _list(shown, profile)),
      ],
    );
  }

  Widget _list(List<ModelInfo> shown, ProviderProfile profile) {
    if (_models.isEmpty) {
      if (_refreshing) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      return Center(
        child: Text(
          _error == null ? 'This provider lists no models.' : 'No models loaded yet.',
          style: FluteText.body.copyWith(color: FluteColors.muted),
        ),
      );
    }
    if (shown.isEmpty) {
      return Center(
        child: Text(
          'No model matches "${_search.text.trim()}".',
          style: FluteText.body.copyWith(color: FluteColors.muted),
        ),
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(FluteSpace.sm, 0, FluteSpace.sm, FluteSpace.lg),
      itemCount: shown.length,
      itemBuilder: (_, i) {
        final model = shown[i];
        return _ModelRow(
          model: model,
          selected: model.id == profile.model,
          enabled: !_selecting,
          onTap: () => _select(model),
        );
      },
    );
  }
}

String _countLabel(int n) => n == 1 ? '1 model' : '$n models';

String _contextLabel(int tokens) {
  if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
  if (tokens >= 1000) return '${(tokens / 1000).round()}K';
  return '$tokens';
}

/// A model: name in label, id in caption. The selected one takes the accent-soft fill and a check.
class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.selected, required this.enabled, required this.onTap});
  final ModelInfo model;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: FluteRadius.mdAll,
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: motion(context, 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.fromLTRB(FluteSpace.md, FluteSpace.md, FluteSpace.md, FluteSpace.md),
            decoration: BoxDecoration(
              color: selected ? FluteColors.accentSoft : Colors.transparent,
              borderRadius: FluteRadius.mdAll,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: FluteText.label),
                      const SizedBox(height: 2),
                      Text(model.id, maxLines: 1, overflow: TextOverflow.ellipsis, style: FluteText.caption),
                    ],
                  ),
                ),
                if (model.contextLength != null)
                  Padding(
                    padding: const EdgeInsets.only(left: FluteSpace.sm),
                    child: Text(_contextLabel(model.contextLength!), style: FluteText.caption),
                  ),
                if (model.acceptsImages == true)
                  const Padding(
                    padding: EdgeInsets.only(left: FluteSpace.sm),
                    child: Tooltip(
                      message: 'Accepts images',
                      child: Icon(Icons.image_outlined, size: 16, color: FluteColors.muted),
                    ),
                  ),
                SizedBox(
                  width: 28,
                  child: selected
                      ? const Align(
                          alignment: Alignment.centerRight,
                          child: Icon(Icons.check_rounded, size: 20, color: FluteColors.accent),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
