import 'dart:async';

import 'package:flutter/services.dart';

/// A fire the native scheduler queued: a routine's time came, or "Run again" was tapped.
class RoutineFire {
  const RoutineFire({
    required this.token,
    required this.routineId,
    required this.firedAt,
    required this.manual,
  });

  /// Unique per fire; acknowledged to native once Dart takes it.
  final String token;
  final String routineId;
  final DateTime firedAt;

  /// True for "Run again" from a notification, false for the schedule.
  final bool manual;

  factory RoutineFire.fromMap(Map<Object?, Object?> map) => RoutineFire(
        token: _string(map['token']),
        routineId: _string(map['routineId']),
        firedAt: DateTime.fromMillisecondsSinceEpoch(_int(map['firedAtMs'])),
        manual: map['manual'] == true,
      );
}

/// One event from the routines channel: a fire, or a notification tap that opens a run.
class RoutineNativeEvent {
  const RoutineNativeEvent._({this.fire, this.openedRunId});
  const RoutineNativeEvent.fired(RoutineFire fire) : this._(fire: fire);
  const RoutineNativeEvent.opened(String runId) : this._(openedRunId: runId);

  final RoutineFire? fire;
  final String? openedRunId;
}

/// Platform bridge for routines: the alarm schedule, notifications, exact-alarm and notification
/// permissions, and the fires queued while Dart was not running. Every call degrades to a
/// `false`, `null` or no-op result when the platform fails, so the rest of the app keeps working.
class RoutineNative {
  RoutineNative({MethodChannel? channel, EventChannel? eventChannel})
      : _channel = channel ?? const MethodChannel('flute/routines'),
        _eventChannel = eventChannel ?? const EventChannel('flute/routines/events');

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  Stream<RoutineNativeEvent>? _events;

  /// Fires and open requests. Subscribing attaches the native sink.
  Stream<RoutineNativeEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .handleError((Object _) {})
      .expand<RoutineNativeEvent>((Object? raw) {
        final event = _parse(raw);
        return event == null ? const <RoutineNativeEvent>[] : <RoutineNativeEvent>[event];
      })
      .asBroadcastStream();

  /// Replaces the native schedule with [items] (see `Routine.scheduleItem`).
  Future<void> sync(List<Map<String, Object?>> items) async {
    await _call('sync', {'items': items});
  }

  /// Exact alarms are allowed (always true below Android 12).
  Future<bool> canScheduleExact() async => _bool(await _call('canScheduleExact'));

  Future<void> openExactAlarmSettings() async {
    await _call('openExactAlarmSettings');
  }

  /// Notifications can be shown (Android 13 permission and the app's notification switch).
  Future<bool> hasNotificationPermission() async => _bool(await _call('hasNotificationPermission'));

  /// Shows the Android 13 dialog when needed. True when allowed. Only works while the launcher is open.
  Future<bool> requestNotificationPermission() async =>
      _bool(await _call('requestNotificationPermission'));

  /// Posts or replaces the result notification of one routine. False when it could not be shown.
  Future<bool> notify({
    required String routineId,
    required String runId,
    required String title,
    required String text,
    required bool ok,
  }) async =>
      _bool(await _call('notify', {
        'routineId': routineId,
        'runId': runId,
        'title': title,
        'text': text,
        'ok': ok,
      }));

  Future<List<RoutineFire>> pendingFires() async {
    final raw = await _call('pendingFires');
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map<Object?, Object?>) RoutineFire.fromMap(item),
    ];
  }

  /// Dart has taken [token]: native drops it from the queue.
  Future<void> ackFire(String token) async {
    await _call('ackFire', {'token': token});
  }

  /// The run for [token] is over: the wake lock can go.
  Future<void> finishFire(String token) async {
    await _call('finishFire', {'token': token});
  }

  /// The run a notification tap asked to open, once.
  Future<String?> takeOpenedRunId() async {
    final raw = await _call('takeOpenedRun');
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  /// True when the screen is on (speech is only for a screen the person can see).
  Future<bool> isScreenOn() async => _bool(await _call('isScreenOn'));

  Future<Object?> _call(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on Exception {
      return null;
    }
  }

  static RoutineNativeEvent? _parse(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    switch (_string(raw['type'])) {
      case 'fire':
        return RoutineNativeEvent.fired(RoutineFire.fromMap(raw));
      case 'opened':
        final runId = _string(raw['runId']);
        return runId.isEmpty ? null : RoutineNativeEvent.opened(runId);
      default:
        return null;
    }
  }

  static bool _bool(Object? value) => value == true;
}

String _string(Object? value) => value is String ? value : '';

int _int(Object? value, [int fallback = 0]) => value is num ? value.toInt() : fallback;
