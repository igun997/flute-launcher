/// How a remote MCP server expects to be authenticated. The secret itself lives in the
/// [SecretStore], never in this config.
enum McpAuthKind { none, bearer, basic, header }

class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.auth = McpAuthKind.none,
    this.headerName,
    this.enabled = true,
    this.readOnly = false,
    this.extraHeaders = const {},
    this.disabledTools = const [],
  });

  final String id;
  final String name;

  /// Streamable HTTP endpoint, e.g. `https://api.githubcopilot.com/mcp/`.
  final String url;
  final McpAuthKind auth;

  /// Only for [McpAuthKind.header]: the header that carries the secret.
  final String? headerName;
  final bool enabled;

  /// Sends `X-MCP-Readonly: true`, which asks servers such as GitHub's to offer only read tools.
  final bool readOnly;

  /// Non-secret headers a preset needs.
  final Map<String, String> extraHeaders;

  /// Raw tool names (as the server reports them) the person switched off.
  final List<String> disabledTools;

  McpServerConfig copyWith({
    String? name,
    String? url,
    McpAuthKind? auth,
    String? headerName,
    bool? enabled,
    bool? readOnly,
    Map<String, String>? extraHeaders,
    List<String>? disabledTools,
  }) =>
      McpServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        auth: auth ?? this.auth,
        headerName: headerName ?? this.headerName,
        enabled: enabled ?? this.enabled,
        readOnly: readOnly ?? this.readOnly,
        extraHeaders: extraHeaders ?? this.extraHeaders,
        disabledTools: disabledTools ?? this.disabledTools,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'auth': auth.name,
        if (headerName != null) 'headerName': headerName,
        'enabled': enabled,
        if (readOnly) 'readOnly': true,
        if (extraHeaders.isNotEmpty) 'extraHeaders': extraHeaders,
        if (disabledTools.isNotEmpty) 'disabledTools': disabledTools,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> j) => McpServerConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String,
        auth: McpAuthKind.values.byName(j['auth'] as String),
        headerName: j['headerName'] as String?,
        enabled: (j['enabled'] as bool?) ?? true,
        readOnly: (j['readOnly'] as bool?) ?? false,
        extraHeaders: {
          for (final e in ((j['extraHeaders'] as Map?) ?? const {}).entries)
            e.key as String: e.value as String,
        },
        disabledTools: [
          for (final t in (j['disabledTools'] as List?) ?? const []) t as String,
        ],
      );
}

/// Checks an MCP endpoint: `https`, or `http` only for localhost and private (LAN, CGNAT) addresses.
/// Returns the parsed URI, or throws [FormatException] with a message for the person.
Uri validateMcpUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const FormatException('Enter the full server address, for example https://example.com/mcp');
  }
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException('Remove the user name and password from the address; use a token instead.');
  }
  if (uri.scheme == 'https') return uri;
  if (uri.scheme == 'http' && _isLocalOrLan(uri.host)) return uri;
  throw const FormatException('Use an https:// address. Plain http:// is only allowed on this network.');
}

bool _isLocalOrLan(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '::1' || h.endsWith('.local')) return true;
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
  final a = octets[0]!;
  final b = octets[1]!;
  return a == 127 ||
      a == 10 ||
      a == 100 ||
      (a == 192 && b == 168) ||
      (a == 172 && b >= 16 && b <= 31);
}
