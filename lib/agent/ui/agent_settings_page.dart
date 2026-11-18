import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../auth/provider_store.dart';
import '../llm/model_info.dart';
import '../tools/builtin_tools.dart';
import '../voice/voice_settings_section.dart';
import 'sandbox_settings_section.dart';
import 'routines_section.dart';
import 'web_settings_section.dart';
import 'mcp_settings.dart';
import 'model_picker.dart';
import 'settings_widgets.dart';
import 'skills_settings.dart';

/// Agent settings: providers, built-in tools, MCP servers and skills.
class AgentSettingsPage extends StatefulWidget {
  const AgentSettingsPage({super.key, required this.flute});
  final Flute flute;

  @override
  State<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends State<AgentSettingsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.flute.mcp.connectEnabled());
  }

  @override
  Widget build(BuildContext context) {
    final flute = widget.flute;
    return Scaffold(
      backgroundColor: FluteColors.bg,
      appBar: AppBar(
        backgroundColor: FluteColors.bg,
        scrolledUnderElevation: 0,
        title: const Text('Agent settings', style: TextStyle(fontWeight: FontWeight.w300)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.paddingOf(context).bottom + 24),
        children: [
          const SettingsLabel('PROVIDER'),
          _ProviderSection(flute: flute),
          const SizedBox(height: 20),
          const SettingsLabel('TOOLS'),
          _ToolsSection(flute: flute),
          const SizedBox(height: 20),
          const SettingsLabel('ROUTINES'),
          RoutinesSection(flute: flute),
          const SizedBox(height: 20),
          const SettingsLabel('VOICE'),
          VoiceSettingsSection(voice: flute.voice),
          const SizedBox(height: 20),
          const SettingsLabel('SANDBOX'),
          SandboxSettingsSection(manager: flute.sandbox),
          const SizedBox(height: 20),
          const SettingsLabel('WEB SEARCH'),
          WebSettingsSection(flute: flute),
          const SizedBox(height: 20),
          const SettingsLabel('MCP SERVERS'),
          McpServersSection(flute: flute),
          const SizedBox(height: 20),
          const SettingsLabel('SKILLS'),
          SkillsSection(flute: flute),
        ],
      ),
    );
  }
}

enum _ProfileAction { model, edit, remove }

class _ProviderSection extends StatefulWidget {
  const _ProviderSection({required this.flute});
  final Flute flute;

  @override
  State<_ProviderSection> createState() => _ProviderSectionState();
}

class _ProviderSectionState extends State<_ProviderSection> {
  String? _busy;
  String? _error;
  bool _cancelled = false;

  ProviderStore get _store => widget.flute.providers;

  /// Runs one provider action behind a progress label. A readable error stays on screen.
  /// Returns true when the action completed.
  Future<bool> _run(String label, Future<void> Function() action) async {
    _cancelled = false;
    setState(() {
      _busy = label;
      _error = null;
    });
    var ok = false;
    try {
      await action();
      ok = true;
    } catch (e) {
      if (mounted && !_cancelled) setState(() => _error = readableError(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    return ok;
  }

  Future<void> _signInChatGpt() async {
    final ok = await _run('Waiting for ChatGPT sign-in...', () async {
      final profile = await _store.signInWithChatGpt();
      await _store.setActive(profile.id);
    });
    if (ok && mounted) await showModelPicker(context, flute: widget.flute);
  }

  Future<void> _connectOpenRouter() async {
    final ok = await _run('Waiting for OpenRouter sign-in...', () async {
      final profile = await _store.signInWithOpenRouter();
      await _store.setActive(profile.id);
    });
    if (ok && mounted) await showModelPicker(context, flute: widget.flute);
  }

  void _cancelSignIn() {
    _cancelled = true;
    _store.cancelSignIn();
  }

  Future<void> _addGateway() async {
    final chooseModel = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GatewaySheet(flute: widget.flute),
    );
    if (chooseModel == true && mounted) await showModelPicker(context, flute: widget.flute);
  }

  Future<void> _choose(ProviderProfile profile) async {
    if (_store.active?.id != profile.id) {
      final ok = await _run('Switching...', () => _store.setActive(profile.id));
      if (!ok || !mounted) return;
    }
    if (mounted) await showModelPicker(context, flute: widget.flute);
  }

  Future<void> _select(ProviderProfile profile) async {
    if (_store.active?.id == profile.id) return;
    await _run('Switching...', () => _store.setActive(profile.id));
  }

  Future<void> _edit(ProviderProfile profile) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EditProviderSheet(flute: widget.flute, profile: profile),
    );
  }

