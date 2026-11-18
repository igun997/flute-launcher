import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart'
    show
        AudioContent,
        CallToolRequest,
        CallToolResult,
        Content,
        EmbeddedResource,
        Implementation,
        ImageContent,
        ListToolsRequest,
        McpClient,
        McpError,
        ResourceLink,
        StreamableHttpClientTransport,
        StreamableHttpClientTransportOptions,
        StreamableHttpError,
        TextContent,
        TextResourceContents,
        Tool,
        Transport,
        UnauthorizedError;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../auth/loopback_server.dart';
import '../auth/secret_store.dart';
import '../tools/agent_tool.dart';
import 'mcp_oauth.dart';
import 'mcp_presets.dart';
import 'mcp_server_config.dart';

export 'mcp_presets.dart';
export 'mcp_server_config.dart';

/// Builds the transport for a server. Tests inject fakes; the app uses Streamable HTTP.
typedef McpTransportFactory = Transport Function(Uri url, Map<String, String> headers);

enum McpStatus { disconnected, connecting, connected, needsSignIn, failed }

/// A failure the person should read, such as a missing token or a refused address.
class McpException implements Exception {
  const McpException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One tool of a remote MCP server, exposed to the agent under a sanitised, unique name.
class McpAgentTool extends AgentTool {
  McpAgentTool._({
    required McpManager manager,
    required this.serverId,
    required this.serverName,
    required this.rawName,
    required this.name,
    required this.description,
    required this.parameters,
    required this.readOnly,
  }) : _manager = manager;

  final McpManager _manager;
  final String serverId;
  final String serverName;

  /// The name the server reports, e.g. `search_issues`. Settings use this for switches.
  final String rawName;

  @override
  final String name;

  @override
  final String description;

  @override
  final Map<String, dynamic> parameters;

  final bool readOnly;

  bool get disabled => _manager.isToolDisabled(serverId, rawName);

  @override
  ToolRisk get risk => readOnly ? ToolRisk.read : ToolRisk.write;

  @override
  String get source => 'mcp:$serverName';

  @override
  String describeCall(Map<String, dynamic> args) => _manager._describe(this, args);

  @override
  Future<ToolResult> run(Map<String, dynamic> args) => _manager._run(this, args);
}

class McpManager extends ChangeNotifier implements ToolSource {
  McpManager({
    required SharedPreferences prefs,
    required SecretStore secrets,
    McpTransportFactory? transportFactory,
    http.Client? httpClient,
    Future<bool> Function(Uri url)? openBrowser,
  })  : _prefs = prefs,
        _secrets = secrets,
        _transportFactory = transportFactory,
        _oauth = McpOAuth(
          httpClient: httpClient ?? http.Client(),
          openBrowser: openBrowser ?? _launchInBrowser,
        );

  static const _serversKey = 'agent.mcp.servers';
  static const connectTimeout = Duration(seconds: 15);
  static const _maxResultChars = 12000;
  static const _maxToolPages = 20;
  static const _maxNameChars = 64;
  static const _maxServerSlugChars = 24;
  static const _oauthSecretPrefix = 'agent.mcp.oauth.';

