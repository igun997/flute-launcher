import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../app/flute.dart';
import '../core/day_style.dart';
import '../weather/weather_service.dart';
import 'pet_library.dart';
import 'pet_world.dart';

/// Why the pets want to be indoors right now: bedtime beats rain.
Shelter shelterFor({required WeatherKind kind, required DayPhase phase, required bool sleepMode, required int hour}) {
  final late = hour >= 21 || hour < 5;
  if (sleepMode || late) return Shelter.sleep;
  final wet = kind == WeatherKind.drizzle || kind == WeatherKind.rain || kind == WeatherKind.thunder || kind == WeatherKind.snow;
  return wet ? Shelter.rain : Shelter.none;
}

/// The animation row for what the pet is doing.
PetAnim animFor(PetMode mode) => switch (mode) {
  PetMode.walking || PetMode.goingHome => PetSprites.walk,
  PetMode.sleeping => PetSprites.sleep,
  PetMode.happy => PetSprites.happy,
  _ => PetSprites.idle,
};

/// A cheap fingerprint of everything that changes what is drawn. The stage only asks for a new
/// frame when it changes, so a pet standing still costs a few repaints a second, not fifteen.
int worldSignature(PetWorld w) {
  var h = 17;
  for (final a in w.actors) {
    h = h * 31 + a.x.round();
    h = h * 31 + a.mode.index;
    h = h * 31 + (a.fade * 10).round();
    h = h * 31 + (a.say == null ? 0 : 1);
    h = h * 31 + animFor(a.mode).frameAt(a.clock);
    h = h * 31 + a.dir;
    // Zzz drifts and the window glow flickers: step them at 6 per second.
    if (a.asleep || a.indoors || a.mode == PetMode.peeking) h = h * 31 + (a.clock * 6).floor();
  }
  for (final heart in w.hearts) {
    h = h * 31 + (heart.age * 12).floor();
  }
  return h * 31 + w.hearts.length;
}

/// Loaded once: the soft window glow, drawn by the GPU.
final Future<ui.FragmentProgram?> _glow = ui.FragmentProgram.fromAsset('shaders/glow.frag').then<ui.FragmentProgram?>((p) => p).catchError((Object _) => null);

/// The characters' stage in the empty middle of the home screen.
///
/// Everything is drawn on the GPU: one texture per character holds every frame and its house, and a
/// single `drawAtlas` call draws it, tinted for the time of day with a blend mode. The simulation
/// runs about 15 times a second only while the stage is on screen.
class PetStage extends StatefulWidget {
  const PetStage({super.key, required this.flute, required this.visible});

  final Flute flute;
  final ValueListenable<bool> visible;

  @override
  State<PetStage> createState() => _PetStageState();
}

class _PetStageState extends State<PetStage> {
  PetWorld? _world;
  final Map<String, PetSprites> _sprites = {};
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  Duration _last = Duration.zero;
  ui.FragmentShader? _glowShader;
  List<String> _loadedFor = const [];
  bool _loading = false;

  Flute get flute => widget.flute;

  @override
  void initState() {
    super.initState();
    flute.pets.addListener(_onSettings);
    flute.style.addListener(_updateShelter);
    flute.modes.addListener(_updateShelter);
    flute.petLibrary.addListener(_onSettings);
    widget.visible.addListener(_syncTimer);
    _glow.then((p) {
      if (mounted && p != null) _glowShader = p.fragmentShader();
    });
    _onSettings();
  }

  @override
  void dispose() {
    _timer?.cancel();
    flute.pets.removeListener(_onSettings);
    flute.style.removeListener(_updateShelter);
    flute.modes.removeListener(_updateShelter);
    flute.petLibrary.removeListener(_onSettings);
    widget.visible.removeListener(_syncTimer);
    _frame.dispose();
    _glowShader?.dispose();
    super.dispose();
  }

  Future<void> _onSettings() async {
    final lib = flute.petLibrary.value;
    if (lib == null || _loading) return;
    final wanted = flute.pets.selected.where((id) => lib.info(id) != null).toList();
    if (_world != null && _sameList(wanted, _loadedFor)) {
      _syncTimer();
      return;
    }
    _loading = true;
    for (final id in wanted) {
      if (_sprites.containsKey(id)) continue;
      final s = await lib.sprites(id);
      if (s != null) _sprites[id] = s;
    }
    _loading = false;
    if (!mounted) return;
    final ids = wanted.where(_sprites.containsKey).toList();
    final world = _world ?? PetWorld(ids: ids, phrases: lib.phrases);
    world.setPets(ids);
    _world = world;
    _loadedFor = wanted;
    _updateShelter();
    _syncTimer();
    if (mounted) setState(() {});
  }

