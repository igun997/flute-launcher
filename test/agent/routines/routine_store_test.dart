import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/routines/routine.dart';
import 'package:focus_launcher/agent/routines/routine_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

RoutineRun _run(
  String routineId,
  int index, {
  bool ok = true,
  bool skipped = false,
  String result = 'answer',
  String? error,
}) {
  final at = DateTime(2026, 11, 1, 7).add(Duration(hours: index));
  return RoutineRun(
    id: 'run-$routineId-$index',
    routineId: routineId,
    startedAt: at,
    endedAt: at.add(const Duration(seconds: 5)),
    ok: ok,
    skipped: skipped,
    error: error,
    result: result,
  );
}

void main() {
  late FakeRoutineNative native;
  late SharedPreferences prefs;
  late RoutineStore store;
  final now = DateTime(2026, 11, 18, 10);

  Routine daily({String id = '', String name = 'Morning briefing'}) => Routine(
        id: id,
        name: name,
        prompt: 'Brief me.',
        trigger: RoutineTrigger.daily,
        minuteOfDay: 7 * 60 + 30,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    native = FakeRoutineNative();
    store = RoutineStore(prefs: prefs, native: native, clock: () => now);
    await store.load();
  });

  tearDown(() async {
    await native.close();
  });

  test('saving assigns an id, keeps it across reloads and pushes the next fire time', () async {
    final saved = await store.save(daily());
    expect(saved.id, isNotEmpty);

    final last = native.syncs.last;
    expect(last, hasLength(1));
    expect(last.single['id'], saved.id);
    expect(last.single['trigger'], 'daily');
    expect(last.single['enabled'], isTrue);
    expect(last.single['nextAtMs'], DateTime(2026, 11, 19, 7, 30).millisecondsSinceEpoch);

    final reloaded = RoutineStore(prefs: prefs, native: native, clock: () => now);
    await reloaded.load();
    expect(reloaded.routines.single.name, 'Morning briefing');
    expect(reloaded.routines.single.id, saved.id);
  });

  test('an invalid routine is refused with a sentence and nothing is saved', () async {
    expect(
      () => store.save(Routine(id: '', name: '', prompt: 'p', trigger: RoutineTrigger.daily)),
      throwsA(isA<RoutineException>()),
    );
    expect(store.routines, isEmpty);
  });

  test('pausing removes the routine from the native schedule and resuming puts it back', () async {
    final saved = await store.save(daily());
    await store.setEnabled(saved.id, false);
    expect(native.syncs.last.single['enabled'], isFalse);
    expect(native.syncs.last.single['nextAtMs'], isNull);

    await store.setEnabled(saved.id, true);
    expect(native.syncs.last.single['nextAtMs'], isNotNull);
  });

  test('removing a routine drops its history and its native alarm', () async {
    final saved = await store.save(daily());
    await store.recordRun(_run(saved.id, 0));
    await store.remove(saved.id);
    expect(store.routines, isEmpty);
    expect(store.history(saved.id), isEmpty);
    expect(native.syncs.last, isEmpty);
  });

  test('history keeps the newest 20 runs and the routine remembers its last result', () async {
    final saved = await store.save(daily());
    for (var i = 0; i < 25; i++) {
      await store.recordRun(_run(saved.id, i, result: 'answer $i'));
    }
    final history = store.history(saved.id);
    expect(history, hasLength(20));
    expect(history.first.result, 'answer 24', reason: 'newest first');
    expect(history.last.result, 'answer 5');
    expect(store.byId(saved.id)!.lastResult, 'answer 24');
  });

  test('two failed runs in a row pause the routine; a success in between resets the count', () async {
    final saved = await store.save(daily());
    await store.recordRun(_run(saved.id, 0, ok: false, error: 'boom'));
    expect(store.consecutiveFailures(saved.id), 1);
    await store.recordRun(_run(saved.id, 1));
    expect(store.consecutiveFailures(saved.id), 0);

    await store.recordRun(_run(saved.id, 2, ok: false, error: 'boom'));
    expect(await store.pauseIfFailing(saved.id), isFalse, reason: 'one failure is not enough');
    await store.recordRun(_run(saved.id, 3, ok: false, error: 'boom'));
    expect(await store.pauseIfFailing(saved.id), isTrue);
    expect(store.byId(saved.id)!.enabled, isFalse);
    expect(store.isPaused(saved.id), isTrue);
    expect(native.syncs.last.single['enabled'], isFalse);
  });

  test('skipped runs are not failures and do not pause the routine', () async {
    final saved = await store.save(daily());
    await store.recordRun(_run(saved.id, 0, ok: false, error: 'boom'));
    await store.recordRun(_run(saved.id, 1, ok: false, skipped: true, error: 'Skipped: add a provider.'));
    await store.recordRun(_run(saved.id, 2, ok: false, error: 'boom'));
    expect(store.consecutiveFailures(saved.id), 2);
    expect(await store.pauseIfFailing(saved.id), isTrue);
  });

  test('a run for a routine that was removed meanwhile is dropped', () async {
    final saved = await store.save(daily());
    await store.remove(saved.id);
    await store.recordRun(_run(saved.id, 0));
    expect(store.history(saved.id), isEmpty);
  });

  test('editing keeps what the runs recorded since the editor opened', () async {
    final saved = await store.save(daily());
    final opened = saved;
    await store.recordRun(_run(saved.id, 0, result: 'new answer'));
    await store.save(opened.copyWith(name: 'Renamed'));
    expect(store.byId(saved.id)!.name, 'Renamed');
    expect(store.byId(saved.id)!.lastResult, 'new answer');
  });

  test('history survives a reload, including tokens and tokens per second', () async {
    final saved = await store.save(daily());
    await store.recordRun(RoutineRun(
      id: 'r1',
      routineId: saved.id,
      startedAt: now,
      endedAt: now.add(const Duration(seconds: 8)),
      ok: true,
      result: 'done',
      inputTokens: 1200,
      outputTokens: 340,
      tokensPerSecond: 41.5,
      tokensEstimated: true,
    ));
    final reloaded = RoutineStore(prefs: prefs, native: native, clock: () => now);
    await reloaded.load();
    final run = reloaded.history(saved.id).single;
    expect(run.inputTokens, 1200);
    expect(run.outputTokens, 340);
    expect(run.tokensPerSecond, 41.5);
    expect(run.tokensEstimated, isTrue);
  });
}
