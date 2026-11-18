// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ModelSearchRequest {
  const ModelSearchRequest({
    required this.id,
    required this.query,
  });

  static ModelSearchRequest deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ModelSearchRequest(
      id: deserializer.deserializeUint32(),
      query: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ModelSearchRequest bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ModelSearchRequest.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final String query;

  ModelSearchRequest copyWith({
    int? id,
    String? query,
  }) {
    return ModelSearchRequest(
      id: id ?? this.id,
      query: query ?? this.query,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeString(query);
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

    return other is ModelSearchRequest
      && id == other.id
      && query == other.query;
  }

  @override
  int get hashCode => Object.hash(
        id,
        query,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'query: $query'
        ')';
      return true;
    }());

    return fullString ?? 'ModelSearchRequest';
  }
}

extension ModelSearchRequestDartSignalExt on ModelSearchRequest {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_model_search_request',
      messageBytes,
      binary,
    );
  }
}