  static Future<bool> _launchInBrowser(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// The raw tool name behind a tool from this manager, or null for other tools.
  static String? rawToolNameOf(AgentTool tool) => tool is McpAgentTool ? tool.rawName : null;

  final SharedPreferences _prefs;
  final SecretStore _secrets;
  final McpTransportFactory? _transportFactory;

  final List<McpServerConfig> _servers = [];
  final Map<String, McpStatus> _status = {};
  final Map<String, String?> _errors = {};
  final Map<String, McpClient> _clients = {};
  final Map<String, List<McpAgentTool>> _tools = {};
  final Map<String, Future<void>> _connecting = {};
  final McpOAuth _oauth;
  final Map<String, Future<McpOAuthRecord>> _refreshes = {};
  final Map<String, LoopbackServer> _pendingSignIns = {};

  /// Bumped by every disconnect, so a connect that finishes late cannot resurrect a server.
  final Map<String, int> _generation = {};
  final Set<String> _takenNames = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _disposed = false;

  /// Reads the saved server list. Does not connect.
  Future<void> load() async {
    final raw = _prefs.getString(_serversKey);
    _servers
      ..clear()
      ..addAll(raw == null
          ? const <McpServerConfig>[]
          : (jsonDecode(raw) as List).map((e) => McpServerConfig.fromJson(e as Map<String, dynamic>)));
    _changed();
  }

  List<McpServerConfig> get servers => List.unmodifiable(_servers);

  McpStatus statusOf(String id) => _status[id] ?? McpStatus.disconnected;

  String? errorOf(String id) => _errors[id];

  /// Every tool the server reported, disabled ones included, so settings can list them.
  /// Empty until the server has connected.
  List<AgentTool> toolsOf(String id) => List.unmodifiable(_tools[id] ?? const <McpAgentTool>[]);

  Future<McpServerConfig> add({
    required String name,
    required String url,
    McpAuthKind auth = McpAuthKind.none,
    String? headerName,
    String? secret,
  }) async {
    final config = await _create(
      name: name,
      url: url,
      auth: auth,
      headerName: headerName,
      secret: secret,
    );
    unawaited(connect(config.id));
    return config;
  }

  /// Adds a preset. Without a token the person signs in with the browser (`preset.auth`);
  /// with one, the token is sent the way `preset.tokenAuth` says.
  Future<McpServerConfig> addPreset(McpPreset preset, {String? secret}) async {
    final config = await _create(
      name: preset.title,
      url: preset.url,
      auth: secret == null ? preset.auth : preset.tokenAuth,
      secret: secret,
      extraHeaders: preset.headers,
    );
    unawaited(connect(config.id));
    return config;
  }

  Future<void> update(String id, {String? name, String? url, String? secret}) async {
    final index = _indexOf(id);
    final old = _servers[index];
    final trimmedName = name?.trim();
    if (trimmedName != null && trimmedName.isEmpty) {
      throw const McpException('Give the server a name.');
    }
    final newUrl = url == null ? old.url : _validUrl(url).toString();
    if (secret != null) {
      if (!_usesToken(old.auth)) {
        throw const McpException('This server does not use a token.');
      }
      if (secret.trim().isEmpty) throw const McpException('Enter the token.');
      await _secrets.write(_secretKey(id), secret.trim());
    }
    if (newUrl != old.url && old.auth == McpAuthKind.oauth) {
      // A sign-in belongs to one address, so the new address needs its own.
      await _secrets.delete(_oauthKey(id));
    }
    _servers[index] = old.copyWith(
      name: trimmedName == null || trimmedName.isEmpty ? old.name : trimmedName,
      url: newUrl,
    );
    await _save();
    _changed();
    if (old.enabled && (newUrl != old.url || secret != null)) {
      unawaited(connect(id));
    }
  }

  Future<void> remove(String id) async {
    cancelSignIn(id);
    disconnect(id);
    _servers.removeWhere((s) => s.id == id);
    _status.remove(id);
    _errors.remove(id);
    await _save();
    await _secrets.delete(_secretKey(id));
    await _secrets.delete(_oauthKey(id));
    _changed();
  }

  /// Asks a server whether it needs browser sign-in, a token, or neither. Saves nothing.
  Future<McpProbe> probe(String url) => _oauth.probe(_validUrl(url));

  bool isSigningIn(String id) => _pendingSignIns.containsKey(id);

  /// Opens the browser so the person can sign in, then connects with the new token.
  Future<void> signIn(String id) async {
    final config = _findOrNull(id);
    if (config == null || config.auth != McpAuthKind.oauth) {
      throw const McpException('This server does not use browser sign-in.');
    }
    cancelSignIn(id);
    final loopback = await LoopbackServer.start(path: '/callback');
    _pendingSignIns[id] = loopback;
    try {
      final record = await _oauth.signIn(mcpUrl: _validUrl(config.url), loopback: loopback);
      await _secrets.write(_oauthKey(id), jsonEncode(record.toJson()));
    } catch (e) {
      throw McpException(_signInFailure(e));
    } finally {
      if (identical(_pendingSignIns[id], loopback)) _pendingSignIns.remove(id);
      unawaited(loopback.close());
    }
    await connect(id);
  }

  /// Stops a sign-in that is waiting for the browser.
  void cancelSignIn(String id) {
    final loopback = _pendingSignIns.remove(id);
    if (loopback != null) unawaited(loopback.close());
  }

  /// Forgets the browser sign-in and revokes it at the server when it can.
  Future<void> signOut(String id) async {
    _indexOf(id);
    cancelSignIn(id);
    final record = await _oauthRecord(id);
    disconnect(id);
    await _secrets.delete(_oauthKey(id));
    if (record != null) await _oauth.revoke(record);
    _setStatus(id, McpStatus.needsSignIn);
  }

  Future<void> setEnabled(String id, bool on) async {
    final index = _indexOf(id);
    _servers[index] = _servers[index].copyWith(enabled: on);
    await _save();
    _changed();
    if (on) {
      await connect(id);
    } else {
      disconnect(id);
    }
  }

  /// Connects and lists tools. Failures are recorded in [statusOf] and [errorOf]; this never throws.
  Future<void> connect(String id) {
    final pending = _connecting[id];
    if (pending != null) return pending;
    // A block body: `() => _connecting.remove(id)` would return this very future, and
    // whenComplete waits for a returned future, so the call would never finish.
    final future = _connect(id).whenComplete(() {
      _connecting.remove(id);
    });
    _connecting[id] = future;
    return future;
  }

  /// Ends the session and forgets the server's tools. The server stays configured.
  void disconnect(String id) {
    _generation[id] = (_generation[id] ?? 0) + 1;
    final client = _clients.remove(id);
    _releaseNames(id);
    _tools.remove(id);
    _status[id] = McpStatus.disconnected;
    _errors.remove(id);
    _changed();
    if (client != null) unawaited(_closeQuietly(client));
  }

  /// Connects every enabled server in parallel, each bounded by [connectTimeout].
  Future<void> connectEnabled() async {
    await Future.wait([
      for (final s in _servers)
        if (s.enabled)
          connect(s.id).timeout(connectTimeout, onTimeout: () {
            disconnect(s.id);
            _setStatus(s.id, McpStatus.failed, error: 'Timed out after 15 seconds.');
          }),
    ]);
  }

  Future<void> setToolDisabled(String serverId, String toolName, bool disabled) async {
    final index = _indexOf(serverId);
    final current = _servers[index];
    final set = {...current.disabledTools};
    if (disabled) {
      set.add(toolName);
    } else {
      set.remove(toolName);
    }
    _servers[index] = current.copyWith(disabledTools: set.toList());
    await _save();
    _changed();
  }

  bool isToolDisabled(String serverId, String toolName) =>
      _findOrNull(serverId)?.disabledTools.contains(toolName) ?? false;

  @override
  List<AgentTool> get tools => [
        for (final s in _servers)
          if (statusOf(s.id) == McpStatus.connected)
            for (final t in _tools[s.id] ?? const <McpAgentTool>[])
              if (!t.disabled) t,
      ];

  @override
  Stream<void> get changes => _changes.stream;

  @override
  void dispose() {
    _disposed = true;
    for (final id in _pendingSignIns.keys.toList()) {
      cancelSignIn(id);
    }
    for (final id in _clients.keys.toList()) {
      disconnect(id);
    }
    unawaited(_changes.close());
    super.dispose();
  }

  // ---- internals ----

  Future<McpServerConfig> _create({
    required String name,
    required String url,
    required McpAuthKind auth,
    String? headerName,
    String? secret,
    Map<String, String> extraHeaders = const {},
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) throw const McpException('Give the server a name.');
    final parsedUrl = _validUrl(url).toString();
    final header = headerName?.trim();
    if (auth == McpAuthKind.header && (header == null || header.isEmpty)) {
      throw const McpException('Name the header that carries the token.');
    }
    if (_usesToken(auth) && (secret == null || secret.trim().isEmpty)) {
      throw const McpException('Enter the token.');
    }
    final id = Uuid().v4();
    final config = McpServerConfig(
      id: id,
      name: trimmedName,
      url: parsedUrl,
      auth: auth,
      headerName: auth == McpAuthKind.header ? header : null,
      extraHeaders: extraHeaders,
    );
    if (_usesToken(auth)) {
      await _secrets.write(_secretKey(id), secret!.trim());
    }
    _servers.add(config);
    await _save();
    _changed();
    return config;
  }

  Uri _validUrl(String url) {
    try {
      return validateMcpUrl(url);
    } on FormatException catch (e) {
      throw McpException(e.message);
    }
  }

  Future<void> _connect(String id, {bool retried = false}) async {
    final config = _findOrNull(id);
    if (config == null) return;
    disconnect(id);
    final generation = _generation[id] ?? 0;
    _setStatus(id, McpStatus.connecting);

    McpClient? client;
    try {
      final url = validateMcpUrl(config.url);
      final headers = await _headersFor(config, forceRefresh: retried);
      final transport = _transportFactory != null
          ? _transportFactory(url, headers)
          : StreamableHttpClientTransport(
              url,
              opts: StreamableHttpClientTransportOptions(
                requestInit: <String, dynamic>{
                  'headers': Map<String, dynamic>.from(headers),
                },
              ),
            );
      client = McpClient(const Implementation(name: 'Flute', version: '1.0.0'));
      await client.connect(transport).timeout(connectTimeout);
      final raw = await _listAllTools(client).timeout(connectTimeout);

      if (generation != (_generation[id] ?? 0) || _findOrNull(id) == null) {
        await _closeQuietly(client);
        return;
      }
      _tools[id] = _buildTools(config, raw);
      _clients[id] = client;
      _setStatus(id, McpStatus.connected);
    } catch (e) {
      if (client != null) await _closeQuietly(client);
      if (generation != (_generation[id] ?? 0)) return;
      if (config.auth == McpAuthKind.oauth && _isUnauthorized(e) && !retried) {
        await _connect(id, retried: true);
        return;
      }
      _releaseNames(id);
      _tools.remove(id);
      if (config.auth == McpAuthKind.oauth &&
          (_isUnauthorized(e) || (e is McpOAuthException && e.requiresSignIn))) {
        final message = e is McpOAuthException
            ? e.message
            : 'Your sign-in expired. Sign in again.';
        _setStatus(id, McpStatus.needsSignIn, error: message);
        return;
      }
      _setStatus(id, McpStatus.failed, error: _describeConnectError(e));
    }
  }

  Future<Map<String, String>> _headersFor(
    McpServerConfig config, {
    bool forceRefresh = false,
  }) async {
    final headers = <String, String>{...config.extraHeaders};
    if (config.readOnly) headers['X-MCP-Readonly'] = 'true';
    if (config.auth == McpAuthKind.none) return headers;
    if (config.auth == McpAuthKind.oauth) {
      final access = await _accessToken(config, forceRefresh: forceRefresh);
      headers['Authorization'] = 'Bearer $access';
      return headers;
    }
    final secret = await _secrets.read(_secretKey(config.id));
    if (secret == null || secret.isEmpty) {
      throw McpException('No token is saved for ${config.name}.');
    }
    switch (config.auth) {
      case McpAuthKind.bearer:
        headers['Authorization'] = 'Bearer $secret';
      case McpAuthKind.basic:
        headers['Authorization'] = 'Basic $secret';
      case McpAuthKind.header:
        headers[config.headerName!] = secret;
      case McpAuthKind.none || McpAuthKind.oauth:
        break;
    }
    return headers;
  }

  Future<String> _accessToken(
    McpServerConfig config, {
    required bool forceRefresh,
  }) async {
    final record = await _oauthRecord(config.id);
    if (record == null) {
      throw const McpOAuthException(
        'Sign in to use this server.',
        requiresSignIn: true,
      );
    }
    if (!forceRefresh && record.isFresh(DateTime.now())) {
      return record.accessToken;
    }
    return (await _refreshRecord(config.id, record)).accessToken;
  }

  Future<McpOAuthRecord> _refreshRecord(String id, McpOAuthRecord record) {
    final pending = _refreshes[id];
    if (pending != null) return pending;
    final refresh = () async {
      try {
        final fresh = await _oauth.refresh(record);
        await _secrets.write(_oauthKey(id), jsonEncode(fresh.toJson()));
        return fresh;
      } finally {
        _refreshes.remove(id);
      }
    }();
    _refreshes[id] = refresh;
    return refresh;
  }

  Future<McpOAuthRecord?> _oauthRecord(String id) async {
    final raw = await _secrets.read(_oauthKey(id));
    if (raw == null || raw.isEmpty) return null;
    try {
      return McpOAuthRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static String _oauthKey(String id) => '$_oauthSecretPrefix$id';

  static bool _usesToken(McpAuthKind auth) =>
      auth == McpAuthKind.bearer ||
      auth == McpAuthKind.basic ||
      auth == McpAuthKind.header;

  static bool _isUnauthorized(Object e) =>
      e is UnauthorizedError || (e is StreamableHttpError && e.code == 401);

  static String _signInFailure(Object e) {
    if (e is McpOAuthException) return e.message;
    if (e is TimeoutException) return 'Sign-in timed out. Try again.';
    if (e is StateError) return 'Sign-in was cancelled.';
    return 'Sign-in failed. Try again.';
  }

  Future<List<Tool>> _listAllTools(McpClient client) async {
    final out = <Tool>[];
    String? cursor;
    var pages = 0;
    do {
      final page = await client.listTools(
        params: cursor == null ? null : ListToolsRequest(cursor: cursor),
      );
      out.addAll(page.tools);
      cursor = page.nextCursor;
      pages++;
    } while (cursor != null && pages < _maxToolPages);
    return out;
  }

  List<McpAgentTool> _buildTools(McpServerConfig config, List<Tool> raw) {
    final slug = _serverSlug(config.name);
    return [
      for (final t in raw)
        McpAgentTool._(
          manager: this,
          serverId: config.id,
          serverName: config.name,
          rawName: t.name,
          name: _allocName(slug, t.name),
          description: t.description ?? t.title ?? '',
          parameters: _schemaOf(t),
          readOnly: t.annotations?.readOnlyHint == true,
        ),
    ];
  }

  /// `<server>__<tool>`, each part sanitised to `[a-zA-Z0-9_-]`, the whole at most 64 characters.
  /// The server part is cut first; a numeric suffix keeps names unique across servers.
  String _allocName(String serverSlug, String rawTool) {
    final tool = _sanitize(rawTool.isEmpty ? 'tool' : rawTool);
    final toolBudget = _maxNameChars - serverSlug.length - 2;
    final base = '${serverSlug}__${_cut(tool, toolBudget)}';
    var candidate = base;
    var n = 2;
    while (_takenNames.contains(candidate)) {
      final suffix = '_$n';
      candidate = '${_cut(base, _maxNameChars - suffix.length)}$suffix';
      n++;
    }
    _takenNames.add(candidate);
    return candidate;
  }

  void _releaseNames(String id) {
    for (final t in _tools[id] ?? const <McpAgentTool>[]) {
      _takenNames.remove(t.name);
    }
  }

  static String _serverSlug(String name) {
    final s = _sanitize(name.trim());
    final cut = _cut(s, _maxServerSlugChars);
    return cut.isEmpty ? 'server' : cut;
  }

  static String _sanitize(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  static String _cut(String s, int max) => s.length <= max ? s : s.substring(0, max);

  static Map<String, dynamic> _schemaOf(Tool t) {
    final schema = Map<String, dynamic>.from(t.inputSchema.toJson())..remove(r'$schema');
    schema.putIfAbsent('type', () => 'object');
    return schema;
  }

  String _describe(McpAgentTool tool, Map<String, dynamic> args) {
    final head = '${tool.serverName}: ${tool.rawName}';
    if (args.isEmpty) return head;
    final pairs = [
      for (final e in args.entries.take(3)) '${e.key}: ${_short(e.value)}',
    ];
    final more = args.length > 3 ? ', ...' : '';
    return '$head (${pairs.join(', ')}$more)';
  }

  static String _short(Object? value) {
    final text = (value is String ? value : jsonEncode(value)).replaceAll(RegExp(r'\s+'), ' ');
    return text.length > 80 ? '${text.substring(0, 80)}...' : text;
  }

  Future<ToolResult> _run(McpAgentTool tool, Map<String, dynamic> args) async {
    final client = _clients[tool.serverId];
    if (client == null || statusOf(tool.serverId) != McpStatus.connected) {
      return ToolResult.error('${tool.serverName} is not connected. Reconnect it in Agent settings.');
    }
    try {
      return _resultOf(await client.callTool(
        CallToolRequest(name: tool.rawName, arguments: args),
      ));
    } catch (e) {
      if (!_isSessionError(e) && !_isUnauthorized(e)) {
        return ToolResult.error('${tool.serverName} failed: ${_describeCallError(e)}');
      }
    }
    // The session expired or the token was refused: reconnect once and retry.
    await connect(tool.serverId);
    final retry = _clients[tool.serverId];
    if (retry == null) {
      if (statusOf(tool.serverId) == McpStatus.needsSignIn) {
        return ToolResult.error('${tool.serverName} needs you to sign in again in Agent settings.');
      }
      return ToolResult.error('${tool.serverName} lost its session and could not reconnect.');
    }
    try {
      return _resultOf(await retry.callTool(
        CallToolRequest(name: tool.rawName, arguments: args),
      ));
    } catch (e) {
      return ToolResult.error('${tool.serverName} failed: ${_describeCallError(e)}');
    }
  }

  static ToolResult _resultOf(CallToolResult result) {
    final text = _contentText(result.content);
    final clipped = text.isEmpty
        ? '(no output)'
        : text.length > _maxResultChars
            ? '${text.substring(0, _maxResultChars)}...(truncated)'
            : text;
    return result.isError ? ToolResult.error(clipped) : ToolResult(clipped);
  }

  static String _contentText(List<Content> parts) {
    final out = <String>[];
    for (final p in parts) {
      switch (p) {
        case TextContent():
          out.add(p.text);
        case ImageContent():
          out.add('[image]');
        case AudioContent():
          out.add('[audio]');
        case ResourceLink():
          out.add('[resource: ${p.uri}]');
        case EmbeddedResource():
          final r = p.resource;
          out.add(r is TextResourceContents ? r.text : '[resource]');
        default:
          out.add('[content]');
      }
    }
    return out.join('\n');
  }

  static bool _isSessionError(Object e) {
    if (e is StreamableHttpError) return e.code == 404;
    if (e is McpError) {
      return e.code == -32000 || e.message.toLowerCase().contains('session');
    }
    return false;
  }

  static String _describeCallError(Object e) => e is McpError ? _cut(e.message, 200) : 'the call did not complete.';

  static String _describeConnectError(Object e) {
    if (e is McpException) return e.message;
    if (e is McpOAuthException) return e.message;
    if (e is TimeoutException) return 'Timed out after 15 seconds.';
    if (e is FormatException) return e.message;
    if (e is UnauthorizedError) return 'The server refused the token. Check it and try again.';
    if (e is StreamableHttpError) {
      if (e.code == 401 || e.code == 403) return 'The server refused the token. Check it and try again.';
      return 'The server answered with HTTP ${e.code}.';
    }
    if (e is McpError) return _cut(e.message, 200);
    return 'Could not connect to the server.';
  }

  static Future<void> _closeQuietly(McpClient client) async {
    try {
      await client.close();
    } catch (_) {
      // Already closed or broken; nothing else to release.
    }
  }

  void _setStatus(String id, McpStatus status, {String? error}) {
    _status[id] = status;
    _errors[id] = error;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    notifyListeners();
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _save() => _prefs.setString(
        _serversKey,
        jsonEncode([for (final s in _servers) s.toJson()]),
      );

  static String _secretKey(String id) => 'agent.mcp.$id';

  int _indexOf(String id) {
    final i = _servers.indexWhere((s) => s.id == id);
    if (i < 0) throw const McpException('That server no longer exists.');
    return i;
  }

  McpServerConfig? _findOrNull(String id) {
    for (final s in _servers) {
      if (s.id == id) return s;
    }
    return null;
  }
}
