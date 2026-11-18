// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Captured output is capped at 1 MiB per stream. `error` is empty unless the run could not
/// finish normally (for example a time limit, or the module failed to instantiate).
@immutable
class WasmRunResponse {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _wasmRunResponseStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<WasmRunResponse>? latestRustSignal = null;

  const WasmRunResponse({
    required this.id,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.error,
  });

  static WasmRunResponse deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = WasmRunResponse(
      id: deserializer.deserializeUint32(),
      exitCode: deserializer.deserializeInt32(),
      stdout: deserializer.deserializeString(),
      stderr: deserializer.deserializeString(),
      error: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static WasmRunResponse bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = WasmRunResponse.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final int exitCode;
  final String stdout;
  final String stderr;
  final String error;

  WasmRunResponse copyWith({
    int? id,
    int? exitCode,
    String? stdout,
    String? stderr,
    String? error,
  }) {
    return WasmRunResponse(
      id: id ?? this.id,
      exitCode: exitCode ?? this.exitCode,
      stdout: stdout ?? this.stdout,
      stderr: stderr ?? this.stderr,
      error: error ?? this.error,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeInt32(exitCode);
    serializer.serializeString(stdout);
    serializer.serializeString(stderr);
    serializer.serializeString(error);
    serializer.decreaseContainerDepth();
  }

  Uint8List bincodeSerialize() {
      final serializer = BincodeSerializer();
      serialize(serializer);
      return serializer.bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is WasmRunResponse
      && id == other.id
      && exitCode == other.exitCode
      && stdout == other.stdout
      && stderr == other.stderr
      && error == other.error;
  }

  @override
  int get hashCode => Object.hash(
        id,
        exitCode,
        stdout,
        stderr,
        error,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'exitCode: $exitCode, '
        'stdout: $stdout, '
        'stderr: $stderr, '
        'error: $error'
        ')';
      return true;
    }());

    return fullString ?? 'WasmRunResponse';
  }
}

final _wasmRunResponseStreamController =
    StreamController<RustSignalPack<WasmRunResponse>>();
