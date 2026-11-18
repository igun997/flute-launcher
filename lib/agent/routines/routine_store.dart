import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'routine.dart';
import 'routine_native.dart';

const _routinesKey = 'routines.list';
const _runsKey = 'routines.runs';
const _historyLimit = 20;
const _pauseAfterFailures = 2;
const _uuid = Uuid();

/// A change the person should read (validation, unknown routine).
class RoutineException implements Exception {
  const RoutineException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Saved routines and their history, in SharedPreferences. Every change re-syncs the native
/// schedule, so alarms match what is saved, even after the app was closed.
class RoutineStore extends ChangeNotifier {
  RoutineStore({required SharedPreferences prefs, RoutineNative? native, DateTime Function()? clock})
      : _prefs = prefs,
        _native = native,
        _clock = clock ?? DateTime.now;

  final SharedPreferences _prefs;
  final RoutineNative? _native;
  final DateTime Function() _clock;

  final List<Routine> _routines = [];
  final Map<String, List<RoutineRun>> _runs = {};

  DateTime now() => _clock();

  /// Reads the saved routines and pushes their schedule to native.
  Future<void> load() async {
    _routines.clear();
    _runs.clear();
    final rawRoutines = _prefs.getString(_routinesKey);
    if (rawRoutines != null) {
      for (final item in (jsonDecode(rawRoutines) as List)) {
        try {
          final routine = Routine.fromJson((item as Map).cast<String, Object?>());
          if (routine.id.isNotEmpty) _routines.add(routine);
        } catch (_) {
          // A damaged entry is dropped rather than blocking the rest.
        }
      }
    }
    final rawRuns = _prefs.getString(_runsKey);
    if (rawRuns != null) {
      final map = jsonDecode(rawRuns) as Map;
      for (final entry in map.entries) {
        final list = <RoutineRun>[];
        for (final item in (entry.value as List)) {
          try {
            list.add(RoutineRun.fromJson((item as Map).cast<String, Object?>()));
          } catch (_) {
            // Skip the damaged run.
          }
        }
        _runs[entry.key as String] = list.take(_historyLimit).toList();
      }
    }
    notifyListeners();
    await syncSchedules();
  }

  List<Routine> get routines => List.unmodifiable(_routines);

  Routine? byId(String id) {
    for (final routine in _routines) {
      if (routine.id == id) return routine;
    }
    return null;
  }

  /// Newest first, at most 20.
  List<RoutineRun> history(String routineId) => List.unmodifiable(_runs[routineId] ?? const []);

  RoutineRun? runById(String runId) {
    for (final runs in _runs.values) {
      for (final run in runs) {
        if (run.id == runId) return run;
      }
    }
    return null;
  }

  /// Adds or replaces a routine. An empty id gets a new one. Throws [RoutineException] when invalid.
  Future<Routine> save(Routine routine) async {
    final problem = routine.validationError();
    if (problem != null) throw RoutineException(problem);
    final index = _routines.indexWhere((r) => r.id == routine.id && routine.id.isNotEmpty);
    final Routine saved;
    if (index < 0) {
      saved = routine.copyWith(id: routine.id.isEmpty ? _uuid.v4() : routine.id);
      _routines.add(saved);
    } else {
      // The editor's copy may be older: keep what the runs recorded since it was opened.
      final stored = _routines[index];
      saved = routine.copyWith(lastRun: stored.lastRun, lastResult: stored.lastResult);
      _routines[index] = saved;
    }
    await _persist();
    notifyListeners();
    await syncSchedules();
    return saved;
  }

  Future<void> remove(String id) async {
    _routines.removeWhere((r) => r.id == id);
    _runs.remove(id);
    await _persist();
    notifyListeners();
    await syncSchedules();
  }

  Future<void> setEnabled(String id, bool on) async {
    final routine = byId(id);
    if (routine == null || routine.enabled == on) return;
    _replace(routine.copyWith(enabled: on));
    await _persist();
    notifyListeners();
    await syncSchedules();
  }

  /// Stores a finished run (newest first, trimmed to 20) and updates the routine's last result.
  /// A run for a routine that was removed meanwhile is dropped.
  Future<void> recordRun(RoutineRun run) async {
    final routine = byId(run.routineId);
    if (routine == null) return;
    final runs = [run, ...(_runs[run.routineId] ?? const <RoutineRun>[])];
    _runs[run.routineId] = runs.take(_historyLimit).toList();
    _replace(routine.copyWith(
      lastRun: run.startedAt,
      lastResult: RoutineRun.trimResult(run.summary),
    ));
    await _persist();
    notifyListeners();
  }

  /// Failed runs in a row, counting from the newest. Skipped runs do not count.
  int consecutiveFailures(String routineId) {
    var count = 0;
    for (final run in _runs[routineId] ?? const <RoutineRun>[]) {
      if (run.skipped) continue;
      if (!run.failed) break;
      count++;
    }
    return count;
  }

  /// Two failed runs in a row paused the routine (it is off, with failures behind it).
  bool isPaused(String routineId) {
    final routine = byId(routineId);
    return routine != null && !routine.enabled && consecutiveFailures(routineId) >= _pauseAfterFailures;
  }

  /// Fails twice in a row: switch the routine off. True when it was switched off now.
  Future<bool> pauseIfFailing(String routineId) async {
    final routine = byId(routineId);
    if (routine == null || !routine.enabled) return false;
    if (consecutiveFailures(routineId) < _pauseAfterFailures) return false;
    await setEnabled(routineId, false);
    return true;
  }

  DateTime? nextRun(String routineId) => byId(routineId)?.nextFire(now());

  /// Pushes every saved routine's next fire time to native, replacing the native schedule.
  Future<void> syncSchedules() async {
    final native = _native;
    if (native == null) return;
    final at = now();
    await native.sync([for (final r in _routines) r.scheduleItem(r.nextFire(at))]);
  }

  void _replace(Routine routine) {
    final index = _routines.indexWhere((r) => r.id == routine.id);
    if (index >= 0) _routines[index] = routine;
  }

  Future<void> _persist() async {
    await _prefs.setString(_routinesKey, jsonEncode([for (final r in _routines) r.toJson()]));
    await _prefs.setString(
      _runsKey,
      jsonEncode({for (final entry in _runs.entries) entry.key: [for (final run in entry.value) run.toJson()]}),
    );
  }
}
