// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// SHA-256 of the attached bytes.
@immutable
class Sha256Request {
  const Sha256Request({
    required this.id,
  });

  static Sha256Request deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = Sha256Request(
      id: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static Sha256Request bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = Sha256Request.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;

  Sha256Request copyWith({
    int? id,
  }) {
    return Sha256Request(
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

    return other is Sha256Request
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

    return fullString ?? 'Sha256Request';
  }
}

extension Sha256RequestDartSignalExt on Sha256Request {
  /// Sends the signal to Rust with separate binary data.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust(Uint8List binary) {
    final messageBytes = bincodeSerialize();
    sendDartSignal(
      'rinf_send_dart_signal_sha256_request',
      messageBytes,
      binary,
    );
  }
}
