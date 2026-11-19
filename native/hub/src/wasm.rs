//! The local Python runtime: a WASI build of CPython run by wasmi. Dart downloads and verifies the
//! module, hands the bytes over once, then asks for runs. Each run gets a fresh instance and its
//! own in-memory stdio, so nothing carries over between runs.

use std::collections::{HashMap, VecDeque};
use std::io::{self, Read, Write};
use std::sync::mpsc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use rinf::{DartSignal, DartSignalBinary, RustSignal};
use tokio::spawn;
use tokio::task::spawn_blocking;
use wasmi::{
  Config, Engine, Linker, Module, ResourceLimiter, Store, StoreLimits, StoreLimitsBuilder, TrapCode,
};
use wasmi_wasi::WasiCtx;
use wasmi_wasi::sync::{WasiCtxBuilder, add_to_linker};
use wasmi_wasi::wasi_common::pipe::{ReadPipe, WritePipe};

use crate::signals::{
  WasmLoadRequest, WasmLoadResponse, WasmNetRequest, WasmNetResponse, WasmRunRequest, WasmRunResponse,
};

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
  spawn(net_replies());
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

// ---- network bridge -------------------------------------------------------------------------
//
// WASI has no sockets. With `network` on, a program's standard HTTP client is swapped for one that
// writes each request to stdout as a marked line and reads the answer from stdin (`net_shim.py`).
// The request goes to Dart, which owns the network and the safety rules, and the reply is fed back.

/// Prefix of a stdout line that is a request, not program output.
const NET_MARKER: &[u8] = b"\x01FLUTE-NET ";
const NET_SHIM: &str = include_str!("net_shim.py");
/// A run may make this many requests.
const MAX_NET_CALLS: u32 = 100;
/// How long one request may wait for Dart's answer.
const NET_WAIT: Duration = Duration::from_secs(90);
/// An unmarked partial line longer than this is flushed as output without waiting for a newline.
const MAX_PARTIAL_LINE: usize = 64 * 1024;

/// Turns a request line into its reply line. Production sends it to Dart; tests answer directly.
type NetFn = Arc<dyn Fn(&str) -> String + Send + Sync>;

static NET_CALL_ID: AtomicU32 = AtomicU32::new(1);
static NET_WAITING: LazyLock<Mutex<HashMap<u32, mpsc::Sender<String>>>> =
  LazyLock::new(|| Mutex::new(HashMap::new()));

fn net_error(message: &str) -> String {
  serde_json::json!({ "error": message }).to_string()
}

/// Sends one request to Dart and waits for the answer (blocking; runs on the blocking pool).
fn ask_dart(request: &str) -> String {
  let call = NET_CALL_ID.fetch_add(1, Ordering::Relaxed);
  let (sender, receiver) = mpsc::channel();
  lock(&NET_WAITING).insert(call, sender);
  WasmNetRequest { call, request: request.to_owned() }.send_signal_to_dart();
  let reply = receiver.recv_timeout(NET_WAIT);
  lock(&NET_WAITING).remove(&call);
  reply.unwrap_or_else(|_| net_error("the network request timed out"))
}

async fn net_replies() {
  let receiver = WasmNetResponse::get_dart_signal_receiver();
  while let Some(pack) = receiver.recv().await {
    let WasmNetResponse { call, response } = pack.message;
    if let Some(sender) = lock(&NET_WAITING).get(&call) {
      let _ = sender.send(response);
    }
  }
}

/// State shared by the stdout filter and the stdin source of one run.
struct NetLink {
  net: NetFn,
  stdout: Arc<Mutex<Vec<u8>>>,
  /// Output seen so far that does not yet end in a newline.
  partial: Mutex<Vec<u8>>,
  /// Request lines waiting for the program to read their answer.
  pending: Mutex<VecDeque<String>>,
  /// Answer bytes the program has not read yet.
  reply: Mutex<VecDeque<u8>>,
  calls: AtomicU32,
}

impl NetLink {
  fn new(net: NetFn, stdout: Arc<Mutex<Vec<u8>>>) -> Self {
    Self {
      net,
      stdout,
      partial: Mutex::new(Vec::new()),
      pending: Mutex::new(VecDeque::new()),
      reply: Mutex::new(VecDeque::new()),
      calls: AtomicU32::new(0),
    }
  }

