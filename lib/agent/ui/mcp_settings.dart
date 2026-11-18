import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../mcp/mcp_manager.dart';
import '../mcp/mcp_oauth.dart';
import '../tools/agent_tool.dart';
import 'settings_widgets.dart';

const _authLabels = {
  McpAuthKind.none: 'None',
  McpAuthKind.bearer: 'Bearer token',
  McpAuthKind.basic: 'Username and API token',
  McpAuthKind.header: 'Custom header',
  McpAuthKind.oauth: 'Browser sign-in',
};

Color _statusColor(McpStatus status) => switch (status) {
      McpStatus.connected => FluteColors.accent,
      McpStatus.connecting => FluteColors.warn,
      McpStatus.failed => settingsAlert,
      McpStatus.disconnected => FluteColors.muted,
      McpStatus.needsSignIn => FluteColors.warn,
    };

String _toolCount(int n) => n == 1 ? '1 tool' : '$n tools';

String _statusText(McpManager mcp, McpServerConfig server) {
  if (!server.enabled) return 'Off';
  return switch (mcp.statusOf(server.id)) {
    McpStatus.connected => _toolCount(mcp.toolsOf(server.id).length),
    McpStatus.connecting => 'Connecting...',
    McpStatus.failed => mcp.errorOf(server.id) ?? 'Could not connect.',
    McpStatus.disconnected => 'Not connected',
    McpStatus.needsSignIn => mcp.errorOf(server.id) ?? 'Sign in to use this server.',
  };
}

McpServerConfig? _findServer(McpManager mcp, String id) {
  for (final s in mcp.servers) {
    if (s.id == id) return s;
  }
  return null;
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// The MCP block of Agent settings: every server with its status, enable switch and detail page.
class McpServersSection extends StatefulWidget {
  const McpServersSection({super.key, required this.flute});
  final Flute flute;

  @override
  State<McpServersSection> createState() => _McpServersSectionState();
}

class _McpServersSectionState extends State<McpServersSection> {
  final Set<String> _toggling = {};
  String? _error;

  McpManager get _mcp => widget.flute.mcp;

  Future<void> _setEnabled(McpServerConfig server, bool on) async {
    setState(() {
      _toggling.add(server.id);
      _error = null;
    });
    try {
      await _mcp.setEnabled(server.id, on);
    } catch (e) {
      if (mounted) setState(() => _error = readableError(e));
    } finally {
      if (mounted) setState(() => _toggling.remove(server.id));
    }
  }

  Future<void> _addServer() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => McpAddPage(flute: widget.flute)),
    );
  }

  void _open(McpServerConfig server) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => McpServerPage(flute: widget.flute, serverId: server.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _mcp,
      builder: (context, _) {
        final servers = _mcp.servers;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (servers.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'No servers yet. Add GitHub, Jira or your own MCP server to give the agent more tools.',
                  style: settingsMuted,
                ),
              ),
            for (final server in servers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _Dot(_statusColor(_mcp.statusOf(server.id))),
                title: Text(server.name),
                subtitle: Text(
                  _statusText(_mcp, server),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _mcp.statusOf(server.id) == McpStatus.failed ? settingsAlert : FluteColors.muted,
                    fontSize: 12,
                  ),
                ),
                trailing: _toggling.contains(server.id)
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Switch(
                        value: server.enabled,
                        onChanged: (v) => _setEnabled(server, v),
                      ),
                onTap: () => _open(server),
              ),
            if (_error != null) ErrorLine(_error!),
            TextButton(
              style: TextButton.styleFrom(alignment: Alignment.centerLeft, padding: EdgeInsets.zero),
              onPressed: _addServer,
              child: const Text('Add server'),
            ),
          ],
        );
      },
    );
  }
}

/// One server: status, reconnect, enable, edit, remove, and a switch per tool.
class McpServerPage extends StatefulWidget {
  const McpServerPage({super.key, required this.flute, required this.serverId});
  final Flute flute;
  final String serverId;

  @override
  State<McpServerPage> createState() => _McpServerPageState();
}

