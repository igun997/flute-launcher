import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../core/redrawn_icons.dart';

/// Luminance-preserving grayscale, so every app icon fits the muted theme.
const _grayscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
]);

const _tone = ColorFilter.mode(Color(0xFFB9C2C6), BlendMode.modulate);
const _toneLight = ColorFilter.mode(Color(0xFF59646E), BlendMode.modulate);

/// A small gray app icon. [dim] lowers it further, e.g. for apps a mode pauses.
class GrayIcon extends StatelessWidget {
  const GrayIcon({super.key, required this.bytes, this.size = 40, this.dim = false, this.light = false});

  final Uint8List? bytes;
  final double size;
  final bool dim;

  /// True on a bright sky: icons are toned darker so they do not wash out.
  final bool light;

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    if (b == null) {
      return SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(color: const Color(0x22FFFFFF), borderRadius: BorderRadius.circular(size * 0.28)),
        ),
      );
    }
    // Grayscale first, then a cool gray multiply so white icons do not glare against the dark theme.
    return Opacity(
      opacity: dim ? 0.35 : (light ? 0.92 : 0.78),
      child: ColorFiltered(
        colorFilter: light ? _toneLight : _tone,
        child: ColorFiltered(
          colorFilter: _grayscale,
          child: Image.memory(b, width: size, height: size, gaplessPlayback: true, filterQuality: FilterQuality.medium),
        ),
      ),
    );
  }
}

/// A pinned app's icon. Apps with a Flute-drawn line icon get it inside a soft rounded tile, tinted
/// to the sky's ink so it reads on day and night; any other app keeps its own icon, toned gray.
class PinIcon extends StatelessWidget {
  const PinIcon({super.key, required this.package, required this.bytes, required this.ink, required this.light, this.size = 42, this.dim = false});

  final String package;
  final Uint8List? bytes;
  final Color ink;
  final bool light;
  final double size;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final asset = redrawnIconAsset(package);
    if (asset == null) return GrayIcon(bytes: bytes, size: size, dim: dim, light: light);
    final glyph = dim ? ink.withValues(alpha: 0.45) : ink;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.17),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: ink.withValues(alpha: dim ? 0.12 : 0.26)),
      ),
      child: Image.asset(asset, color: glyph, colorBlendMode: BlendMode.srcIn, filterQuality: FilterQuality.medium),
    );
  }
}
