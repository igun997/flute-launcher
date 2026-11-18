import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/mcp/mcp_manager.dart';
import 'package:focus_launcher/agent/mcp/mcp_presets.dart';
import 'package:focus_launcher/agent/mcp/mcp_server_config.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two in-process ends of a transport: what one sends, the other receives.
class _Linked extends Transport {
  _Linked? peer;

  @override
  void Function()? onclose;

  @override
  void Function(Error error)? onerror;

  @override
  void Function(JsonRpcMessage message)? onmessage;

  @override
  Future<void> start() async {}

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    scheduleMicrotask(() => peer?.onmessage?.call(message));
  }

  @override
  Future<void> close() async {}

  @override
  String? get sessionId => null;
}

class _BrokenTransport extends _Linked {
  @override
  Future<void> start() async => throw StateError('no route to host');
}

/// A factory that starts a fresh fake MCP server for every connection and records the headers.
McpTransportFactory _fakeServer(
  void Function(McpServer server) setup, {
  List<Map<String, String>>? headersSeen,
}) {
  return (url, headers) {
    headersSeen?.add(Map.of(headers));
    final server = McpServer(const Implementation(name: 'fake', version: '1.0.0'));
    setup(server);
    final client = _Linked();
    final side = _Linked();
    client.peer = side;
    side.peer = client;
    unawaited(server.connect(side));
    return client;
  };
}

void _registerSearch(McpServer server) {
  server.registerTool(
    'search',
    description: 'Search things',
    inputSchema: JsonSchema.object(
      properties: {'query': JsonSchema.string()},
      required: ['query'],
    ),
    annotations: const ToolAnnotations(readOnlyHint: true),
    callback: (args, extra) => CallToolResult(
      content: [TextContent(text: 'found ${args['query']}')],
    ),
  );
  server.registerTool(
    'write_note',
    description: 'Write a note',
    inputSchema: JsonSchema.object(
      properties: {'text': JsonSchema.string()},
    ),
    callback: (args, extra) => CallToolResult(
      content: [TextContent(text: 'saved'), ImageContent(data: 'AAAA', mimeType: 'image/png')],
    ),
  );
  server.registerTool(
    'fail',
    description: 'Always fails',
    callback: (args, extra) => CallToolResult(
      content: [TextContent(text: 'bad input')],
      isError: true,
    ),
  );
}

