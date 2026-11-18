import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/mcp/mcp_presets.dart';
import 'package:focus_launcher/agent/mcp/mcp_server_config.dart';

void main() {
  test('Jira preset secret is base64 of email:token, sent as Basic', () {
    expect(
      McpPresets.jiraBasic('user@example.com', 'secret'),
      'dXNlckBleGFtcGxlLmNvbTpzZWNyZXQ=',
    );
  });

  test('https endpoints are accepted', () {
    expect(validateMcpUrl('https://mcp.atlassian.com/v2/mcp').host, 'mcp.atlassian.com');
  });

  test('plain http is refused outside localhost and the local network', () {
    expect(() => validateMcpUrl('http://example.com/mcp'), throwsFormatException);
    expect(() => validateMcpUrl('ftp://example.com/mcp'), throwsFormatException);
    expect(() => validateMcpUrl('not a url'), throwsFormatException);
  });

  test('http is allowed for localhost and private addresses', () {
    expect(validateMcpUrl('http://localhost:8080/mcp').port, 8080);
    expect(validateMcpUrl('http://192.168.1.20/mcp').host, '192.168.1.20');
    expect(validateMcpUrl('http://10.0.0.5/mcp').host, '10.0.0.5');
    expect(validateMcpUrl('http://172.20.1.1/mcp').host, '172.20.1.1');
    expect(() => validateMcpUrl('http://172.40.1.1/mcp'), throwsFormatException);
  });

  test('credentials in the address are refused', () {
    expect(() => validateMcpUrl('https://user:pw@example.com/mcp'), throwsFormatException);
  });

  test('server config survives a JSON round trip without the secret', () {
    const config = McpServerConfig(
      id: 'abc',
      name: 'GitHub',
      url: 'https://api.githubcopilot.com/mcp/',
      auth: McpAuthKind.bearer,
      readOnly: true,
      extraHeaders: {'X-Test': '1'},
      disabledTools: ['delete_issue'],
    );
    final back = McpServerConfig.fromJson(config.toJson());
    expect(back.name, 'GitHub');
    expect(back.auth, McpAuthKind.bearer);
    expect(back.readOnly, isTrue);
    expect(back.extraHeaders, {'X-Test': '1'});
    expect(back.disabledTools, ['delete_issue']);
    expect(back.enabled, isTrue);
    expect(config.toJson().toString(), isNot(contains('token')));
  });
}
