//! The work Dart hands to Rust. Each handler loops on one request type; CPU-heavy ones run on the
//! blocking pool so the message loop keeps answering.

use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::sync::{Arc, LazyLock, Mutex};

use regex::RegexSet;
use rinf::{DartSignal, DartSignalBinary, RustSignal, RustSignalBinary};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::spawn;
use tokio::task::spawn_blocking;

use crate::signals::{
  AppRow, ArchiveEntry, ArchiveRequest, ArchiveResponse, CategorizeRequest, CategorizeResponse,
  ModelIndexReady, ModelIndexSet, ModelRow, ModelSearchRequest, ModelSearchResponse, Ping, Pong,
  Sha256Request, Sha256Response, SseChunk, SseDelta,
};

/// Starts every handler. Returns when they have all been spawned.
pub fn start() {
  spawn(ping());
  spawn(sha256());
  spawn(archive());
  spawn(sse());
  spawn(models());
  spawn(categorize());
}

async fn ping() {
  let receiver = Ping::get_dart_signal_receiver();
  while let Some(pack) = receiver.recv().await {
    Pong { id: pack.message.id }.send_signal_to_dart();
  }
}

// ---- SHA-256 ----

async fn sha256() {
  let receiver = Sha256Request::get_dart_signal_receiver();
  while let Some(pack) = receiver.recv().await {
    let id = pack.message.id;
    let bytes = pack.binary;
    spawn_blocking(move || {
      let hex = to_hex(&Sha256::digest(&bytes));
      Sha256Response { id, hex }.send_signal_to_dart();
    });
  }
}

fn to_hex(bytes: &[u8]) -> String {
  const DIGITS: &[u8; 16] = b"0123456789abcdef";
  let mut out = String::with_capacity(bytes.len() * 2);
  for b in bytes {
    out.push(DIGITS[(b >> 4) as usize] as char);
    out.push(DIGITS[(b & 15) as usize] as char);
  }
  out
}

// ---- zip ----

async fn archive() {
  let receiver = ArchiveRequest::get_dart_signal_receiver();
  while let Some(pack) = receiver.recv().await {
    let request = pack.message;
    let bytes = pack.binary;
    spawn_blocking(move || {
      let (entries, symlinks, contents, error) = match unpack(&bytes, &request) {
        Ok(unpacked) => {
          let mut entries = Vec::with_capacity(unpacked.files.len());
          let mut contents = Vec::with_capacity(unpacked.total as usize);
          for (path, data) in unpacked.files {
            entries.push(ArchiveEntry { path, length: data.len() as u32 });
            contents.extend_from_slice(&data);
          }
          (entries, unpacked.symlinks, contents, String::new())
        }
        Err(message) => (Vec::new(), Vec::new(), Vec::new(), message),
      };
      ArchiveResponse { id: request.id, error, entries, symlinks }.send_signal_to_dart(contents);
    });
  }
}

struct Unpacked {
  files: Vec<(String, Vec<u8>)>,
  symlinks: Vec<String>,
  total: u64,
}

/// Regular files with their stored names, in archive order. Directories are skipped, symbolic
/// links are listed but not read. Refuses too many files, too many bytes, and paths that climb out.
fn unpack(bytes: &[u8], request: &ArchiveRequest) -> Result<Unpacked, String> {
  let mut archive =
    zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| "Not a readable zip file.".to_string())?;
  if archive.len() as u32 > request.max_files {
    return Err("The archive has too many files.".to_string());
  }
  let mut files: Vec<(String, Vec<u8>)> = Vec::with_capacity(archive.len());
  let mut symlinks = Vec::new();
  let mut total: u64 = 0;
  for i in 0..archive.len() {
    let mut file = archive.by_index(i).map_err(|_| "A file in the archive is damaged.".to_string())?;
    let path = file
      .name()
      .map_err(|_| "A file name in the archive is not valid.".to_string())?
      .into_owned();
    if path.starts_with('/') || path.split(['/', '\\']).any(|part| part == "..") {
      return Err("The archive has an unsafe path.".to_string());
    }
    if file.is_symlink() {
      symlinks.push(path);
      continue;
    }
    if file.is_dir() {
      continue;
    }
    total += file.size();
    if total > u64::from(request.max_total_bytes) {
      return Err("The archive unpacks to more than the allowed size.".to_string());
    }
    let mut data = Vec::with_capacity(file.size() as usize);
    file
      .by_ref()
      .take(u64::from(request.max_total_bytes) + 1)
      .read_to_end(&mut data)
      .map_err(|_| "A file in the archive is damaged.".to_string())?;
    files.push((path, data));
  }
  Ok(Unpacked { files, symlinks, total })
}

