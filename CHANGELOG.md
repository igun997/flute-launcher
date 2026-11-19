# Changelog

## 0.2.0

**Not only focus. Boost your productivity, in a lightweight launcher.**

### Assistant
- **Launcher control by chat:** switch mode with a timer, manage schedules, pins, app categories and a few settings. Changes ask first.
- **Routines:** saved prompts that run on a schedule and report by notification, in a list or a month calendar.
- **Voice mode:** talk and it talks back, with a GPU-drawn orb. Approvals work by voice.
- **Web search** (Tavily or Firecrawl) and **tokens per second** readout.
- **Images:** `image_generate` finds the image models of your provider (and other connected providers) by itself; a GPU shader animates the wait.
- **Sandbox:** Python in Instabox, Daytona, or on the phone (WASM, in Rust). Local Python can fetch public web pages; files written to `/out` appear in the chat with open, share and save-to-Downloads.
- **MCP with OAuth**, a **Simular Box** preset (cloud desktop), and `skills add owner/repo`.
- Sign in with ChatGPT or OpenRouter, or bring any OpenAI-compatible gateway.

### Design
- A design system: tonal surfaces, a rationed accent, Inter, shared component themes (`docs/DESIGN.md`).
- Redesigned Ask (greeting, grouped suggestions, one composer dock), a grouped settings hub with sub-pages, an immersive voice page, calmer launcher pages.

### Fixes
- The full-screen picture viewer put small pictures (such as a sandbox chart) in a strip at the top; it now fills the screen and keeps its buttons on the top edge.
- Citation markers that some models leak after a web search are no longer shown.
- Local Python time limit is calibrated per device.
- Pinned `jni` 1.1.2 / `jni_flutter` 1.0.4+1 (1.2.0 crashes at startup).

### Under the hood
- A small Rust core (Rinf) for hashing, unzip, categories and the WASM Python runtime, used only where it measured faster (`docs/PERFORMANCE.md`).

## 0.1.0

First release: the sky-driven home screen, companions, modes, the pause gate, the inbox, the lockscreen and the first version of Ask Flute.
