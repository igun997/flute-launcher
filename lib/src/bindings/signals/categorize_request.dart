// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class CategorizeRequest {
  const CategorizeRequest({
    required this.id,
    required this.apps,
  });

  static CategorizeRequest deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CategorizeRequest(
      id: deserializer.deserializeUint32(),
      apps: TraitHelpers.deserializeVectorAppRow(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CategorizeRequest bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CategorizeRequest.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final List<AppRow> apps;

  CategorizeRequest copyWith({
    int? id,
    List<AppRow>? apps,
  }) {
    return CategorizeRequest(
      id: id ?? this.id,
      apps: apps ?? this.apps,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    TraitHelpers.serializeVectorAppRow(apps, serializer);
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

    return other is CategorizeRequest
      && id == other.id
      && listEquals(apps, other.apps);
  }

  @override
  int get hashCode => Object.hash(
        id,
        apps,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'apps: $apps'
        ')';
      return true;
    }());

    return fullString ?? 'CategorizeRequest';
  }
}

extension CategorizeRequestDartSignalExt on CategorizeRequest {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_categorize_request',
      messageBytes,
      binary,
    );
  }
}
