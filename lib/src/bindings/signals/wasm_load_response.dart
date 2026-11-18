// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// `error` is empty on success. `elapsed_ms` is how long compiling the module took.
@immutable
class WasmLoadResponse {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _wasmLoadResponseStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<WasmLoadResponse>? latestRustSignal = null;

  const WasmLoadResponse({
    required this.id,
    required this.error,
    required this.elapsedMs,
  });

  static WasmLoadResponse deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = WasmLoadResponse(
      id: deserializer.deserializeUint32(),
      error: deserializer.deserializeString(),
      elapsedMs: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static WasmLoadResponse bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = WasmLoadResponse.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final String error;
  final int elapsedMs;

  WasmLoadResponse copyWith({
    int? id,
    String? error,
    int? elapsedMs,
  }) {
    return WasmLoadResponse(
      id: id ?? this.id,
      error: error ?? this.error,
      elapsedMs: elapsedMs ?? this.elapsedMs,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeString(error);
    serializer.serializeUint32(elapsedMs);
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

    return other is WasmLoadResponse
      && id == other.id
      && error == other.error
      && elapsedMs == other.elapsedMs;
  }

  @override
  int get hashCode => Object.hash(
        id,
        error,
        elapsedMs,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'error: $error, '
        'elapsedMs: $elapsedMs'
        ')';
      return true;
    }());

    return fullString ?? 'WasmLoadResponse';
  }
}

final _wasmLoadResponseStreamController =
    StreamController<RustSignalPack<WasmLoadResponse>>();
