// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Runs the loaded module's `_start` with the given arguments, environment and stdin.
/// Each env entry is `KEY=VALUE`. The timeout and memory cap are clamped on the Rust side.
@immutable
class WasmRunRequest {
  const WasmRunRequest({
    required this.id,
    required this.argv,
    required this.env,
    required this.stdin,
    required this.timeoutMs,
    required this.maxMemoryMb,
    required this.network,
  });

  static WasmRunRequest deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = WasmRunRequest(
      id: deserializer.deserializeUint32(),
      argv: TraitHelpers.deserializeVectorStr(deserializer),
      env: TraitHelpers.deserializeVectorStr(deserializer),
      stdin: deserializer.deserializeString(),
      timeoutMs: deserializer.deserializeUint32(),
      maxMemoryMb: deserializer.deserializeUint32(),
      network: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static WasmRunRequest bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = WasmRunRequest.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final List<String> argv;
  final List<String> env;
  final String stdin;
  final int timeoutMs;
  final int maxMemoryMb;
  final bool network;

  WasmRunRequest copyWith({
    int? id,
    List<String>? argv,
    List<String>? env,
    String? stdin,
    int? timeoutMs,
    int? maxMemoryMb,
    bool? network,
  }) {
    return WasmRunRequest(
      id: id ?? this.id,
      argv: argv ?? this.argv,
      env: env ?? this.env,
      stdin: stdin ?? this.stdin,
      timeoutMs: timeoutMs ?? this.timeoutMs,
      maxMemoryMb: maxMemoryMb ?? this.maxMemoryMb,
      network: network ?? this.network,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    TraitHelpers.serializeVectorStr(argv, serializer);
    TraitHelpers.serializeVectorStr(env, serializer);
    serializer.serializeString(stdin);
    serializer.serializeUint32(timeoutMs);
    serializer.serializeUint32(maxMemoryMb);
    serializer.serializeBool(network);
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

    return other is WasmRunRequest
      && id == other.id
      && listEquals(argv, other.argv)
      && listEquals(env, other.env)
      && stdin == other.stdin
      && timeoutMs == other.timeoutMs
      && maxMemoryMb == other.maxMemoryMb
      && network == other.network;
  }

  @override
  int get hashCode => Object.hash(
        id,
        argv,
        env,
        stdin,
        timeoutMs,
        maxMemoryMb,
        network,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'argv: $argv, '
        'env: $env, '
        'stdin: $stdin, '
        'timeoutMs: $timeoutMs, '
        'maxMemoryMb: $maxMemoryMb, '
        'network: $network'
        ')';
      return true;
    }());

    return fullString ?? 'WasmRunRequest';
  }
}

extension WasmRunRequestDartSignalExt on WasmRunRequest {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_wasm_run_request',
      messageBytes,
      binary,
    );
  }
}
