import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../sandbox/local_wasm_provider.dart';
import '../sandbox/sandbox_manager.dart';
import '../sandbox/sandbox_provider.dart';
import '../tools/tool_support.dart';
import 'settings_widgets.dart';

/// Sandbox provider choice, API keys, the local Python runtime, and a self-test.
/// Only the provider being viewed shows its form. Saved keys are never shown again.
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
  bool _howOpen = false;

  /// The block that started the latest action. Null means the top-level provider choice.
  String? _owner;

  /// The provider whose form is shown. Independent of the preferred provider.
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

  /// Shows a provider's form. Only a usable provider becomes the preferred one.
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
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final idle = _busy == null;
        final stopError = m.stopError;
        final viewed = m.providers.firstWhere((p) => p.id == _viewing, orElse: () => m.providers.last);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Runs Python in an isolated machine and shuts it down when the answer is done.',
                style: settingsMuted,
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _howOpen = !_howOpen),
              child: Semantics(
                button: true,
                expanded: _howOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('How it works', style: TextStyle(color: FluteColors.softText, fontSize: 13)),
                      Icon(
                        _howOpen ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: FluteColors.muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: motionDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topLeft,
              child: _howOpen
                  ? const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'A sandbox starts when the agent first needs it and stops when its run ends. Sandboxes this app creates are deleted. One you name is paused or stopped. It also stops after 90 seconds idle and when the app goes to the background. Keys stay on this device. Local Python has no shell and no file access.',
                        style: settingsMuted,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
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
            if (!viewed.usable)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Add a key to use ${viewed.label}.', style: settingsMuted),
              ),
            AnimatedSwitcher(
              duration: motionDuration,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topLeft,
                children: [...previous, ?current],
              ),
              transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
              child: KeyedSubtree(
                key: ValueKey('form-${viewed.id}'),
                child: SizedBox(
                  width: double.infinity,
                  child: viewed.needsKey ? _remoteBlock(viewed, idle) : _localBlock(idle),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SettingsLabel('Keep warm'),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Keeps the sandbox running after a run for this many minutes, so the next run starts faster. 0 stops it when the run ends.',
                      style: settingsMuted,
                    ),
                  ),
                  Row(
                    children: [
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: _keepWarm,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(isDense: true, suffixText: 'minutes'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(onPressed: idle ? _saveKeepWarm : null, child: const Text('Save')),
                    ],
                  ),
                  if (_owner == _ownerKeepWarm && _busy != null) ProgressLine(_busy!),
                  if (_owner == _ownerKeepWarm && _error != null) ErrorLine(_error!),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SettingsLabel('Test'),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Runs print(1+1) in the sandbox the agent would use and reports how long it took.',
                      style: settingsMuted,
                    ),
                  ),
                  OutlinedButton(onPressed: idle ? _test : null, child: const Text('Run test')),
                  if (_owner == _ownerTest && _busy != null) ProgressLine(_busy!),
                  if (_owner == _ownerTest && _error != null) ErrorLine(_error!),
                  AnimatedSwitcher(
                    duration: motionDuration,
                    child: _result == null
                        ? const SizedBox.shrink(key: ValueKey('no-result'))
                        : Padding(
                            key: ValueKey(_result),
                            padding: const EdgeInsets.only(top: 8),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _result!,
                                style: const TextStyle(color: FluteColors.softText, fontSize: 13),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _remoteBlock(SandboxProviderStatus p, bool idle) {
    final saved = p.hasKey;
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
            controller: _keys[p.id],
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '${p.label} API key',
              hintText: saved ? 'Paste a new key to replace it' : 'Paste it here',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urls[p.id],
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'API address',
              hintText: 'Optional, https only',
              isDense: true,
            ),
          ),
          Row(
            children: [
              FilledButton(onPressed: idle ? () => _saveKey(p) : null, child: const Text('Save key')),
              if (saved) ...[
                const Spacer(),
                TextButton(
                  onPressed: idle ? () => _remove(p) : null,
                  child: const Text('Remove', style: TextStyle(color: settingsAlert)),
                ),
              ],
            ],
          ),
          if (_owner == p.id && _busy != null) ProgressLine(_busy!),
          if (_owner == p.id && _error != null) ErrorLine(_error!),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _existing[p.id],
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Existing sandbox ID',
                    helperText: 'Optional. The agent resumes it and stops or pauses it after each run instead of deleting it.',
                    helperMaxLines: 2,
                    isDense: true,
                  ),
                ),
              ),
              TextButton(onPressed: idle ? () => _saveExisting(p.id) : null, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _localBlock(bool idle) {
    final sizeMb = (LocalWasmProvider.sizeBytes / (1024 * 1024)).toStringAsFixed(0);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Local Python', style: TextStyle(color: FluteColors.text, fontSize: 15)),
              const SizedBox(width: 8),
              if (_localInstalled) const CalmTag('Installed'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Python 3.12 on this phone, no account needed. About $sizeMb MB, downloaded once.',
            style: settingsMuted,
          ),
          const SizedBox(height: 8),
          if (_localInstalled)
            TextButton(
              onPressed: idle ? _deleteLocal : null,
              child: const Text('Delete runtime', style: TextStyle(color: settingsAlert)),
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
    );
  }
}
