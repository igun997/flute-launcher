//! The local Python runtime: a WASI build of CPython run by wasmi. Dart downloads and verifies the
//! module, hands the bytes over once, then asks for runs. Each run gets a fresh instance and its
//! own in-memory stdio, so nothing carries over between runs.

use std::io::{self, Write};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};
use std::time::Instant;

use rinf::{DartSignal, DartSignalBinary, RustSignal};
use tokio::spawn;
use tokio::task::spawn_blocking;
use wasmi::{Config, Engine, Linker, Module, ResourceLimiter, Store, StoreLimits, StoreLimitsBuilder};
use wasmi_wasi::WasiCtx;
use wasmi_wasi::sync::{WasiCtxBuilder, add_to_linker};
use wasmi_wasi::wasi_common::pipe::{ReadPipe, WritePipe};

use crate::signals::{WasmLoadRequest, WasmLoadResponse, WasmRunRequest, WasmRunResponse};

/// Each captured stream stops growing here; the rest is discarded.
const MAX_OUTPUT_BYTES: usize = 1024 * 1024;
const MAX_TIMEOUT_MS: u32 = 300_000;
const MAX_MEMORY_MB: u32 = 512;
/// Rough fuel budget per millisecond. Fuel counts wasm instructions, so this is only approximate.
const FUEL_PER_MS: u64 = 50_000;

static ENGINE: LazyLock<Engine> = LazyLock::new(|| {
  let mut config = Config::default();
  config.consume_fuel(true);
  Engine::new(&config)
});

static MODULE: Mutex<Option<Module>> = Mutex::new(None);

/// Starts the load and run handlers.
pub fn start() {
  spawn(load());
  spawn(run());
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
  mutex.lock().unwrap_or_else(|e| e.into_inner())
}

async fn load() {
  let receiver = WasmLoadRequest::get_dart_signal_receiver();
  while let Some(pack) = receiver.recv().await {
    let id = pack.message.id;
    let bytes = pack.binary;
    spawn_blocking(move || {
      let started = Instant::now();
      let error = match Module::new(&ENGINE, bytes) {
        Ok(module) => {
          *lock(&MODULE) = Some(module);
          String::new()
        }
        Err(err) => {
          *lock(&MODULE) = None;
          err.to_string()
        }
      };
      let elapsed_ms = u32::try_from(started.elapsed().as_millis()).unwrap_or(u32::MAX);
      WasmLoadResponse {
        id,
        error,
        elapsed_ms,
      }
      .send_signal_to_dart();
    });
  }
}

async fn run() {
  let receiver = WasmRunRequest::get_dart_signal_receiver();
  while let Some(pack) = receiver.recv().await {
    let request = pack.message;
    spawn_blocking(move || {
      run_module(&request).send_signal_to_dart();
    });
  }
}

/// Store state: the WASI context and the memory limit for one run.
struct RunState {
  wasi: WasiCtx,
  limits: StoreLimits,
}

/// Collects writes up to `MAX_OUTPUT_BYTES`. Writes past the cap report success so the guest
/// keeps running without an error.
struct Capture(Arc<Mutex<Vec<u8>>>);

impl Write for Capture {
  fn write(&mut self, data: &[u8]) -> io::Result<usize> {
    let mut out = lock(&self.0);
    let room = MAX_OUTPUT_BYTES.saturating_sub(out.len());
    out.extend_from_slice(&data[..data.len().min(room)]);
    Ok(data.len())
  }

  fn flush(&mut self) -> io::Result<()> {
    Ok(())
  }
}

