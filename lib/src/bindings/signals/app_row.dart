// ignore_for_file: type=lint, type=warning
part of 'signals.dart';


@immutable
class AppRow {
  const AppRow({
    required this.package,
    required this.label,
  });

  static AppRow deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = AppRow(
      package: deserializer.deserializeString(),
      label: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static AppRow bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = AppRow.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String package;
  final String label;

  AppRow copyWith({
    String? package,
    String? label,
  }) {
    return AppRow(
      package: package ?? this.package,
      label: label ?? this.label,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(package);
    serializer.serializeString(label);
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

    return other is AppRow
      && package == other.package
      && label == other.label;
  }

  @override
  int get hashCode => Object.hash(
        package,
        label,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'package: $package, '
        'label: $label'
        ')';
      return true;
    }());

    return fullString ?? 'AppRow';
  }
}
