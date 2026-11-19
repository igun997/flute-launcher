import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rinf/rinf.dart';

import '../agent/llm/model_info.dart';
import '../src/bindings/bindings.dart';

/// What came back from [RustCore.unzip]: regular files with their stored names (contents are views
/// into one buffer) and the names of symbolic links, which are never unpacked.
class UnzippedFiles {
  UnzippedFiles(this.files, this.symlinks);
  final Map<String, Uint8List> files;
  final Set<String> symlinks;
}

class RustException implements Exception {
  const RustException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Calls into the Rust side (native/hub). Every call is a request signal with an id, answered by
/// a response signal with the same id; nothing here blocks the UI isolate while Rust works.
///
/// Call [start] once, after `initializeRust`. Without it every call throws, so a missing setup
/// is loud, never a silent fallback.
class RustCore {
  RustCore._();
  static final RustCore instance = RustCore._();

  final _pending = <int, Completer<Object>>{};
  final _sseListeners = <int, void Function(SseDelta)>{};
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Answers the HTTP requests a networked local Python run makes (one JSON line in, one out).
  /// Without it every request gets an error answer.
  Future<String> Function(String request)? netHandler;
  int _nextId = 1;
  int _nextStream = 1;
  bool _started = false;

  bool get isStarted => _started;

  void start() {
    if (_started) return;
    _started = true;
    _listen<Pong>(Pong.rustSignalStream, (m) => m.id);
    _listen<Sha256Response>(Sha256Response.rustSignalStream, (m) => m.id);
    _listen<ModelIndexReady>(ModelIndexReady.rustSignalStream, (m) => m.id);
    _listen<ModelSearchResponse>(ModelSearchResponse.rustSignalStream, (m) => m.id);
    _listen<CategorizeResponse>(CategorizeResponse.rustSignalStream, (m) => m.id);
    _listen<WasmLoadResponse>(WasmLoadResponse.rustSignalStream, (m) => m.id);
    _listen<WasmRunResponse>(WasmRunResponse.rustSignalStream, (m) => m.id);
    _subscriptions.add(WasmNetRequest.rustSignalStream.listen((pack) async {
      final handler = netHandler;
      String reply;
      if (handler == null) {
        reply = jsonEncode({'error': 'network is not available'});
      } else {
        try {
          reply = await handler(pack.message.request);
        } catch (_) {
          reply = jsonEncode({'error': 'the network request failed'});
        }
      }
      WasmNetResponse(call: pack.message.call, response: reply).sendSignalToRust();
    }));
    _subscriptions.add(ArchiveResponse.rustSignalStream.listen((pack) {
      _pending.remove(pack.message.id)?.complete(pack);
    }));
    _subscriptions.add(SseDelta.rustSignalStream.listen((pack) {
      _sseListeners[pack.message.stream]?.call(pack.message);
    }));
  }

  /// Hands one response type to whoever is waiting on its id.
  void _listen<T>(Stream<RustSignalPack<T>> stream, int Function(T) idOf) {
    _subscriptions.add(stream.listen((pack) => _pending.remove(idOf(pack.message))?.complete(pack.message as Object)));
  }

  Future<T> _call<T extends Object>(int id, void Function() send) {
    if (!_started) throw StateError('RustCore.start() was not called.');
    final completer = Completer<Object>();
    _pending[id] = completer;
    send();
    return completer.future.then((v) => v as T);
  }

  /// A round trip with nothing in it: the cost of crossing the bridge.
  Future<void> ping() {
    final id = _nextId++;
    return _call<Pong>(id, () => Ping(id: id).sendSignalToRust());
  }

  Future<String> sha256(Uint8List data) async {
    final id = _nextId++;
    final r = await _call<Sha256Response>(id, () => Sha256Request(id: id).sendSignalToRust(data));
    return r.hex;
  }