// ---- server-sent events ----

#[derive(Default)]
struct SseState {
  buffer: Vec<u8>,
}

async fn sse() {
  let receiver = SseChunk::get_dart_signal_receiver();
  let mut streams: HashMap<u32, SseState> = HashMap::new();
  while let Some(pack) = receiver.recv().await {
    let chunk = pack.message;
    let state = streams.entry(chunk.stream).or_default();
    state.buffer.extend_from_slice(&pack.binary);
    let mut out = SseDelta {
      id: chunk.id,
      stream: chunk.stream,
      text: String::new(),
      reasoning: String::new(),
      completion_tokens: 0,
      done: false,
      error: String::new(),
    };
    drain_events(&mut state.buffer, |event| apply_event(event, &mut out));
    if chunk.last {
      // A final event without its blank line still counts.
      let rest = std::mem::take(&mut state.buffer);
      if !rest.is_empty() {
        apply_event(&rest, &mut out);
      }
      out.done = true;
      streams.remove(&chunk.stream);
    }
    out.send_signal_to_dart();
  }
}

/// Calls `on_event` for every complete event (up to a blank line) in `buffer` and removes them,
/// leaving only the unfinished tail. One pass: the buffer is not shifted per event.
fn drain_events(buffer: &mut Vec<u8>, mut on_event: impl FnMut(&[u8])) {
  let mut start = 0;
  let mut i = 0;
  while i < buffer.len() {
    if buffer[i] == b'\n' {
      let rest = &buffer[i + 1..];
      let end = if rest.starts_with(b"\n") {
        Some(i + 2)
      } else if rest.starts_with(b"\r\n") {
        Some(i + 3)
      } else {
        None
      };
      if let Some(end) = end {
        let mut event = &buffer[start..i];
        if event.last() == Some(&b'\r') {
          event = &event[..event.len() - 1];
        }
        on_event(event);
        start = end;
        i = end;
        continue;
      }
    }
    i += 1;
  }
  buffer.drain(..start);
}

fn apply_event(raw: &[u8], out: &mut SseDelta) {
  let text = String::from_utf8_lossy(raw);
  let mut data = String::new();
  for line in text.split('\n') {
    let line = line.strip_suffix('\r').unwrap_or(line);
    if let Some(value) = line.strip_prefix("data:") {
      if !data.is_empty() {
        data.push('\n');
      }
      data.push_str(value.strip_prefix(' ').unwrap_or(value));
    }
  }
  if data.is_empty() || data == "[DONE]" {
    return;
  }
  let json: Value = match serde_json::from_str(&data) {
    Ok(v) => v,
    Err(_) => {
      out.error = "An event was not valid JSON.".to_string();
      return;
    }
  };
  if let Some(delta) = json.pointer("/choices/0/delta") {
    if let Some(s) = delta.get("content").and_then(Value::as_str) {
      out.text.push_str(s);
    }
    for key in ["reasoning_content", "reasoning"] {
      if let Some(s) = delta.get(key).and_then(Value::as_str) {
        out.reasoning.push_str(s);
      }
    }
  }
  if let Some(tokens) = json.pointer("/usage/completion_tokens").and_then(Value::as_u64) {
    out.completion_tokens = tokens as u32;
  }
}

// ---- model search ----

struct Indexed {
  id: String,
  id_lower: String,
  name_lower: String,
  owned_lower: String,
}

/// The list the last `ModelIndexSet` sent; searches work on a cheap shared snapshot of it.
static INDEX: LazyLock<Mutex<Arc<Vec<Indexed>>>> = LazyLock::new(|| Mutex::new(Arc::new(Vec::new())));

async fn models() {
  spawn(async {
    let receiver = ModelIndexSet::get_dart_signal_receiver();
    while let Some(pack) = receiver.recv().await {
      let rows: Vec<Indexed> = pack.message.models.into_iter().map(indexed).collect();
      let count = rows.len() as u32;
      if let Ok(mut slot) = INDEX.lock() {
        *slot = Arc::new(rows);
      }
      ModelIndexReady { id: pack.message.id, count }.send_signal_to_dart();
    }
  });
  let receiver = ModelSearchRequest::get_dart_signal_receiver();
  while let Some(pack) = receiver.recv().await {
    let rows = match INDEX.lock() {
      Ok(slot) => Arc::clone(&slot),
      Err(_) => Arc::new(Vec::new()),
    };
    let request = pack.message;
    let indices = search(&rows, &request.query);
    ModelSearchResponse { id: request.id, indices }.send_signal_to_dart();
  }
}

