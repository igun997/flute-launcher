import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which provider and model draw pictures. Both null means Auto: every OpenAI-compatible provider
/// the user saved is searched, the active one first, so the pictures may come from a different
/// provider than the one that chats.
class ImageSettings extends ChangeNotifier {
  ImageSettings(this._prefs);

  static const _modelKey = 'agent.image.model';
  static const _profileKey = 'agent.image.profile';

  final SharedPreferences _prefs;

  String? get model => _read(_modelKey);

  /// The provider profile the chosen [model] belongs to. Null with a model set means "the active
  /// provider" (how the setting was stored before providers could be chosen).
  String? get profileId => _read(_profileKey);

  String? _read(String key) {
    final value = _prefs.getString(key);
    return value == null || value.isEmpty ? null : value;
  }

  /// Chooses a model of a provider, or Auto when [model] is null.
  Future<void> choose({String? profileId, String? model}) async {
    if (model == null || model.isEmpty) {
      await _prefs.remove(_modelKey);
      await _prefs.remove(_profileKey);
    } else {
      await _prefs.setString(_modelKey, model);
      if (profileId == null || profileId.isEmpty) {
        await _prefs.remove(_profileKey);
      } else {
        await _prefs.setString(_profileKey, profileId);
      }
    }
    notifyListeners();
  }
}
