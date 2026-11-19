# Flute: v1 spec

Flute, a lightweight Android launcher that boosts productivity, not only focus (Flutter UI + Kotlin native). English only. Reference: minimalist phone; extension: understands apps by category.
Package/app id `id.nst.focus_launcher`, Dart package `focus_launcher`, label "Flute". Flutter 3.50 (import `package:material_ui/material_ui.dart`).

## Product
- Home: animated clock, weather, recents (WhatsApp, SMS, email), favorites, text-only app list grouped by category, search.
- Auto-categories: Banking, Work, Chat, Social, Media, Games, Shopping, Travel, Tools, Other. User can override per app.
- Modes (Work, Focus, Sleep, Free): rules by category (show / hide / soft-lock). Manual, timer or schedule. "Always allowed" list overrides.
- Soft lock: opening a locked app shows a pause screen (countdown), then "Open anyway" (grace 5 min) or "Go back". No accessibility service.
- Usage by category (UsageStatsManager).
- Recents: WhatsApp / SMS captured from notifications (NotificationListenerService, no READ_SMS, no WhatsApp API). Only messages after access is granted.
- Email: IMAP (Lark preset `imap.larksuite.com:993` SSL with the generated third-party client password; Gmail preset; custom). Read-only inbox preview (unread count + latest 10).
- Weather: Open-Meteo (no key), city search via Open-Meteo geocoding, no location permission.
- Motion: procedural (CustomPainter/AnimationController) weather scenes, clock digit transitions, mode-change transitions. Assets (icon, wallpapers, illustrations) generated with `python3 tools/gen.py image ... --model cx/gpt-6.1-sol`.
- Not in v1: hard blocks 4h-30d, notification digest, per-app monochrome, accounts/cloud.

## Directory ownership (each slice edits ONLY its own paths)
| Slice | Paths |
|---|---|
| Native | `android/app/src/main/**` (kotlin, res, manifest), `lib/native/**` |
| Email | `lib/email/**`, `test/email/**` |
| Clock/weather/motion/assets | `lib/widgets/**`, `lib/weather/**`, `assets/**`, `tools/**` |
| Core (parent) | `lib/main.dart`, `lib/app/**`, `lib/core/**`, `lib/home/**`, `pubspec.yaml` |

Do NOT edit `pubspec.yaml`; dependencies already present: `enough_mail`, `flutter_secure_storage`, `http`, `shared_preferences`. Need another? Say so in your final message, do not add it.
Do NOT run flutter/dart/gradle (build runs once, remotely, by the parent via `rflutter`). Write careful, compile-ready code.

## Native contract (`lib/native/flute_native.dart`, Kotlin `FluteNative`)
MethodChannel `flute/native`; EventChannel `flute/events`. Dart API (all static, async):

```dart
class InstalledApp { final String package; final String label; final int androidCategory; /* ApplicationInfo.category, -1 undefined */ final bool isSystem; }
class UsageEntry { final String package; final int foregroundMs; }          // today since local midnight
class RecentMessage { final String id; final String source; /* 'whatsapp' | 'sms' */ final String package;
  final String sender; final String text; final int timestampMs; final String conversationKey; }

FluteNative.getApps() -> Future<List<InstalledApp>>                 // launchable apps (LauncherApps), excludes Flute itself
FluteNative.launchApp(String package) -> Future<bool>
FluteNative.openAppInfo(String package) -> Future<void>
FluteNative.hasUsageAccess() / openUsageAccessSettings()
FluteNative.getUsageToday() -> Future<List<UsageEntry>>
FluteNative.hasNotificationAccess() / openNotificationAccessSettings()
FluteNative.hasOverlayPermission() / openOverlaySettings()          // SYSTEM_ALERT_WINDOW not required if using activity lock; keep for background-activity-start on Android 10+
FluteNative.getRecentMessages({int limit = 30}) -> Future<List<RecentMessage>>   // newest first, persisted (SharedPreferences JSON, max 200)
FluteNative.clearRecentMessages()
FluteNative.setLockConfig(LockConfig c) -> Future<void>             // starts/stops the foreground LockService
class LockConfig { final bool enabled; final List<String> lockedPackages; final List<String> allowedPackages; final int pauseSeconds; final int graceMinutes; }
FluteNative.events -> Stream<NativeEvent>                           // {type:'message', message: RecentMessage} | {type:'homePressed'}
FluteNative.isDefaultLauncher() / openHomeSettings()
FluteNative.expandNotificationShade(); FluteNative.lockScreen() -> Future<bool>  // lockScreen needs DeviceAdmin; return false if unavailable, do not request it in v1
```
Lock behaviour (Kotlin): foreground service polls `UsageStatsManager.queryEvents` ~900 ms; when foreground package is in `lockedPackages` and not in `allowedPackages` and not in grace, start translucent `LockActivity` over it showing pause countdown, buttons "Go back" (go Home) and "Open anyway" (after countdown; sets grace for that package). Foreground service type `specialUse` with the PROPERTY_SPECIAL_USE_FGS_SUBTYPE property. START_STICKY. Persist last `LockConfig` so the service restarts after reboot (BOOT_COMPLETED receiver).
Notification capture: `NotificationListenerService` handles `com.whatsapp`, `com.whatsapp.w4b`, and SMS apps (`com.google.android.apps.messaging`, `com.samsung.android.messaging`, `com.android.mms`, `com.android.messaging`). Use `EXTRA_TITLE` as sender, `EXTRA_TEXT`/`EXTRA_MESSAGES` for text; skip group summaries (`FLAG_GROUP_SUMMARY`) and "N new messages" placeholders; dedupe by (conversationKey, text, ts); conversationKey = package + title. Do not log message content. Emit event to Dart if the engine is attached.
Manifest: HOME intent-filter exists (keep), add queries for launcher intent (`<queries><intent><action MAIN/><category LAUNCHER/></intent></queries>`; do not use QUERY_ALL_PACKAGES), `PACKAGE_USAGE_STATS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`, `SYSTEM_ALERT_WINDOW`. `MainActivity`: `launchMode=singleTask`, emit `homePressed` when a HOME intent arrives while running. App label "Flute".

