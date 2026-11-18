// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// Per app: the position of the first keyword rule that matched, or 255 for none.
@immutable
class CategorizeResponse {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _categorizeResponseStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<CategorizeResponse>? latestRustSignal = null;

  const CategorizeResponse({
    required this.id,
    required this.rules,
  });

  static CategorizeResponse deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = CategorizeResponse(
      id: deserializer.deserializeUint32(),
      rules: TraitHelpers.deserializeVectorU8(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static CategorizeResponse bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = CategorizeResponse.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final List<int> rules;

  CategorizeResponse copyWith({
    int? id,
    List<int>? rules,
  }) {
    return CategorizeResponse(
      id: id ?? this.id,
      rules: rules ?? this.rules,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    TraitHelpers.serializeVectorU8(rules, serializer);
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

    return other is CategorizeResponse
      && id == other.id
      && listEquals(rules, other.rules);
  }

  @override
  int get hashCode => Object.hash(
        id,
        rules,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'rules: $rules'
        ')';
      return true;
    }());

    return fullString ?? 'CategorizeResponse';
  }
}

final _categorizeResponseStreamController =
    StreamController<RustSignalPack<CategorizeResponse>>();
