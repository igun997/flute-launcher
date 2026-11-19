import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../rust/rust_core.dart';
import 'local_net.dart';
import 'sandbox_provider.dart';

/// Outcome of one WASI run, as returned by the Rust runtime.
class WasmOutcome {
  const WasmOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.error,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// Non-empty only when the run could not finish normally (time limit, trap).
  final String error;
}

/// Seam over the Rust WASI runtime so tests can run without the native library.
abstract class WasmRuntime {
  Future<void> load(Uint8List module);

  Future<WasmOutcome> run({
    required List<String> argv,
    required List<String> env,
    required String stdin,
    required int timeoutMs,
    required int maxMemoryMb,
    bool network = false,
  });
}

class RustWasmRuntime implements WasmRuntime {
  RustWasmRuntime({LocalNetBridge? net}) : _net = net ?? LocalNetBridge();

  final LocalNetBridge _net;

  @override
  Future<void> load(Uint8List module) async {
    await RustCore.instance.wasmLoad(module);
  }

  @override
  Future<WasmOutcome> run({
    required List<String> argv,
    required List<String> env,
    required String stdin,
    required int timeoutMs,
    required int maxMemoryMb,
    bool network = false,
  }) async {
    if (network) RustCore.instance.netHandler = _net.handle;
    final r = await RustCore.instance.wasmRun(
      argv: argv,
      env: env,
      stdin: stdin,
      timeoutMs: timeoutMs,
      maxMemoryMb: maxMemoryMb,
      network: network,
    );
    return WasmOutcome(
      exitCode: r.exitCode,
      stdout: r.stdout,
      stderr: r.stderr,
      error: r.error,
    );
  }
}

/// Python 3.12 compiled to WASI, run in-process by the Rust hub. Downloaded on
/// first use from a pinned release; never bundled in the APK. Has no files
/// and no shell: each run gets stdin and env only.
class LocalWasmProvider implements SandboxProvider {
  LocalWasmProvider({
    required this.directory,
    required WasmRuntime runtime,
    required http.Client client,
    Uri? url,
    this.stallTimeout = const Duration(seconds: 60),
    bool Function()? allowNetwork,
  }) : _runtime = runtime,
       _allowNetwork = allowNetwork ?? (() => false),
       _client = client,
       url = url ?? pythonUrl;

  static final pythonUrl = Uri.parse(
    'https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python/3.12.0%2B20231211-040d5a6/python-3.12.0.wasm',
  );
  static const sha256Hex =
      'e5dc5a398b07b54ea8fdb503bf68fb583d533f10ec3f930963e02b9505f7a763';
  static const sizeBytes = 26267204;

  static const _fileName = 'python-3.12.0.wasm';
  static const _runMemoryMb = 256;

  /// Directory the runtime file is stored in (app support dir in the app).
  final Future<Directory> Function() directory;
  final Uri url;
  final Duration stallTimeout;
  final bool Function() _allowNetwork;
  final WasmRuntime _runtime;
  final http.Client _client;

  bool _moduleLoaded = false;

  @override
  String get id => 'local';

  @override
  String get label => 'Local Python';

  @override
  bool get isRemote => false;

  Future<File> _file() async {
    final dir = await directory();
    return File('${dir.path}/$_fileName');
  }

  /// True when the runtime file is present at its pinned size.
  Future<bool> isInstalled() async {
    final file = await _file();
    return await file.exists() && await file.length() == sizeBytes;
  }

