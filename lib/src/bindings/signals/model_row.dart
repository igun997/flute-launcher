// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ModelRow {
  const ModelRow({
    required this.id,
    required this.name,
    required this.ownedBy,
  });

  static ModelRow deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ModelRow(
      id: deserializer.deserializeString(),
      name: deserializer.deserializeString(),
      ownedBy: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ModelRow bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ModelRow.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String id;
  final String name;
  final String ownedBy;

  ModelRow copyWith({
    String? id,
    String? name,
    String? ownedBy,
  }) {
    return ModelRow(
      id: id ?? this.id,
      name: name ?? this.name,
      ownedBy: ownedBy ?? this.ownedBy,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(id);
    serializer.serializeString(name);
    serializer.serializeString(ownedBy);
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

    return other is ModelRow
      && id == other.id
      && name == other.name
      && ownedBy == other.ownedBy;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        ownedBy,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'name: $name, '
        'ownedBy: $ownedBy'
        ')';
      return true;
    }());

    return fullString ?? 'ModelRow';
  }
}
