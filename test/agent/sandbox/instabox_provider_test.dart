import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/sandbox/instabox_provider.dart';
import 'package:focus_launcher/agent/sandbox/sandbox_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  test('creates an ephemeral machine, runs python, and deletes it on close', () async {
    final seen = <http.Request>[];
    final client = MockClient((request) async {
      seen.add(request);
      final path = request.url.path;
      if (request.method == 'POST' && path == '/v1/machines') {
        return _json({'id': 'op-create', 'machineId': 'm1'});
      }
      if (request.method == 'GET' && path.startsWith('/v1/operations/')) {
        return _json({'state': 'succeeded'});
      }
      if (request.method == 'POST' && path == '/v1/machines/m1/exec') {
        return _json({'stdout': '4\n', 'stderr': '', 'exitCode': 0, 'timedOut': false});
      }
      if (request.method == 'DELETE' && path == '/v1/machines/m1') {
        return _json({'id': 'op-delete'});
      }
      return http.Response('unexpected request', 500);
    });
    final provider = InstaboxProvider(
      apiKey: 'ib-test-key',
      client: client,
      pollInterval: Duration.zero,
    );

    final session = await provider.open();
    final result = await session.runPython('print(2 + 2)', timeout: const Duration(seconds: 5));
    expect(result.stdout, '4\n');
    expect(result.exitCode, 0);

    await session.close();
    final delete = seen.singleWhere((r) => r.method == 'DELETE');
    expect(delete.headers['X-Confirm-Delete'], 'm1');
    expect(delete.headers['X-API-Key'], 'ib-test-key');
    expect(seen.any((r) => r.url.path.endsWith('/suspend')), isFalse);
  });

  test('resumes a suspended machine on open and suspends it on close', () async {
    final seen = <http.Request>[];
    final client = MockClient((request) async {
      seen.add(request);
      final path = request.url.path;
      if (request.method == 'GET' && path == '/v1/machines/m1') {
        return _json({'id': 'm1', 'state': 'suspended'});
      }
      if (request.method == 'POST' && path == '/v1/machines/m1/resume') {
        return _json({'id': 'op-resume'});
      }
      if (request.method == 'GET' && path.startsWith('/v1/operations/')) {
        return _json({'state': 'succeeded'});
      }
      if (request.method == 'POST' && path == '/v1/machines/m1/suspend') {
        return _json({'id': 'op-suspend'});
      }
      return http.Response('unexpected request', 500);
    });
    final provider = InstaboxProvider(
      apiKey: 'ib-test-key',
      client: client,
      pollInterval: Duration.zero,
    );

    final session = await provider.open(existingId: 'm1');
    expect(seen.any((r) => r.url.path == '/v1/machines/m1/resume'), isTrue);

    await session.close();
    expect(seen.any((r) => r.url.path == '/v1/machines/m1/suspend'), isTrue);
    expect(seen.any((r) => r.method == 'DELETE'), isFalse);
  });

  test('surfaces a rejected create request and leaves nothing to delete', () async {
    final seen = <http.Request>[];
    final client = MockClient((request) async {
      seen.add(request);
      return _json({'message': 'quota exceeded'}, status: 402);
    });
    final provider = InstaboxProvider(
      apiKey: 'ib-test-key',
      client: client,
      pollInterval: Duration.zero,
    );

    await expectLater(
      provider.open(),
      throwsA(
        isA<SandboxException>().having((e) => e.message, 'message', contains('402')),
      ),
    );
    expect(seen.where((r) => r.method == 'DELETE'), isEmpty);
  });

  test('deletes a machine whose creation operation failed', () async {
    final seen = <http.Request>[];
    final client = MockClient((request) async {
      seen.add(request);
      final path = request.url.path;
      if (request.method == 'POST' && path == '/v1/machines') {
        return _json({'id': 'op-create', 'machineId': 'm2'});
      }
      if (request.method == 'GET' && path == '/v1/operations/op-create') {
        return _json({'state': 'failed', 'error': {'message': 'no capacity'}});
      }
      if (request.method == 'DELETE' && path == '/v1/machines/m2') {
        return _json({'id': 'op-delete'});
      }
      if (request.method == 'GET' && path == '/v1/operations/op-delete') {
        return _json({'state': 'succeeded'});
      }
      return http.Response('unexpected request', 500);
    });
    final provider = InstaboxProvider(
      apiKey: 'ib-test-key',
      client: client,
      pollInterval: Duration.zero,
    );

    await expectLater(provider.open(), throwsA(isA<SandboxException>()));
    expect(seen.any((r) => r.method == 'DELETE' && r.url.path == '/v1/machines/m2'), isTrue);
  });
}
