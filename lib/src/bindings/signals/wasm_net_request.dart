// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One HTTP request a sandboxed program made. `request` is the JSON line the program wrote
/// (`m` method, `u` url, `h` headers, `b` base64 body). Dart answers with [WasmNetResponse].
@immutable
class WasmNetRequest {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _wasmNetRequestStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<WasmNetRequest>? latestRustSignal = null;

  const WasmNetRequest({
    required this.call,
    required this.request,
  });

  static WasmNetRequest deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = WasmNetRequest(
      call: deserializer.deserializeUint32(),
      request: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static WasmNetRequest bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = WasmNetRequest.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int call;
  final String request;

  WasmNetRequest copyWith({
    int? call,
    String? request,
  }) {
    return WasmNetRequest(
      call: call ?? this.call,
      request: request ?? this.request,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(call);
    serializer.serializeString(request);
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

    return other is WasmNetRequest
      && call == other.call
      && request == other.request;
  }

  @override
  int get hashCode => Object.hash(
        call,
        request,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'call: $call, '
        'request: $request'
        ')';
      return true;
    }());

    return fullString ?? 'WasmNetRequest';
  }
}

final _wasmNetRequestStreamController =
    StreamController<RustSignalPack<WasmNetRequest>>();
