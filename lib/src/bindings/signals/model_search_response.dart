// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Positions in the list last sent with `ModelIndexSet`, best match first.
@immutable
class ModelSearchResponse {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _modelSearchResponseStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<ModelSearchResponse>? latestRustSignal = null;

  const ModelSearchResponse({
    required this.id,
    required this.indices,
  });

  static ModelSearchResponse deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ModelSearchResponse(
      id: deserializer.deserializeUint32(),
      indices: TraitHelpers.deserializeVectorU32(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ModelSearchResponse bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ModelSearchResponse.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final List<int> indices;

  ModelSearchResponse copyWith({
    int? id,
    List<int>? indices,
  }) {
    return ModelSearchResponse(
      id: id ?? this.id,
      indices: indices ?? this.indices,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    TraitHelpers.serializeVectorU32(indices, serializer);
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

    return other is ModelSearchResponse
      && id == other.id
      && listEquals(indices, other.indices);
  }

  @override
  int get hashCode => Object.hash(
        id,
        indices,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'indices: $indices'
        ')';
      return true;
    }());

    return fullString ?? 'ModelSearchResponse';
  }
}

final _modelSearchResponseStreamController =
    StreamController<RustSignalPack<ModelSearchResponse>>();
