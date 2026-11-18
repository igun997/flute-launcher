// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class ArchiveEntry {
  const ArchiveEntry({
    required this.path,
    required this.length,
  });

  static ArchiveEntry deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ArchiveEntry(
      path: deserializer.deserializeString(),
      length: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ArchiveEntry bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ArchiveEntry.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String path;
  final int length;

  ArchiveEntry copyWith({
    String? path,
    int? length,
  }) {
    return ArchiveEntry(
      path: path ?? this.path,
      length: length ?? this.length,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(path);
    serializer.serializeUint32(length);
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

    return other is ArchiveEntry
      && path == other.path
      && length == other.length;
  }

  @override
  int get hashCode => Object.hash(
        path,
        length,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'path: $path, '
        'length: $length'
        ')';
      return true;
    }());

    return fullString ?? 'ArchiveEntry';
  }
}
