import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which image model the agent uses. Null means Auto: the first one the provider offers.
class ImageSettings extends ChangeNotifier {
  ImageSettings(this._prefs);

  static const _key = 'agent.image.model';

  final SharedPreferences _prefs;

  String? get model {
    final value = _prefs.getString(_key);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> setModel(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(_key);
    } else {
      await _prefs.setString(_key, id);
    }
    notifyListeners();
  }
}
