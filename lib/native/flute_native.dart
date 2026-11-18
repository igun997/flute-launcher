import 'dart:async';


import 'package:flutter/services.dart';

/// A launchable app reported by Android LauncherApps.
class InstalledApp {
  const InstalledApp({
    required this.package,
    required this.label,
    required this.androidCategory,
    required this.isSystem,
  });

  final String package;
  final String label;

  /// `ApplicationInfo.category`; -1 when the app does not declare one.
  final int androidCategory;
  final bool isSystem;

  factory InstalledApp._fromMap(Map<Object?, Object?> map) => InstalledApp(
    package: _string(map['package']),
    label: _string(map['label']),
    androidCategory: _int(map['category'], -1),
    isSystem: map['isSystem'] == true,
  );
}

/// Foreground time for one package since local midnight.
class UsageEntry {
  const UsageEntry({required this.package, required this.foregroundMs});

  final String package;
  final int foregroundMs;

  factory UsageEntry._fromMap(Map<Object?, Object?> map) => UsageEntry(
    package: _string(map['package']),
    foregroundMs: _int(map['foregroundMs']),
  );
}

/// A WhatsApp or SMS message captured from a notification.
class RecentMessage {
  const RecentMessage({
    required this.id,
    required this.source,
    required this.package,
    required this.sender,
    required this.text,
    required this.timestampMs,
    required this.conversationKey,
  });

  final String id;

  /// `whatsapp` or `sms`.
  final String source;
  final String package;
  final String sender;
  final String text;
  final int timestampMs;

  /// `package|conversation title`.
  final String conversationKey;

  DateTime get timestamp => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  factory RecentMessage._fromMap(Map<Object?, Object?> map) => RecentMessage(
    id: _string(map['id']),
    source: _string(map['source']),
    package: _string(map['package']),
    sender: _string(map['sender']),
    text: _string(map['text']),
    timestampMs: _int(map['timestampMs']),
    conversationKey: _string(map['conversationKey']),
  );
}

/// Soft-lock settings pushed to the native foreground LockService.
class LockConfig {
  const LockConfig({
    required this.enabled,
    required this.lockedPackages,
    required this.allowedPackages,
    required this.pauseSeconds,
    required this.graceMinutes,
  });

  final bool enabled;
  final List<String> lockedPackages;

  /// Overrides [lockedPackages]: these are never locked.
  final List<String> allowedPackages;
  final int pauseSeconds;

  /// Minutes a package stays open after "Open anyway".
  final int graceMinutes;

  Map<String, Object?> toMap() => <String, Object?>{
    'enabled': enabled,
    'lockedPackages': lockedPackages,
    'allowedPackages': allowedPackages,
    'pauseSeconds': pauseSeconds,
    'graceMinutes': graceMinutes,
  };
}

/// Wake-related device state. [WakeInfo.none] is used when the platform cannot answer.
class WakeInfo {
  const WakeInfo({
    required this.systemDoubleTapWake,
    required this.systemDoubleTapSleep,
    required this.hasProximity,
    required this.waveToWake,
  });

  /// Nothing known: every flag is false.
  static const WakeInfo none = WakeInfo(
    systemDoubleTapWake: false,
    systemDoubleTapSleep: false,
    hasProximity: false,
    waveToWake: false,
  );

  /// System "double tap to wake" is on (the Samsung key spelling is accepted too).
  final bool systemDoubleTapWake;

  /// System "double tap to sleep" is on.
  final bool systemDoubleTapSleep;

  /// The device has a proximity sensor, which wave-to-wake needs.
  final bool hasProximity;

  /// Flute's own wave-to-wake setting.
  final bool waveToWake;

  factory WakeInfo._fromMap(Map<Object?, Object?> map) => WakeInfo(
    systemDoubleTapWake: map['systemDoubleTapWake'] == true,
    systemDoubleTapSleep: map['systemDoubleTapSleep'] == true,
    hasProximity: map['hasProximity'] == true,
    waveToWake: map['waveToWake'] == true,
  );
}

/// Event pushed from native on the `flute/events` channel.
///
/// `type` is `message` (with [message] set), `homePressed`, or `surface` (with [surface] set to
/// 'lock' or 'home').
class NativeEvent {
  const NativeEvent({required this.type, this.message, this.surface});

  final String type;
  final RecentMessage? message;
  final String? surface;

