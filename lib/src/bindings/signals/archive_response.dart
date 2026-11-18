// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

/// The attached bytes are the file contents back to back, in `entries` order. Names are exactly
/// as stored in the archive; what to keep, strip or refuse is Dart's call.
@immutable
class ArchiveResponse {
  /// An async broadcast stream that listens for signals from Rust.
  /// It supports multiple subscriptions.
  /// Make sure to cancel the subscription when it's no longer needed,
  /// such as when a widget is disposed.
  static final rustSignalStream =
      _archiveResponseStreamController.stream.asBroadcastStream();
        
  /// The latest signal value received from Rust.
  /// This is updated every time a new signal is received.
  /// It can be null if no signals have been received yet.
  static RustSignalPack<ArchiveResponse>? latestRustSignal = null;

  const ArchiveResponse({
    required this.id,
    required this.error,
    required this.entries,
    required this.symlinks,
  });

  static ArchiveResponse deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ArchiveResponse(
      id: deserializer.deserializeUint32(),
      error: deserializer.deserializeString(),
      entries: TraitHelpers.deserializeVectorArchiveEntry(deserializer),
      symlinks: TraitHelpers.deserializeVectorStr(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ArchiveResponse bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ArchiveResponse.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final int id;
  final String error;
  final List<ArchiveEntry> entries;
  final List<String> symlinks;

  ArchiveResponse copyWith({
    int? id,
    String? error,
    List<ArchiveEntry>? entries,
    List<String>? symlinks,
  }) {
    return ArchiveResponse(
      id: id ?? this.id,
      error: error ?? this.error,
      entries: entries ?? this.entries,
      symlinks: symlinks ?? this.symlinks,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeUint32(id);
    serializer.serializeString(error);
    TraitHelpers.serializeVectorArchiveEntry(entries, serializer);
    TraitHelpers.serializeVectorStr(symlinks, serializer);
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

    return other is ArchiveResponse
      && id == other.id
      && error == other.error
      && listEquals(entries, other.entries)
      && listEquals(symlinks, other.symlinks);
  }

  @override
  int get hashCode => Object.hash(
        id,
        error,
        entries,
        symlinks,
      );

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString = '$runtimeType('
        'id: $id, '
        'error: $error, '
        'entries: $entries, '
        'symlinks: $symlinks'
        ')';
      return true;
    }());

    return fullString ?? 'ArchiveResponse';
  }
}

final _archiveResponseStreamController =
    StreamController<RustSignalPack<ArchiveResponse>>();
