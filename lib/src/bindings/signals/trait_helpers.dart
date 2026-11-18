// ignore_for_file: type=lint, type=warning
part of 'signals.dart';
class TraitHelpers {
  static void serializeVectorAppRow(List<AppRow> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<AppRow> deserializeVectorAppRow(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => AppRow.deserialize(deserializer));
  }

  static void serializeVectorArchiveEntry(List<ArchiveEntry> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ArchiveEntry> deserializeVectorArchiveEntry(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ArchiveEntry.deserialize(deserializer));
  }

  static void serializeVectorModelRow(List<ModelRow> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        item.serialize(serializer);
    }
  }

  static List<ModelRow> deserializeVectorModelRow(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => ModelRow.deserialize(deserializer));
  }

  static void serializeVectorStr(List<String> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        serializer.serializeString(item);
    }
  }

  static List<String> deserializeVectorStr(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => deserializer.deserializeString());
  }

  static void serializeVectorU32(List<int> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        serializer.serializeUint32(item);
    }
  }

  static List<int> deserializeVectorU32(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => deserializer.deserializeUint32());
  }

  static void serializeVectorU8(List<int> value, BinarySerializer serializer) {
    serializer.serializeLength(value.length);
    for (final item in value) {
        serializer.serializeUint8(item);
    }
  }

  static List<int> deserializeVectorU8(BinaryDeserializer deserializer) {
    final length = deserializer.deserializeLength();
    return List.generate(length, (_) => deserializer.deserializeUint8());
  }

}

