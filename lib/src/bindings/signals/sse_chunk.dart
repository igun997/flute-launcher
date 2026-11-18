// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// One piece of a server-sent-event stream (the attached bytes), in order, per `stream`.
@immutable
class SseChunk {
  const SseChunk({
    required this.id,
    required this.stream,
    required this.last,
  });

  static SseChunk deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SseChunk(
      id: deserializer.deserializeUint32(),
      stream: deserializer.deserializeUint32(),
      last: deserializer.deserializeBool(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SseChunk bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SseChunk.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final int stream;
  final bool last;

  SseChunk copyWith({
    int? id,
    int? stream,
    bool? last,
  }) {
    return SseChunk(
      id: id ?? this.id,
      stream: stream ?? this.stream,
      last: last ?? this.last,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeUint32(stream);
    serializer.serializeBool(last);
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

    return other is SseChunk
      && id == other.id
      && stream == other.stream
      && last == other.last;
  }

  @override
  int get hashCode => Object.hash(
        id,
        stream,
        last,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'stream: $stream, '
        'last: $last'
        ')';
      return true;
    }());

    return fullString ?? 'SseChunk';
  }
}

extension SseChunkDartSignalExt on SseChunk {
  /// Sends the signal to Rust with separate binary data.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust(Uint8List binary) {
    final messageBytes = bincodeSerialize();
    sendDartSignal(
      'rinf_send_dart_signal_sse_chunk',
      messageBytes,
      binary,
    );
  }
}
