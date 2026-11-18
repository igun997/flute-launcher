import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../native/flute_native.dart';

/// User choices for the lockscreen. Previews are off by default: no message text is shown before
/// unlock unless the user turns them on.
class LockSettings extends ChangeNotifier {
  LockSettings(this._prefs);

  static const _kEnabled = 'lock.enabled';
  static const _kPreviews = 'lock.previews';

  final SharedPreferences _prefs;
  bool _enabled = false;
  bool _showPreviews = false;

  bool get enabled => _enabled;
  bool get showPreviews => _showPreviews;

  /// Loads the saved choices and pushes [enabled] to native so both sides agree.
  Future<void> init() async {
    _enabled = _prefs.getBool(_kEnabled) ?? false;
    _showPreviews = _prefs.getBool(_kPreviews) ?? false;
    notifyListeners();
    await FluteNative.setLockscreenEnabled(_enabled);
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled != value) {
      _enabled = value;
      notifyListeners();
    }
    await _prefs.setBool(_kEnabled, value);
    await FluteNative.setLockscreenEnabled(value);
  }

  Future<void> setShowPreviews(bool value) async {
    if (_showPreviews != value) {
      _showPreviews = value;
      notifyListeners();
    }
    await _prefs.setBool(_kPreviews, value);
  }
}
