import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

/// One animation: a row of equally wide frames inside the pet's sheet.
class PetAnim {
  const PetAnim({required this.row, required this.frames, required this.fps});
  final int row;
  final int frames;
  final double fps;

  int frameAt(double seconds) => (seconds * fps).floor() % frames;
}

/// A character: its name, lines it says, and one GPU texture holding every frame plus its house.
///
/// Sheet layout (cell = [cell] px): rows 0..3 are walk, idle, sleep, happy with [frames] frames each;
/// the house sits below them in a square of [houseCell] px.
class PetSprites {
  PetSprites({required this.id, required this.name, required this.phrases, required this.sheet, required this.sheetLeft, required this.cell, required this.houseCell, required this.frames});

  final String id;
  final String name;
  final List<String> phrases;
  /// Frames facing right.
  final ui.Image sheet;

  /// The same frames mirrored to face left (frame order reversed within each row). Pre-mirrored so
  /// nothing has to be flipped at draw time.
  final ui.Image sheetLeft;
  final int cell;
  final int houseCell;
  final int frames;

  static const walk = PetAnim(row: 0, frames: 4, fps: 8);
  static const idle = PetAnim(row: 1, frames: 4, fps: 3);
  static const sleep = PetAnim(row: 2, frames: 4, fps: 1.6);
  static const happy = PetAnim(row: 3, frames: 4, fps: 8);

  ui.Image sheetFor({required bool left}) => left ? sheetLeft : sheet;

  /// The frame to draw at [seconds]. Inset by one pixel so linear filtering never samples the
  /// neighbouring frame.
  ui.Rect frameRect(PetAnim a, double seconds, {bool left = false}) {
    var f = a.frameAt(seconds);
    if (left) f = frames - 1 - f;
    return ui.Rect.fromLTWH(f * cell.toDouble(), a.row * cell.toDouble(), cell.toDouble(), cell.toDouble()).deflate(1);
  }

  ui.Rect get houseRect => ui.Rect.fromLTWH(0, 4 * cell.toDouble(), houseCell.toDouble(), houseCell.toDouble()).deflate(1);
}

/// Entry in `assets/pets/index.json`.
class PetInfo {
  const PetInfo({required this.id, required this.name, required this.phrases});
  final String id;
  final String name;
  final List<String> phrases;
}

/// Loads the character packs bundled under `assets/pets/`. Each pack is a folder named by its id
/// with `walk.png`, `idle.png`, `sleep.png`, `happy.png` (4 frames in a row) and `house.png`.
class PetLibrary {
  PetLibrary._(this.infos, this._cell, this._houseCell);

  final List<PetInfo> infos;
  final int _cell;
  final int _houseCell;
  final Map<String, PetSprites> _loaded = {};

  static Future<PetLibrary> open() async {
    final raw = jsonDecode(await rootBundle.loadString('assets/pets/index.json')) as Map<String, dynamic>;
    final infos = [
      for (final p in (raw['pets'] as List).cast<Map<String, dynamic>>())
        PetInfo(id: p['id'] as String, name: p['name'] as String, phrases: (p['phrases'] as List).cast<String>()),
    ];
    return PetLibrary._(infos, (raw['cell'] as num).toInt(), (raw['houseCell'] as num).toInt());
  }

  PetInfo? info(String id) {
    for (final i in infos) {
      if (i.id == id) return i;
    }
    return null;
  }

  Map<String, List<String>> get phrases => {for (final i in infos) i.id: i.phrases};

  /// Builds (once) the GPU sheet for [id].
  Future<PetSprites?> sprites(String id) async {
    final cached = _loaded[id];
    if (cached != null) return cached;
    final meta = info(id);
    if (meta == null) return null;
    try {
      final rows = [
        for (final n in ['walk', 'idle', 'sleep', 'happy']) await _decode('assets/pets/$id/$n.png'),
      ];
      final house = await _decode('assets/pets/$id/house.png');
      Future<ui.Image> compose({required bool mirror}) async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
        for (var r = 0; r < rows.length; r++) {
          canvas.save();
          if (mirror) {
            canvas.translate(4 * _cell.toDouble(), 0);
            canvas.scale(-1, 1);
          }
          canvas.drawImageRect(
            rows[r],
            ui.Rect.fromLTWH(0, 0, rows[r].width.toDouble(), rows[r].height.toDouble()),
            ui.Rect.fromLTWH(0, r * _cell.toDouble(), 4 * _cell.toDouble(), _cell.toDouble()),
            paint,
          );
          canvas.restore();
        }
        canvas.drawImageRect(
          house,
          ui.Rect.fromLTWH(0, 0, house.width.toDouble(), house.height.toDouble()),
          ui.Rect.fromLTWH(0, 4 * _cell.toDouble(), _houseCell.toDouble(), _houseCell.toDouble()),
          paint,
        );
        return recorder.endRecording().toImage(4 * _cell, 4 * _cell + _houseCell);
      }

      final sheet = await compose(mirror: false);
      final sheetLeft = await compose(mirror: true);
      for (final i in [...rows, house]) {
        i.dispose();
      }
      return _loaded[id] = PetSprites(id: id, name: meta.name, phrases: meta.phrases, sheet: sheet, sheetLeft: sheetLeft, cell: _cell, houseCell: _houseCell, frames: 4);
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image> _decode(String asset) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void dispose() {
    for (final s in _loaded.values) {
      s.sheet.dispose();
      s.sheetLeft.dispose();
    }
    _loaded.clear();
  }
}
