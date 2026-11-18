// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Replaces the list Rust searches. Send it once per catalog refresh.
@immutable
class ModelIndexSet {
  const ModelIndexSet({
    required this.id,
    required this.models,
  });

  static ModelIndexSet deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ModelIndexSet(
      id: deserializer.deserializeUint32(),
      models: TraitHelpers.deserializeVectorModelRow(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ModelIndexSet bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ModelIndexSet.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final List<ModelRow> models;

  ModelIndexSet copyWith({
    int? id,
    List<ModelRow>? models,
  }) {
    return ModelIndexSet(
      id: id ?? this.id,
      models: models ?? this.models,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    TraitHelpers.serializeVectorModelRow(models, serializer);
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

    return other is ModelIndexSet
      && id == other.id
      && listEquals(models, other.models);
  }

  @override
  int get hashCode => Object.hash(
        id,
        models,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'models: $models'
        ')';
      return true;
    }());

    return fullString ?? 'ModelIndexSet';
  }
}

extension ModelIndexSetDartSignalExt on ModelIndexSet {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_model_index_set',
      messageBytes,
      binary,
    );
  }
}
