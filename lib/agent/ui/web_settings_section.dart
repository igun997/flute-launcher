import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../web/web_api.dart';
import '../web/web_settings.dart';
import 'settings_widgets.dart';

/// Web search keys (Tavily or Firecrawl). Saved keys are never shown again.
class WebSettingsSection extends StatefulWidget {
  const WebSettingsSection({super.key, required this.flute});
  final Flute flute;

  @override
  State<WebSettingsSection> createState() => _WebSettingsSectionState();
}

class _WebSettingsSectionState extends State<WebSettingsSection> {
  final _fields = {for (final p in WebProvider.values) p: TextEditingController()};
  String? _busy;
  String? _error;

  /// The provider whose block started the latest action. Null means the top-level choice.
  WebProvider? _owner;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() action, {WebProvider? owner}) async {
    setState(() {
      _busy = label;
      _owner = owner;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  static String _message(Object e) => switch (e) {
    WebApiException(:final message) => message,
    FormatException(:final message) => message,
    _ => readableError(e),
  };

  Future<void> _save(WebProvider p) => _run('Checking key...', () async {
    await widget.flute.web.saveKey(p, _fields[p]!.text);
    _fields[p]!.clear();
  }, owner: p);

  Future<void> _openKeyPage(WebProvider p) => _run(
    'Opening...',
    () async {
      await launchUrl(Uri.parse(p.keyUrl), mode: LaunchMode.externalApplication);
    },
    owner: p,
  );

  Future<void> _remove(WebProvider p) async {
    final sure = await confirmRemove(
      context,
      title: 'Remove the ${p.label} key?',
      message: 'Web search stops working if no other key is saved.',
    );
    if (!sure) return;
    await _run('Removing...', () => widget.flute.web.removeKey(p), owner: p);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.flute.web,
      builder: (context, _) {
        final web = widget.flute.web;
        final chosen = web.provider;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Lets the agent search the web and read pages. Add a Tavily or Firecrawl key. Keys stay on this device.',
                style: settingsMuted,
              ),
            ),
            if (_owner == null && _busy != null) ProgressLine(_busy!),
            if (_owner == null && _error != null) ErrorLine(_error!),
            SegmentedButton<WebProvider>(
              emptySelectionAllowed: true,
              segments: [
                for (final p in WebProvider.values)
                  ButtonSegment(value: p, label: Text(p.label), enabled: web.hasKey(p)),
              ],
              selected: {?chosen},
              onSelectionChanged: (s) {
                if (s.isNotEmpty) web.setProvider(s.first);
              },
            ),
            for (final p in WebProvider.values) _providerBlock(p, web),
          ],
        );
      },
    );
  }

  Widget _providerBlock(WebProvider p, WebSettings web) {
    final saved = web.hasKey(p);
    final idle = _busy == null;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(p.label, style: const TextStyle(color: FluteColors.text, fontSize: 15)),
              const SizedBox(width: 8),
              if (saved) const CalmTag('Saved'),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _fields[p],
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '${p.label} API key',
              hintText: saved ? 'Paste a new key to replace it' : 'Paste it here',
              isDense: true,
            ),
          ),
          Row(
            children: [
              FilledButton(onPressed: idle ? () => _save(p) : null, child: const Text('Save key')),
              const SizedBox(width: 8),
              TextButton(onPressed: idle ? () => _openKeyPage(p) : null, child: const Text('Get a key')),
              if (saved) ...[
                const Spacer(),
                TextButton(
                  onPressed: idle ? () => _remove(p) : null,
                  child: const Text('Remove', style: TextStyle(color: settingsAlert)),
                ),
              ],
            ],
          ),
          if (_owner == p && _busy != null) ProgressLine(_busy!),
          if (_owner == p && _error != null) ErrorLine(_error!),
        ],
      ),
    );
  }
}