## Email contract (`lib/email/`)
```dart
class EmailAccount { final String id; final String label; final String address; final String host; final int port; final bool ssl; /* password stored in flutter_secure_storage under key 'email.<id>' */ }
class EmailPreview { final String accountId; final String from; final String subject; final DateTime date; final bool seen; final String uid; }
class EmailSummary { final int unread; final List<EmailPreview> latest; final DateTime fetchedAt; final String? error; }
abstract final class EmailPresets { static const lark = ...; static const gmail = ...; }   // lark: imap.larksuite.com:993 ssl (needs admin-allowed third-party client + generated password); gmail: imap.gmail.com:993 (needs app password)
class EmailService {            // singleton, ChangeNotifier
  Future<void> init();          // loads accounts from shared_preferences key 'email.accounts' (JSON)
  List<EmailAccount> get accounts;
  Future<String?> addAccount(EmailAccount a, String password);   // verifies login; returns error text or null
  Future<void> removeAccount(String id);
  Future<void> refresh({bool force = false});   // min interval 60 s unless force; per-account errors kept in summary
  EmailSummary get summary;      // merged across accounts, newest first, max 10
}
Widget EmailAccountsSheet(...)  // bottom-sheet content: list accounts, add (preset chooser), remove; shows Lark instructions text
Widget EmailCard()              // compact home card: unread count + 3 latest subjects, tap opens `EmailAccountsSheet` when no account
```
Use `enough_mail` ImapClient (fetch headers only, never bodies). Never log passwords.

## Clock / weather / motion contract (`lib/widgets/`, `lib/weather/`)
```dart
class WeatherService extends ChangeNotifier { Future<void> init(); WeatherNow? get now; Future<List<CitySuggestion>> searchCity(String q); Future<void> setCity(CitySuggestion c); Future<void> refresh(); }
class WeatherNow { final double tempC; final int code; /* WMO */ final bool isDay; final double hi; final double lo; final String city; final DateTime updated; }
enum WeatherKind { clear, partlyCloudy, cloudy, fog, drizzle, rain, thunder, snow }   WeatherKind kindFromWmo(int code);
Widget FluteClock({bool animate = true})            // large time, date, digit roll animation
Widget WeatherScene({WeatherKind kind, bool isDay}) // procedural animated painter (rain, sun rays, clouds drift, stars, lightning, snow); respects MediaQuery.disableAnimations
Widget WeatherChip(WeatherService s)                // small: temp, icon, city; tap -> city search sheet
Widget ModeTransition(...)                          // fade/scale between mode labels
```
Persist city in shared_preferences key `weather.city` (JSON). Cache last result for offline. Network: `package:http`, Open-Meteo `forecast` (`current=temperature_2m,weather_code,is_day`, `daily=temperature_2m_max,temperature_2m_min`, `timezone=auto`) and geocoding-api `v1/search`.
Assets: `assets/brand/icon.png` (1024, launcher icon source), `assets/art/*.png` (wallpaper/illustrations) generated with `tools/gen.py` using `cx/gpt-6.1-sol`; keep each <= 600 KB (convert with ffmpeg). Add a `tools/make_icons.sh` that writes Android mipmap launcher icons from `assets/brand/icon.png` with ffmpeg (no new deps). Android `res/mipmap-*` files are shared with Native slice: the Assets slice writes ONLY `res/mipmap-*/ic_launcher.png`.

## Core (parent)
`AppRepository` (apps + category + overrides + usage), `CategoryEngine` (bundled `assets/data/categories.json` package->category map + androidCategory + keyword heuristics), `ModeEngine` (rules, schedule, timer, always-allowed -> `LockConfig`), `HomePage`, `SettingsPage`, permissions onboarding.

