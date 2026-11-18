# Performance: Dart vs the Rust core

Flute has a small Rust crate (`native/hub`) connected through [Rinf](https://github.com/cunarist/rinf).
It was added after measuring, not before: the same jobs were timed in Dart first, and only the ones
that were slow on a mid-range phone were moved.

## How it was measured

- Phone: Samsung Galaxy A22 (SM-A225F, MediaTek, 4 GB), Android 13, **release** build (AOT).
- Each job runs once to warm up, then 7 times; the table shows the **median**. A checksum from both
  implementations must match, so a fast but wrong answer cannot pass.
- Rust numbers include everything the app pays: copying the input across the bridge, the work on a
  background thread, and getting the answer back. Dart numbers run on the UI isolate.
- Re-run it yourself: Settings, scroll to the bottom, **long-press the version text**. Results go
  to the screen and to the log (`adb logcat -s flutter | grep BENCH`). Code: `lib/dev/benchmarks.dart`.

## Results

| Job | Dart | Rust | Faster |
|---|---:|---:|---:|
| SHA-256 of 5 MB | 144.7 ms | 11.0 ms | **13x** |
| Unzip 300 files (about 6 MB) and hash them | 280.5 ms | 65.2 ms | **4.3x** |
| Categorize 3000 apps by keyword rules | 149.4 ms | 30.4 ms | **4.9x** |
| 6 searches over 5000 models (index already in Rust) | 37.8 ms | 10.4 ms | **3.6x** |
| Parse a 4000-event chat stream, 1 KB chunks, pipelined | 36.9 ms | 25.0 ms | 1.5x |
| Same stream as one buffer | 36.9 ms | 19.5 ms | 1.9x |
| Send 5000 models to Rust (once per refresh) | n/a | 73.5 ms | cost, not a gain |
| Empty round trip Dart to Rust and back | n/a | 0.15 ms each | the bridge itself |

An earlier run showed the one-buffer stream at 160 ms: the first Rust version shifted its buffer for
every event (quadratic). The benchmark caught it and it was fixed; the table is after the fix.

## What moved and what did not

Moved, because the gain is large and the work is real:

- **Skill install** (`npx skills`-style): unzip and SHA-256 now run in Rust (`SkillArchiveBackend`).
  Checked on the phone by installing a real skill from GitHub through the chat command.
- **App categories** at launcher start and refresh: one batch to Rust (`CategoryEngine.categorizeAll`).

Kept in Dart, on purpose:

- **Model search.** Rust is 3.6x faster on 5000 models, but real gateways list 200 to 300, where
  Dart takes about 1 ms. Sending the list costs more than the saving. The Rust search exists and is
  tested (`RustCore.searchModels`) for catalogs that are actually large.
- **Chat stream parsing.** 1.5x to 1.9x on a 4000-event reply, which is a very long answer. A normal
  reply is a few hundred events, so the saving is a couple of milliseconds, below what the screen
  can show.
- **Everything network-bound** (gateway, MCP, OAuth, weather, mail): time goes to the network, and
  Rust would add a bridge crossing for no gain.
- **UI, pets, sky**: already on the GPU (`drawAtlas`, fragment shaders).

## Where Rust is not used, and why

Measured on the same phone: one call across the bridge costs about **0.15 ms**. Work that Dart does
in microseconds loses that on every call, so it stays in Dart:

- Turning one streamed chat event into text: about 9 microseconds in Dart.
- Converting a line of Markdown to speakable text for voice mode: microseconds.
- Pet simulation (one pet, 12 ticks a second) and the next-fire maths for routines: far below a frame.

**GPU work stays on the GPU.** Sprites are drawn with `drawAtlas` and the sky, the window glow and the
voice orb are fragment shaders. Rust runs on the CPU and cannot draw faster than the GPU does.

Rust is used where it is the right tool: hashing and unzip (13x and 4x), categories (5x), search and,
for the sandbox, a WASI interpreter (`wasmi`) that runs Python on the phone with a fuel limit, a memory cap
and no network.

## Costs

- APK (arm64): about +4 MB for the Rust library with the WASM runtime (34.7 MB before the Rust core, 39.9 MB now, which also includes the voice, routines and sandbox code).
- Build: needs a Rust toolchain and the Android targets; first build compiles the crate (about 1 min on a
  4-core box), later builds are cached.
- Rinf's README says the project is looking for a new maintainer. The Rust side is small and isolated
  behind `RustCore`, and every Rust path has a Dart fallback, so it can be removed without touching callers.
- If the Rust library fails to load, the launcher still starts and uses the Dart code (see `lib/main.dart`).
