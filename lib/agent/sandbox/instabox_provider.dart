import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'sandbox_provider.dart';

/// Instabox cloud machines. Ephemeral sandboxes are deleted on close; a
/// user-selected sandbox is suspended (paused) on close and keeps its files.
class InstaboxProvider implements SandboxProvider {
  InstaboxProvider({
    required this.apiKey,
    required http.Client client,
    String? baseUrl,
    this.pollInterval = const Duration(seconds: 1),
    this.operationTimeout = const Duration(minutes: 3),
  }) : _client = client,
       baseUrl = _cleanBase(baseUrl ?? defaultBaseUrl);

  static const defaultBaseUrl = 'https://api.instabox.sh';

  /// Server-side safety net: an ephemeral sandbox is deleted even if this
  /// client dies before closing it.
  static const ephemeralLifetimeSeconds = 14400;

  static const _requestTimeout = Duration(seconds: 30);

  final String apiKey;
  final String baseUrl;
  final Duration pollInterval;
  final Duration operationTimeout;
  final http.Client _client;

  @override
  String get id => 'instabox';

  @override
  String get label => 'Instabox';

  @override
  bool get isRemote => true;

  /// Cheap authenticated call used to check a key before it is saved.
  Future<void> verifyKey() async {
    await _send('GET', '/v1/machines');
  }

  @override
  Future<SandboxSession> open({String? existingId}) async {
    if (existingId != null) {
      await _ensureRunning(existingId);
      return _InstaboxSession(this, existingId, ephemeral: false);
    }
    final op = await _json(
      'POST',
      '/v1/machines',
      body: {
        'name': 'flute-${const Uuid().v4().substring(0, 8)}',
        'desiredState': 'running',
        'deleteAfterSeconds': ephemeralLifetimeSeconds,
      },
      mutating: true,
    );
    final machineId = _str(op, 'machineId');
    try {
      await _waitOperation(_str(op, 'id'));
    } catch (_) {
      await _bestEffortDelete(machineId);
      rethrow;
    }
    return _InstaboxSession(this, machineId, ephemeral: true);
  }

  Future<void> _ensureRunning(String machineId) async {
    final machine = await _json('GET', '/v1/machines/$machineId');
    final String action;
    switch (_str(machine, 'state')) {
      case 'running':
        return;
      case 'suspended':
        action = 'resume';
      case 'stopped':
        action = 'start';
      case final state:
        throw SandboxException('Instabox sandbox is $state; wait for it to settle.');
    }
    final op = await _json('POST', '/v1/machines/$machineId/$action', mutating: true);
    await _waitOperation(_str(op, 'id'));
  }