fn indexed(row: ModelRow) -> Indexed {
  Indexed {
    id_lower: row.id.to_lowercase(),
    name_lower: row.name.to_lowercase(),
    owned_lower: row.owned_by.to_lowercase(),
    id: row.id,
  }
}

/// Every whitespace-separated token must occur in the id, name or owner. Ranked by whether the
/// id starts with the query, contains it, or only the name does; then by name, then id.
fn search(rows: &[Indexed], query: &str) -> Vec<u32> {
  let q = query.trim().to_lowercase().split_whitespace().collect::<Vec<_>>().join(" ");
  if q.is_empty() {
    return (0..rows.len() as u32).collect();
  }
  let tokens: Vec<&str> = q.split(' ').collect();
  let mut hits: Vec<(u8, usize)> = Vec::new();
  for (i, row) in rows.iter().enumerate() {
    let all = tokens.iter().all(|t| {
      row.id_lower.contains(t) || row.name_lower.contains(t) || row.owned_lower.contains(t)
    });
    if !all {
      continue;
    }
    let tier = if row.id_lower.starts_with(&q) {
      0
    } else if row.id_lower.contains(&q) {
      1
    } else if row.name_lower.contains(&q) {
      2
    } else {
      3
    };
    hits.push((tier, i));
  }
  hits.sort_by(|a, b| {
    let (ra, rb) = (&rows[a.1], &rows[b.1]);
    a.0
      .cmp(&b.0)
      .then_with(|| ra.name_lower.cmp(&rb.name_lower))
      .then_with(|| ra.id.cmp(&rb.id))
  });
  hits.into_iter().map(|(_, i)| i as u32).collect()
}

// ---- app categories ----

/// Same order as `CategoryEngine._keywords` in Dart; the answer is the position in this list.
const KEYWORD_RULES: [&str; 9] = [
  r"bank|wallet|\bpay\b|payment|finance|invest|crypto|broker|insurance|dana|ovo|gopay|jago|jenius",
  r"whatsapp|telegram|messag|messenger|\bsms\b|signal|discord|\bchat\b|dialer|\bphone\b",
  r"instagram|facebook|twitter|tiktok|snapchat|reddit|threads|linkedin|pinterest",
  r"game|\bplay games\b|roblox|minecraft",
  r"music|video|player|podcast|stream|netflix|youtube|spotify|news|radio|tv\b",
  r"shop|store|market|mall|ecommerce|food|delivery",
  r"map|travel|taxi|ride|flight|hotel|train|transit|navigation",
  r"office|docs|sheet|slides|calendar|mail|meet|zoom|teams|notion|drive|\bnotes?\b|task|todo|slack|lark|github",
  r"camera|gallery|photo|file|calculator|clock|setting|browser|chrome|keyboard|weather|vpn|security|launcher",
];

/// One pass over the text finds every rule that matches; the lowest index wins.
static RULES: LazyLock<Option<RegexSet>> = LazyLock::new(|| RegexSet::new(KEYWORD_RULES).ok());

async fn categorize() {
  let receiver = CategorizeRequest::get_dart_signal_receiver();
  while let Some(pack) = receiver.recv().await {
    let request = pack.message;
    spawn_blocking(move || {
      let rules = classify(&request.apps);
      CategorizeResponse { id: request.id, rules }.send_signal_to_dart();
    });
  }
}

fn classify(apps: &[AppRow]) -> Vec<u8> {
  let Some(set) = RULES.as_ref() else {
    return vec![255; apps.len()];
  };
  let mut hay = String::new();
  apps
    .iter()
    .map(|app| {
      hay.clear();
      hay.push_str(&app.package);
      hay.push(' ');
      hay.push_str(&app.label);
      let lowered = hay.to_lowercase();
      set.matches(&lowered).iter().next().map_or(255, |p| p as u8)
    })
    .collect()
}

#[cfg(test)]
mod tests {
  use super::*;

  fn row(id: &str, name: &str, owner: &str) -> Indexed {
    indexed(ModelRow { id: id.into(), name: name.into(), owned_by: owner.into() })
  }

