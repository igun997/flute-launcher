// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The answer to one [WasmNetRequest]: one JSON line with `status`, `reason`, `headers`, `body`
/// (base64), or `error`.
@immutable
class WasmNetResponse {
  const WasmNetResponse({
    required this.call,
    required this.response,
  });

  static WasmNetResponse deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = WasmNetResponse(
      call: deserializer.deserializeUint32(),
      response: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static WasmNetResponse bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = WasmNetResponse.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int call;
  final String response;

  WasmNetResponse copyWith({
    int? call,
    String? response,
  }) {
    return WasmNetResponse(
      call: call ?? this.call,
      response: response ?? this.response,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(call);
    serializer.serializeString(response);
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

    return other is WasmNetResponse
      && call == other.call
      && response == other.response;
  }

  @override
  int get hashCode => Object.hash(
        call,
        response,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'call: $call, '
        'response: $response'
        ')';
      return true;
    }());

    return fullString ?? 'WasmNetResponse';
  }
}

extension WasmNetResponseDartSignalExt on WasmNetResponse {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_wasm_net_response',
      messageBytes,
      binary,
    );
  }
}
