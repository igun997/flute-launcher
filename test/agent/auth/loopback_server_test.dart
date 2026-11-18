import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/loopback_server.dart';

import 'test_support.dart';

void main() {
  test('the first request to the callback path resolves the wait with its query', () async {
    final server = await LoopbackServer.start(path: '/auth/callback');
    addTearDown(server.close);
    final waiting = server.waitForCallback(timeout: const Duration(seconds: 10));
    await followRedirect(server.redirectUri(), {'code': 'abc', 'state': 'xyz'});
    expect(await waiting, {'code': 'abc', 'state': 'xyz'});
  });

  test('requests to other paths get a 404 and leave the wait open', () async {
    final server = await LoopbackServer.start(path: '/auth/callback');
    addTearDown(server.close);
    final waiting = server.waitForCallback(timeout: const Duration(seconds: 10));
    await followRedirect(server.redirectUri().replace(path: '/favicon.ico'), {'x': '1'});
    await followRedirect(server.redirectUri(), {'code': 'abc'});
    expect(await waiting, {'code': 'abc'});
  });

  test('the redirect URI uses the bound port, the requested host and the path', () async {
    final server = await LoopbackServer.start(path: '/callback');
    addTearDown(server.close);
    expect(server.redirectUri().toString(), 'http://127.0.0.1:${server.port}/callback');
    expect(server.redirectUri(host: 'localhost').toString(),
        'http://localhost:${server.port}/callback');
  });

  test('the wait times out when no redirect arrives', () async {
    final server = await LoopbackServer.start();
    addTearDown(server.close);
    await expectLater(
      server.waitForCallback(timeout: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('closing the listener ends a pending wait', () async {
    final server = await LoopbackServer.start();
    final outcome = server
        .waitForCallback(timeout: const Duration(seconds: 10))
        .then<Object?>((value) => value, onError: (Object error) => error);
    await server.close();
    expect(await outcome, isA<StateError>());
  });
}