  #[test]
  fn sha256_matches_the_known_vector() {
    assert_eq!(
      to_hex(&Sha256::digest(b"abc")),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
  }

  #[test]
  fn search_ranks_prefix_before_contains_and_needs_every_token() {
    let rows = vec![
      row("openai/gpt-5", "GPT 5", "openai"),
      row("cx/gpt-6", "GPT 6", "cx"),
      row("cx/other", "gpt thing", "cx"),
    ];
    assert_eq!(search(&rows, "cx"), vec![1, 2]);
    assert_eq!(search(&rows, "cx gpt"), vec![1, 2]);
    assert_eq!(search(&rows, "gpt-6"), vec![1]);
    assert!(search(&rows, "zzz").is_empty());
    assert_eq!(search(&rows, "  ").len(), 3);
  }

  #[test]
  fn events_split_across_chunks_are_reassembled() {
    let mut buffer = b"data: {\"a\":1}\n\ndata: {\"b\"".to_vec();
    let mut seen: Vec<Vec<u8>> = Vec::new();
    drain_events(&mut buffer, |e| seen.push(e.to_vec()));
    assert_eq!(seen, vec![b"data: {\"a\":1}".to_vec()]);
    assert_eq!(buffer, b"data: {\"b\"".to_vec());
    buffer.extend_from_slice(b":2}\r\n\r\n");
    drain_events(&mut buffer, |e| seen.push(e.to_vec()));
    assert_eq!(seen[1], b"data: {\"b\":2}".to_vec());
    assert!(buffer.is_empty());
  }

  #[test]
  fn a_delta_event_yields_text_and_usage() {
    let mut out = SseDelta {
      id: 0,
      stream: 0,
      text: String::new(),
      reasoning: String::new(),
      completion_tokens: 0,
      done: false,
      error: String::new(),
    };
    apply_event(b"data: {\"choices\":[{\"delta\":{\"content\":\"hi \"}}]}", &mut out);
    apply_event(b"data: {\"choices\":[],\"usage\":{\"completion_tokens\":7}}", &mut out);
    apply_event(b"data: [DONE]", &mut out);
    assert_eq!((out.text.as_str(), out.completion_tokens, out.error.as_str()), ("hi ", 7, ""));
  }

  fn zip_of(files: &[(&str, &[u8])]) -> Vec<u8> {
    use std::io::Write;
    let mut out = Cursor::new(Vec::new());
    {
      let mut writer = zip::ZipWriter::new(&mut out);
      for (name, data) in files {
        writer.start_file(*name, zip::write::SimpleFileOptions::default()).unwrap();
        writer.write_all(data).unwrap();
      }
      writer.finish().unwrap();
    }
    out.into_inner()
  }

  fn request(max_total_bytes: u32, max_files: u32) -> ArchiveRequest {
    ArchiveRequest { id: 1, max_total_bytes, max_files }
  }

  #[test]
  fn an_archive_is_unpacked_with_its_stored_names() {
    let zip = zip_of(&[("repo-abc/skills/a/SKILL.md", b"hello"), ("repo-abc/readme.md", b"hi")]);
    let u = unpack(&zip, &request(1000, 10)).unwrap();
    let names: Vec<_> = u.files.iter().map(|f| f.0.as_str()).collect();
    assert_eq!(names, vec!["repo-abc/skills/a/SKILL.md", "repo-abc/readme.md"]);
    assert_eq!(u.files[0].1, b"hello");
    assert_eq!(u.total, 7);
  }

  #[test]
  fn limits_and_unsafe_paths_are_refused() {
    let big = zip_of(&[("a.txt", &[7u8; 600]), ("b.txt", &[7u8; 600])]);
    assert!(unpack(&big, &request(1000, 10)).is_err());
    assert!(unpack(&big, &request(5000, 1)).is_err());
    let climbing = zip_of(&[("x/../../evil", b"no")]);
    assert!(unpack(&climbing, &request(1000, 10)).is_err());
    assert!(unpack(b"not a zip", &request(1000, 10)).is_err());
  }

  #[test]
  fn categories_follow_the_first_matching_rule() {
    let apps = vec![
      AppRow { package: "id.co.bank".into(), label: "My Bank".into() },
      AppRow { package: "com.x.whatsapp".into(), label: "Chat".into() },
      AppRow { package: "a.b.c".into(), label: "zzz".into() },
    ];
    assert_eq!(classify(&apps), vec![0, 1, 255]);
  }
}