Future<void> _until(bool Function() check) async {
  for (var i = 0; i < 2000 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(check(), isTrue, reason: 'condition not reached in time');
}

Future<void> _settle(McpManager m, String id) =>
    _until(() => m.statusOf(id) == McpStatus.connected || m.statusOf(id) == McpStatus.failed);

void main() {
  late SharedPreferences prefs;
  late MemorySecretStore secrets;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySecretStore();
  });

  test('config is saved without the token and reloads in a new manager', () async {
    final first = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer((s) {}),
    );
    await first.load();
    final config = await first.addPreset(McpPresets.github, secret: 'ghp_SECRETVALUE');
    await _settle(first, config.id);

    expect(prefs.getString('agent.mcp.servers'), isNot(contains('ghp_SECRETVALUE')));
    expect(await secrets.read('agent.mcp.${config.id}'), 'ghp_SECRETVALUE');

    final second = McpManager(prefs: prefs, secrets: secrets);
    await second.load();
    expect(second.servers.map((s) => s.name), ['GitHub']);
    expect(second.statusOf(config.id), McpStatus.disconnected);
  });

  test('bearer token is sent as Authorization on connect', () async {
    final headers = <Map<String, String>>[];
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer(_registerSearch, headersSeen: headers),
    );
    await m.load();
    final config = await m.add(
      name: 'Fake',
      url: 'https://example.com/mcp',
      auth: McpAuthKind.bearer,
      secret: 'tok123',
    );
    await _settle(m, config.id);
    expect(m.statusOf(config.id), McpStatus.connected);
    expect(headers.last['Authorization'], 'Bearer tok123');
  });

  test('plain http to a public host is refused before anything is saved', () async {
    final m = McpManager(prefs: prefs, secrets: secrets);
    await m.load();
    await expectLater(
      m.add(name: 'Bad', url: 'http://example.com/mcp'),
      throwsA(isA<McpException>()),
    );
    expect(m.servers, isEmpty);
  });

  test('connected tools are named, risk-mapped and run through the server', () async {
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer(_registerSearch),
    );
    await m.load();
    final config = await m.add(name: 'Fake Server', url: 'https://example.com/mcp');
    await _settle(m, config.id);

    final tools = {for (final t in m.tools) t.name: t};
    expect(tools.keys, containsAll(['Fake_Server__search', 'Fake_Server__write_note', 'Fake_Server__fail']));
    expect(tools['Fake_Server__search']!.risk, ToolRisk.read);
    expect(tools['Fake_Server__write_note']!.risk, ToolRisk.write);
    expect(tools['Fake_Server__search']!.source, 'mcp:Fake Server');
    expect(McpManager.rawToolNameOf(tools['Fake_Server__search']!), 'search');

    final found = await tools['Fake_Server__search']!.run({'query': 'cats'});
    expect(found.isError, isFalse);
    expect(found.text, 'found cats');

    final saved = await tools['Fake_Server__write_note']!.run({'text': 'hi'});
    expect(saved.text, 'saved\n[image]');

    final failed = await tools['Fake_Server__fail']!.run({});
    expect(failed.isError, isTrue);
    expect(failed.text, 'bad input');
  });

  test('describeCall shows the server, tool and first arguments', () async {
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer(_registerSearch),
    );
    await m.load();
    final config = await m.add(name: 'Fake', url: 'https://example.com/mcp');
    await _settle(m, config.id);
    final tool = m.tools.firstWhere((t) => t.name == 'Fake__write_note');
    expect(
      tool.describeCall({'text': 'hello', 'x': 1, 'y': 2, 'z': 3}),
      'Fake: write_note (text: hello, x: 1, y: 2, ...)',
    );
    expect(tool.describeCall({}), 'Fake: write_note');
  });

  test('disabled tools are hidden from the agent but still listed for settings', () async {
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer(_registerSearch),
    );
    await m.load();
    final config = await m.add(name: 'Fake', url: 'https://example.com/mcp');
    await _settle(m, config.id);

    await m.setToolDisabled(config.id, 'write_note', true);
    expect(m.isToolDisabled(config.id, 'write_note'), isTrue);
    expect(m.tools.map((t) => t.name), isNot(contains('Fake__write_note')));
    expect(m.toolsOf(config.id).map((t) => t.name), contains('Fake__write_note'));

    await m.setToolDisabled(config.id, 'write_note', false);
    expect(m.tools.map((t) => t.name), contains('Fake__write_note'));
  });

  test('two servers with the same name get distinct tool names within 64 characters', () async {
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer(_registerSearch),
    );
    await m.load();
    final longName = 'A very long server name that goes on and on and on forever';
    final a = await m.add(name: longName, url: 'https://example.com/a');
    final b = await m.add(name: longName, url: 'https://example.com/b');
    await _settle(m, a.id);
    await _settle(m, b.id);

    final names = m.tools.map((t) => t.name).toList();
    expect(names.toSet().length, names.length);
    for (final n in names) {
      expect(n.length, lessThanOrEqualTo(64));
      expect(RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(n), isTrue);
    }
    expect(names, hasLength(6));
    expect(names.where((n) => n.startsWith('A_very_long_server_name_')), hasLength(6));
  });

  test('a server that cannot start reports failed with a readable error', () async {
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: (url, headers) => _BrokenTransport(),
    );
    await m.load();
    final config = await m.add(name: 'Broken', url: 'https://example.com/mcp');
    await _settle(m, config.id);
    expect(m.statusOf(config.id), McpStatus.failed);
    expect(m.errorOf(config.id), 'Could not connect to the server.');
    expect(m.tools, isEmpty);
  });

  test('disabling a server disconnects it and enabling connects again', () async {
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer(_registerSearch),
    );
    await m.load();
    final config = await m.add(name: 'Fake', url: 'https://example.com/mcp');
    await _settle(m, config.id);
    expect(m.tools, isNotEmpty);

    await m.setEnabled(config.id, false);
    expect(m.statusOf(config.id), McpStatus.disconnected);
    expect(m.tools, isEmpty);
    expect(m.servers.single.enabled, isFalse);

    await m.setEnabled(config.id, true);
    await _settle(m, config.id);
    expect(m.statusOf(config.id), McpStatus.connected);
  });

  test('removing a server deletes its token and config', () async {
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer(_registerSearch),
    );
    await m.load();
    final config = await m.add(
      name: 'Fake',
      url: 'https://example.com/mcp',
      auth: McpAuthKind.bearer,
      secret: 'tok',
    );
    await _settle(m, config.id);
    await m.remove(config.id);
    expect(m.servers, isEmpty);
    expect(await secrets.read('agent.mcp.${config.id}'), isNull);
    expect(jsonDecode(prefs.getString('agent.mcp.servers')!), isEmpty);
  });

  test('Jira preset sends the encoded email and token as Basic auth', () async {
    final headers = <Map<String, String>>[];
    final m = McpManager(
      prefs: prefs,
      secrets: secrets,
      transportFactory: _fakeServer(_registerSearch, headersSeen: headers),
    );
    await m.load();
    final config = await m.addPreset(
      McpPresets.jira,
      secret: McpPresets.jiraBasic('user@example.com', 'secret'),
    );
    await _settle(m, config.id);
    expect(headers.last['Authorization'], 'Basic dXNlckBleGFtcGxlLmNvbTpzZWNyZXQ=');
    expect(config.url, 'https://mcp.atlassian.com/v2/mcp');
  });
}
