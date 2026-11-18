import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/core/default_pins.dart';
import 'package:focus_launcher/core/redrawn_icons.dart';

void main() {
  test('every default pin has a redrawn icon', () {
    for (final slot in defaultPinSlots) {
      for (final pkg in slot) {
        expect(redrawnIconAsset(pkg), isNotNull, reason: pkg);
      }
    }
  });

  test('every mapped icon file exists and is a non-empty PNG', () {
    for (final key in redrawnIconKeys) {
      final f = File('assets/icons/$key.png');
      expect(f.existsSync(), isTrue, reason: key);
      final bytes = f.readAsBytesSync();
      expect(bytes.length, greaterThan(500), reason: key);
      expect(bytes.sublist(1, 4), [0x50, 0x4E, 0x47], reason: '$key is not a PNG');
    }
  });

  test('other apps keep their own icon', () {
    expect(redrawnIconAsset('com.example.unknown'), isNull);
    expect(redrawnIconAsset('com.bca.blu'), isNull);
  });
}