  fn emit(&self, bytes: &[u8]) {
    let mut out = lock(&self.stdout);
    let room = MAX_OUTPUT_BYTES.saturating_sub(out.len());
    out.extend_from_slice(&bytes[..bytes.len().min(room)]);
  }

  /// Splits program output into request lines (kept for stdin) and everything else (captured).
  fn filter(&self, data: &[u8]) {
    let mut partial = lock(&self.partial);
    partial.extend_from_slice(data);
    while let Some(end) = partial.iter().position(|&b| b == b'\n') {
      let line: Vec<u8> = partial.drain(..=end).collect();
      match line.strip_prefix(NET_MARKER) {
        Some(request) => {
          let text = String::from_utf8_lossy(request).trim_end().to_owned();
          lock(&self.pending).push_back(text);
        }
        None => self.emit(&line),
      }
    }
    let could_be_request = NET_MARKER.starts_with(&partial) || partial.starts_with(NET_MARKER);
    if partial.len() > MAX_PARTIAL_LINE && !could_be_request {
      let rest: Vec<u8> = partial.drain(..).collect();
      self.emit(&rest);
    }
  }

  /// Output that never got its newline when the program ended.
  fn finish(&self) {
    let rest: Vec<u8> = lock(&self.partial).drain(..).collect();
    if !rest.starts_with(NET_MARKER) {
      self.emit(&rest);
    }
  }

  fn answer_next(&self) -> bool {
    let Some(request) = lock(&self.pending).pop_front() else {
      return false;
    };
    let calls = self.calls.fetch_add(1, Ordering::Relaxed) + 1;
    let reply = if calls > MAX_NET_CALLS {
      net_error("too many network requests in one run")
    } else {
      (self.net)(&request)
    };
    let mut queue = lock(&self.reply);
    queue.extend(reply.replace('\n', " ").bytes());
    queue.push_back(b'\n');
    true
  }
}

struct NetOut(Arc<NetLink>);

impl Write for NetOut {
  fn write(&mut self, data: &[u8]) -> io::Result<usize> {
    self.0.filter(data);
    Ok(data.len())
  }

  fn flush(&mut self) -> io::Result<()> {
    Ok(())
  }
}

struct NetIn(Arc<NetLink>);

impl Read for NetIn {
  fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
    loop {
      {
        let mut queue = lock(&self.0.reply);
        if !queue.is_empty() {
          let n = buf.len().min(queue.len());
          for slot in &mut buf[..n] {
            *slot = queue.pop_front().unwrap_or_default();
          }
          return Ok(n);
        }
      }
      if !self.0.answer_next() {
        return Ok(0);
      }
    }
  }
}

/// `python -c <code>` becomes `python -c <boot> <code>`; anything else is left alone.
fn with_network_boot(argv: &[String]) -> Vec<String> {
  let mut out = argv.to_vec();
  if let Some(i) = out.iter().position(|a| a == "-c")
    && i + 1 < out.len()
  {
    out.insert(i + 1, NET_SHIM.to_owned());
  }
  out
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
    network: false,
  };
  let mut used = 0;
  let started = Instant::now();
  let response = run_with(&request, CALIBRATION_FUEL, &mut used, None);
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
  let net: Option<NetFn> = request.network.then(|| Arc::new(ask_dart) as NetFn);
  run_with(request, fuel, &mut 0, net)
}

