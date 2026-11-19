import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../web/web_api.dart';
import '../web/web_settings.dart';
import 'settings_widgets.dart';

/// Web search keys (Tavily or Firecrawl). One provider's card shows at a time; saved keys are never
/// shown again.
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

  /// The provider whose card started the latest action. Null means the top-level choice.
  WebProvider? _owner;

  /// The provider whose card is shown. Selecting a provider with a saved key also uses it.
  late WebProvider _viewing;

  @override
  void initState() {
    super.initState();
    _viewing = widget.flute.web.provider ?? WebProvider.values.first;
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _select(WebProvider p) {
    setState(() => _viewing = p);
    if (widget.flute.web.hasKey(p)) widget.flute.web.setProvider(p);
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: settingsSpaced([
            Text(
              'Lets the agent search the web and read pages. Keys stay on this device.',
              style: FluteText.caption,
            ),
            SettingsSection(
              title: 'Search provider',
              children: [
                if (_owner == null && _busy != null) ProgressLine(_busy!),
                if (_owner == null && _error != null) ErrorLine(_error!),
                SegmentedButton<WebProvider>(
                  segments: [
                    for (final p in WebProvider.values) ButtonSegment(value: p, label: Text(p.label)),
                  ],
                  selected: {_viewing},
                  onSelectionChanged: (s) => _select(s.first),
                ),
                _providerCard(_viewing, web),
              ],
            ),
          ]),
        );
      },
    );
  }

  Widget _providerCard(WebProvider p, WebSettings web) {
    final saved = web.hasKey(p);
    final idle = _busy == null;
    final inUse = web.provider == p;
    final status = inUse
        ? 'Used for web search.'
        : saved
            ? 'Saved. Select it to use it.'
            : 'Add a key to use ${p.label}.';
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(FluteSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(p.label, style: FluteText.heading.copyWith(color: FluteColors.text)),
                  ),
                  if (saved) const CalmTag('Saved'),
                ],
              ),
              const SizedBox(height: FluteSpace.xs),
              Text(status, style: FluteText.caption),
              const SizedBox(height: FluteSpace.md),
              TextField(
                controller: _fields[p],
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '${p.label} API key',
                  hintText: saved ? 'Paste a new key to replace it' : 'Paste it here',
                ),
              ),
              const SizedBox(height: FluteSpace.md),
              Row(
                children: [
                  FilledButton(onPressed: idle ? () => _save(p) : null, child: const Text('Save key')),
                  const SizedBox(width: FluteSpace.sm),
                  TextButton(onPressed: idle ? () => _openKeyPage(p) : null, child: const Text('Get a key')),
                  if (saved) ...[
                    const Spacer(),
                    SettingsDangerButton(label: 'Remove', onPressed: idle ? () => _remove(p) : null),
                  ],
                ],
              ),
              if (_owner == p && _busy != null) ProgressLine(_busy!),
              if (_owner == p && _error != null) ErrorLine(_error!),
            ],
          ),
        ),
      ],
    );
  }
}
