import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'sandbox_provider.dart';

/// Daytona sandboxes. Ephemeral sandboxes are deleted on close. A user-selected
/// sandbox is stopped on close: stop keeps files but not memory.
class DaytonaProvider implements SandboxProvider {
  DaytonaProvider({
    required this.apiKey,
    required http.Client client,
    String? baseUrl,
    this.pollInterval = const Duration(seconds: 1),
    this.operationTimeout = const Duration(minutes: 3),
  }) : _client = client,
       baseUrl = _cleanBase(baseUrl ?? defaultBaseUrl);

  static const defaultBaseUrl = 'https://app.daytona.io/api';

  /// Server-side safety net: an ephemeral sandbox is stopped after this many
  /// idle minutes and then deleted (autoDeleteInterval 0).
  static const ephemeralAutoStopMinutes = 10;

  static const _requestTimeout = Duration(seconds: 30);

  final String apiKey;
  final String baseUrl;
  final Duration pollInterval;
  final Duration operationTimeout;
  final http.Client _client;

  @override
  String get id => 'daytona';

  @override
  String get label => 'Daytona';

  @override
  bool get isRemote => true;

  /// Cheap authenticated call used to check a key before it is saved.
  Future<void> verifyKey() async {
    await _send('GET', '$baseUrl/sandbox');
  }

  @override
  Future<SandboxSession> open({String? existingId}) async {
    if (existingId != null) {
      final box = await _ensureStarted(existingId);
      return _DaytonaSession(this, box, ephemeral: false);
    }
    final created = await _api(
      'POST',
      '/sandbox',
      body: {
        'autoStopInterval': ephemeralAutoStopMinutes,
        'autoDeleteInterval': 0,
        'labels': {'app': 'flute'},
      },
    );
    final box = _boxFrom(created);
    try {
      await _waitFor(box.id, 'started');
    } catch (_) {
      await _bestEffortDelete(box.id);
      rethrow;
    }
    return _DaytonaSession(this, box, ephemeral: true);
  }

  Future<_DaytonaBox> _ensureStarted(String id) async {
    var sb = await _api('GET', '/sandbox/$id');
    switch (_str(sb, 'state')) {
      case 'started':
        return _boxFrom(sb);
      case 'stopped' || 'paused':
        await _api('POST', '/sandbox/$id/start');
        sb = await _waitFor(id, 'started');
      case 'starting' || 'resuming':
        sb = await _waitFor(id, 'started');
      case final state:
        throw SandboxException('Daytona sandbox is $state; wait for it to settle.');
    }
    return _boxFrom(sb);
  }