  bool _sameList(List<String> a, List<String> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((e) => e);

  void _updateShelter() {
    final w = _world;
    if (w == null) return;
    w.shelter = shelterFor(
      kind: flute.style.kind,
      phase: flute.style.phase,
      sleepMode: flute.modes.current.id == 'sleep',
      hour: DateTime.now().hour,
    );
  }

  void _syncTimer() {
    final run = _world != null && flute.pets.enabled && widget.visible.value;
    if (run && _timer == null) {
      _clock
        ..reset()
        ..start();
      _last = Duration.zero;
      _timer = Timer.periodic(const Duration(milliseconds: 83), _tick);
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _clock.stop();
    }
  }

  Offset? _downAt;
  Duration _downTime = Duration.zero;
  int _sig = 0;
  int _shelterCheck = 0;

  void _tick(Timer _) {
    final w = _world;
    if (w == null) return;
    final now = _clock.elapsed;
    final dt = math.min(0.2, (now - _last).inMicroseconds / 1e6);
    _last = now;
    if (++_shelterCheck % 30 == 0) _updateShelter();
    w.update(dt);
    final sig = worldSignature(w);
    if (sig != _sig) {
      _sig = sig;
      _frame.value++;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([flute.pets, flute.style]),
      builder: (context, _) {
        final w = _world;
        if (!flute.pets.enabled || w == null || _sprites.isEmpty) return const SizedBox.expand();
        final style = flute.style.style;
        return LayoutBuilder(
          builder: (context, c) {
            w.layout(Size(c.maxWidth, c.maxHeight));
            // A raw Listener, not a GestureDetector: it must not take part in the gesture arena, or
            // the home page's double-tap to lock and swipe up would stop working over the stage.
            return Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) {
                _downAt = e.localPosition;
                _downTime = e.timeStamp;
              },
              onPointerUp: (e) {
                final start = _downAt;
                if (start == null) return;
                final quick = (e.timeStamp - _downTime).inMilliseconds < 350;
                if (quick && (e.localPosition - start).distance < 18 && w.tap(e.localPosition)) {
                  flute.pets.markHit();
                  _frame.value++;
                }
                _downAt = null;
              },
              child: RepaintBoundary(
                child: CustomPaint(
                  size: Size(c.maxWidth, c.maxHeight),
                  painter: _PetPainter(
                    world: w,
                    sprites: _sprites,
                    glow: _glowShader,
                    phase: flute.style.phase,
                    ink: style.ink,
                    light: style.light,
                    repaint: _frame,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PetPainter extends CustomPainter {
  _PetPainter({
    required this.world,
    required this.sprites,
    required this.glow,
    required this.phase,
    required this.ink,
    required this.light,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final PetWorld world;
  final Map<String, PetSprites> sprites;
  final ui.FragmentShader? glow;
  final DayPhase phase;
  final Color ink;
  final bool light;

  final Paint _atlasPaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _shadow = Paint();
  final Paint _glowPaint = Paint()..blendMode = BlendMode.plus;

  /// Multiplies the sprites so they sit in the light of the hour.
  Color get _tint => switch (phase) {
    DayPhase.night => const Color(0xFFA9B6E0),
    DayPhase.dawn || DayPhase.dusk => const Color(0xFFF1DCCB),
    _ => const Color(0xFFFFFFFF),
  };

  @override
  void paint(Canvas canvas, Size size) {
    // Stepped at 6 per second, matching worldSignature, so slow effects never force extra frames.
    final t = world.actors.isEmpty ? 0.0 : (world.actors.first.clock * 6).floor() / 6;

    // Ground line.
    canvas.drawLine(
      Offset(size.width * 0.04, world.houseBaseY + 2),
      Offset(size.width * 0.96, world.houseBaseY + 2),
      Paint()
        ..color = ink.withValues(alpha: 0.10)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round,
    );

    // Houses first, then pets back to front.
    for (final a in world.actors) {
      final s = sprites[a.id];
      if (s == null) continue;
      final r = world.houseRect(a);
      _atlas(canvas, s.sheet, [s.houseRect], [r], [_tint]);
      final lit = a.indoors || a.asleep || a.mode == PetMode.peeking;
      final g = glow;
      if (lit && g != null) {
        final glowRect = Rect.fromCenter(center: Offset(r.center.dx, r.center.dy - r.height * 0.08), width: r.width * 1.5, height: r.width * 1.5);
        g
          ..setFloat(0, glowRect.width)
          ..setFloat(1, glowRect.height)
          ..setFloat(2, t)
          ..setFloat(3, a.asleep || a.indoors ? 0.55 : 0.3)
          ..setFloat(4, 1.0)
          ..setFloat(5, 0.78)
          ..setFloat(6, 0.42);
        _glowPaint.shader = g;
        canvas.save();
        canvas.translate(glowRect.left, glowRect.top);
        canvas.drawRect(Offset.zero & glowRect.size, _glowPaint);
        canvas.restore();
      }
    }

    final order = [...world.actors]..sort((a, b) => a.lane.compareTo(b.lane));
    for (final a in order) {
      final s = sprites[a.id];
      if (s == null || !a.visible) continue;
      final y = world.laneY(a.lane);
      final size0 = world.sprite;
      // Soft shadow on the ground.
      _shadow.color = const Color(0xFF000000).withValues(alpha: (light ? 0.10 : 0.18) * a.fade);
      canvas.drawOval(Rect.fromCenter(center: Offset(a.x, y - 1), width: size0 * (a.asleep ? 0.9 : 0.55), height: size0 * 0.12), _shadow);

      final anim = animFor(a.mode);
      final left = a.dir < 0 && !a.asleep;
      final src = s.frameRect(anim, a.clock, left: left);
      final dst = Rect.fromLTWH(a.x - size0 / 2, y - size0, size0, size0);
      final tint = _tint.withValues(alpha: a.fade);
      _atlas(canvas, s.sheetFor(left: left), [src], [dst], [tint]);

      if (a.asleep) _zzz(canvas, a, y, size0, t);
      if (a.say != null) _bubble(canvas, size, a, y - size0 - 4, a.say!);
    }

    for (final h in world.hearts) {
      _heart(canvas, h);
    }
  }

  /// One GPU draw call (`drawAtlas`) for the given sprites of one texture.
  void _atlas(Canvas canvas, ui.Image texture, List<Rect> src, List<Rect> dst, List<Color> colors) {
    final transforms = <ui.RSTransform>[
      for (var i = 0; i < src.length; i++)
        ui.RSTransform.fromComponents(
          rotation: 0,
          scale: dst[i].width / src[i].width,
          anchorX: src[i].width / 2,
          anchorY: src[i].height / 2,
          translateX: dst[i].center.dx,
          translateY: dst[i].center.dy,
        ),
    ];
    canvas.drawAtlas(texture, transforms, src, colors, BlendMode.modulate, null, _atlasPaint);
  }

  final Map<String, TextPainter> _text = {};

  TextPainter _tp(String text, double size, Color color, {FontWeight weight = FontWeight.w600}) {
    final key = '$text|$size|${color.toARGB32()}|${weight.value}';
    return _text.putIfAbsent(key, () {
      final p = TextPainter(
        text: TextSpan(text: text, style: TextStyle(fontSize: size, color: color, fontWeight: weight, height: 1.1)),
        textDirection: TextDirection.ltr,
        maxLines: 2,
      )..layout(maxWidth: 150);
      return p;
    });
  }

  void _zzz(Canvas canvas, PetActor a, double y, double sprite, double t) {
    for (var i = 0; i < 3; i++) {
      final phase = ((t * 0.5 + i / 3) % 1.0);
      final tp = _tp(i == 0 ? 'z' : (i == 1 ? 'Z' : 'z'), 10 + i * 3.0, ink.withValues(alpha: (1 - phase) * 0.8));
      tp.paint(canvas, Offset(a.x + sprite * 0.18 + phase * 14 + i * 6, y - sprite * 0.78 - phase * 24 - i * 6));
    }
  }

  void _bubble(Canvas canvas, Size size, PetActor a, double bottom, String text) {
    final tp = _tp(text, 12, const Color(0xFF14202B), weight: FontWeight.w600);
    final w = tp.width + 20;
    final h = tp.height + 14;
    final left = (a.x - w / 2).clamp(4.0, math.max(4.0, size.width - w - 4)).toDouble();
    final rect = RRect.fromRectAndRadius(Rect.fromLTWH(left, bottom - h, w, h), const Radius.circular(12));
    canvas.drawRRect(rect, Paint()..color = const Color(0xF2FFFFFF));
    final tail = Path()
      ..moveTo(a.x - 5, bottom - 1)
      ..lineTo(a.x + 5, bottom - 1)
      ..lineTo(a.x, bottom + 6)
      ..close();
    canvas.drawPath(tail, Paint()..color = const Color(0xF2FFFFFF));
    tp.paint(canvas, Offset(left + 10, bottom - h + 7));
  }

  void _heart(Canvas canvas, Heart h) {
    final alpha = (1 - h.age / 1.4).clamp(0.0, 1.0);
    final s = 7 + 4 * math.sin(h.age * 6).abs();
    final path = Path()
      ..moveTo(h.x, h.y + s * 0.9)
      ..cubicTo(h.x - s * 1.6, h.y - s * 0.2, h.x - s * 0.6, h.y - s * 1.3, h.x, h.y - s * 0.4)
      ..cubicTo(h.x + s * 0.6, h.y - s * 1.3, h.x + s * 1.6, h.y - s * 0.2, h.x, h.y + s * 0.9)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFFF6F91).withValues(alpha: alpha));
  }

  @override
  bool shouldRepaint(covariant _PetPainter old) =>
      old.phase != phase || old.ink != ink || old.glow != glow || old.world != world || old.sprites.length != sprites.length;
}