  /// Downloads the runtime. Verifies size and SHA-256 before it is installed.
  Future<void> download({void Function(double fraction)? onProgress}) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.part');
    try {
      await _fetchTo(partial, onProgress);
      final size = await partial.length();
      final digest = await sha256.bind(partial.openRead()).first;
      if (size != sizeBytes || digest.toString() != sha256Hex) {
        throw const SandboxException(
          'The downloaded Python runtime failed its integrity check.',
        );
      }
      await partial.rename(file.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<void> _fetchTo(File target, void Function(double)? onProgress) async {
    final http.StreamedResponse response;
    try {
      response = await _client
          .send(http.Request('GET', url))
          .timeout(stallTimeout);
    } on TimeoutException {
      throw const SandboxException('Python download timed out. Check the network.');
    } on http.ClientException {
      throw const SandboxException('Python download failed. Check the network.');
    }
    if (response.statusCode != 200) {
      throw SandboxException(
        'Python download failed with HTTP ${response.statusCode}.',
      );
    }
    var received = 0;
    final out = target.openWrite();
    try {
      await for (final chunk in response.stream.timeout(stallTimeout)) {
        received += chunk.length;
        if (received > sizeBytes) {
          throw const SandboxException('The Python download is larger than expected.');
        }
        out.add(chunk);
        onProgress?.call(received / sizeBytes);
      }
    } on TimeoutException {
      throw const SandboxException('Python download stalled. Check the network.');
    } on http.ClientException {
      throw const SandboxException('Python download was interrupted.');
    } finally {
      await out.close();
    }
  }

  Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  @override
  Future<SandboxSession> open({String? existingId}) async {
    if (existingId != null) {
      throw const SandboxException('The local Python runtime has no saved sandboxes.');
    }
    await _ensureLoaded();
    return _LocalWasmSession(_runtime, network: _allowNetwork());
  }

  /// Loads the module into Rust once per process; Rust keeps it afterwards.
  Future<void> _ensureLoaded() async {
    if (_moduleLoaded) return;
    final file = await _file();
    if (!await file.exists() || await file.length() != sizeBytes) {
      throw const SandboxException(
        'The local Python runtime is not downloaded. Download it in Sandbox settings.',
      );
    }
    final bytes = await file.readAsBytes();
    try {
      await _runtime.load(bytes);
    } on RustException catch (e) {
      throw SandboxException('Could not load the Python runtime: ${e.message}');
    }
    _moduleLoaded = true;
  }
}

class _LocalWasmSession implements SandboxSession {
  _LocalWasmSession(this._runtime, {required this.network});

  final WasmRuntime _runtime;

  /// Public web addresses may be fetched (through the Dart bridge) while the program runs.
  final bool network;
  bool _closed = false;

  @override
  String get label => 'Local Python';

  @override
  Future<ExecResult> runPython(String code, {required Duration timeout}) async {
    if (_closed) throw const SandboxException('The sandbox is closed.');
    final WasmOutcome out;
    try {
      out = await _runtime.run(
        // The program is an argument, not stdin: with networking on, stdin carries the answers.
        argv: ['python', '-c', code],
        env: const ['PYTHONDONTWRITEBYTECODE=1'],
        stdin: '',
        timeoutMs: timeout.inMilliseconds,
        maxMemoryMb: LocalWasmProvider._runMemoryMb,
        network: network,
      );
    } on RustException catch (e) {
      throw SandboxException('Local Python failed: ${e.message}');
    }
    if (out.error.isNotEmpty) {
      if (out.error.startsWith('time limit exceeded')) {
        return ExecResult(
          stdout: out.stdout,
          stderr: out.error,
          exitCode: 124,
          timedOut: true,
        );
      }
      throw SandboxException(out.error);
    }
    return ExecResult(
      stdout: out.stdout,
      stderr: out.stderr,
      exitCode: out.exitCode,
    );
  }

  @override
  Future<ExecResult> runShell(String command, {required Duration timeout}) async {
    throw const SandboxException(
      'Shell commands need a remote sandbox. The local Python runtime has no shell.',
    );
  }

  @override
  Future<void> writeFile(String path, List<int> bytes) async {
    throw const SandboxException(
      'File transfer needs a remote sandbox. The local Python runtime keeps no files.',
    );
  }

  @override
  Future<List<int>> readFile(String path) async {
    throw const SandboxException(
      'File transfer needs a remote sandbox. The local Python runtime keeps no files.',
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
