
import 'package:flutter/foundation.dart';

import '../native/flute_native.dart';

/// In-memory cache of app icons (PNG bytes) fetched in batches from the native side.
class AppIcons extends ChangeNotifier {
  final Map<String, Uint8List> _icons = {};
  final Set<String> _requested = {};

  Uint8List? of(String package) => _icons[package];

  /// Fetches icons that are not cached yet. Safe to call repeatedly with the same list.
  Future<void> ensure(Iterable<String> packages) async {
    final missing = [
      for (final p in packages)
        if (!_icons.containsKey(p) && _requested.add(p)) p,
    ];
    if (missing.isEmpty) return;
    final got = await FluteNative.getIcons(missing);
    if (got.isEmpty) return;
    _icons.addAll(got);
    notifyListeners();
  }
}
