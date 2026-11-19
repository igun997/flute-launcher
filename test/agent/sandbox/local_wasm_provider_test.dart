import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/sandbox/local_wasm_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeRuntime implements WasmRuntime {
  List<String>? argv;
  String? stdin;
  bool? network;
  int loads = 0;

  @override
  Future<void> load(Uint8List module) async => loads++;

  @override
  Future<WasmOutcome> run({
    required List<String> argv,
    required List<String> env,
    required String stdin,
    required int timeoutMs,
    required int maxMemoryMb,
    bool network = false,
  }) async {
    this.argv = argv;
    this.stdin = stdin;
    this.network = network;
    return const WasmOutcome(exitCode: 0, stdout: '2\n', stderr: '', error: '');
  }
}

Future<LocalWasmProvider> _provider(Directory dir, _FakeRuntime runtime, {required bool network}) async {
  // The provider only checks that a file of the pinned size exists before handing it to the runtime.
  final file = File('${dir.path}/python-3.12.0.wasm');
  final raf = await file.open(mode: FileMode.write);
  await raf.truncate(LocalWasmProvider.sizeBytes);
  await raf.close();
  return LocalWasmProvider(
    directory: () async => dir,
    runtime: runtime,
    client: MockClient((_) async => http.Response('', 500)),
    allowNetwork: () => network,
  );
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('flute_wasm'));
  tearDown(() => dir.delete(recursive: true));

  test('the program is passed as -c and stdin stays free for network answers', () async {
    final runtime = _FakeRuntime();
    final session = await (await _provider(dir, runtime, network: true)).open();
    final result = await session.runPython('print(1+1)', timeout: const Duration(seconds: 5));

    expect(runtime.argv, ['python', '-c', 'print(1+1)']);
    expect(runtime.stdin, isEmpty);
    expect(runtime.network, isTrue);
    expect(result.stdout, '2\n');
  });

  test('turning the setting off runs the same program without network', () async {
    final runtime = _FakeRuntime();
    final session = await (await _provider(dir, runtime, network: false)).open();
    await session.runPython('print(1)', timeout: const Duration(seconds: 5));
    expect(runtime.network, isFalse);
  });
}
