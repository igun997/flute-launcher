import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_icons.dart';
import '../core/app_repository.dart';
import '../core/category_engine.dart';
import '../core/day_style.dart';
import '../core/mode_engine.dart';
import '../email/email_service.dart';
import '../lock/lock_settings.dart';
import '../native/flute_native.dart';
import '../pets/pet_library.dart';
import '../pets/pet_settings.dart';
import '../weather/weather_service.dart';

/// Owns every long-lived service and keeps the native lock in sync.
class Flute {
  Flute._(this.prefs, this.repo, this.modes, this.weather)
    : style = StyleController(prefs, weather, modes),
      lockSettings = LockSettings(prefs),
      pets = PetSettings(prefs);

  final SharedPreferences prefs;
  final AppRepository repo;
  final ModeEngine modes;
  final WeatherService weather;
  final StyleController style;
  final AppIcons icons = AppIcons();
  final LockSettings lockSettings;
  final PetSettings pets;
  final ValueNotifier<PetLibrary?> petLibrary = ValueNotifier(null);
  EmailService get email => EmailService.instance;

  /// Latest messages captured from notifications, newest first.
  final ValueNotifier<List<RecentMessage>> messages = ValueNotifier(const []);
  final ValueNotifier<bool> notificationAccess = ValueNotifier(false);
  final ValueNotifier<bool> usageAccess = ValueNotifier(false);
  final ValueNotifier<bool> dndAccess = ValueNotifier(false);
  final ValueNotifier<bool> defaultHome = ValueNotifier(false);
  final ValueNotifier<bool> accessibilityOn = ValueNotifier(false);
  final ValueNotifier<WakeInfo> wakeInfo = ValueNotifier(WakeInfo.none);
  bool? _dnd;

  static const _appsEvery = Duration(minutes: 10);
  static const _usageEvery = Duration(minutes: 1);
  DateTime _lastApps = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastUsage = DateTime.fromMillisecondsSinceEpoch(0);

  StreamSubscription<NativeEvent>? _events;
  Timer? _syncDebounce;

  static Future<Flute> create() async {
    final prefs = await SharedPreferences.getInstance();
    final engine = await CategoryEngine.load();
    final repo = AppRepository(prefs, engine);
    final modes = ModeEngine(prefs)..load();
    final weather = WeatherService();
    final flute = Flute._(prefs, repo, modes, weather);
    await flute._start();
    return flute;
  }

  Future<void> _start() async {
    // Independent start-up work runs together so the first frame is not held up in sequence.
    await Future.wait([
      repo.load(),
      weather.init(),
      email.init(),
      refreshPermissions(),
      refreshMessages(),
      lockSettings.init(),
    ]);
    unawaited(PetLibrary.open().then((l) => petLibrary.value = l, onError: (Object _) {}));
    unawaited(icons.ensure(repo.favoritePackages));
    repo.addListener(() => unawaited(icons.ensure(repo.favoritePackages)));
    _lastApps = _lastUsage = DateTime.now();
    repo.addListener(_scheduleSync);
    modes.addListener(_scheduleSync);
    modes.addListener(() => unawaited(_applyDnd()));
    _scheduleSync();
    _events = FluteNative.events.listen((e) {
      if (e.type == 'message') unawaited(refreshMessages());
    });
    unawaited(weather.refresh());
    unawaited(email.refresh());
  }

  Future<void> refreshPermissions() async {
    notificationAccess.value = await FluteNative.hasNotificationAccess();
    usageAccess.value = await FluteNative.hasUsageAccess();
    dndAccess.value = await FluteNative.hasPolicyAccess();
    defaultHome.value = await FluteNative.isDefaultLauncher();
    accessibilityOn.value = await FluteNative.isAccessibilityEnabled();
    wakeInfo.value = await FluteNative.getWakeInfo();
    await _applyDnd();
  }

  Future<void> refreshMessages() async {
    messages.value = await FluteNative.getRecentMessages(limit: 40);
  }

  /// Called when the launcher returns to the foreground.
  ///
  /// The app list (every label loaded from PackageManager) and the usage query are the
  /// expensive parts, so they are throttled instead of running on every resume.
  Future<void> onResume() async {
    final now = DateTime.now();
    await Future.wait([
      refreshPermissions(),
      refreshMessages(),
      if (now.difference(_lastApps) > _appsEvery)
        repo.refresh().then((_) => _lastApps = _lastUsage = now)
      else if (now.difference(_lastUsage) > _usageEvery)
        repo.refreshUsage().then((_) => _lastUsage = now),
      weather.refresh(),
      email.refresh(),
    ]);
  }

  /// Syncs Do Not Disturb with the active mode. Retried on resume if access was missing.
  Future<void> _applyDnd() async {
    final want = modes.wantsDnd;
    if (_dnd == want) return;
    if (await FluteNative.setDoNotDisturb(want)) _dnd = want;
  }

  void _scheduleSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(FluteNative.setLockConfig(modes.lockConfig(repo.apps)));
    });
  }

  void dispose() {
    _events?.cancel();
    _syncDebounce?.cancel();
    petLibrary.value?.dispose();
    pets.dispose();
    icons.dispose();
    repo.dispose();
    modes.dispose();
    style.dispose();
  }
}
