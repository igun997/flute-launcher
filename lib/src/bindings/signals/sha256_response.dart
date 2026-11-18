// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class Sha256Response {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _sha256ResponseStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<Sha256Response>? latestRustSignal = null;

  const Sha256Response({
    required this.id,
    required this.hex,
  });

  static Sha256Response deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = Sha256Response(
      id: deserializer.deserializeUint32(),
      hex: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static Sha256Response bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = Sha256Response.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final String hex;

  Sha256Response copyWith({
    int? id,
    String? hex,
  }) {
    return Sha256Response(
      id: id ?? this.id,
      hex: hex ?? this.hex,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeString(hex);
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

    return other is Sha256Response
      && id == other.id
      && hex == other.hex;
  }

  @override
  int get hashCode => Object.hash(
        id,
        hex,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'hex: $hex'
        ')';
      return true;
    }());

    return fullString ?? 'Sha256Response';
  }
}

final _sha256ResponseStreamController =
    StreamController<RustSignalPack<Sha256Response>>();