/// One run with `fuel` units to spend. `used` receives the fuel the guest consumed.
fn run_with(
  request: &WasmRunRequest,
  fuel: u64,
  used: &mut u64,
  net: Option<NetFn>,
) -> WasmRunResponse {
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
  // Program input is used for the network answers, so networking needs stdin to be free.
  let link = match net {
    Some(net) if request.stdin.is_empty() => Some(Arc::new(NetLink::new(net, Arc::clone(&stdout)))),
    _ => None,
  };
  let argv = if link.is_some() { with_network_boot(&request.argv) } else { request.argv.clone() };
  if let Err(err) = builder.args(&argv) {
    return failed(err.to_string());
  }
  if let Err(err) = builder.envs(&env) {
    return failed(err.to_string());
  }
  match &link {
    Some(link) => {
      builder.stdin(Box::new(ReadPipe::new(NetIn(Arc::clone(link)))));
      builder.stdout(Box::new(WritePipe::new(NetOut(Arc::clone(link)))));
    }
    None => {
      builder.stdin(Box::new(ReadPipe::from(request.stdin.as_bytes().to_vec())));
      builder.stdout(Box::new(WritePipe::new(Capture(Arc::clone(&stdout)))));
    }
  }
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
  if let Some(link) = &link {
    link.finish();
  }

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
      network: false,
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

  fn python_with_net(code: &str, net: NetFn) -> WasmRunResponse {
    let request = WasmRunRequest {
      id: 1,
      argv: vec!["python".to_owned(), "-c".to_owned(), code.to_owned()],
      env: Vec::new(),
      stdin: String::new(),
      timeout_ms: 60_000,
      max_memory_mb: MAX_MEMORY_MB,
      network: true,
    };
    let fuel = 60_000 * FUEL_PER_MS.load(Ordering::Relaxed);
    run_with(&request, fuel, &mut 0, Some(net))
  }

  /// A host that answers every request with a fixed page and remembers what it was asked.
  fn fake_host(seen: Arc<Mutex<Vec<String>>>) -> NetFn {
    Arc::new(move |request: &str| {
      lock(&seen).push(request.to_owned());
      serde_json::json!({
        "status": 200,
        "reason": "OK",
        "headers": { "content-type": "text/plain", "x-from": "host" },
        "body": "aGVsbG8gZnJvbSB0aGUgaG9zdA==",
      })
      .to_string()
    })
  }

  #[test]
  fn urllib_fetches_through_the_host_and_output_stays_clean() -> Result<(), String> {
    if load_python()?.is_none() {
      return Ok(());
    }
    let seen = Arc::new(Mutex::new(Vec::new()));
    let code = "import urllib.request\n\
      r = urllib.request.urlopen('https://example.test/a?b=1')\n\
      print(r.status, r.headers['x-from'], r.read().decode())\n\
      print(sum(range(10)))\n";
    let response = python_with_net(code, fake_host(Arc::clone(&seen)));
    assert!(response.error.is_empty(), "{}", response.error);
    assert_eq!(response.exit_code, 0, "{}", response.stderr);
    assert_eq!(response.stdout, "200 host hello from the host\n45\n");
    let requests = lock(&seen);
    assert_eq!(requests.len(), 1);
    assert!(requests[0].contains("\"https://example.test/a?b=1\""), "{}", requests[0]);
    assert!(requests[0].contains("\"GET\""), "{}", requests[0]);
    Ok(())
  }

  #[test]
  fn a_post_body_and_a_failed_host_reach_the_program() -> Result<(), String> {
    if load_python()?.is_none() {
      return Ok(());
    }
    let seen = Arc::new(Mutex::new(Vec::new()));
    let seen_in = Arc::clone(&seen);
    let net: NetFn = Arc::new(move |request: &str| {
      lock(&seen_in).push(request.to_owned());
      if request.contains("fail.test") {
        net_error("blocked address")
      } else {
        serde_json::json!({ "status": 201, "reason": "Created", "headers": {}, "body": "" }).to_string()
      }
    });
    let code = "import urllib.request, urllib.error\n\
      r = urllib.request.urlopen(urllib.request.Request('http://ok.test/p', data=b'x=1', method='POST'))\n\
      print(r.status)\n\
      try:\n    urllib.request.urlopen('http://fail.test/')\n\
      except urllib.error.URLError as e:\n    print('failed:', e.reason)\n";
    let response = python_with_net(code, net);
    assert_eq!(response.exit_code, 0, "{}", response.stderr);
    assert_eq!(response.stdout, "201\nfailed: blocked address\n");
    assert!(lock(&seen)[0].contains("eD0x"), "the body is base64");
    Ok(())
  }

  #[test]
  fn plain_output_that_looks_like_nothing_special_is_untouched() {
    let out = Arc::new(Mutex::new(Vec::new()));
    let link = NetLink::new(Arc::new(|_| String::new()), Arc::clone(&out));
    link.filter(b"no newline");
    link.filter(b" yet\nsecond\n");
    link.filter(b"tail");
    link.finish();
    assert_eq!(String::from_utf8_lossy(&lock(&out)), "no newline yet\nsecond\ntail");
  }
}