  bool get isSurface => type == 'surface' && surface != null;

  bool get isMessage => type == 'message' && message != null;
  bool get isHomePressed => type == 'homePressed';
}

/// Platform bridge for the Android launcher features. Every call degrades to
/// an empty, `false` or no-op result when the platform throws or is missing.
abstract final class FluteNative {
  static const MethodChannel _channel = MethodChannel('flute/native');
  static const EventChannel _eventChannel = EventChannel('flute/events');

  static final Stream<NativeEvent> _events = _eventChannel
      .receiveBroadcastStream()
      .handleError((Object _) {})
      .expand<NativeEvent>((Object? raw) {
        final event = _parseEvent(raw);
        return event == null ? const <NativeEvent>[] : <NativeEvent>[event];
      })
      .asBroadcastStream();

  /// Native events (captured messages, home button). Subscribing attaches the
  /// native sink; cancelling detaches it.
  static Stream<NativeEvent> get events => _events;

  /// Launchable apps, excluding Flute itself.
  static Future<List<InstalledApp>> getApps() async {
    return _maps(
      await _call('getApps'),
    ).map(InstalledApp._fromMap).toList(growable: false);
  }

  static Future<bool> launchApp(String package) async =>
      _bool(await _call('launchApp', {'package': package}));

  static Future<void> openAppInfo(String package) async {
    await _call('openAppInfo', {'package': package});
  }

  static Future<bool> hasUsageAccess() async =>
      _bool(await _call('hasUsageAccess'));

  static Future<void> openUsageAccessSettings() async {
    await _call('openUsageAccessSettings');
  }

  /// Foreground time per package since local midnight, largest first.
  static Future<List<UsageEntry>> getUsageToday() async {
    return _maps(
      await _call('getUsageToday'),
    ).map(UsageEntry._fromMap).toList(growable: false);
  }

  static Future<bool> hasNotificationAccess() async =>
      _bool(await _call('hasNotificationAccess'));

  static Future<void> openNotificationAccessSettings() async {
    await _call('openNotificationAccessSettings');
  }

  static Future<bool> hasOverlayPermission() async =>
      _bool(await _call('hasOverlayPermission'));

  static Future<void> openOverlaySettings() async {
    await _call('openOverlaySettings');
  }

  /// Newest first. Messages are persisted natively (max 200).
  static Future<List<RecentMessage>> getRecentMessages({int limit = 30}) async {
    return _maps(
      await _call('getRecentMessages', {'limit': limit}),
    ).map(RecentMessage._fromMap).toList(growable: false);
  }

  static Future<void> clearRecentMessages() async {
    await _call('clearRecentMessages');
  }

  /// Saves [config] and starts or stops the foreground LockService.
  static Future<void> setLockConfig(LockConfig config) async {
    await _call('setLockConfig', config.toMap());
  }

  /// "Do Not Disturb access", needed for [setDoNotDisturb].
  static Future<bool> hasPolicyAccess() async => _bool(await _call('hasPolicyAccess'));

  static Future<void> openPolicyAccessSettings() async {
    await _call('openPolicyAccessSettings');
  }

  /// Turns alarms-only Do Not Disturb on or off. Turning it off restores whatever was set
  /// before Flute turned it on. Returns false when access has not been granted.
  static Future<bool> setDoNotDisturb(bool enabled) async =>
      _bool(await _call('setDoNotDisturb', {'enabled': enabled}));

  /// PNG icon bytes per package (square [size] px). Packages that fail are left out.
  static Future<Map<String, Uint8List>> getIcons(List<String> packages, {int size = 96}) async {
    final raw = await _call('getIcons', {'packages': packages, 'size': size});
    if (raw is! Map) return const {};
    final out = <String, Uint8List>{};
    raw.forEach((k, v) {
      if (k is String && v is Uint8List) out[k] = v;
    });
    return out;
  }

  /// Which surface the engine is attached to: 'lock' over the keyguard, otherwise 'home'.
  static Future<String> getSurface() async {
    final v = await _call('getSurface');
    return v == 'lock' ? 'lock' : 'home';
  }

  static Future<void> setLockscreenEnabled(bool enabled) async {
    await _call('setLockscreenEnabled', {'enabled': enabled});
  }

  static Future<bool> isLockscreenEnabled() async => _bool(await _call('isLockscreenEnabled'));