---

# v1.1: lockscreen, compact pins, gesture navigation

Research summary (sources: Android docs "Activity security" and KeyguardManager, RottenWiFi lockscreen guide, Glance AI lockscreen write-up):
- An ordinary app cannot replace the secure keyguard or verify the user's PIN. It CAN show an activity above the keyguard (`setShowWhenLocked(true)`, `setTurnScreenOn(true)`), and ask the system to dismiss the keyguard (`KeyguardManager.requestDismissKeyguard`), which shows the system PIN/biometric prompt on secure devices.
- Background activity starts are allowed when the app holds `SYSTEM_ALERT_WINDOW` (Flute already requires it) or has a visible window.
- A `NotificationListenerService` that the user enabled stays bound by the system, so it is the process anchor and can register `ACTION_SCREEN_OFF/ON` receivers without another foreground notification.
- Never show private content before unlock without the user's say-so; never touch the system credential.
- Never cover an incoming call or a ringing alarm.

## Flute lockscreen = a Flutter surface over the keyguard, same engine as the launcher
One cached `FlutterEngine` ("flute") is shared by `MainActivity` (home) and `LockscreenActivity` (lock). Dart decides what to draw from a `surface` value: `'home'` or `'lock'`.

### Native contract additions (Dart wrappers already exist in `lib/native/flute_native.dart`; native owner implements the Kotlin side with identical method names)
| Dart | Channel method | Behaviour |
|---|---|---|
| `FluteNative.getIcons(List<String> packages, {int size = 96})` -> `Map<String, Uint8List>` | `getIcons` `{packages, size}` -> `Map<String, ByteArray>` | PNG bytes, square `size` px, adaptive icons flattened, skip packages that fail. Run off the main thread. |
| `FluteNative.getSurface()` -> `String` | `getSurface` | `'lock'` while `LockscreenActivity` is the attached host, else `'home'`. |
| event `{type:'surface', surface:'lock'|'home'}` | EventChannel `flute/events` | Sent when the attached activity changes (after attach). |
| `FluteNative.setLockscreenEnabled(bool)` | `setLockscreenEnabled` `{enabled}` | Persist in native SharedPreferences (read by the listener service). |
| `FluteNative.isLockscreenEnabled()` | `isLockscreenEnabled` | |
| `FluteNative.isKeyguardLocked()` | `isKeyguardLocked` | `KeyguardManager.isKeyguardLocked`. |
| `FluteNative.dismissKeyguard()` -> `bool` | `dismissKeyguard` | `requestDismissKeyguard(activity, callback)`; resolve `true` on success (then finish `LockscreenActivity`), `false` on cancel/error or when no lock activity. On a device with no secure lock it succeeds at once. |
| `FluteNative.finishLockscreen()` | `finishLockscreen` | Finish `LockscreenActivity` if showing. |

### Lockscreen launch rules (Kotlin)
- `FluteNotificationListener` registers a receiver (in `onListenerConnected`, unregister in `onListenerDisconnected`/`onDestroy`) for `ACTION_SCREEN_OFF` and `ACTION_SCREEN_ON`.
- On SCREEN_OFF and on SCREEN_ON: if lockscreen enabled, overlay permission granted, `isKeyguardLocked` (or device secure and screen just turned off), telephony state idle, and no active notification with category `alarm` or `call` (check `getActiveNotifications()`), then `startActivity(LockscreenActivity, FLAG_ACTIVITY_NEW_TASK)` unless it is already showing.
- `LockscreenActivity`: extends `FlutterActivity` using the cached engine (`provideFlutterEngine`, `shouldDestroyEngineWithHost() = false`, `getCachedEngineId`), `setShowWhenLocked(true)`, `setTurnScreenOn(true)` only when launched from SCREEN_ON, `setInheritShowWhenLocked(true)` on API 33+, `excludeFromRecents`, `launchMode=singleTask`, own `taskAffinity`, back/home pressed finish it. Transparent system bars. Emits `surface=lock` after attach and `surface=home` when it finishes.
- `MainActivity` also uses the cached engine (`provideFlutterEngine`, `shouldDestroyEngineWithHost() = false`). `FluteNative` handlers are registered once when the engine is created, not per activity. Engine creation (`FluteEngine.get(context)`) is lazy and runs the default Dart entrypoint.
- Native must not leak activity references; keep a `WeakReference` to the showing `LockscreenActivity`.

## Dart UX contract (owned by the parent)
- Home page does not scroll. Drag up anywhere on Home opens the Apps route. Swipe left opens the Inbox page (WhatsApp/SMS/email in one feed); swipe right returns.
- Pins render as small gray icons (4 per row) fetched with `getIcons`.
- Settings is a full page (gear on Apps page and long-press on Home).
- Preview overrides (time of day, weather) auto-expire after 10 minutes.