class _McpServerPageState extends State<McpServerPage> {
  bool _working = false;
  String? _error;

  McpManager get _mcp => widget.flute.mcp;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = readableError(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _delete(McpServerConfig server) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${server.name}?'),
        content: const Text('Its token is deleted from this phone and the agent loses its tools.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    await _run(() => _mcp.remove(server.id));
    if (mounted && _mcp.servers.every((s) => s.id != server.id)) Navigator.of(context).pop();
  }

  Future<void> _edit(McpServerConfig server) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EditServerSheet(flute: widget.flute, server: server),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _mcp,
      builder: (context, _) {
        final server = _findServer(_mcp, widget.serverId);
        return Scaffold(
          backgroundColor: FluteColors.bg,
          appBar: AppBar(
            backgroundColor: FluteColors.bg,
            scrolledUnderElevation: 0,
            title: Text(server?.name ?? 'Server', style: const TextStyle(fontWeight: FontWeight.w300)),
            actions: server == null
                ? null
                : [
                    IconButton(
                      tooltip: 'Edit',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: _working ? null : () => _edit(server),
                    ),
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _working ? null : () => _delete(server),
                    ),
                  ],
          ),
          body: server == null
              ? const Center(
                  child: Text('This server was removed.', style: TextStyle(color: FluteColors.muted)),
                )
              : _details(server),
        );
      },
    );
  }

  List<Widget> _signInActions(McpServerConfig server, McpStatus status, bool connecting) {
    if (_mcp.isSigningIn(server.id)) {
      return [
        const Text('Waiting for the browser. Finish signing in there, then come back.', style: settingsMuted),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => _mcp.cancelSignIn(server.id),
          child: const Text('Cancel sign-in'),
        ),
        const SizedBox(height: 12),
      ];
    }
    final signedIn = status == McpStatus.connected || status == McpStatus.failed;
    return [
      Row(
        children: [
          FilledButton(
            onPressed: connecting || !server.enabled ? null : () => _run(() => _mcp.signIn(server.id)),
            child: Text(signedIn ? 'Sign in again' : 'Sign in with browser'),
          ),
          if (signedIn) ...[
            const SizedBox(width: 12),
            TextButton(
              onPressed: connecting ? null : () => _run(() => _mcp.signOut(server.id)),
              child: const Text('Sign out'),
            ),
          ],
        ],
      ),
      const SizedBox(height: 12),
    ];
  }

  Widget _details(McpServerConfig server) {
    final status = _mcp.statusOf(server.id);
    final tools = _mcp.toolsOf(server.id);
    final connecting = _working || status == McpStatus.connecting;
    final error = _error ?? (status == McpStatus.failed ? _mcp.errorOf(server.id) : null);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      children: [
        Text(server.url, style: settingsMuted),
        const SizedBox(height: 16),
        Row(
          children: [
            _Dot(_statusColor(status)),
            const SizedBox(width: 8),
            Expanded(child: Text(_statusText(_mcp, server), style: const TextStyle(fontSize: 15))),
          ],
        ),
        const SizedBox(height: 12),
        if (error != null) ErrorLine(error),
        if (server.auth == McpAuthKind.oauth) ..._signInActions(server, status, connecting),
        if (server.auth != McpAuthKind.oauth || status != McpStatus.needsSignIn)
          Row(
            children: [
              OutlinedButton(
                onPressed: connecting || !server.enabled ? null : () => _run(() => _mcp.connect(server.id)),
                child: Text(status == McpStatus.connected ? 'Reconnect' : 'Connect'),
              ),
              if (connecting) ...[
                const SizedBox(width: 12),
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ],
          ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use this server'),
          subtitle: const Text(
            'Turning it off disconnects it and removes its tools from the agent.',
            style: settingsMuted,
          ),
          value: server.enabled,
          onChanged: connecting ? null : (v) => _run(() => _mcp.setEnabled(server.id, v)),
        ),
        const SizedBox(height: 16),
        const SettingsLabel('TOOLS'),
        if (tools.isEmpty)
          Text(
            status == McpStatus.connected ? 'This server has no tools.' : 'Connect to see its tools.',
            style: settingsMuted,
          ),
        for (final tool in tools)
          if (tool is McpAgentTool)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tool.rawName),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tool.description, style: settingsMuted, maxLines: 3, overflow: TextOverflow.ellipsis),
                  if (tool.risk == ToolRisk.write)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: SettingsTag('needs confirmation'),
                    ),
                ],
              ),
              value: !_mcp.isToolDisabled(server.id, tool.rawName),
              onChanged: connecting
                  ? null
                  : (on) => _run(() => _mcp.setToolDisabled(server.id, tool.rawName, !on)),
            ),
      ],
    );
  }
}

