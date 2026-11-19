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
      McpStatus.failed => FluteColors.danger,
      McpStatus.disconnected => FluteColors.faint,
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

/// The MCP block of Agent settings: every server with its status, tool count, enable switch and
/// detail page.
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
      settingsRoute<void>(context, (_) => McpAddPage(flute: widget.flute)),
    );
  }

  void _open(McpServerConfig server) {
    Navigator.of(context).push<void>(
      settingsRoute<void>(context, (_) => McpServerPage(flute: widget.flute, serverId: server.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _mcp,
      builder: (context, _) {
        final servers = _mcp.servers;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: settingsSpaced([
            if (servers.isEmpty)
              Text(
                'No servers yet. Add GitHub, Jira or your own MCP server to give the agent more tools.',
                style: FluteText.caption,
              ),
            if (servers.isNotEmpty)
              SettingsSection(
                title: 'Servers',
                children: [
                  SettingsGroup(
                    children: [
                      for (final server in servers)
                        SettingsRow(
                          leading: SizedBox(
                            width: 20,
                            child: Center(child: StatusDot(_statusColor(_mcp.statusOf(server.id)))),
                          ),
                          title: server.name,
                          subtitle: Text(
                            _statusText(_mcp, server),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _mcp.statusOf(server.id) == McpStatus.failed
                                ? FluteText.caption.copyWith(color: FluteColors.danger)
                                : FluteText.caption,
                          ),
                          trailing: _toggling.contains(server.id)
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Switch(
                                  value: server.enabled,
                                  onChanged: (v) => _setEnabled(server, v),
                                ),
                          chevron: true,
                          onTap: () => _open(server),
                        ),
                    ],
                  ),
                ],
              ),
            if (_error != null) ErrorLine(_error!),
            FilledButton(onPressed: _addServer, child: const Text('Add server')),
          ]),
        );
      },
    );
  }
}