  /// Unpacks a zip off the UI isolate; names are as stored in the archive. Throws [RustException] for damaged, unsafe or oversized archives.
  Future<UnzippedFiles> unzip(Uint8List zip, {int maxTotalBytes = 25 * 1024 * 1024, int maxFiles = 1000}) async {
    final id = _nextId++;
    final pack = await _call<RustSignalPack<ArchiveResponse>>(
      id,
      () => ArchiveRequest(id: id, maxTotalBytes: maxTotalBytes, maxFiles: maxFiles).sendSignalToRust(zip),
    );
    final r = pack.message;
    if (r.error.isNotEmpty) throw RustException(r.error);
    final files = <String, Uint8List>{};
    var offset = 0;
    for (final e in r.entries) {
      files[e.path] = Uint8List.sublistView(pack.binary, offset, offset + e.length);
      offset += e.length;
    }
    return UnzippedFiles(files, r.symlinks.toSet());
  }

  /// Feeds [bytes] of one event stream to Rust. [onDelta] gets what each chunk produced, in order,
  /// and a final delta with `done` set once [last] was sent. Chunks are not awaited one by one.
  int openSse(void Function(SseDelta delta) onDelta) {
    final stream = _nextStream++;
    _sseListeners[stream] = (d) {
      onDelta(d);
      if (d.done) _sseListeners.remove(stream);
    };
    return stream;
  }

  void feedSse(int stream, Uint8List bytes, {bool last = false}) {
    if (!_started) throw StateError('RustCore.start() was not called.');
    SseChunk(id: _nextId++, stream: stream, last: last).sendSignalToRust(bytes);
  }

  /// Replaces the model list Rust searches. Resolves with how many rows it holds.
  Future<int> setModels(List<ModelInfo> models) async {
    final id = _nextId++;
    final r = await _call<ModelIndexReady>(
      id,
      () => ModelIndexSet(
        id: id,
        models: [for (final m in models) ModelRow(id: m.id, name: m.name, ownedBy: m.ownedBy ?? '')],
      ).sendSignalToRust(),
    );
    return r.count;
  }

  /// Positions in the list last given to [setModels], best match first.
  Future<List<int>> searchModels(String query) async {
    final id = _nextId++;
    final r = await _call<ModelSearchResponse>(id, () => ModelSearchRequest(id: id, query: query).sendSignalToRust());
    return r.indices;
  }

  /// Per app, the index of the first keyword rule that matched or 255. See `CategoryEngine`.
  Future<List<int>> categorize(List<(String, String)> apps) async {
    final id = _nextId++;
    final r = await _call<CategorizeResponse>(
      id,
      () => CategorizeRequest(id: id, apps: [for (final (p, l) in apps) AppRow(package: p, label: l)]).sendSignalToRust(),
    );
    return r.rules;
  }

  /// Loads the WASI module [wasmRun] executes, replacing any loaded before. Resolves with how long Rust took to compile it.
  Future<int> wasmLoad(Uint8List module) async {
    final id = _nextId++;
    final r = await _call<WasmLoadResponse>(id, () => WasmLoadRequest(id: id).sendSignalToRust(module));
    if (r.error.isNotEmpty) throw RustException(r.error);
    return r.elapsedMs;
  }

  /// Runs the loaded module in a fresh instance. The response carries its own `error` (empty on success) and exit code.
  Future<WasmRunResponse> wasmRun({
    required List<String> argv,
    required List<String> env,
    required String stdin,
    required int timeoutMs,
    required int maxMemoryMb,
    bool network = false,
    String filesDir = '',
  }) {
    final id = _nextId++;
    return _call<WasmRunResponse>(
      id,
      () => WasmRunRequest(
        id: id,
        argv: argv,
        env: env,
        stdin: stdin,
        timeoutMs: timeoutMs,
        maxMemoryMb: maxMemoryMb,
        network: network,
        filesDir: filesDir,
      ).sendSignalToRust(),
    );
  }

  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _pending.clear();
    _sseListeners.clear();
    _started = false;
  }
}
