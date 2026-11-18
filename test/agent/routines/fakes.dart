import 'dart:async';

import 'package:focus_launcher/agent/routines/routine_native.dart';

/// Records what the routines would ask Android to do. Never touches a platform channel.
class FakeRoutineNative extends RoutineNative {
  final syncs = <List<Map<String, Object?>>>[];
  final notifications = <Map<String, Object?>>[];
  final acked = <String>[];
  final finished = <String>[];
  List<RoutineFire> pending = [];
  String? openedRunId;
  bool screenOn = false;
  final _events = StreamController<RoutineNativeEvent>.broadcast();

  @override
  Stream<RoutineNativeEvent> get events => _events.stream;

  void emit(RoutineNativeEvent event) => _events.add(event);

  @override
  Future<void> sync(List<Map<String, Object?>> items) async => syncs.add(items);

  @override
  Future<bool> notify({
    required String routineId,
    required String runId,
    required String title,
    required String text,
    required bool ok,
  }) async {
    notifications.add({'routineId': routineId, 'runId': runId, 'title': title, 'text': text, 'ok': ok});
    return true;
  }

  @override
  Future<List<RoutineFire>> pendingFires() async => pending;

  @override
  Future<void> ackFire(String token) async => acked.add(token);

  @override
  Future<void> finishFire(String token) async => finished.add(token);

  @override
  Future<String?> takeOpenedRunId() async {
    final id = openedRunId;
    openedRunId = null;
    return id;
  }

  @override
  Future<bool> isScreenOn() async => screenOn;

  @override
  Future<bool> hasNotificationPermission() async => true;

  @override
  Future<bool> canScheduleExact() async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<void> openExactAlarmSettings() async {}

  Future<void> close() => _events.close();
}
