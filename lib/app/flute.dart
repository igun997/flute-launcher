import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/auth/provider_store.dart';
import '../agent/auth/secret_store.dart';
import '../agent/mcp/mcp_manager.dart';
import '../agent/routines/routine_native.dart';
import '../agent/routines/routine_runner.dart';
import '../agent/routines/routine_store.dart';
import '../agent/routines/routine_tools.dart';
import '../agent/runtime/agent_runtime.dart';
import '../agent/skills/skill_manager.dart';
import '../agent/skills/skill_tools.dart';
import '../agent/sandbox/sandbox_manager.dart';
import '../agent/sandbox/sandbox_tools.dart';
import '../agent/tools/agent_tool.dart';
import '../agent/tools/builtin_tools.dart';
import '../agent/image/image_settings.dart';
import '../agent/tools/audio_tools.dart';
import '../agent/tools/image_tools.dart';
import '../agent/ui/confirm_controller.dart';
import '../agent/voice/voice_confirmer.dart';
import '../agent/voice/voice_controller.dart';
import '../agent/voice/voice_native.dart';
import '../agent/web/web_settings.dart';
import '../agent/web/web_tools.dart';
import '../core/app_icons.dart';
import '../core/app_repository.dart';
import '../core/category_engine.dart';
import '../core/day_style.dart';
import '../core/mode_engine.dart';
import '../email/email_service.dart';
import '../lock/lock_settings.dart';
import '../native/flute_native.dart';
import '../pets/pet_library.dart';
import '../rust/rust_core.dart';
import '../pets/pet_settings.dart';
import '../weather/weather_service.dart';

/// Owns every long-lived service and keeps the native lock in sync.
class Flute {
  Flute._({
    required this.prefs,
    required this.repo,
    required this.modes,
    required this.weather,
    required this.providers,
    required this.mcp,
    required this.skills,
    required this.builtins,
    required this.lockSettings,
    required this.pets,
    required this.web,
    required this.imageSettings,
    required this.routines,
    required this.voice,
    required this.sandbox,
    required RoutineNative routineNative,
  }) : style = StyleController(prefs, weather, modes) {
    // What a routine may use: everything except the routine tools themselves.
    final shared = <ToolSource>[
      builtins,
      mcp,
      SkillTools(skills),
      WebTools(web),
      AudioTools(providers: providers, prefs: prefs),
      ImageTools(providers: providers, prefs: prefs, settings: imageSettings),
      SandboxTools(sandbox),
    ];
    routineRunner = RoutineRunner(
      providers: providers,
      toolSources: shared,
      skills: skills,
      store: routines,
      native: routineNative,
      speak: (text) => voice.speakAndWait(text),
      onRunEnd: () async => sandbox.endRun(),
    );
    agent = AgentRuntime(
      providers: providers,
      toolSources: [...shared, RoutineTools(routines, routineRunner)],
      skills: skills,
      confirmer: VoiceAwareConfirmer(sheet: confirm, voice: voice),
      onNewChat: confirm.reset,
      onRunEnd: () async => sandbox.endRun(),
    );
  }

  final SharedPreferences prefs;
  final AppRepository repo;
  final ModeEngine modes;
  final WeatherService weather;
  final StyleController style;
  final AppIcons icons = AppIcons();
  final LockSettings lockSettings;
  final PetSettings pets;
  final ValueNotifier<PetLibrary?> petLibrary = ValueNotifier(null);

  // The AI agent: providers and sign-in, MCP servers, skills, built-in tools, the chat itself.
  final ProviderStore providers;
  final McpManager mcp;
  final SkillManager skills;
  final BuiltinTools builtins;
  final WebSettings web;
  final ImageSettings imageSettings;
  final RoutineStore routines;
  final VoiceController voice;
  final SandboxManager sandbox;
  late final RoutineRunner routineRunner;
  final ConfirmController confirm = ConfirmController();
  late final AgentRuntime agent;
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

  static int _externalDepth = 0;
  static Timer? _externalGrace;

  /// True while a system picker or another app holds the screen, so resume must not jump home.
  static bool get inExternalFlow => _externalDepth > 0 || (_externalGrace?.isActive ?? false);

  /// Runs an activity that takes the screen away (a system picker). The launcher stays put on
  /// resume while it runs and for a short grace period after it returns.
  static Future<T> externalFlow<T>(Future<T> Function() run) async {
    _externalDepth++;
    _externalGrace?.cancel();
    try {
      return await run();
    } finally {
      _externalDepth--;
      _externalGrace = Timer(const Duration(seconds: 2), () {});
    }
  }

  static Future<Flute> create() async {
    final prefs = await SharedPreferences.getInstance();
    final engine = await CategoryEngine.load(
      bulkKeywords: RustCore.instance.isStarted ? RustCore.instance.categorize : null,
    );
    final repo = AppRepository(prefs, engine);
    final modes = ModeEngine(prefs)..load();
    final weather = WeatherService();
    final providers = ProviderStore(prefs: prefs, secrets: SecureSecretStore());
    final mcp = McpManager(prefs: prefs, secrets: SecureSecretStore());
    final skills = await SkillManager.open();
    final lockSettings = LockSettings(prefs);
    final pets = PetSettings(prefs);
    final builtins = BuiltinTools(prefs: prefs, modes: modes, apps: repo, lock: lockSettings, pets: pets);
    final web = WebSettings(prefs: prefs, secrets: SecureSecretStore());
    final routineNative = RoutineNative();
    final routines = RoutineStore(prefs: prefs, native: routineNative);
    final flute = Flute._(
      prefs: prefs,
      repo: repo,
      modes: modes,
      weather: weather,
      providers: providers,
      mcp: mcp,
      skills: skills,
      builtins: builtins,
      lockSettings: lockSettings,
      pets: pets,
      web: web,
      imageSettings: ImageSettings(prefs),
      routines: routines,
      voice: VoiceController(engine: NativeVoiceEngine(), prefs: prefs),
      sandbox: SandboxManager(prefs: prefs, secrets: SecureSecretStore()),
      routineNative: routineNative,
    );
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
      providers.load(),
      mcp.load(),
      skills.load(),
      web.load(),
      routines.load(),
      sandbox.load(),
    ]);
    unawaited(PetLibrary.open().then((l) => petLibrary.value = l, onError: (Object _) {}));
    unawaited(mcp.connectEnabled());
    unawaited(routineRunner.start());
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
    agent.dispose();
    routineRunner.dispose();
    voice.dispose();
    unawaited(sandbox.shutdown());
    sandbox.dispose();
    web.dispose();
    imageSettings.dispose();
    confirm.dispose();
    mcp.dispose();
    providers.dispose();
  }
}