/// Lists the presets and a custom server.
class McpAddPage extends StatelessWidget {
  const McpAddPage({super.key, required this.flute});
  final Flute flute;

  Future<void> _open(BuildContext context, McpPreset? preset) async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => _McpServerForm(flute: flute, preset: preset)),
    );
    if (added == true && context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FluteColors.bg,
      appBar: AppBar(
        backgroundColor: FluteColors.bg,
        scrolledUnderElevation: 0,
        title: const Text('Add server', style: TextStyle(fontWeight: FontWeight.w300)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
        children: [
          const SettingsLabel('PRESETS'),
          for (final preset in McpPresets.all)
            SettingsCard(
              onTap: () => _open(context, preset),
              child: Row(
                children: [
                  const Icon(Icons.extension_outlined, color: FluteColors.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(preset.title, style: const TextStyle(fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(preset.description, style: settingsMuted),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          const SettingsLabel('CUSTOM'),
          SettingsCard(
            onTap: () => _open(context, null),
            child: const Row(
              children: [
                Icon(Icons.dns_outlined, color: FluteColors.accent),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Custom server', style: TextStyle(fontSize: 15)),
                      SizedBox(height: 2),
                      Text('Any remote MCP server that speaks Streamable HTTP.', style: settingsMuted),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Token inputs shared by the add and edit forms. Secrets are only read here, never shown back.
class _SecretFields {
  final token = TextEditingController();
  final user = TextEditingController();
  final header = TextEditingController();

  void dispose() {
    token.dispose();
    user.dispose();
    header.dispose();
  }

  /// The value stored as the server's secret. Null when nothing was typed and [required] is false
  /// (edit keeps the saved secret). [preset] builds Jira-style basic auth through [McpPresets.jiraBasic].
  String? build(McpAuthKind auth, {required bool required, bool preset = false}) {
    if (auth == McpAuthKind.none || auth == McpAuthKind.oauth) return null;
    if (auth == McpAuthKind.basic) {
      final u = user.text.trim();
      final p = token.text.trim();
      if (u.isEmpty && p.isEmpty) {
        if (required) throw const FormatException('Enter the username and the API token.');
        return null;
      }
      if (u.isEmpty || p.isEmpty) throw const FormatException('Enter both the username and the API token.');
      return preset ? McpPresets.jiraBasic(u, p) : base64Encode(utf8.encode('$u:$p'));
    }
    final value = token.text.trim();
    if (value.isEmpty) {
      if (required) {
        throw FormatException(auth == McpAuthKind.header ? 'Paste the header value.' : 'Paste the token.');
      }
      return null;
    }
    return value;
  }

  List<Widget> fields(
    McpAuthKind auth, {
    required String tokenLabel,
    required String userLabel,
    required bool keepSavedHint,
  }) {
    final hint = keepSavedHint ? 'Leave blank to keep the saved one' : null;
    if (auth == McpAuthKind.none || auth == McpAuthKind.oauth) return const [];
    final secret = TextField(
      controller: token,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: tokenLabel, hintText: hint),
    );
    if (auth == McpAuthKind.basic) {
      return [
        TextField(
          controller: user,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: userLabel, hintText: hint),
        ),
        const SizedBox(height: 12),
        secret,
      ];
    }
    return [secret];
  }
}

String _tokenLabel(McpAuthKind auth) => switch (auth) {
      McpAuthKind.none => '',
      McpAuthKind.bearer => 'Token',
      McpAuthKind.basic => 'API token',
      McpAuthKind.header => 'Header value',
      McpAuthKind.oauth => '',
    };

/// The form for a preset (name and URL fixed) or a custom server.
class _McpServerForm extends StatefulWidget {
  const _McpServerForm({required this.flute, required this.preset});
  final Flute flute;
  final McpPreset? preset;

  @override
  State<_McpServerForm> createState() => _McpServerFormState();
}

class _McpServerFormState extends State<_McpServerForm> {
  static const _manualAuths = [McpAuthKind.bearer, McpAuthKind.basic, McpAuthKind.header];

  final _name = TextEditingController();
  final _url = TextEditingController();
  final _secret = _SecretFields();
  // Token auth: chosen by hand for a custom server, or the token fallback for a preset.
  late McpAuthKind _auth = widget.preset?.tokenAuth ?? McpAuthKind.bearer;
  // Custom server: the probe found a browser sign-in.
  bool _oauth = false;
  // Custom server: the probe could not tell how to sign in, or the user chose a token.
  bool _manual = false;
  // The server created for a sign-in. Kept so a retry reuses it.
  McpServerConfig? _saved;
  bool _busy = false;
  String? _error;

  bool get _decided => _oauth || _manual;

  bool get _signInFirst {
    if (_manual) return false;
    final preset = widget.preset;
    return preset != null ? preset.auth == McpAuthKind.oauth : _oauth;
  }

  bool get _showSecrets => widget.preset != null ? !_signInFirst : _manual;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _openLink(String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the link.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the link.')));
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = readableError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish(String id) async {
    final mcp = widget.flute.mcp;
    if (mcp.statusOf(id) != McpStatus.connected) await mcp.connect(id);
    if (mounted) Navigator.of(context).pop(true);
  }

  // Custom servers: the probe decides whether to save with no auth, offer browser sign-in, or ask for a token.
  Future<void> _connect() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = 'Enter a name and the server URL.');
      return;
    }
    await _run(() async {
      final mcp = widget.flute.mcp;
      final probe = await mcp.probe(url);
      switch (probe.outcome) {
        case McpProbeOutcome.noAuth:
          final server = await mcp.add(name: name, url: url);
          await _finish(server.id);
        case McpProbeOutcome.oauth:
          setState(() => _oauth = true);
        case McpProbeOutcome.askUser:
          setState(() {
            _manual = true;
            _error = probe.message;
          });
      }
    });
  }

  Future<McpServerConfig> _createForSignIn() {
    final preset = widget.preset;
    final mcp = widget.flute.mcp;
    if (preset != null) return mcp.addPreset(preset);
    return mcp.add(name: _name.text.trim(), url: _url.text.trim(), auth: McpAuthKind.oauth);
  }

  Future<void> _signIn() => _run(() async {
        final mcp = widget.flute.mcp;
        final server = _saved ?? await _createForSignIn();
        setState(() => _saved = server);
        await mcp.signIn(server.id);
        if (mounted) Navigator.of(context).pop(true);
      });

  void _cancelSignIn() {
    final id = _saved?.id;
    if (id != null) widget.flute.mcp.cancelSignIn(id);
  }

  Future<void> _save() async {
    final preset = widget.preset;
    final name = preset?.title ?? _name.text.trim();
    final url = preset?.url ?? _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = 'Enter a name and the server URL.');
      return;
    }
    final headerName = _secret.header.text.trim();
    if (preset == null && _auth == McpAuthKind.header && headerName.isEmpty) {
      setState(() => _error = 'Enter the header name, for example X-API-Key.');
      return;
    }
    await _run(() async {
      final mcp = widget.flute.mcp;
      final secret = _secret.build(_auth, required: true, preset: preset != null);
      final McpServerConfig server;
      if (preset != null) {
        server = await mcp.addPreset(preset, secret: secret ?? '');
      } else {
        server = await mcp.add(
          name: name,
          url: url,
          auth: _auth,
          headerName: _auth == McpAuthKind.header ? headerName : null,
          secret: secret,
        );
      }
      await _finish(server.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    return Scaffold(
      backgroundColor: FluteColors.bg,
      appBar: AppBar(
        backgroundColor: FluteColors.bg,
        scrolledUnderElevation: 0,
        title: Text(preset?.title ?? 'Custom server', style: const TextStyle(fontWeight: FontWeight.w300)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
        children: [
          if (preset != null) ...[
            Text(preset.description, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Text(preset.url, style: settingsMuted),
            if (preset.helpUrl.isNotEmpty)
              TextButton.icon(
                style: TextButton.styleFrom(alignment: Alignment.centerLeft, padding: EdgeInsets.zero),
                onPressed: () => _openLink(preset.helpUrl),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Get a token'),
              ),
          ] else ...[
            const Text(
              'Remote servers only, over https (plain http only on your own network). '
              'Servers that run on your computer cannot run on Android.',
              style: settingsMuted,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              enabled: !_decided,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Notion'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              enabled: !_decided,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Server URL', hintText: 'https://mcp.example.com/mcp'),
            ),
          ],
          const SizedBox(height: 16),
          if (preset == null && !_decided)
            FilledButton(
              onPressed: _busy ? null : _connect,
              child: const Text('Connect'),
            ),
          if (_signInFirst) ...[
            const Text(
              'Flute opens your browser so you can sign in. The access stays in this phone\'s secure storage.',
              style: settingsMuted,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _signIn,
              icon: const Icon(Icons.login),
              label: const Text('Sign in with browser'),
            ),
            if (_busy && _saved != null)
              TextButton(onPressed: _cancelSignIn, child: const Text('Cancel sign-in')),
            if (_saved == null)
              TextButton(
                onPressed: _busy ? null : () => setState(() => _manual = true),
                child: const Text('Use a token instead'),
              ),
          ],
          if (_showSecrets) ...[
            if (preset == null) ...[
              const SettingsLabel('AUTHENTICATION'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final auth in _manualAuths)
                    ChoiceChip(
                      label: Text(_authLabels[auth] ?? auth.name),
                      selected: _auth == auth,
                      onSelected: _busy ? null : (_) => setState(() => _auth = auth),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (_auth == McpAuthKind.header)
                TextField(
                  controller: _secret.header,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Header name', hintText: 'X-API-Key'),
                ),
            ],
            const SizedBox(height: 12),
            ..._secret.fields(
              _auth,
              tokenLabel: preset?.secretLabel ?? _tokenLabel(_auth),
              userLabel: preset != null ? 'Email' : 'Username',
              keepSavedHint: false,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Add server'),
            ),
          ],
          const SizedBox(height: 16),
          if (_busy) ProgressLine(_saved != null ? 'Waiting for the browser...' : 'Working...'),
          if (_error != null) ErrorLine(_error!),
        ],
      ),
    );
  }
}

class _EditServerSheet extends StatefulWidget {
  const _EditServerSheet({required this.flute, required this.server});
  final Flute flute;
  final McpServerConfig server;

  @override
  State<_EditServerSheet> createState() => _EditServerSheetState();
}

class _EditServerSheetState extends State<_EditServerSheet> {
  late final _name = TextEditingController(text: widget.server.name);
  late final _url = TextEditingController(text: widget.server.url);
  final _secret = _SecretFields();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = 'Enter a name and the server URL.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final secret = _secret.build(widget.server.auth, required: false);
      await widget.flute.mcp.update(widget.server.id, name: name, url: url, secret: secret);
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
    final auth = widget.server.auth;
    return SettingsSheet(
      title: 'Edit server',
      children: [
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
          decoration: const InputDecoration(labelText: 'Server URL'),
        ),
        if (auth != McpAuthKind.none && auth != McpAuthKind.oauth) ...[
          const SizedBox(height: 12),
          ..._secret.fields(
            auth,
            tokenLabel: _tokenLabel(auth),
            userLabel: 'Username or email',
            keepSavedHint: true,
          ),
        ],
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