  Future<void> _remove(ProviderProfile profile) async {
    final oauth = profile.auth != ProviderAuth.apiKey;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${profile.label}?'),
        content: Text(
          oauth
              ? 'Its sign-in is deleted from this phone. You can sign in again later.'
              : 'Its saved key is deleted from this phone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    await _run('Removing...', () => _store.remove(profile.id));
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final signingIn = store.signingIn;
        final locked = _busy != null || signingIn;
        final profiles = store.profiles;
        final active = store.active;
        final busy = _busy;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'No provider yet. Sign in or add a gateway to start chatting.',
                  style: TextStyle(color: FluteColors.muted, fontSize: 13),
                ),
              ),
            for (final profile in profiles)
              _ProfileRow(
                profile: profile,
                active: profile.id == active?.id,
                detail: _detailOf(profile, store.accountLabel(profile.id)),
                locked: locked,
                onSelect: () => _select(profile),
                onModel: () => _choose(profile),
                onEdit: () => _edit(profile),
                onRemove: () => _remove(profile),
              ),
            if (signingIn) _SignInBanner(onCancel: _cancelSignIn),
            if (busy != null && !signingIn) ProgressLine(busy),
            if (_error != null) ErrorLine(_error!),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: locked ? null : _signInChatGpt,
                  child: const Text('Continue with ChatGPT'),
                ),
                OutlinedButton(
                  onPressed: locked ? null : _connectOpenRouter,
                  child: const Text('Connect OpenRouter'),
                ),
                OutlinedButton(
                  onPressed: locked ? null : _addGateway,
                  child: const Text('Add OpenAI-compatible gateway'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Uses your ChatGPT plan allowance. Manage app limits in ChatGPT > Settings > Usage.',
              style: TextStyle(color: FluteColors.muted, fontSize: 12),
            ),
          ],
        );
      },
    );
  }

  static String _detailOf(ProviderProfile profile, String? account) {
    if (profile.auth == ProviderAuth.chatgptOAuth) return account ?? 'ChatGPT plan';
    return Uri.tryParse(profile.baseUrl)?.host ?? profile.baseUrl;
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.active,
    required this.detail,
    required this.locked,
    required this.onSelect,
    required this.onModel,
    required this.onEdit,
    required this.onRemove,
  });

  final ProviderProfile profile;
  final bool active;
  final String detail;
  final bool locked;
  final VoidCallback onSelect;
  final VoidCallback onModel;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: locked ? null : onSelect,
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? FluteColors.accent : FluteColors.muted,
      ),
      title: Text(profile.label),
      subtitle: Text(
        '${profile.model ?? 'No model chosen'} · $detail',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: settingsMuted,
      ),
      trailing: PopupMenuButton<_ProfileAction>(
        enabled: !locked,
        icon: const Icon(Icons.more_vert, color: FluteColors.muted),
        onSelected: (action) {
          switch (action) {
            case _ProfileAction.model:
              onModel();
              break;
            case _ProfileAction.edit:
              onEdit();
              break;
            case _ProfileAction.remove:
              onRemove();
              break;
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: _ProfileAction.model, child: Text('Choose model')),
          if (profile.auth == ProviderAuth.apiKey)
            const PopupMenuItem(value: _ProfileAction.edit, child: Text('Edit')),
          const PopupMenuItem(value: _ProfileAction.remove, child: Text('Remove')),
        ],
      ),
    );
  }
}

class _SignInBanner extends StatelessWidget {
  const _SignInBanner({required this.onCancel});
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: FluteColors.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: FluteColors.line),
      ),
      child: Row(
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Finish in your browser', style: TextStyle(fontSize: 14)),
                Text('Sign in there, then return to Flute.', style: settingsMuted),
              ],
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ),
    );
  }
}

class _GatewaySheet extends StatefulWidget {
  const _GatewaySheet({required this.flute});
  final Flute flute;

  @override
  State<_GatewaySheet> createState() => _GatewaySheetState();
}

class _GatewaySheetState extends State<_GatewaySheet> {
  final _name = TextEditingController(text: 'Gateway');
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _showKey = false;
  String? _busy;
  String? _error;
  ProviderProfile? _saved;
  int? _modelCount;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    final key = _key.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() => _error = 'Enter the base URL and the API key.');
      return;
    }
    final store = widget.flute.providers;
    setState(() {
      _busy = 'Saving...';
      _error = null;
    });
    final ProviderProfile profile;
    try {
      profile = await store.addApiKeyProfile(
        label: name.isEmpty ? 'Gateway' : name,
        baseUrl: url,
        apiKey: key,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = null;
          _error = readableError(e);
        });
      }
      return;
    }
    // The key is stored now; it must not stay on screen.
    _key.clear();
    setState(() {
      _saved = profile;
      _busy = 'Checking the gateway for models...';
    });
    try {
      await store.setActive(profile.id);
      final models = await loadModels(widget.flute, profile);
      if (mounted) setState(() => _modelCount = models.length);
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'Saved, but its models could not be listed. ${readableError(e)} '
            'Edit the provider to fix the URL or key.');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    final busy = _busy;
    final count = _modelCount;
    final working = busy != null;
    return SettingsSheet(
      title: 'Add a gateway',
      children: [
        const Text(
          'Any server that speaks the OpenAI API: a self-hosted gateway, LiteLLM, Ollama or an OpenAI key. '
          'Use https; plain http only on your own network.',
          style: settingsMuted,
        ),
        const SizedBox(height: 16),
        if (saved == null) ...[
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://gateway.example.com/v1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(
              labelText: 'API key',
              suffixIcon: IconButton(
                tooltip: _showKey ? 'Hide key' : 'Show key',
                icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
          ),
        ] else
          Text('${saved.label} saved.', style: const TextStyle(fontSize: 15)),
        const SizedBox(height: 12),
        if (busy != null) ProgressLine(busy),
        if (_error != null) ErrorLine(_error!),
        if (count != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              count == 1 ? '1 model found.' : '$count models found.',
              style: const TextStyle(color: FluteColors.accent, fontSize: 13),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (saved == null) ...[
              TextButton(
                onPressed: working ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: working ? null : _save,
                child: const Text('Save and check'),
              ),
            ] else ...[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Done'),
              ),
              if (count != null)
                FilledButton(
                  onPressed: working ? null : () => Navigator.pop(context, true),
                  child: const Text('Choose model'),
                ),
            ],
          ],
        ),
      ],
    );
  }
}

