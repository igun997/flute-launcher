// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Round trip with nothing in it: measures the cost of crossing the bridge.
@immutable
class Ping {
  const Ping({
    required this.id,
  });

  static Ping deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = Ping(
      id: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static Ping bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = Ping.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;

  Ping copyWith({
    int? id,
  }) {
    return Ping(
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

    return other is Ping
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

    return fullString ?? 'Ping';
  }
}

extension PingDartSignalExt on Ping {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_ping',
      messageBytes,
      binary,
    );
  }
}
