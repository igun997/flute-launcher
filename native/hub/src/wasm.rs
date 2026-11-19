//! The local Python runtime: a WASI build of CPython run by wasmi. Dart downloads and verifies the
//! module, hands the bytes over once, then asks for runs. Each run gets a fresh instance and its
//! own in-memory stdio, so nothing carries over between runs.

use std::io::{self, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};
use std::time::Instant;

use rinf::{DartSignal, DartSignalBinary, RustSignal};
use tokio::spawn;
use tokio::task::spawn_blocking;
use wasmi::{
  Config, Engine, Linker, Module, ResourceLimiter, Store, StoreLimits, StoreLimitsBuilder, TrapCode,
};
use wasmi_wasi::WasiCtx;
use wasmi_wasi::sync::{WasiCtxBuilder, add_to_linker};
use wasmi_wasi::wasi_common::pipe::{ReadPipe, WritePipe};

use crate::signals::{WasmLoadRequest, WasmLoadResponse, WasmRunRequest, WasmRunResponse};

/// Each captured stream stops growing here; the rest is discarded.
const MAX_OUTPUT_BYTES: usize = 1024 * 1024;
const MAX_TIMEOUT_MS: u32 = 300_000;
const MAX_MEMORY_MB: u32 = 512;
/// Fuel per millisecond until the device is measured. Fuel is not a unit of time (CPython needs
/// billions of units to start, in under a second on a laptop), so `load` measures it on this device.
const DEFAULT_FUEL_PER_MS: u64 = 1_000_000;
/// The measuring run may use this much fuel before it is cut off.
const CALIBRATION_FUEL: u64 = 100_000_000_000;
/// Measured rates outside this range are not believed.
const FUEL_PER_MS_RANGE: (u64, u64) = (50_000, 100_000_000);

static FUEL_PER_MS: AtomicU64 = AtomicU64::new(DEFAULT_FUEL_PER_MS);

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
          calibrate();
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

/// A small loop of ordinary work. Fuel per millisecond differs by workload (starting the
/// interpreter is about half as fuel-hungry per millisecond as a compute loop), so measuring a
/// loop keeps the limit on the safe, early side for real scripts.
const CALIBRATION_PROGRAM: &str = "x = 0\nfor i in range(10000): x += i * i";

/// Runs a short Python program to learn how much fuel one millisecond is on this device.
fn calibrate() {
  let request = WasmRunRequest {
    id: 0,
    argv: vec!["python".to_owned(), "-c".to_owned(), CALIBRATION_PROGRAM.to_owned()],
    env: Vec::new(),
    stdin: String::new(),
    timeout_ms: MAX_TIMEOUT_MS,
    max_memory_mb: MAX_MEMORY_MB,
  };
  let mut used = 0;
  let started = Instant::now();
  let response = run_with(&request, CALIBRATION_FUEL, &mut used);
  let elapsed_ms = started.elapsed().as_millis();
  if !response.error.is_empty() || response.exit_code != 0 || elapsed_ms == 0 {
    return;
  }
  let rate = u64::try_from(u128::from(used) / elapsed_ms).unwrap_or(u64::MAX);
  if (FUEL_PER_MS_RANGE.0..=FUEL_PER_MS_RANGE.1).contains(&rate) {
    FUEL_PER_MS.store(rate, Ordering::Relaxed);
  }
}

fn run_module(request: &WasmRunRequest) -> WasmRunResponse {
  let timeout_ms = request.timeout_ms.clamp(1, MAX_TIMEOUT_MS);
  let fuel = u64::from(timeout_ms).saturating_mul(FUEL_PER_MS.load(Ordering::Relaxed));
  run_with(request, fuel, &mut 0)
}

/// One run with `fuel` units to spend. `used` receives the fuel the guest consumed.
fn run_with(request: &WasmRunRequest, fuel: u64, used: &mut u64) -> WasmRunResponse {
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
  if let Err(err) = store.set_fuel(fuel) {
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
      None if err.as_trap_code() == Some(TrapCode::OutOfFuel) => {
        (-1, format!("time limit exceeded after {timeout_ms} ms"))
      }
      None => (-1, err.to_string()),
    },
  };
  *used = fuel.saturating_sub(store.get_fuel().unwrap_or(0));

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

  /// Loads the pinned python-3.12.0.wasm named by `FLUTE_PYTHON_WASM`. None skips the test.
  fn load_python() -> Result<Option<()>, String> {
    let Ok(path) = std::env::var("FLUTE_PYTHON_WASM") else {
      return Ok(None);
    };
    let bytes = std::fs::read(&path).map_err(|err| err.to_string())?;
    let module = Module::new(&ENGINE, bytes).map_err(|err| err.to_string())?;
    *lock(&MODULE) = Some(module);
    calibrate();
    Ok(Some(()))
  }

  fn python(code: &str, timeout_ms: u32) -> WasmRunResponse {
    run_module(&WasmRunRequest {
      id: 1,
      argv: vec!["python".to_owned(), "-c".to_owned(), code.to_owned()],
      env: Vec::new(),
      stdin: String::new(),
      timeout_ms,
      max_memory_mb: MAX_MEMORY_MB,
    })
  }

  #[test]
  fn python_prints_arithmetic() -> Result<(), String> {
    if load_python()?.is_none() {
      return Ok(());
    }
    let response = python("print(1+1)", 30_000);
    if !response.error.is_empty() {
      return Err(response.error);
    }
    assert_eq!(response.exit_code, 0);
    assert_eq!(response.stdout, "2\n");
    Ok(())
  }

  #[test]
  fn a_runaway_loop_stops_near_the_time_limit() -> Result<(), String> {
    if load_python()?.is_none() {
      return Ok(());
    }
    let started = Instant::now();
    let response = python("while True: pass", 3_000);
    let took = started.elapsed();
    assert_eq!(response.exit_code, -1);
    assert!(response.error.contains("time limit exceeded"), "{}", response.error);
    // The limit is measured in work, not seconds: a bare `while True: pass` burns fuel several
    // times faster per millisecond than the calibration loop, so it stops early, never late.
    assert!(took.as_millis() > 200 && took.as_millis() < 12_000, "took {took:?}");
    Ok(())
  }
}
