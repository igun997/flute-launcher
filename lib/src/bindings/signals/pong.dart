// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class Pong {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _pongStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<Pong>? latestRustSignal = null;

  const Pong({
    required this.id,
  });

  static Pong deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = Pong(
      id: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static Pong bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = Pong.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;

  Pong copyWith({
    int? id,
  }) {
    return Pong(
      id: id ?? this.id,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
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

    return other is Pong
      && id == other.id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id'
        ')';
      return true;
    }());

    return fullString ?? 'Pong';
  }
}

final _pongStreamController =
    StreamController<RustSignalPack<Pong>>();
