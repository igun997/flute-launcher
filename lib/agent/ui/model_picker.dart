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
            ? const Center(
                child: Text('Add a provider first.', style: TextStyle(color: FluteColors.muted)),
              )
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: [
              const Expanded(child: Text('Choose a model', style: TextStyle(fontSize: 18))),
              Text(count, style: const TextStyle(color: FluteColors.muted, fontSize: 13)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search by name or id',
              hintStyle: const TextStyle(color: FluteColors.muted),
              prefixIcon: const Icon(Icons.search, size: 20, color: FluteColors.muted),
              isDense: true,
              border: _fieldBorder(FluteColors.line),
              enabledBorder: _fieldBorder(FluteColors.line),
              focusedBorder: _fieldBorder(FluteColors.accent),
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
                  padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(_error!, style: const TextStyle(color: settingsAlert, fontSize: 13)),
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

  static OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color),
      );

  Widget _list(List<ModelInfo> shown, ProviderProfile profile) {
    if (_models.isEmpty) {
      if (_refreshing) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      return Center(
        child: Text(
          _error == null ? 'This provider lists no models.' : 'No models loaded yet.',
          style: const TextStyle(color: FluteColors.muted),
        ),
      );
    }
    if (shown.isEmpty) {
      return Center(
        child: Text(
          'No model matches "${_search.text.trim()}".',
          style: const TextStyle(color: FluteColors.muted),
        ),
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 16),
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

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.selected, required this.enabled, required this.onTap});
  final ModelInfo model;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      selected: selected,
      selectedColor: FluteColors.accent,
      onTap: enabled ? onTap : null,
      title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(model.id, maxLines: 1, overflow: TextOverflow.ellipsis, style: settingsMuted),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (model.contextLength != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(_contextLabel(model.contextLength!), style: settingsMuted),
            ),
          if (model.acceptsImages == true)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Tooltip(
                message: 'Accepts images',
                child: Icon(Icons.image_outlined, size: 16, color: FluteColors.muted),
              ),
            ),
          if (selected)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.check, size: 20, color: FluteColors.accent),
            ),
        ],
      ),
    );
  }
}