fn run_module(request: &WasmRunRequest) -> WasmRunResponse {
  let id = request.id;
  let failed = |error: String| WasmRunResponse {
    id,
    exit_code: -1,
    stdout: String::new(),
    stderr: String::new(),
    error,
  };

  let Some(module) = lock(&MODULE).clone() else {
    return failed("the WASI runtime is not loaded".to_owned());
  };

  let timeout_ms = request.timeout_ms.clamp(1, MAX_TIMEOUT_MS);
  let max_memory_mb = request.max_memory_mb.clamp(1, MAX_MEMORY_MB);

  let mut env = Vec::with_capacity(request.env.len());
  for entry in &request.env {
    match entry.split_once('=') {
      Some((key, value)) if !key.is_empty() => env.push((key.to_owned(), value.to_owned())),
      _ => return failed("invalid environment entry, expected KEY=VALUE".to_owned()),
    }
  }

  let stdout = Arc::new(Mutex::new(Vec::new()));
  let stderr = Arc::new(Mutex::new(Vec::new()));

  let mut builder = WasiCtxBuilder::new();
  if let Err(err) = builder.args(&request.argv) {
    return failed(err.to_string());
  }
  if let Err(err) = builder.envs(&env) {
    return failed(err.to_string());
  }
  builder.stdin(Box::new(ReadPipe::from(request.stdin.as_bytes().to_vec())));
  builder.stdout(Box::new(WritePipe::new(Capture(Arc::clone(&stdout)))));
  builder.stderr(Box::new(WritePipe::new(Capture(Arc::clone(&stderr)))));
  let wasi = builder.build();

  let limits = StoreLimitsBuilder::new()
    .memory_size((max_memory_mb as usize) << 20)
    .build();
  let mut store = Store::new(&ENGINE, RunState { wasi, limits });
  store.limiter(|state: &mut RunState| -> &mut dyn ResourceLimiter { &mut state.limits });
  if let Err(err) = store.set_fuel(u64::from(timeout_ms) * FUEL_PER_MS) {
    return failed(err.to_string());
  }

  let mut linker: Linker<RunState> = Linker::new(&ENGINE);
  if let Err(err) = add_to_linker(&mut linker, |state: &mut RunState| -> &mut WasiCtx {
    &mut state.wasi
  }) {
    return failed(err.to_string());
  }
  let instance = match linker.instantiate_and_start(&mut store, &module) {
    Ok(instance) => instance,
    Err(err) => return failed(err.to_string()),
  };
  let start = match instance.get_typed_func::<(), ()>(&store, "_start") {
    Ok(start) => start,
    Err(err) => return failed(err.to_string()),
  };

  let (exit_code, error) = match start.call(&mut store, ()) {
    Ok(()) => (0, String::new()),
    Err(err) => match err.i32_exit_status() {
      Some(code) => (code, String::new()),
      None if store.get_fuel().is_ok_and(|fuel| fuel == 0) => {
        (-1, format!("time limit exceeded after {timeout_ms} ms"))
      }
      None => (-1, err.to_string()),
    },
  };

  WasmRunResponse {
    id,
    exit_code,
    stdout: String::from_utf8_lossy(&lock(&stdout)).into_owned(),
    stderr: String::from_utf8_lossy(&lock(&stderr)).into_owned(),
    error,
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  /// Runs only when `FLUTE_PYTHON_WASM` points at the pinned python-3.12.0.wasm.
  #[test]
  fn python_prints_arithmetic() -> Result<(), String> {
    let Ok(path) = std::env::var("FLUTE_PYTHON_WASM") else {
      return Ok(());
    };
    let bytes = std::fs::read(&path).map_err(|err| err.to_string())?;
    let module = Module::new(&ENGINE, bytes).map_err(|err| err.to_string())?;
    *lock(&MODULE) = Some(module);

    let response = run_module(&WasmRunRequest {
      id: 1,
      argv: vec!["python".to_owned(), "-c".to_owned(), "print(1+1)".to_owned()],
      env: Vec::new(),
      stdin: String::new(),
      timeout_ms: MAX_TIMEOUT_MS,
      max_memory_mb: MAX_MEMORY_MB,
    });
    if !response.error.is_empty() {
      return Err(response.error);
    }
    assert_eq!(response.exit_code, 0);
    assert_eq!(response.stdout, "2\n");
    Ok(())
  }
}