  Future<void> _waitOperation(String operationId) async {
    final deadline = DateTime.now().add(operationTimeout);
    while (true) {
      final op = await _json('GET', '/v1/operations/$operationId');
      switch (op['state']) {
        case 'succeeded':
          return;
        case 'failed':
          throw SandboxException(_errorMessage(op['error']) ?? 'Instabox operation failed.');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const SandboxException('Instabox operation did not finish in time.');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Deletes a sandbox. A machine already gone (404) counts as deleted.
  Future<void> _deleteMachine(String machineId) async {
    final res = await _send(
      'DELETE',
      '/v1/machines/$machineId',
      headers: {'X-Confirm-Delete': machineId},
      mutating: true,
      allowNotFound: true,
    );
    if (res.statusCode == 404) return;
    await _waitOperation(_str(_decode(res), 'id'));
  }

  Future<void> _bestEffortDelete(String machineId) async {
    try {
      await _deleteMachine(machineId);
    } catch (_) {
      // The server-side deleteAfterSeconds still reclaims the machine.
    }
  }

  Future<void> _suspendMachine(String machineId) async {
    final op = await _json('POST', '/v1/machines/$machineId/suspend', mutating: true);
    await _waitOperation(_str(op, 'id'));
  }

  Future<ExecResult> _exec(
    String machineId, {
    required Map<String, Object?> request,
    required Duration timeout,
  }) async {
    final seconds = timeout.inSeconds.clamp(1, 600).toInt();
    final json = await _json(
      'POST',
      '/v1/machines/$machineId/exec',
      body: {...request, 'timeoutSeconds': seconds},
      timeout: Duration(seconds: seconds) + _requestTimeout,
    );
    return ExecResult(
      stdout: (json['stdout'] as String?) ?? '',
      stderr: (json['stderr'] as String?) ?? '',
      exitCode: (json['exitCode'] as num).toInt(),
      timedOut: json['timedOut'] == true,
    );
  }

  Future<void> _writeFile(String machineId, String path, List<int> bytes) async {
    await _send(
      'PUT',
      '/v1/machines/$machineId/files',
      query: {'path': path, 'parents': 'true'},
      body: bytes,
      mutating: true,
    );
  }

  Future<List<int>> _readFile(String machineId, String path) async {
    final res = await _send(
      'GET',
      '/v1/machines/$machineId/files/content',
      query: {'path': path},
    );
    return res.bodyBytes;
  }

  Future<dynamic> _json(
    String method,
    String path, {
    Object? body,
    Map<String, String>? headers,
    bool mutating = false,
    Duration timeout = _requestTimeout,
  }) async {
    final res = await _send(
      method,
      path,
      body: body,
      headers: headers,
      mutating: mutating,
      timeout: timeout,
    );
    return _decode(res);
  }

  static dynamic _decode(http.Response res) {
    if (res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Map<String, String>? headers,
    bool mutating = false,
    bool allowNotFound = false,
    Duration timeout = _requestTimeout,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final request = http.Request(method, uri)
      ..headers['X-API-Key'] = apiKey
      ..headers['Accept'] = 'application/json';
    headers?.forEach((k, v) => request.headers[k] = v);
    if (mutating) request.headers['Idempotency-Key'] = const Uuid().v4();
    if (body is List<int>) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = body;
    } else if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response res;
    try {
      res = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      throw const SandboxException('Instabox request timed out.');
    } on http.ClientException {
      throw const SandboxException('Instabox is unreachable. Check the network.');
    }

    if (res.statusCode == 404 && allowNotFound) return res;
    if (res.statusCode >= 400) {
      throw SandboxException(
        'Instabox ${res.statusCode}: ${_errorBody(res.bodyBytes) ?? 'request failed'}',
      );
    }
    return res;
  }

  static String _cleanBase(String url) {
    final trimmed = url.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  static String _str(dynamic json, String key) {
    final value = json is Map ? json[key] : null;
    if (value is! String || value.isEmpty) {
      throw SandboxException('Instabox returned no $key.');
    }
    return value;
  }

  static String? _errorMessage(dynamic error) {
    if (error is Map && error['message'] is String) return error['message'] as String;
    return null;
  }

  static String? _errorBody(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map && decoded['error'] is Map) {
        return _errorMessage(decoded['error']);
      }
    } catch (_) {
      // Not JSON: no detail to show.
    }
    return null;
  }
}

class _InstaboxSession implements SandboxSession {
  _InstaboxSession(this._provider, this._machineId, {required bool ephemeral})
    : _ephemeral = ephemeral;

  final InstaboxProvider _provider;
  final String _machineId;
  final bool _ephemeral;
  bool _closed = false;

  @override
  String get label => 'Instabox';

  @override
  Future<ExecResult> runPython(String code, {required Duration timeout}) =>
      _provider._exec(
        _machineId,
        request: {
          'argv': ['python3', '-'],
          'stdin': code,
        },
        timeout: timeout,
      );

  @override
  Future<ExecResult> runShell(String command, {required Duration timeout}) =>
      _provider._exec(_machineId, request: {'cmd': command}, timeout: timeout);

  @override
  Future<void> writeFile(String path, List<int> bytes) =>
      _provider._writeFile(_machineId, path, bytes);

  @override
  Future<List<int>> readFile(String path) => _provider._readFile(_machineId, path);

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_ephemeral) {
      await _provider._deleteMachine(_machineId);
    } else {
      await _provider._suspendMachine(_machineId);
    }
    _closed = true;
  }
}
