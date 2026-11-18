// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// A zip archive in the attached bytes: unpack its regular files.
@immutable
class ArchiveRequest {
  const ArchiveRequest({
    required this.id,
    required this.maxTotalBytes,
    required this.maxFiles,
  });

  static ArchiveRequest deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ArchiveRequest(
      id: deserializer.deserializeUint32(),
      maxTotalBytes: deserializer.deserializeUint32(),
      maxFiles: deserializer.deserializeUint32(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ArchiveRequest bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ArchiveRequest.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final int maxTotalBytes;
  final int maxFiles;

  ArchiveRequest copyWith({
    int? id,
    int? maxTotalBytes,
    int? maxFiles,
  }) {
    return ArchiveRequest(
      id: id ?? this.id,
      maxTotalBytes: maxTotalBytes ?? this.maxTotalBytes,
      maxFiles: maxFiles ?? this.maxFiles,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeUint32(maxTotalBytes);
    serializer.serializeUint32(maxFiles);
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

    return other is ArchiveRequest
      && id == other.id
      && maxTotalBytes == other.maxTotalBytes
      && maxFiles == other.maxFiles;
  }

  @override
  int get hashCode => Object.hash(
        id,
        maxTotalBytes,
        maxFiles,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'maxTotalBytes: $maxTotalBytes, '
        'maxFiles: $maxFiles'
        ')';
      return true;
    }());

    return fullString ?? 'ArchiveRequest';
  }
}

extension ArchiveRequestDartSignalExt on ArchiveRequest {
  /// Sends the signal to Rust with separate binary data.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust(Uint8List binary) {
    final messageBytes = bincodeSerialize();
    sendDartSignal(
      'rinf_send_dart_signal_archive_request',
      messageBytes,
      binary,
    );
  }
}
