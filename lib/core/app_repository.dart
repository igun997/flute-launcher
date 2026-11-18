import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../native/flute_native.dart';
import 'category_engine.dart';
import 'default_pins.dart';
import 'models.dart';

/// Installed apps with categories, favorites and today's usage.
class AppRepository extends ChangeNotifier {
  AppRepository(this._prefs, this._engine);

  final SharedPreferences _prefs;
  final CategoryEngine _engine;

  List<FluteApp> _apps = const [];
  List<String> _favorites = [];
  Map<String, int> _usageMs = const {};
  bool _loading = false;

  static const _kOverrides = 'apps.overrides';
  static const _kFavorites = 'apps.favorites';
  static const maxFavorites = 8;

  List<FluteApp> get apps => _apps;
  bool get loading => _loading;
  List<String> get favoritePackages => List.unmodifiable(_favorites);

  List<FluteApp> get favorites {
    final byPkg = {for (final a in _apps) a.package: a};
    return [for (final p in _favorites) if (byPkg[p] != null) byPkg[p]!];
  }

  /// Today's foreground time per category, largest first, zeros dropped.
  List<(AppCategory, Duration)> get usageByCategory {
    final totals = <AppCategory, int>{};
    final byPkg = {for (final a in _apps) a.package: a};
    _usageMs.forEach((pkg, ms) {
      final app = byPkg[pkg];
      if (app == null || ms <= 0) return;
      totals.update(app.category, (v) => v + ms, ifAbsent: () => ms);
    });
    final list = totals.entries.map((e) => (e.key, Duration(milliseconds: e.value))).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return list;
  }

  Duration get totalUsage => Duration(milliseconds: _usageMs.values.fold(0, (a, b) => a + b));

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    _favorites = _prefs.getStringList(_kFavorites) ?? [];
    final raw = _prefs.getString(_kOverrides);
    if (raw != null) {
      final m = (jsonDecode(raw) as Map).cast<String, String>();
      _engine.overrides
        ..clear()
        ..addEntries(m.entries.map((e) => MapEntry(e.key, AppCategory.fromName(e.value) ?? AppCategory.other)));
    }
    await _reload();
    // First run only: an empty list the user cleared on purpose stays empty.
    if (!_prefs.containsKey(_kFavorites)) {
      _favorites = resolveDefaultPins({for (final a in _apps) a.package});
      await _prefs.setStringList(_kFavorites, _favorites);
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> _reload() async {
    final installed = await FluteNative.getApps();
    _apps = [
      for (final a in installed)
        FluteApp(
          package: a.package,
          label: a.label,
          isSystem: a.isSystem,
          category: _engine.categorize(a.package, a.label, androidCategory: a.androidCategory),
        ),
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    await refreshUsage(notify: false);
  }

  /// Reloads the list (after installs/uninstalls) and usage.
  Future<void> refresh() async {
    await _reload();
    notifyListeners();
  }

  Future<void> refreshUsage({bool notify = true}) async {
    if (await FluteNative.hasUsageAccess()) {
      final u = await FluteNative.getUsageToday();
      _usageMs = {for (final e in u) e.package: e.foregroundMs};
    } else {
      _usageMs = const {};
    }
    if (notify) notifyListeners();
  }

  Future<void> setCategory(FluteApp app, AppCategory category) async {
    _engine.overrides[app.package] = category;
    await _prefs.setString(_kOverrides, jsonEncode({for (final e in _engine.overrides.entries) e.key: e.value.name}));
    _apps = [
      for (final a in _apps)
        if (a.package == app.package)
          FluteApp(package: a.package, label: a.label, category: category, isSystem: a.isSystem)
        else
          a,
    ];
    notifyListeners();
  }

  /// Replaces the pinned list (at most [maxFavorites]).
  Future<void> setFavorites(List<String> packages) async {
    _favorites = packages.take(maxFavorites).toList();
    await _prefs.setStringList(_kFavorites, _favorites);
    notifyListeners();
  }

  bool isFavorite(String package) => _favorites.contains(package);

  /// Returns false when the list is full.
  Future<bool> toggleFavorite(String package) async {
    if (_favorites.contains(package)) {
      _favorites.remove(package);
    } else {
      if (_favorites.length >= maxFavorites) return false;
      _favorites.add(package);
    }
    await _prefs.setStringList(_kFavorites, _favorites);
    notifyListeners();
    return true;
  }

  FluteApp? byPackage(String package) {
    for (final a in _apps) {
      if (a.package == package) return a;
    }
    return null;
  }
}
