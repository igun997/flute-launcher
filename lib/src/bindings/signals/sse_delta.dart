// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// What a chunk produced: the reply text and reasoning in it, plus the final usage when seen.
@immutable
class SseDelta {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _sseDeltaStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<SseDelta>? latestRustSignal = null;

  const SseDelta({
    required this.id,
    required this.stream,
    required this.text,
    required this.reasoning,
    required this.completionTokens,
    required this.done,
    required this.error,
  });

  static SseDelta deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = SseDelta(
      id: deserializer.deserializeUint32(),
      stream: deserializer.deserializeUint32(),
      text: deserializer.deserializeString(),
      reasoning: deserializer.deserializeString(),
      completionTokens: deserializer.deserializeUint32(),
      done: deserializer.deserializeBool(),
      error: deserializer.deserializeString(),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static SseDelta bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = SseDelta.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final int stream;
  final String text;
  final String reasoning;
  final int completionTokens;
  final bool done;
  final String error;

  SseDelta copyWith({
    int? id,
    int? stream,
    String? text,
    String? reasoning,
    int? completionTokens,
    bool? done,
    String? error,
  }) {
    return SseDelta(
      id: id ?? this.id,
      stream: stream ?? this.stream,
      text: text ?? this.text,
      reasoning: reasoning ?? this.reasoning,
      completionTokens: completionTokens ?? this.completionTokens,
      done: done ?? this.done,
      error: error ?? this.error,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeUint32(stream);
    serializer.serializeString(text);
    serializer.serializeString(reasoning);
    serializer.serializeUint32(completionTokens);
    serializer.serializeBool(done);
    serializer.serializeString(error);
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

    return other is SseDelta
      && id == other.id
      && stream == other.stream
      && text == other.text
      && reasoning == other.reasoning
      && completionTokens == other.completionTokens
      && done == other.done
      && error == other.error;
  }

  @override
  int get hashCode => Object.hash(
        id,
        stream,
        text,
        reasoning,
        completionTokens,
        done,
        error,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'stream: $stream, '
        'text: $text, '
        'reasoning: $reasoning, '
        'completionTokens: $completionTokens, '
        'done: $done, '
        'error: $error'
        ')';
      return true;
    }());

    return fullString ?? 'SseDelta';
  }
}

final _sseDeltaStreamController =
    StreamController<RustSignalPack<SseDelta>>();
