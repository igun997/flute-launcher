//! Messages between Dart and Rust. `rinf gen` turns these into Dart classes.
//!
//! Every request carries an `id` the reply echoes, so Dart can match answers to calls.

use rinf::{DartSignal, DartSignalBinary, RustSignal, RustSignalBinary, SignalPiece};
use serde::{Deserialize, Serialize};

/// Round trip with nothing in it: measures the cost of crossing the bridge.
#[derive(Deserialize, DartSignal)]
pub struct Ping {
  pub id: u32,
}

#[derive(Serialize, RustSignal)]
pub struct Pong {
  pub id: u32,
}

/// SHA-256 of the attached bytes.
#[derive(Deserialize, DartSignalBinary)]
pub struct Sha256Request {
  pub id: u32,
}

#[derive(Serialize, RustSignal)]
pub struct Sha256Response {
  pub id: u32,
  pub hex: String,
}

/// A zip archive in the attached bytes: unpack its regular files.
#[derive(Deserialize, DartSignalBinary)]
pub struct ArchiveRequest {
  pub id: u32,
  /// Files whose unpacked size exceeds this are refused.
  pub max_total_bytes: u32,
  pub max_files: u32,
}

#[derive(Serialize, SignalPiece)]
pub struct ArchiveEntry {
  pub path: String,
  pub length: u32,
}

/// The attached bytes are the file contents back to back, in `entries` order. Names are exactly
/// as stored in the archive; what to keep, strip or refuse is Dart's call.
#[derive(Serialize, RustSignalBinary)]
pub struct ArchiveResponse {
  pub id: u32,
  /// Empty on success.
  pub error: String,
  /// Regular files.
  pub entries: Vec<ArchiveEntry>,
  /// Symbolic links, which are never unpacked.
  pub symlinks: Vec<String>,
}

/// One piece of a server-sent-event stream (the attached bytes), in order, per `stream`.
#[derive(Deserialize, DartSignalBinary)]
pub struct SseChunk {
  pub id: u32,
  pub stream: u32,
  /// No more bytes will follow for this stream.
  pub last: bool,
}

/// What a chunk produced: the reply text and reasoning in it, plus the final usage when seen.
#[derive(Serialize, RustSignal)]
pub struct SseDelta {
  pub id: u32,
  pub stream: u32,
  pub text: String,
  pub reasoning: String,
  pub completion_tokens: u32,
  pub done: bool,
  /// Set when an event could not be read.
  pub error: String,
}

#[derive(Serialize, Deserialize, SignalPiece)]
pub struct ModelRow {
  pub id: String,
  pub name: String,
  pub owned_by: String,
}

/// Replaces the list Rust searches. Send it once per catalog refresh.
#[derive(Deserialize, DartSignal)]
pub struct ModelIndexSet {
  pub id: u32,
  pub models: Vec<ModelRow>,
}

#[derive(Serialize, RustSignal)]
pub struct ModelIndexReady {
  pub id: u32,
  pub count: u32,
}

#[derive(Deserialize, DartSignal)]
pub struct ModelSearchRequest {
  pub id: u32,
  pub query: String,
}

/// Positions in the list last sent with `ModelIndexSet`, best match first.
#[derive(Serialize, RustSignal)]
pub struct ModelSearchResponse {
  pub id: u32,
  pub indices: Vec<u32>,
}

#[derive(Deserialize, SignalPiece)]
pub struct AppRow {
  pub package: String,
  pub label: String,
}

#[derive(Deserialize, DartSignal)]
pub struct CategorizeRequest {
  pub id: u32,
  pub apps: Vec<AppRow>,
}

/// Per app: the position of the first keyword rule that matched, or 255 for none.
#[derive(Serialize, RustSignal)]
pub struct CategorizeResponse {
  pub id: u32,
  pub rules: Vec<u8>,
}

/// A WASI module (the Python runtime) Dart downloaded, sent as the binary payload.
#[derive(Deserialize, DartSignalBinary)]
pub struct WasmLoadRequest {
  pub id: u32,
}

/// `error` is empty on success. `elapsed_ms` is how long compiling the module took.
#[derive(Serialize, RustSignal)]
pub struct WasmLoadResponse {
  pub id: u32,
  pub error: String,
  pub elapsed_ms: u32,
}

/// Runs the loaded module's `_start` with the given arguments, environment and stdin.
/// Each env entry is `KEY=VALUE`. The timeout and memory cap are clamped on the Rust side.
#[derive(Deserialize, DartSignal)]
pub struct WasmRunRequest {
  pub id: u32,
  pub argv: Vec<String>,
  pub env: Vec<String>,
  pub stdin: String,
  pub timeout_ms: u32,
  pub max_memory_mb: u32,
  /// Lets a `python -c <code>` program reach the network through Dart (see `wasm::NetLink`).
  pub network: bool,
  /// A host directory the program sees as `/out`, read and write. Empty means no files.
  pub files_dir: String,
}

/// Captured output is capped at 1 MiB per stream. `error` is empty unless the run could not
/// finish normally (for example a time limit, or the module failed to instantiate).
#[derive(Serialize, RustSignal)]
pub struct WasmRunResponse {
  pub id: u32,
  pub exit_code: i32,
  pub stdout: String,
  pub stderr: String,
  pub error: String,
}

/// One HTTP request a sandboxed program made. `request` is the JSON line the program wrote
/// (`m` method, `u` url, `h` headers, `b` base64 body). Dart answers with [WasmNetResponse].
#[derive(Serialize, RustSignal)]
pub struct WasmNetRequest {
  pub call: u32,
  pub request: String,
}

/// The answer to one [WasmNetRequest]: one JSON line with `status`, `reason`, `headers`, `body`
/// (base64), or `error`.
#[derive(Deserialize, DartSignal)]
pub struct WasmNetResponse {
  pub call: u32,
  pub response: String,
}