/// One server: status, connect or sign in, enable, edit, remove, and a switch per tool.
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
    final sure = await confirmRemove(
      context,
      title: 'Remove ${server.name}?',
      message: 'Its token is deleted from this phone and the agent loses its tools.',
    );
    if (!sure) return;
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
            title: Text(server?.name ?? 'Server'),
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
                  child: Text('This server was removed.', style: FluteText.caption),
                )
              : _details(context, server),
        );
      },
    );
  }

  /// The sign-in and connect actions for a server, in the order the user needs them.
  List<Widget> _actions(McpServerConfig server, McpStatus status, bool connecting) {
    final signedIn = status == McpStatus.connected || status == McpStatus.failed;
    final spinner = connecting
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : null;
    if (server.auth == McpAuthKind.oauth && _mcp.isSigningIn(server.id)) {
      return [
        Text(
          'Waiting for the browser. Finish signing in there, then come back.',
          style: FluteText.caption,
        ),
        Wrap(
          spacing: FluteSpace.sm,
          runSpacing: FluteSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: () => _mcp.cancelSignIn(server.id),
              child: const Text('Cancel sign-in'),
            ),
          ],
        ),
      ];
    }
    final canConnect = server.auth != McpAuthKind.oauth || status != McpStatus.needsSignIn;
    return [
      Wrap(
        spacing: FluteSpace.sm,
        runSpacing: FluteSpace.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (server.auth == McpAuthKind.oauth)
            FilledButton(
              onPressed: connecting || !server.enabled ? null : () => _run(() => _mcp.signIn(server.id)),
              child: Text(signedIn ? 'Sign in again' : 'Sign in with browser'),
            ),
          if (server.auth == McpAuthKind.oauth && signedIn)
            TextButton(
              onPressed: connecting ? null : () => _run(() => _mcp.signOut(server.id)),
              child: const Text('Sign out'),
            ),
          if (canConnect)
            OutlinedButton(
              onPressed: connecting || !server.enabled ? null : () => _run(() => _mcp.connect(server.id)),
              child: Text(status == McpStatus.connected ? 'Reconnect' : 'Connect'),
            ),
          ?spinner,
        ],
      ),
    ];
  }

  Widget _details(BuildContext context, McpServerConfig server) {
    final status = _mcp.statusOf(server.id);
    final tools = _mcp.toolsOf(server.id);
    final connecting = _working || status == McpStatus.connecting;
    final error = _error ?? (status == McpStatus.failed ? _mcp.errorOf(server.id) : null);
    return ListView(
      padding: settingsPagePadding(context),
      children: settingsSpaced([
        Text(server.url, style: FluteText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        SettingsSection(
          title: 'Status',
          children: [
            SettingsGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.all(FluteSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          StatusDot(_statusColor(status)),
                          const SizedBox(width: FluteSpace.sm),
                          Expanded(
                            child: Text(
                              _statusText(_mcp, server),
                              style: FluteText.label.copyWith(color: FluteColors.text),
                            ),
                          ),
                        ],
                      ),
                      if (error != null) ...[
                        const SizedBox(height: FluteSpace.md),
                        ErrorLine(error),
                      ],
                      const SizedBox(height: FluteSpace.md),
                      ...settingsSpaced(_actions(server, status, connecting), gap: FluteSpace.sm),
                    ],
                  ),
                ),
                SettingsSwitchRow(
                  title: 'Use this server',
                  subtitle: Text('Off disconnects it and removes its tools.', style: FluteText.caption),
                  value: server.enabled,
                  onChanged: connecting ? null : (v) => _run(() => _mcp.setEnabled(server.id, v)),
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: 'Tools',
          children: [
            if (tools.isEmpty)
              Text(
                status == McpStatus.connected ? 'This server has no tools.' : 'Connect to see its tools.',
                style: FluteText.caption,
              )
            else
              SettingsGroup(
                children: [
                  for (final tool in tools)
                    if (tool is McpAgentTool)
                      SettingsSwitchRow(
                        title: tool.rawName,
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tool.description,
                              style: FluteText.caption,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (tool.risk == ToolRisk.write)
                              const Padding(
                                padding: EdgeInsets.only(top: FluteSpace.xs),
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
              ),
          ],
        ),
      ]),
    );
  }
}

/// Lists the presets and a custom server.
class McpAddPage extends StatelessWidget {
  const McpAddPage({super.key, required this.flute});
  final Flute flute;

  Future<void> _open(BuildContext context, McpPreset? preset) async {
    final added = await Navigator.of(context).push<bool>(
      settingsRoute<bool>(context, (_) => _McpServerForm(flute: flute, preset: preset)),
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
        title: const Text('Add server'),
      ),
      body: ListView(
        padding: settingsPagePadding(context),
        children: settingsSpaced([
          SettingsSection(
            title: 'Presets',
            children: [
              SettingsGroup(
                children: [
                  for (final preset in McpPresets.all)
                    SettingsRow(
                      leading: const SettingsIconTile(icon: Icons.extension_outlined),
                      title: preset.title,
                      subtitle: Text(
                        preset.description,
                        style: FluteText.caption,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      chevron: true,
                      onTap: () => _open(context, preset),
                    ),
                ],
              ),
            ],
          ),
          SettingsSection(
            title: 'Custom',
            children: [
              SettingsGroup(
                children: [
                  SettingsRow(
                    leading: const SettingsIconTile(icon: Icons.dns_outlined),
                    title: 'Custom server',
                    subtitle: Text('Any remote MCP server that speaks Streamable HTTP.', style: FluteText.caption),
                    chevron: true,
                    onTap: () => _open(context, null),
                  ),
                ],
              ),
            ],
          ),
        ]),
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
        const SizedBox(height: FluteSpace.md),
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
        title: Text(preset?.title ?? 'Custom server'),
      ),
      body: ListView(
        padding: settingsPagePadding(context),
        children: [
          if (preset != null) ...[
            Text(preset.description, style: FluteText.body.copyWith(color: FluteColors.text)),
            const SizedBox(height: FluteSpace.xs),
            Text(preset.url, style: FluteText.caption),
            if (preset.helpUrl.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _openLink(preset.helpUrl),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Get a token'),
                ),
              ),
          ] else ...[
            Text(
              'Remote servers over https only. Servers that run on your computer cannot run on Android.',
              style: FluteText.caption,
            ),
            const SizedBox(height: FluteSpace.lg),
            TextField(
              controller: _name,
              enabled: !_decided,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Notion'),
            ),
            const SizedBox(height: FluteSpace.md),
            TextField(
              controller: _url,
              enabled: !_decided,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Server URL', hintText: 'https://mcp.example.com/mcp'),
            ),
            if (!_decided) ...[
              const SizedBox(height: FluteSpace.lg),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: const Text('Connect'),
              ),
            ],
          ],
          if (_signInFirst) ...[
            const SizedBox(height: FluteSpace.lg),
            Text(
              "Flute opens your browser so you can sign in. The access stays in this phone's secure storage.",
              style: FluteText.caption,
            ),
            const SizedBox(height: FluteSpace.md),
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
            const SizedBox(height: FluteSpace.lg),
            if (preset == null) ...[
              const SettingsLabel('Authentication'),
              Wrap(
                spacing: FluteSpace.sm,
                runSpacing: FluteSpace.sm,
                children: [
                  for (final auth in _manualAuths)
                    ChoiceChip(
                      label: Text(_authLabels[auth] ?? auth.name),
                      selected: _auth == auth,
                      onSelected: _busy ? null : (_) => setState(() => _auth = auth),
                    ),
                ],
              ),
              const SizedBox(height: FluteSpace.md),
              if (_auth == McpAuthKind.header) ...[
                TextField(
                  controller: _secret.header,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Header name', hintText: 'X-API-Key'),
                ),
                const SizedBox(height: FluteSpace.md),
              ],
            ],
            ..._secret.fields(
              _auth,
              tokenLabel: preset?.secretLabel ?? _tokenLabel(_auth),
              userLabel: preset != null ? 'Email' : 'Username',
              keepSavedHint: false,
            ),
            const SizedBox(height: FluteSpace.lg),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Add server'),
            ),
          ],
          const SizedBox(height: FluteSpace.lg),
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
        const SizedBox(height: FluteSpace.md),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Server URL'),
        ),
        if (auth != McpAuthKind.none && auth != McpAuthKind.oauth) ...[
          const SizedBox(height: FluteSpace.md),
          ..._secret.fields(
            auth,
            tokenLabel: _tokenLabel(auth),
            userLabel: 'Username or email',
            keepSavedHint: true,
          ),
        ],
        const SizedBox(height: FluteSpace.md),
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
