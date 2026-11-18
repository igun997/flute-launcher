part of 'signals.dart';

final assignRustSignal = <String, void Function(Uint8List, Uint8List)>{
  'ArchiveResponse': (Uint8List messageBytes, Uint8List binary) {
    final message = ArchiveResponse.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _archiveResponseStreamController.add(rustSignal);
    ArchiveResponse.latestRustSignal = rustSignal;
  },
  'CategorizeResponse': (Uint8List messageBytes, Uint8List binary) {
    final message = CategorizeResponse.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _categorizeResponseStreamController.add(rustSignal);
    CategorizeResponse.latestRustSignal = rustSignal;
  },
  'ModelIndexReady': (Uint8List messageBytes, Uint8List binary) {
    final message = ModelIndexReady.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _modelIndexReadyStreamController.add(rustSignal);
    ModelIndexReady.latestRustSignal = rustSignal;
  },
  'ModelSearchResponse': (Uint8List messageBytes, Uint8List binary) {
    final message = ModelSearchResponse.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _modelSearchResponseStreamController.add(rustSignal);
    ModelSearchResponse.latestRustSignal = rustSignal;
  },
  'Pong': (Uint8List messageBytes, Uint8List binary) {
    final message = Pong.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _pongStreamController.add(rustSignal);
    Pong.latestRustSignal = rustSignal;
  },
  'Sha256Response': (Uint8List messageBytes, Uint8List binary) {
    final message = Sha256Response.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _sha256ResponseStreamController.add(rustSignal);
    Sha256Response.latestRustSignal = rustSignal;
  },
  'SseDelta': (Uint8List messageBytes, Uint8List binary) {
    final message = SseDelta.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _sseDeltaStreamController.add(rustSignal);
    SseDelta.latestRustSignal = rustSignal;
  },
  'WasmLoadResponse': (Uint8List messageBytes, Uint8List binary) {
    final message = WasmLoadResponse.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _wasmLoadResponseStreamController.add(rustSignal);
    WasmLoadResponse.latestRustSignal = rustSignal;
  },
  'WasmRunResponse': (Uint8List messageBytes, Uint8List binary) {
    final message = WasmRunResponse.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(
      message,
      binary,
    );
    _wasmRunResponseStreamController.add(rustSignal);
    WasmRunResponse.latestRustSignal = rustSignal;
  },
};
