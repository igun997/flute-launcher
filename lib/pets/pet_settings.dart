import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which characters live on the home screen. Persisted.
class PetSettings extends ChangeNotifier {
  PetSettings(this._prefs) {
    _enabled = _prefs.getBool(_kEnabled) ?? true;
    final saved = _prefs.getStringList(_kSelected) ?? const ['pip'];
    // An older version let several characters share the stage; keep only the first.
    _selected = saved.isEmpty ? const ['pip'] : [saved.first];
  }

  static const _kEnabled = 'pets.enabled';
  static const _kSelected = 'pets.selected';

  /// One character lives on the home screen at a time, so the stage stays calm.
  static const maxPets = 1;

  final SharedPreferences _prefs;
  late bool _enabled;
  late List<String> _selected;

  DateTime _lastHit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Called when a tap landed on a pet or house, so the home page's double-tap to lock can tell it
  /// was meant for the character.
  void markHit() => _lastHit = DateTime.now();

  bool get hitRecently => DateTime.now().difference(_lastHit) < const Duration(milliseconds: 600);

  bool get enabled => _enabled;
  List<String> get selected => List.unmodifiable(_selected);

  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    notifyListeners();
    await _prefs.setBool(_kEnabled, v);
  }

  /// Makes [id] the character on the home screen.
  Future<void> select(String id) async {
    if (_selected.length == 1 && _selected.first == id) return;
    _selected = [id];
    notifyListeners();
    await _prefs.setStringList(_kSelected, _selected);
  }
}