class _EditProviderSheet extends StatefulWidget {
  const _EditProviderSheet({required this.flute, required this.profile});
  final Flute flute;
  final ProviderProfile profile;

  @override
  State<_EditProviderSheet> createState() => _EditProviderSheetState();
}

class _EditProviderSheetState extends State<_EditProviderSheet> {
  late final _label = TextEditingController(text: widget.profile.label);
  late final _url = TextEditingController(text: widget.profile.baseUrl);
  final _key = TextEditingController();
  bool _showKey = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final label = _label.text.trim();
    final url = _url.text.trim();
    final key = _key.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Give the provider a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.flute.providers.updateApiKeyProfile(
        widget.profile.id,
        label: label,
        baseUrl: url,
        apiKey: key.isEmpty ? null : key,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = readableError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSheet(
      title: 'Edit provider',
      children: [
        TextField(
          controller: _label,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Base URL'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          obscureText: !_showKey,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(
            labelText: 'New API key',
            hintText: 'Leave blank to keep the saved key',
            suffixIcon: IconButton(
              tooltip: _showKey ? 'Hide key' : 'Show key',
              icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_busy) const ProgressLine('Saving...'),
        if (_error != null) ErrorLine(_error!),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Group {
  const _Group(this.key, this.title, this.detail);
  final String key;
  final String title;
  final String detail;
}

const _groups = [
  _Group('calendar', 'Calendar', 'Read and add events on this phone.'),
  _Group('contacts', 'Contacts', 'Look up and edit people on this phone.'),
  _Group('notes', 'Notes', 'Notes kept inside Flute.'),
];

class _ToolsSection extends StatefulWidget {
  const _ToolsSection({required this.flute});
  final Flute flute;

  @override
  State<_ToolsSection> createState() => _ToolsSectionState();
}

class _ToolsSectionState extends State<_ToolsSection> {
  Map<String, bool> _on = const {};
  Map<String, bool> _granted = const {};
  String? _busyKey;
  String? _error;

  BuiltinTools get _tools => widget.flute.builtins;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final on = {for (final g in _groups) g.key: _tools.isEnabled(g.key)};
    final granted = <String, bool>{};
    for (final g in _groups) {
      granted[g.key] = await _tools.hasPermission(g.key);
    }
    if (!mounted) return;
    setState(() {
      _on = on;
      _granted = granted;
    });
  }

  Future<void> _toggle(_Group group, bool want) async {
    setState(() {
      _busyKey = group.key;
      _error = null;
    });
    try {
      if (want) {
        var granted = await _tools.hasPermission(group.key);
        if (!granted) granted = await _tools.requestPermission(group.key);
        if (!granted) {
          if (mounted) {
            setState(() => _error =
                '${group.title} access was denied. Turn it on in Settings > Apps > Flute > Permissions.');
          }
          return;
        }
      }
      await _tools.setEnabled(group.key, want);
    } catch (e) {
      if (mounted) setState(() => _error = readableError(e));
    } finally {
      if (mounted) setState(() => _busyKey = null);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final busyKey = _busyKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in _groups)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(g.title),
            subtitle: Text(
              _on[g.key] == true && _granted[g.key] == false
                  ? '${g.detail} Permission is off.'
                  : g.detail,
              style: settingsMuted,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busyKey == g.key)
                  const Padding(
                    padding: EdgeInsets.only(right: 10),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Switch(
                  value: _on[g.key] ?? false,
                  onChanged: busyKey != null ? null : (v) => _toggle(g, v),
                ),
              ],
            ),
          ),
        if (_error != null) ErrorLine(_error!),
        const Text(
          'Changes to your calendar and contacts always ask you first.',
          style: settingsMuted,
        ),
      ],
    );
  }
}
