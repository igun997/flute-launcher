import 'dart:convert';

import 'mcp_server_config.dart';

/// A known remote MCP server the person can add with one token.
class McpPreset {
  const McpPreset({
    required this.key,
    required this.title,
    required this.description,
    required this.url,
    required this.auth,
    required this.secretLabel,
    required this.helpUrl,
    this.headers = const {},
  });

  final String key;
  final String title;
  final String description;
  final String url;
  final McpAuthKind auth;

  /// What the token field asks for, e.g. "Personal access token".
  final String secretLabel;
  final String helpUrl;
  final Map<String, String> headers;
}

class McpPresets {
  McpPresets._();

  static const github = McpPreset(
    key: 'github',
    title: 'GitHub',
    description: 'Repositories, issues, pull requests and code search.',
    url: 'https://api.githubcopilot.com/mcp/',
    auth: McpAuthKind.bearer,
    secretLabel: 'Personal access token',
    helpUrl: 'https://github.com/settings/personal-access-tokens',
  );

  static const jira = McpPreset(
    key: 'jira',
    title: 'Jira and Confluence',
    description: 'Issues, projects and pages in Atlassian Cloud. Needs an API token.',
    url: 'https://mcp.atlassian.com/v2/mcp',
    auth: McpAuthKind.basic,
    secretLabel: 'Email and API token',
    helpUrl: 'https://id.atlassian.com/manage-profile/security/api-tokens',
  );

  static const List<McpPreset> all = [github, jira];

  /// The value stored as the secret of a [jira] server: base64 of `email:apiToken`,
  /// sent as `Authorization: Basic <value>`.
  static String jiraBasic(String email, String apiToken) =>
      base64Encode(utf8.encode('${email.trim()}:${apiToken.trim()}'));
}
