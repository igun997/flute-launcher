import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../sandbox/local_wasm_provider.dart';
import '../sandbox/sandbox_manager.dart';
import '../sandbox/sandbox_provider.dart';
import '../tools/tool_support.dart';
import 'settings_widgets.dart';

/// Sandbox provider choice, API keys, the local Python runtime, and a self-test.
/// Saved keys are never shown again.
class SandboxSettingsSection extends StatefulWidget {
  const SandboxSettingsSection({super.key, required this.manager});
  final SandboxManager manager;

  @override
  State<SandboxSettingsSection> createState() => _SandboxSettingsSectionState();
}

class _SandboxSettingsSectionState extends State<SandboxSettingsSection> {
  final _keys = <String, TextEditingController>{};
  final _urls = <String, TextEditingController>{};
  final _existing = <String, TextEditingController>{};
  final _keepWarm = TextEditingController();
  String? _busy;
  String? _error;
  String? _result;
  bool _localInstalled = false;

  @override
  void initState() {
    super.initState();
    for (final p in widget.manager.providers.where((p) => p.needsKey)) {
      _keys[p.id] = TextEditingController();
      _urls[p.id] = TextEditingController(text: widget.manager.apiUrl(p.id) ?? '');
      _existing[p.id] = TextEditingController(text: widget.manager.existingSandbox(p.id) ?? '');
    }
    _keepWarm.text = '${widget.manager.keepWarmMinutes}';
    _refreshLocal();
  }

  @override
  void dispose() {
    for (final c in [..._keys.values, ..._urls.values, ..._existing.values, _keepWarm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    setState(() {
      _busy = label;
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

  Future<void> _refreshLocal() async {
    final installed = await widget.manager.localInstalled();
    if (mounted) setState(() => _localInstalled = installed);
  }

  Future<void> _saveKey(SandboxProviderStatus p) => _run('Checking key...', () async {
    final url = _urls[p.id]!.text.trim();
    await widget.manager.saveKey(p.id, _keys[p.id]!.text, apiUrl: url.isEmpty ? null : url);
    _keys[p.id]!.clear();
  });

  Future<void> _saveExisting(String id) =>
      _run('Saving...', () => widget.manager.setExistingSandbox(id, _existing[id]!.text));

  Future<void> _remove(SandboxProviderStatus p) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove the ${p.label} key?'),
        content: Text('Sandbox runs on ${p.label} stop working until a new key is saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    await _run('Removing...', () => widget.manager.removeKey(p.id));
  }

  Future<void> _downloadLocal() => _run('Downloading...', () async {
    await widget.manager.downloadLocal(
      onProgress: (f) {
        if (mounted) setState(() => _busy = 'Downloading ${(f * 100).round()}%');
      },
    );
    await _refreshLocal();
  });

  Future<void> _deleteLocal() => _run('Deleting...', () async {
    await widget.manager.deleteLocal();
    await _refreshLocal();
  });

  Future<void> _saveKeepWarm() => _run('Saving...', () async {
    final minutes = int.tryParse(_keepWarm.text.trim());
    if (minutes == null) throw const FormatException('Enter whole minutes, 0 to 60.');
    await widget.manager.setKeepWarmMinutes(minutes);
    _keepWarm.text = '${widget.manager.keepWarmMinutes}';
  });

  Future<void> _test() => _run('Running print(1+1)...', () async {
    final took = await widget.manager.selfTest();
    if (mounted) setState(() => _result = 'Works. Printed 2 in ${took.inMilliseconds} ms.');
  });

  @override
  Widget build(BuildContext context) {
    final m = widget.manager;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final idle = _busy == null;
        final stopError = m.stopError;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SettingsLabel('Sandbox'),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Lets the agent run Python and shell commands in an isolated machine. Keys stay on this device.',
                style: settingsMuted,
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'A sandbox starts when the agent first needs it and stops when its run ends. Sandboxes this app creates are deleted. One you name is paused or stopped. It also stops after 90 seconds idle and when the app goes to the background.',
                style: settingsMuted,
              ),
            ),
            if (_busy != null) ProgressLine(_busy!),
            if (_error != null) ErrorLine(_error!),
            if (stopError != null) ErrorLine('Could not stop the last sandbox. Retrying. $stopError'),
            SegmentedButton<String>(
              emptySelectionAllowed: true,
              segments: [
                for (final p in m.providers)
                  ButtonSegment(value: p.id, label: Text(p.label), enabled: p.usable),
              ],
              selected: {?m.preferredProviderId},
              onSelectionChanged: idle
                  ? (s) => _run('Saving...', () => m.setPreferred(s.isEmpty ? null : s.first))
                  : null,
            ),
            for (final p in m.providers)
              if (p.needsKey) _remoteBlock(p, idle) else _localBlock(idle),
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
                  if (_result != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _result!,
                        style: const TextStyle(color: FluteColors.softText, fontSize: 13),
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
              if (saved) const SettingsTag('Saved'),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keys[p.id],
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: saved ? 'Paste a new key to replace it' : 'Paste your ${p.label} API key',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urls[p.id],
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(hintText: 'API address (optional, https only)', isDense: true),
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
          const SizedBox(height: 8),
          const Text(
            'Existing sandbox ID (optional). The agent resumes it and stops or pauses it after each run instead of deleting it.',
            style: settingsMuted,
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _existing[p.id],
                  autocorrect: false,
                  decoration: const InputDecoration(hintText: 'Sandbox ID', isDense: true),
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
              if (_localInstalled) const SettingsTag('Installed'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Runs Python 3.12 on this phone with no account. The runtime is about $sizeMb MB, downloaded on first use and kept in app storage. Python only: no shell and no file access.',
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
        ],
      ),
    );
  }
}
