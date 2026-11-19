import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../sandbox/local_wasm_provider.dart';
import '../sandbox/sandbox_manager.dart';
import '../sandbox/sandbox_provider.dart';
import '../tools/tool_support.dart';
import 'chat_bubbles.dart' show motion;
import 'settings_widgets.dart';

const _howItWorks =
    'A sandbox starts when the agent first needs it and stops when its run ends. Sandboxes this app '
    'creates are deleted. One you name is paused or stopped. It also stops after 90 seconds idle and '
    'when the app goes to the background. Keys stay on this device. Local Python has no shell and no '
    'file access.';

/// Sandbox provider choice, API keys, the local Python runtime, and a self-test.
/// Only the provider being viewed shows its card. Saved keys are never shown again.
class SandboxSettingsSection extends StatefulWidget {
  const SandboxSettingsSection({super.key, required this.manager});
  final SandboxManager manager;

  @override
  State<SandboxSettingsSection> createState() => _SandboxSettingsSectionState();
}

/// Owner keys for the status lines: a provider id, or one of these.
const _ownerLocal = 'local';
const _ownerKeepWarm = 'keepWarm';
const _ownerTest = 'test';

class _SandboxSettingsSectionState extends State<SandboxSettingsSection> {
  final _keys = <String, TextEditingController>{};
  final _urls = <String, TextEditingController>{};
  final _existing = <String, TextEditingController>{};
  final _keepWarm = TextEditingController();
  String? _busy;
  String? _error;
  String? _result;
  bool _localInstalled = false;

  /// The block that started the latest action. Null means the top-level provider choice.
  String? _owner;

  /// The provider whose card is shown. Independent of the preferred provider.
  late String _viewing;

  @override
  void initState() {
    super.initState();
    final m = widget.manager;
    for (final p in m.providers.where((p) => p.needsKey)) {
      _keys[p.id] = TextEditingController();
      _urls[p.id] = TextEditingController(text: m.apiUrl(p.id) ?? '');
      _existing[p.id] = TextEditingController(text: m.existingSandbox(p.id) ?? '');
    }
    _keepWarm.text = '${m.keepWarmMinutes}';
    _viewing = _initialView();
    _refreshLocal();
  }

  /// The preferred provider if it exists, else the first usable one, else Local.
  String _initialView() {
    final m = widget.manager;
    final providers = m.providers;
    final preferred = m.preferredProviderId;
    if (preferred != null && providers.any((p) => p.id == preferred)) return preferred;
    for (final p in providers) {
      if (p.usable) return p.id;
    }
    return 'local';
  }

