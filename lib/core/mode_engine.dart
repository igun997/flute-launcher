import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../native/flute_native.dart';
import 'models.dart';

/// Which mode is active and what it means for each app.
///
/// Priority: timed override, then a covering schedule, then the base mode.
/// Apps on the always-allowed list ignore every rule.
class ModeEngine extends ChangeNotifier {
  ModeEngine(this._prefs, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final SharedPreferences _prefs;
  final DateTime Function() _clock;
  Timer? _tick;

  String _baseId = Mode.free.id;
  String? _overrideId;
  DateTime? _overrideUntil;
  List<Schedule> _schedules = [];
  Set<String> _allowed = {};
  bool dndInSleep = true;
  int pauseSeconds = 10;
  int graceMinutes = 5;

  static const _kBase = 'mode.base';
  static const _kOverride = 'mode.override';
  static const _kUntil = 'mode.until';
  static const _kSchedules = 'mode.schedules';
  static const _kAllowed = 'mode.allowed';
  static const _kDnd = 'mode.dndSleep';
  static const _kPause = 'lock.pause';
  static const _kGrace = 'lock.grace';

  /// Packages that are never locked, whatever the mode says.
  static const defaultAllowed = <String>{
    'com.android.dialer',
    'com.google.android.dialer',
    'com.samsung.android.dialer',
    'com.android.settings',
    'com.android.emergency',
  };

  void load() {
    _baseId = _prefs.getString(_kBase) ?? Mode.free.id;
    _overrideId = _prefs.getString(_kOverride);
    final until = _prefs.getInt(_kUntil);
    _overrideUntil = until == null ? null : DateTime.fromMillisecondsSinceEpoch(until);
    final raw = _prefs.getString(_kSchedules);
    if (raw != null) {
      _schedules = (jsonDecode(raw) as List)
          .map((e) => Schedule.fromJson((e as Map).cast<String, Object?>()))
          .toList();
    }
    _allowed = {...defaultAllowed, ...?_prefs.getStringList(_kAllowed)};
    dndInSleep = _prefs.getBool(_kDnd) ?? true;
    pauseSeconds = _prefs.getInt(_kPause) ?? pauseSeconds;
    graceMinutes = _prefs.getInt(_kGrace) ?? graceMinutes;
    _expireOverride();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      final before = current.id;
      _expireOverride();
      if (current.id != before) {
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _expireOverride() {
    final until = _overrideUntil;
    if (until != null && !until.isAfter(_clock())) {
      _overrideId = null;
      _overrideUntil = null;
      _prefs.remove(_kOverride);
      _prefs.remove(_kUntil);
    }
  }

  Mode get current {
    final o = _overrideId;
    if (o != null && _overrideUntil != null && _overrideUntil!.isAfter(_clock())) return Mode.byId(o);
    final now = _clock();
    for (final s in _schedules) {
      if (s.covers(now)) return Mode.byId(s.modeId);
    }
    return Mode.byId(_baseId);
  }

  Mode get base => Mode.byId(_baseId);
  DateTime? get overrideUntil => _overrideUntil;
  List<Schedule> get schedules => List.unmodifiable(_schedules);
  Set<String> get allowed => Set.unmodifiable(_allowed);

  /// Switches the base mode and clears any timer.
  Future<void> setMode(Mode m) async {
    _baseId = m.id;
    _overrideId = null;
    _overrideUntil = null;
    await _prefs.setString(_kBase, m.id);
    await _prefs.remove(_kOverride);
    await _prefs.remove(_kUntil);
    notifyListeners();
  }

  /// Ends the current mode early and goes to Free. If a schedule is what put the phone in this
  /// mode, Free holds until that schedule's window ends instead of snapping straight back.
  Future<void> wakeUp() async {
    final now = _clock();
    for (final s in _schedules) {
      if (s.covers(now) && s.modeId == current.id) {
        await _clearOverrideOnly();
        await startTimer(Mode.free, s.endsAt(now).difference(now));
        return;
      }
    }
    await setMode(Mode.free);
  }

  Future<void> _clearOverrideOnly() async {
    _overrideId = null;
    _overrideUntil = null;
    await _prefs.remove(_kOverride);
    await _prefs.remove(_kUntil);
  }

  /// Applies [m] for [d], after which the previous behaviour returns.
  Future<void> startTimer(Mode m, Duration d) async {
    _overrideId = m.id;
    _overrideUntil = _clock().add(d);
    await _prefs.setString(_kOverride, m.id);
    await _prefs.setInt(_kUntil, _overrideUntil!.millisecondsSinceEpoch);
    notifyListeners();
  }

  Future<void> setSchedules(List<Schedule> s) async {
    _schedules = [...s];
    await _prefs.setString(_kSchedules, jsonEncode(_schedules.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> setAllowed(String package, bool allowed) async {
    allowed ? _allowed.add(package) : _allowed.remove(package);
    await _prefs.setStringList(_kAllowed, _allowed.where((p) => !defaultAllowed.contains(p)).toList());
    notifyListeners();
  }

  /// True when the active mode asks for Do Not Disturb and the user allows it.
  bool get wantsDnd => dndInSleep && current.dnd;

  Future<void> setDndInSleep(bool v) async {
    dndInSleep = v;
    await _prefs.setBool(_kDnd, v);
    notifyListeners();
  }

  Future<void> setLockTimings({int? pause, int? grace}) async {
    if (pause != null) {
      pauseSeconds = pause;
      await _prefs.setInt(_kPause, pause);
    }
    if (grace != null) {
      graceMinutes = grace;
      await _prefs.setInt(_kGrace, grace);
    }
    notifyListeners();
  }

  /// The rule that applies to [app] right now.
  Rule ruleFor(FluteApp app) {
    if (_allowed.contains(app.package)) return Rule.show;
    return current.ruleFor(app.category);
  }

  /// Everything the native lock service needs. Hidden apps are locked too, so
  /// opening one through search still goes through the pause.
  LockConfig lockConfig(Iterable<FluteApp> apps) {
    final locked = <String>[];
    for (final a in apps) {
      if (ruleFor(a) != Rule.show) locked.add(a.package);
    }
    return LockConfig(
      enabled: locked.isNotEmpty,
      lockedPackages: locked,
      allowedPackages: _allowed.toList(),
      pauseSeconds: pauseSeconds,
      graceMinutes: graceMinutes,
    );
  }
}