  static Future<bool> isKeyguardLocked() async => _bool(await _call('isKeyguardLocked'));

  /// Asks the system to dismiss the keyguard (PIN or biometric prompt on secure devices).
  /// True once unlocked; the lockscreen activity then finishes itself.
  static Future<bool> dismissKeyguard() async => _bool(await _call('dismissKeyguard'));

  static Future<void> finishLockscreen() async {
    await _call('finishLockscreen');
  }

  static Future<bool> isDefaultLauncher() async =>
      _bool(await _call('isDefaultLauncher'));

  static Future<void> openHomeSettings() async {
    await _call('openHomeSettings');
  }

  /// Not available to third-party apps on current Android; native side is a no-op.
  static Future<void> expandNotificationShade() async {
    await _call('expandNotificationShade');
  }

  /// Locks the screen through Flute's accessibility service (double-tap to lock). Returns `false`
  /// when the service is not enabled and connected, or when the device runs below Android 9.
  static Future<bool> lockScreen() async => _bool(await _call('lockScreen'));

  /// True when Flute's accessibility service is enabled in Settings and connected.
  static Future<bool> isAccessibilityEnabled() async =>
      _bool(await _call('isAccessibilityEnabled'));

  static Future<void> openAccessibilitySettings() async {
    await _call('openAccessibilitySettings');
  }

  /// Wake and double-tap state. Falls back to [WakeInfo.none] when the platform cannot answer.
  static Future<WakeInfo> getWakeInfo() async {
    final raw = await _call('getWakeInfo');
    return raw is Map<Object?, Object?> ? WakeInfo._fromMap(raw) : WakeInfo.none;
  }

  /// Turns the two-wave wake gesture on or off. Turning it off stops the proximity sensor.
  static Future<void> setWaveToWake(bool enabled) async {
    await _call('setWaveToWake', {'enabled': enabled});
  }

  static Future<bool> isWaveToWakeEnabled() async =>
      _bool(await _call('isWaveToWakeEnabled'));

  /// Best effort: Samsung's motions-and-gestures settings, else display settings. Never throws.
  static Future<void> openMotionSettings() async {
    await _call('openMotionSettings');
  }

  /// True when coarse location (ACCESS_COARSE_LOCATION) is granted.
  static Future<bool> hasLocationPermission() async =>
      _bool(await _call('hasLocationPermission'));

  /// Shows the system dialog for coarse location when it is not granted yet. True when granted.
  static Future<bool> requestLocationPermission() async =>
      _bool(await _call('requestLocationPermission'));

  /// One coarse fix, or null when there is no permission, no fix in time, or no provider.
  static Future<({double latitude, double longitude})?> getLocation() async {
    final raw = await _call('getLocation');
    if (raw is! Map<Object?, Object?>) return null;
    final latitude = raw['latitude'];
    final longitude = raw['longitude'];
    if (latitude is! num || longitude is! num) return null;
    return (latitude: latitude.toDouble(), longitude: longitude.toDouble());
  }

  /// Place names for a point. [name] is the locality, else the sub-admin area, else the admin
  /// area. Null when the platform has no geocoder or cannot name the point.
  static Future<({String name, String admin, String country})?> reverseGeocode(
    double latitude,
    double longitude,
  ) async {
    final raw = await _call('reverseGeocode', {
      'latitude': latitude,
      'longitude': longitude,
    });
    if (raw is! Map<Object?, Object?>) return null;
    final name = _string(raw['name']);
    if (name.isEmpty) return null;
    return (
      name: name,
      admin: _string(raw['admin']),
      country: _string(raw['country']),
    );
  }

  static Future<Object?> _call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on Exception {
      return null;
    }
  }

  static NativeEvent? _parseEvent(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return null;
    }
    final type = _string(raw['type']);
    if (type.isEmpty) {
      return null;
    }
    final message = raw['message'];
    return NativeEvent(
      type: type,
      message: message is Map<Object?, Object?>
          ? RecentMessage._fromMap(message)
          : null,
      surface: raw['surface'] is String ? raw['surface'] as String : null,
    );
  }

  static bool _bool(Object? value) => value == true;

  static List<Map<Object?, Object?>> _maps(Object? value) => value is List
      ? value.whereType<Map<Object?, Object?>>().toList(growable: false)
      : const <Map<Object?, Object?>>[];
}

String _string(Object? value) => value is String ? value : '';

int _int(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;
