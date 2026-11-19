# Flute

A calm, text-first Android home screen that **understands your apps**. Flute sorts what you have installed into categories (Banking, Work, Chat, Social, Media, Games, Shopping, Travel, Tools), lets you switch between **modes** that decide what is shown or paused, and puts a small animated companion on the home screen that follows the weather and your bedtime.

[![Nightly](https://github.com/igun997/flute-launcher/actions/workflows/nightly.yml/badge.svg)](https://github.com/igun997/flute-launcher/actions/workflows/nightly.yml)
[![Latest release](https://img.shields.io/github/v/release/igun997/flute-launcher?label=release)](https://github.com/igun997/flute-launcher/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

![Flute: day, dusk, rain, sleep mode and the mode sheet](docs/screenshots/hero.png)

> Flutter UI with a small Kotlin layer. Android 7.0+ (API 24). English only. No account, no ads, no analytics.

## Download

| Channel | What it is | Get it |
|---|---|---|
| **Release** | Tagged, tested builds. Use this one. | [Latest release](https://github.com/igun997/flute-launcher/releases/latest) |
| **Nightly** | Latest commit on `main`, rebuilt on every push. May be unstable. | [Nightly pre-release](https://github.com/igun997/flute-launcher/releases/tag/nightly) |

Both are **release builds signed with the same Flute key**, so they update over each other without uninstalling. Android never installs an older build over a newer one, so to go from a nightly back to an older release, uninstall first.

### Install

1. Download `flute-<version>-arm64-v8a.apk` on your phone. It fits almost every phone made since 2017. For another CPU, [build it yourself](#build-it-yourself).
2. Open it and allow **Install unknown apps** for your browser or file manager when Android asks.
3. Press Home and choose **Flute** as your default home app (Settings → Apps → Default apps → Home app).
4. Open Flute → long-press the home screen → **Settings** and switch on what you want. Each permission is optional and explained in the app.

Verify the download (optional, recommended). Every release ships a `.sha256` file, and the signing certificate fingerprint is printed in the release notes.

```bash
sha256sum -c flute-0.1.0-arm64-v8a.apk.sha256
apksigner verify --print-certs flute-0.1.0-arm64-v8a.apk
```

The official signing certificate has this SHA-256 fingerprint:

```
3ea3728ed33224da4b49915df935e3b566413c91567161eb3c7834730190dd59
```

If `apksigner` prints a different value, the APK was not built by this project's CI.

## What it does

### Looks like the sky outside

A GPU shader draws the sky behind the home screen. It follows **sunrise and sunset** at your location and the **live weather** (clear, clouds, fog, drizzle, rain, thunderstorm, snow). Text switches to dark ink when the sky is bright so it always stays readable. In Settings → Appearance you can preview any time of day or weather for ten minutes.

<p>
  <img src="docs/screenshots/home-day.png" width="24%" alt="Day">
  <img src="docs/screenshots/home-dawn.png" width="24%" alt="Dawn">
  <img src="docs/screenshots/home-dusk.png" width="24%" alt="Dusk">
  <img src="docs/screenshots/home-rain.png" width="24%" alt="Rain">
</p>

### A companion that lives on Home

Pick one of six original chibi characters in **Settings → Characters**. They stroll across the home screen, react when you tap them, **go into their little house when it rains** (the window glows), and **fall asleep outside the door at night** or in Sleep mode. Knock on the house to see who is inside.

![Characters: Kiri, Luma, Momo, Nori, Pip, Sora](docs/screenshots/characters.png)

Characters are drawn with a single GPU `drawAtlas` call and only repaint when something visibly changes, so a pet standing still costs a few frames a second. Want your own? See [Add your own character](#add-your-own-character).

### Modes

Free, Work, Focus and Sleep. A mode decides which categories are shown, dimmed or paused. Start one manually, for a set time, or on a schedule. Opening a paused app shows a short pause screen first: wait, go back, or open anyway.

**Sleep** also turns on Do Not Disturb (alarms only; your previous setting returns when you wake up), darkens the sky and lets the companion go to bed.

<p>
  <img src="docs/screenshots/modes.png" width="32%" alt="Mode sheet">
  <img src="docs/screenshots/home-sleep.png" width="32%" alt="Sleep mode">
  <img src="docs/screenshots/apps.png" width="32%" alt="Apps grouped by category">
</p>

### Apps by category, text first

Swipe up for a plain text list grouped by category (Flute ships with 900+ known package names, and you can override any app). Search is built in. Pinned apps on Home get a redrawn line icon; everything else stays quiet and gray.

### One inbox

Swipe left on Home for **Inbox**: WhatsApp and SMS notifications (captured from your notifications, no SMS permission, nothing leaves the phone) and optional IMAP mail (Lark, Gmail, or any IMAP server; headers only). Unread counts show on Home.

### Lockscreen and gestures

- **Flute lockscreen** shows the clock, weather and message counts. Your PIN or fingerprint is still what unlocks the phone. Message previews are off by default.
- **Double-tap an empty spot on Home** to turn the screen off (needs the optional Flute lock service in Accessibility, which can only lock the screen).
- **Wave to wake**: cover the proximity sensor twice to wake the phone. A backup for a broken power button.

<p><img src="docs/screenshots/lockscreen.png" width="32%" alt="Lockscreen"> <img src="docs/screenshots/settings.png" width="32%" alt="Settings"></p>

### Ask Flute: an assistant on the left of Home

Swipe right from Home. Chat with any model: Markdown answers (tables included), attachments (photo, camera, video, files), and a live **tokens per second** readout while it writes.

- **Bring your own model:** any OpenAI-compatible gateway (the model list is pulled automatically and searchable), **Sign in with ChatGPT** (uses your ChatGPT plan, through OpenAI's official flow for open-source apps) or **OpenRouter** (OAuth). Claude's own subscription login is not offered: Anthropic does not allow it in third-party apps. Use an API key via a gateway or OpenRouter.
- **It runs your launcher:** switch mode (Free, Work, Focus, Sleep, with a timer), manage schedules, pins, app categories and a few settings. Changes ask first.
- **Tools on your phone:** calendar (by date range), contacts (list or search) and notes. **Every change, and every read of personal data, asks you first** (allow once, allow for this chat, deny).
- **Voice mode:** talk to it and it talks back (Android speech recognition and text-to-speech, free, on device where available) with a Jarvis-style orb drawn by a GPU shader. Approvals work by voice too: it reads the action and you say allow or deny.
- **Routines:** saved prompts the model runs on a schedule (daily, weekly, every N minutes) and reports by notification, e.g. a morning briefing. They only read unless you allow writes. See them in a list or a month calendar.
- **Web search:** add a Tavily or Firecrawl key and the assistant can search and read pages.
- **Images:** the assistant can draw. `image_generate` finds the image models of your provider by itself (its capability flags, known names such as `gpt-image`, `imagen`, `flux`, and, on a gateway, `cx/gpt-image-2` and Gemini image models), tries up to three, and shows the picture in the chat while a GPU shader animates the wait. Tap a picture for full screen. Pick a model in Agent settings or leave it on Auto.
- **Sandbox:** run Python in an **Instabox** or **Daytona** sandbox (API key in settings) or, with no key, in a small **WASM Python on the phone** (runs in Rust). The sandbox is always shut down when the answer is done. Local Python can fetch public web pages with `urllib` (the phone and your home network stay blocked), and anything it writes to `/out` (a chart, a CSV) is shown in the chat with open, share and save-to-Downloads; remote sandboxes show files listed in `show_files`. A remote sandbox can also transcribe audio with Whisper (`sandbox_transcribe_audio`); `audio_transcribe` uses your provider instead.
- **External tools (MCP):** add GitHub, Jira, **Simular Box** (a cloud Linux desktop with a browser and a shell for the agent) or any Streamable HTTP MCP server. Servers that support OAuth sign in through the browser (no token to paste); otherwise use a bearer token or a custom header. Tool calls that are not read-only ask first.
- **Skills:** type `skills add owner/repo` in the chat (the same commands as `npx skills`: `list`, `find`, `update`, `remove`). Skills are instructions only; Flute never runs code from them.
- Video is sent to the model as a few frames, since chat APIs take images, not video.

### Weather where you are

Pick a city, or turn on **Follow my location**: Flute updates the city when you have moved more than 5 km. It uses approximate location only, only while Flute is open, and never asks on its own.

## Permissions

| Permission | Why | Needed for |
|---|---|---|
| Notification access | Read WhatsApp/SMS notifications | Inbox, lockscreen counts |
| Usage access | Time per category | "Today 4h" summary, pause screen |
| Display over other apps | Show the pause screen and lockscreen on top | Soft lock, lockscreen |
| Do Not Disturb access | Alarms-only while sleeping | Sleep mode |
| Accessibility (Flute lock service) | `GLOBAL_ACTION_LOCK_SCREEN` only | Double-tap to lock |
| Approximate location | Pick the weather city | Follow my location |
| Calendar, Contacts | Let the assistant read and change them, after you allow each action | Ask Flute (off until you switch it on) |
| Microphone | Voice mode and speech to text | Voice mode (asked when you first use it) |
| Notifications, exact alarms | Show routine results at the time you chose | Routines |
| Network | Weather (Open-Meteo), IMAP if you add mail | Weather, mail |

Everything is opt-in and off until you enable it. Flute reads no message bodies from mail, stores IMAP passwords in the Android keystore, and has no analytics or server of its own.

> **Samsung phones:** keep *One UI Home* enabled. Flute is your home app, but the Recents button is served by Samsung's launcher, and disabling it breaks Recents.

## Build it yourself

You need **Flutter (stable channel)**, **JDK 17**, the **Android SDK** and a **Rust toolchain** ([rustup](https://rustup.rs)). Check with `flutter doctor` and `rustc --version`.

```bash
rustup target add aarch64-linux-android   # add armv7-linux-androideabi / x86_64-linux-android for those builds
```

```bash
git clone https://github.com/igun997/flute-launcher.git
cd flute-launcher
flutter pub get
flutter analyze && flutter test
cargo test -p hub                      # the Rust side

flutter run                            # debug build on a connected phone
flutter build apk --release --target-platform android-arm64
# -> build/app/outputs/flutter-apk/app-release.apk
```

Other CPUs: use `--target-platform android-arm` (32-bit phones) or `android-x64` (emulators), or `--split-per-abi` for all of them. Only `arm64` is tested.

Without any signing setup the release APK is signed with your local **debug key**. It installs fine, but it is a different identity than the official builds, so Android will not update one over the other. Uninstall first when switching.

### Sign with your own key

Create a keystore once and keep it somewhere safe. **If you lose it you can never update the app for people who installed it.**

```bash
keytool -genkeypair -v -keystore ~/flute-release.jks -storetype PKCS12 \
  -alias flute -keyalg RSA -keysize 4096 -validity 36500
```

Create `android/key.properties` (it is git-ignored; never commit it):

```properties
storeFile=/home/you/flute-release.jks
storePassword=...
keyAlias=flute
keyPassword=...
```

`flutter build apk --release` now signs with that key. Print its fingerprint with
`keytool -list -v -keystore ~/flute-release.jks -alias flute`.

### Run the same pipeline on your own fork

The repository is built by GitHub Actions. To get signed nightly and release APKs on your fork:

1. **Fork** the repository and enable Actions on the fork.
2. Add these under *Settings → Secrets and variables → Actions → New repository secret*:

   | Secret | Value |
   |---|---|
   | `ANDROID_KEYSTORE_BASE64` | `base64 -w0 ~/flute-release.jks` (on macOS: `base64 -i ~/flute-release.jks`) |
   | `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
   | `ANDROID_KEY_ALIAS` | `flute` |
   | `ANDROID_KEY_PASSWORD` | the key password |

   Or with the GitHub CLI:
   ```bash
   base64 -w0 ~/flute-release.jks | gh secret set ANDROID_KEYSTORE_BASE64
   gh secret set ANDROID_KEYSTORE_PASSWORD
   gh secret set ANDROID_KEY_ALIAS
   gh secret set ANDROID_KEY_PASSWORD
   ```
3. **Nightly:** push to `main`. The *Nightly* workflow analyzes, tests, builds, signs and replaces the `nightly` pre-release.
4. **Release:** tag a commit and push the tag.
   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```
   The *Release* workflow builds from the tag (`v0.2.0` becomes version name `0.2.0`) and publishes a release with the APK and its checksum. Tags with a dash (`v0.2.0-rc1`) are marked pre-release.

Without the secrets, the workflows still run and produce debug-signed APKs. Secrets are only given to workflows that run on your own branches and tags; pull requests from forks use the plain *CI* workflow (analyze + test) and never see them.

The Android version code is the build time in minutes since 1970, so every build is newer than the last and installs over the previous one, nightly or release.

## Add your own character

A character is a folder of sprite strips plus an entry in an index file.

```
assets/pets/<id>/
  walk.png    idle.png    sleep.png    happy.png   4 frames each, 640×160 (4 cells of 160 px)
  house.png                                          256×256
assets/pets/index.json                               { "cell": 160, "houseCell": 256,
                                                       "pets": [ { "id": "...", "name": "...", "phrases": ["..."] } ] }
```

Draw characters facing **right**; Flute mirrors them. Add the folder to the `assets:` list in `pubspec.yaml` and rebuild. The character then shows up in Settings → Characters. `tools/make_pets_art.py` and `tools/cut_pets.py` show how the bundled characters were generated and cut (they need an image API key in `.env`, which is git-ignored).

Please only add characters you drew or have the right to use.

## Project layout

```
lib/core        categories, modes, app repository, day/sky styles
lib/home        home, apps, inbox, mode sheet, settings
lib/widgets     clock, weather chip, GPU sky, mode transitions, icons
lib/pets        companion simulation, sprites, stage
lib/weather     Open-Meteo client, location following
lib/email       IMAP inbox
lib/lock        lockscreen
lib/agent       AI agent: providers, tools, MCP, skills, chat
lib/rust        Dart client for the Rust core
native/hub      Rust core (Rinf): archives, hashing, categories, search
android/app/src/main/kotlin   notification listener, lockscreen, DND, accessibility lock, wave to wake
shaders         sky, mode transition and window glow fragment shaders
docs/SPEC.md    architecture notes
```

## Performance

Heavy jobs run in a small Rust crate through [Rinf](https://github.com/cunarist/rinf), but only after being
measured on a real phone first. SHA-256 is 13x faster, unzipping skills 4x, app categories 5x. Method,
numbers, what stayed in Dart and why: [docs/PERFORMANCE.md](docs/PERFORMANCE.md). Run the benchmark on
your own phone by long-pressing the version text at the bottom of Settings.

## Contributing

Issues and pull requests are welcome. Run `flutter analyze` and `flutter test` before you open one; the *CI* workflow runs both on every pull request.

## License

[MIT](LICENSE). The bundled character art was generated with AI image models for this project and is released under the same license.
