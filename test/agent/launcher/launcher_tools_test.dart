import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/agent/tools/launcher_tools.dart';
import 'package:focus_launcher/core/app_repository.dart';
import 'package:focus_launcher/core/category_engine.dart';
import 'package:focus_launcher/core/mode_engine.dart';
import 'package:focus_launcher/core/models.dart';
import 'package:focus_launcher/lock/lock_settings.dart';
import 'package:focus_launcher/pets/pet_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late DateTime now;
  late ModeEngine modes;
  late PetSettings pets;
  late LockSettings lock;
  late List<AgentTool> tools;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = DateTime(2025, 1, 6, 9); // Monday
    modes = ModeEngine(prefs, clock: () => now)..load();
    pets = PetSettings(prefs);
    lock = LockSettings(prefs);
    tools = launcherTools(
      modes: modes,
      apps: AppRepository(prefs, CategoryEngine(const {})),
      lock: lock,
      pets: pets,
    );
  });

  tearDown(() => modes.dispose());

  Future<ToolResult> call(String name, [Map<String, dynamic> args = const {}]) =>
      tools.firstWhere((t) => t.name == name).run(args);

  Future<void> addSleepWindow() async {
    await call('launcher_add_schedule', {
      'mode': 'sleep',
      'days': [1, 2, 3, 4, 5],
      'start': '22:00',
      'end': '07:00',
    });
  }

  test('launcher_set_mode switches the base mode', () async {
    final r = await call('launcher_set_mode', {'mode': 'work'});

    expect(r.isError, isFalse);
    expect(modes.base.id, Mode.work.id);
  });

  test('launcher_set_mode with minutes starts a timed override', () async {
    final r = await call('launcher_set_mode', {'mode': 'focus', 'minutes': 30});

    expect(r.isError, isFalse);
    expect(modes.current.id, Mode.focus.id);
    expect(modes.overrideUntil, now.add(const Duration(minutes: 30)));
  });

  test('launcher_wake_up leaves a scheduled sleep window early', () async {
    await addSleepWindow();
    now = DateTime(2025, 1, 6, 23); // Monday 23:00, inside the window
    expect(modes.current.id, Mode.sleep.id);

    final r = await call('launcher_wake_up');

    expect(r.isError, isFalse);
    expect(modes.current.id, Mode.free.id);
  });

  test('launcher_add_schedule adds a window that switches the mode', () async {
    now = DateTime(2025, 1, 6, 23); // Monday 23:00

    final r = await call('launcher_add_schedule', {
      'mode': 'sleep',
      'days': [1, 2, 3, 4, 5],
      'start': '22:00',
      'end': '07:00',
    });

    expect(r.isError, isFalse);
    expect(modes.schedules, hasLength(1));
    expect(modes.current.id, Mode.sleep.id);
  });

  test('a window that wraps past midnight covers the early morning of the next day', () async {
    await addSleepWindow();
    now = DateTime(2025, 1, 7, 6, 30); // Tuesday 06:30, still inside Monday's window

    expect(modes.current.id, Mode.sleep.id);
  });

  test('launcher_add_schedule rejects bad times and days without saving', () async {
    final badTime = await call('launcher_add_schedule', {
      'mode': 'focus',
      'days': [1],
      'start': '25:00',
      'end': '07:00',
    });
    expect(badTime.isError, isTrue);
    expect(badTime.text, contains('24-hour HH:MM'));

    final badDay = await call('launcher_add_schedule', {
      'mode': 'focus',
      'days': [0],
      'start': '09:00',
      'end': '10:00',
    });
    expect(badDay.isError, isTrue);

    expect(modes.schedules, isEmpty);
  });

  test('launcher_list_schedules reports none, then lists the added window', () async {
    expect((await call('launcher_list_schedules')).text, 'No schedules.');

    await addSleepWindow();
    final r = await call('launcher_list_schedules');

    expect(r.isError, isFalse);
    expect(r.text, isNot(contains('No schedules')));
  });

  test('launcher_update_schedule changes only the given fields', () async {
    await addSleepWindow();

    final r = await call('launcher_update_schedule', {'index': 0, 'mode': 'focus'});

    expect(r.isError, isFalse);
    final s = modes.schedules.single;
    expect(s.modeId, Mode.focus.id);
    expect(s.days, {1, 2, 3, 4, 5});
    expect(s.startMinute, 22 * 60);
    expect(s.endMinute, 7 * 60);
  });

  test('launcher_update_schedule rejects an index that does not exist', () async {
    await addSleepWindow();

    final r = await call('launcher_update_schedule', {'index': 5, 'mode': 'focus'});

    expect(r.isError, isTrue);
    expect(modes.schedules.single.modeId, Mode.sleep.id);
  });

  test('launcher_delete_schedule removes the chosen window', () async {
    await addSleepWindow();
    await call('launcher_add_schedule', {
      'mode': 'focus',
      'days': [6, 7],
      'start': '10:00',
      'end': '12:00',
    });

    final r = await call('launcher_delete_schedule', {'index': 0});

    expect(r.isError, isFalse);
    expect(modes.schedules, hasLength(1));
    expect(modes.schedules.single.modeId, Mode.focus.id);
  });

  test('launcher_delete_schedule rejects an index that does not exist', () async {
    await addSleepWindow();

    final r = await call('launcher_delete_schedule', {'index': 3});

    expect(r.isError, isTrue);
    expect(modes.schedules, hasLength(1));
  });

  test('launcher_set_always_allowed adds and removes a package', () async {
    await call('launcher_set_always_allowed', {'package': 'com.example.chat', 'allowed': true});
    expect(modes.allowed, contains('com.example.chat'));

    await call('launcher_set_always_allowed', {'package': 'com.example.chat', 'allowed': false});
    expect(modes.allowed, isNot(contains('com.example.chat')));
  });

  test('launcher_set_setting turns off pets and sleep DND', () async {
    final petsResult = await call('launcher_set_setting', {'setting': 'pets_enabled', 'value': false});
    expect(petsResult.isError, isFalse);
    expect(pets.enabled, isFalse);

    final r = await call('launcher_set_setting', {'setting': 'dnd_in_sleep', 'value': false});
    expect(r.isError, isFalse);
    expect(modes.dndInSleep, isFalse);
  });

  test('launcher_set_setting lock_enabled pushes the value to native', () async {
    final nativeCalls = <MethodCall>[];
    const channel = MethodChannel('flute/native');
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final r = await call('launcher_set_setting', {'setting': 'lock_enabled', 'value': true});

    expect(r.isError, isFalse);
    expect(lock.enabled, isTrue);
    expect(nativeCalls.single.method, 'setLockscreenEnabled');
    expect(nativeCalls.single.arguments, {'enabled': true});
  });

  test('launcher_pin_app reports an unknown package as an error', () async {
    final r = await call('launcher_pin_app', {'package': 'com.example.missing'});

    expect(r.isError, isTrue);
  });
}