  Future<Map<String, dynamic>> _waitFor(String id, String target) async {
    final deadline = DateTime.now().add(operationTimeout);
    while (true) {
      final sb = await _api('GET', '/sandbox/$id');
      final state = _str(sb, 'state');
      if (state == target) return sb;
      if (state == 'error') {
        throw const SandboxException('Daytona sandbox entered an error state.');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw SandboxException('Daytona sandbox did not reach $target in time.');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<void> _stop(String id) async {
    await _api('POST', '/sandbox/$id/stop');
    await _waitFor(id, 'stopped');
  }

  /// Deletion is asynchronous. A sandbox already gone (404) counts as deleted.
  Future<void> _deleteSandbox(String id) async {
    await _send('DELETE', '$baseUrl/sandbox/$id', allow: const {404});
    final deadline = DateTime.now().add(operationTimeout);
    while (true) {
      final res = await _send('GET', '$baseUrl/sandbox/$id', allow: const {404});
      if (res.statusCode == 404 || _decodeMap(res)['state'] == 'destroyed') return;
      if (DateTime.now().isAfter(deadline)) {
        throw const SandboxException('Daytona sandbox was not deleted in time.');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<void> _bestEffortDelete(String id) async {
    try {
      await _deleteSandbox(id);
    } catch (_) {
      // The server-side autoDeleteInterval still reclaims the sandbox.
    }
  }

  Future<ExecResult> _exec(
    _DaytonaBox box,
    String command, {
    required Duration timeout,
  }) async {
    final seconds = timeout.inSeconds.clamp(1, 600).toInt();
    final res = await _send(
      'POST',
      '${box.toolboxRoot}/process/execute',
      body: {'command': command, 'timeout': seconds},
      allow: const {408},
      timeout: Duration(seconds: seconds) + _requestTimeout,
    );
    if (res.statusCode == 408) {
      return ExecResult(
        stdout: '',
        stderr: _errorBody(res.bodyBytes) ?? 'Command timed out.',
        exitCode: 124,
        timedOut: true,
      );
    }
    // The toolbox merges stderr into the result; there is no separate stream.
    final json = _decodeMap(res);
    final output = json['result'];
    return ExecResult(
      stdout: output is String ? output : '',
      stderr: '',
      exitCode: (json['exitCode'] as num?)?.toInt() ?? -1,
    );
  }

  Future<ExecResult> _runPython(_DaytonaBox box, String code, Duration timeout) async {
    // The toolbox exec endpoint has no stdin, so the script is uploaded first.
    final path = '/tmp/flute_${const Uuid().v4().replaceAll('-', '')}.py';
    await _upload(box, path, utf8.encode(code));
    try {
      return await _exec(box, 'python3 ${_quote(path)}', timeout: timeout);
    } finally {
      try {
        await _exec(box, 'rm -f ${_quote(path)}', timeout: const Duration(seconds: 15));
      } catch (_) {
        // Scratch file in /tmp; nothing else depends on it.
      }
    }
  }

  Future<void> _writeFile(_DaytonaBox box, String path, List<int> bytes) async {
    final dir = _dirname(path);
    if (dir.isNotEmpty) {
      final made = await _exec(
        box,
        'mkdir -p ${_quote(dir)}',
        timeout: const Duration(seconds: 30),
      );
      if (made.exitCode != 0) {
        throw SandboxException('Daytona could not create $dir.');
      }
    }
    await _upload(box, path, bytes);
  }

  Future<void> _upload(_DaytonaBox box, String path, List<int> bytes) async {
    final uri = Uri.parse(
      '${box.toolboxRoot}/files/upload-v2',
    ).replace(queryParameters: {'path': path});
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: _basename(path)),
      );
    await _dispatch(request, allow: const {}, timeout: _requestTimeout);
  }

  Future<List<int>> _readFile(_DaytonaBox box, String path) async {
    final res = await _send(
      'GET',
      '${box.toolboxRoot}/files/download',
      query: {'path': path},
    );
    return res.bodyBytes;
  }

  Future<Map<String, dynamic>> _api(
    String method,
    String path, {
    Object? body,
  }) async {
    final res = await _send(method, '$baseUrl$path', body: body);
    return _decodeMap(res);
  }

  static Map<String, dynamic> _decodeMap(http.Response res) {
    if (res.bodyBytes.isEmpty) return {};
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : {};
  }

  Future<http.Response> _send(
    String method,
    String url, {
    Map<String, String>? query,
    Object? body,
    Set<int> allow = const {},
    Duration timeout = _requestTimeout,
  }) {
    final request = http.Request(method, Uri.parse(url).replace(queryParameters: query))
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return _dispatch(request, allow: allow, timeout: timeout);
  }

  Future<http.Response> _dispatch(
    http.BaseRequest request, {
    required Set<int> allow,
    required Duration timeout,
  }) async {
    final http.Response res;
    try {
      res = await _client.send(request).then(http.Response.fromStream).timeout(timeout);
    } on TimeoutException {
      throw const SandboxException('Daytona request timed out.');
    } on http.ClientException {
      throw const SandboxException('Daytona is unreachable. Check the network.');
    }
    if (res.statusCode >= 400 && !allow.contains(res.statusCode)) {
      throw SandboxException(
        'Daytona ${res.statusCode}: ${_errorBody(res.bodyBytes) ?? 'request failed'}',
      );
    }
    return res;
  }

  static _DaytonaBox _boxFrom(Map<String, dynamic> sb) {
    final id = _str(sb, 'id');
    final proxy = _cleanBase(_str(sb, 'toolboxProxyUrl'));
    return _DaytonaBox(id, '$proxy/$id');
  }

  static String _cleanBase(String url) {
    final trimmed = url.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  static String _str(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw SandboxException('Daytona returned no $key.');
    }
    return value;
  }

  static String? _errorBody(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map && decoded['message'] is String) {
        return decoded['message'] as String;
      }
    } catch (_) {
      // Not JSON: no detail to show.
    }
    return null;
  }

  static String _quote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _dirname(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '' : path.substring(0, i);
  }

  static String _basename(String path) => path.substring(path.lastIndexOf('/') + 1);
}

class _DaytonaBox {
  const _DaytonaBox(this.id, this.toolboxRoot);

  final String id;
  final String toolboxRoot;
}

class _DaytonaSession implements SandboxSession {
  _DaytonaSession(this._provider, this._box, {required bool ephemeral})
    : _ephemeral = ephemeral;

  final DaytonaProvider _provider;
  final _DaytonaBox _box;
  final bool _ephemeral;
  bool _closed = false;

  @override
  String get label => 'Daytona';

  @override
  Future<ExecResult> runPython(String code, {required Duration timeout}) =>
      _provider._runPython(_box, code, timeout);

  @override
  Future<ExecResult> runShell(String command, {required Duration timeout}) =>
      _provider._exec(_box, command, timeout: timeout);

  @override
  Future<void> writeFile(String path, List<int> bytes) =>
      _provider._writeFile(_box, path, bytes);

  @override
  Future<List<int>> readFile(String path) => _provider._readFile(_box, path);

  @override
  Future<List<String>> newFiles() async => const [];

  /// Marks closed only after success, so a failed close can be retried.
  @override
  Future<void> close() async {
    if (_closed) return;
    if (_ephemeral) {
      await _provider._deleteSandbox(_box.id);
    } else {
      await _provider._stop(_box.id);
    }
    _closed = true;
  }
}
