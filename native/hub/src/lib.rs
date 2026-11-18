//! The entry point of Flute's Rust side: heavy, CPU-bound jobs Dart hands over through Rinf.

mod jobs;
mod signals;

use rinf::{dart_shutdown, write_interface};

write_interface!();

// A single-thread loop answers messages; CPU-heavy jobs move to the blocking pool (see `jobs`).
#[tokio::main(flavor = "current_thread")]
async fn main() {
  jobs::start();
  // Keep running until Dart shuts the runtime down.
  dart_shutdown().await;
}