  @override
  void dispose() {
    for (final c in [..._keys.values, ..._urls.values, ..._existing.values, _keepWarm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() action, {String? owner}) async {
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
    ToolError(:final message) => message,
    FormatException(:final message) => message,
    _ => readableError(e),
  };

  /// Shows a provider's card. Only a usable provider becomes the preferred one.
  Future<void> _view(SandboxManager m, String id) async {
    final p = m.providers.firstWhere((p) => p.id == id);
    setState(() => _viewing = id);
    if (p.usable) await _run('Saving...', () => m.setPreferred(id));
  }

  Future<void> _refreshLocal() async {
    final installed = await widget.manager.localInstalled();
    if (mounted) setState(() => _localInstalled = installed);
  }

  Future<void> _saveKey(SandboxProviderStatus p) => _run('Checking key...', () async {
    final url = _urls[p.id]!.text.trim();
    await widget.manager.saveKey(p.id, _keys[p.id]!.text, apiUrl: url.isEmpty ? null : url);
    _keys[p.id]!.clear();
  }, owner: p.id);

  Future<void> _saveExisting(String id) =>
      _run('Saving...', () => widget.manager.setExistingSandbox(id, _existing[id]!.text), owner: id);

  Future<void> _remove(SandboxProviderStatus p) async {
    final sure = await confirmRemove(
      context,
      title: 'Remove the ${p.label} key?',
      message: 'Sandbox runs on ${p.label} stop working until a new key is saved.',
    );
    if (!sure) return;
    await _run('Removing...', () => widget.manager.removeKey(p.id), owner: p.id);
  }

  Future<void> _downloadLocal() => _run('Downloading...', () async {
    await widget.manager.downloadLocal(
      onProgress: (f) {
        if (mounted) setState(() => _busy = 'Downloading ${(f * 100).round()}%');
      },
    );
    await _refreshLocal();
  }, owner: _ownerLocal);

  Future<void> _deleteLocal() async {
    final sure = await confirmRemove(
      context,
      title: 'Delete the local Python runtime?',
      message: 'It downloads again the next time the agent needs Python.',
      action: 'Delete',
    );
    if (!sure) return;
    await _run('Deleting...', () async {
      await widget.manager.deleteLocal();
      await _refreshLocal();
    }, owner: _ownerLocal);
  }

  Future<void> _saveKeepWarm() => _run('Saving...', () async {
    final minutes = int.tryParse(_keepWarm.text.trim());
    if (minutes == null) throw const FormatException('Enter whole minutes, 0 to 60.');
    await widget.manager.setKeepWarmMinutes(minutes);
    _keepWarm.text = '${widget.manager.keepWarmMinutes}';
  }, owner: _ownerKeepWarm);

  Future<void> _test() => _run('Running print(1+1)...', () async {
    final took = await widget.manager.selfTest();
    if (mounted) setState(() => _result = 'Works. Printed 2 in ${took.inMilliseconds} ms.');
  }, owner: _ownerTest);

  @override
  Widget build(BuildContext context) {
    final m = widget.manager;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final idle = _busy == null;
        final stopError = m.stopError;
        final viewed = m.providers.firstWhere((p) => p.id == _viewing, orElse: () => m.providers.last);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: settingsSpaced([
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Runs Python in an isolated machine and shuts it down when the answer is done.',
                  style: FluteText.caption,
                ),
                const SettingsHowItWorks(text: _howItWorks),
              ],
            ),
            SettingsSection(
              title: 'Provider',
              children: [
                if (_owner == null && _busy != null) ProgressLine(_busy!),
                if (_owner == null && _error != null) ErrorLine(_error!),
                if (stopError != null) ErrorLine('Could not stop the last sandbox. Retrying. $stopError'),
                SegmentedButton<String>(
                  segments: [
                    for (final p in m.providers) ButtonSegment(value: p.id, label: Text(p.label)),
                  ],
                  selected: {_viewing},
                  onSelectionChanged: idle ? (s) => _view(m, s.first) : null,
                ),
                AnimatedSwitcher(
                  duration: motion(context, 220),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topLeft,
                    children: [...previous, ?current],
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                  child: KeyedSubtree(
                    key: ValueKey('form-${viewed.id}'),
                    child: viewed.needsKey ? _remoteCard(viewed, idle) : _localCard(idle),
                  ),
                ),
              ],
            ),
            SettingsSection(
              title: 'Advanced',
              children: [
                SettingsGroup(children: [_keepWarmBlock(idle), _testBlock(idle)]),
              ],
            ),
          ]),
        );
      },
    );
  }

  Widget _remoteCard(SandboxProviderStatus p, bool idle) {
    final saved = p.hasKey;
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
              if (!p.usable) ...[
                const SizedBox(height: FluteSpace.xs),
                Text('Add a key to use ${p.label}.', style: FluteText.caption),
              ],
              const SizedBox(height: FluteSpace.md),
              TextField(
                controller: _keys[p.id],
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '${p.label} API key',
                  hintText: saved ? 'Paste a new key to replace it' : 'Paste it here',
                ),
              ),
              const SizedBox(height: FluteSpace.sm),
              TextField(
                controller: _urls[p.id],
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'API address',
                  hintText: 'Optional, https only',
                ),
              ),
              const SizedBox(height: FluteSpace.md),
              Row(
                children: [
                  FilledButton(
                    onPressed: idle ? () => _saveKey(p) : null,
                    child: const Text('Save key'),
                  ),
                  if (saved) ...[
                    const Spacer(),
                    SettingsDangerButton(label: 'Remove', onPressed: idle ? () => _remove(p) : null),
                  ],
                ],
              ),
              if (_owner == p.id && _busy != null) ProgressLine(_busy!),
              if (_owner == p.id && _error != null) ErrorLine(_error!),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(FluteSpace.lg, 0, FluteSpace.sm, FluteSpace.md),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _existing[p.id],
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Existing sandbox ID',
                    helperText: 'Optional. Resumed, then paused after each run instead of deleted.',
                    helperMaxLines: 2,
                  ),
                ),
              ),
              TextButton(
                onPressed: idle ? () => _saveExisting(p.id) : null,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _localCard(bool idle) {
    final sizeMb = (LocalWasmProvider.sizeBytes / (1024 * 1024)).toStringAsFixed(0);
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
                    child: Text('Local Python', style: FluteText.heading.copyWith(color: FluteColors.text)),
                  ),
                  if (_localInstalled) const CalmTag('Installed'),
                ],
              ),
              const SizedBox(height: FluteSpace.xs),
              Text(
                'Python 3.12 on this phone, no account needed. About $sizeMb MB, downloaded once.',
                style: FluteText.caption,
              ),
              const SizedBox(height: FluteSpace.md),
              if (_localInstalled)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SettingsDangerButton(label: 'Delete runtime', onPressed: idle ? _deleteLocal : null),
                )
              else
                FilledButton(
                  onPressed: idle ? _downloadLocal : null,
                  child: Text('Download runtime ($sizeMb MB)'),
                ),
              if (_owner == _ownerLocal && _busy != null) ProgressLine(_busy!),
              if (_owner == _ownerLocal && _error != null) ErrorLine(_error!),
            ],
          ),
        ),
        SettingsSwitchRow(
          title: 'Allow internet',
          subtitle: Text(
            'Python can fetch public web pages and APIs. Your phone and home network stay blocked.',
            style: FluteText.caption,
          ),
          value: widget.manager.localNetwork,
          onChanged: idle ? (v) => widget.manager.setLocalNetwork(v) : null,
        ),
      ],
    );
  }

  Widget _keepWarmBlock(bool idle) => Padding(
        padding: const EdgeInsets.all(FluteSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Keep warm', style: FluteText.heading.copyWith(color: FluteColors.text)),
            const SizedBox(height: FluteSpace.xs),
            Text(
              'Keeps the sandbox running this many minutes after a run. 0 stops it when the run ends.',
              style: FluteText.caption,
            ),
            const SizedBox(height: FluteSpace.md),
            Row(
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _keepWarm,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Minutes'),
                  ),
                ),
                const SizedBox(width: FluteSpace.sm),
                TextButton(onPressed: idle ? _saveKeepWarm : null, child: const Text('Save')),
              ],
            ),
            if (_owner == _ownerKeepWarm && _busy != null) ProgressLine(_busy!),
            if (_owner == _ownerKeepWarm && _error != null) ErrorLine(_error!),
          ],
        ),
      );

  Widget _testBlock(bool idle) => Padding(
        padding: const EdgeInsets.all(FluteSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Test', style: FluteText.heading.copyWith(color: FluteColors.text)),
            const SizedBox(height: FluteSpace.xs),
            Text(
              'Runs print(1+1) in the sandbox the agent would use and reports how long it took.',
              style: FluteText.caption,
            ),
            const SizedBox(height: FluteSpace.md),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(onPressed: idle ? _test : null, child: const Text('Run test')),
            ),
            if (_owner == _ownerTest && _busy != null) ProgressLine(_busy!),
            if (_owner == _ownerTest && _error != null) ErrorLine(_error!),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(top: FluteSpace.sm),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _result!,
                    style: FluteText.caption.copyWith(color: FluteColors.softText),
                  ),
                ),
              ),
          ],
        ),
      );
}
