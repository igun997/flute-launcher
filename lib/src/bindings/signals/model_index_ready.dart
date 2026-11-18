// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ModelIndexReady {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _modelIndexReadyStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<ModelIndexReady>? latestRustSignal = null;

  const ModelIndexReady({
    required this.id,
    required this.count,
  });

  static ModelIndexReady deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ModelIndexReady(
      id: deserializer.deserializeUint32(),
      count: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ModelIndexReady bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ModelIndexReady.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final int count;

  ModelIndexReady copyWith({
    int? id,
    int? count,
  }) {
    return ModelIndexReady(
      id: id ?? this.id,
      count: count ?? this.count,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeUint32(count);
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

    return other is ModelIndexReady
      && id == other.id
      && count == other.count;
  }

  @override
  int get hashCode => Object.hash(
        id,
        count,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'count: $count'
        ')';
      return true;
    }());

    return fullString ?? 'ModelIndexReady';
  }
}

final _modelIndexReadyStreamController =
    StreamController<RustSignalPack<ModelIndexReady>>();
