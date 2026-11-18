import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:material_ui/material_ui.dart';

import '../core/day_style.dart';
import '../core/sky_palette.dart';
import '../weather/weather_service.dart';

/// Full-bleed procedural sky for a weather kind: gradient, sun or moon, stars,
/// drifting clouds, rain, snow, fog and lightning.
///
/// Everything is drawn by one fragment shader (`shaders/sky.frag`) so the GPU
/// does the work and the UI thread only sets a few uniforms per frame. Frames are
/// capped at 15-30 per second to spare battery on slow phones. Motion stops and a still frame
/// is shown when the platform requests reduced motion. If the shader cannot be
/// loaded, a plain gradient is drawn instead.
class WeatherScene extends StatefulWidget {
  const WeatherScene({super.key, required this.kind, required this.phase, this.active = true});

  final WeatherKind kind;
  final DayPhase phase;

  /// False while the scene is off screen: no timer, no frames.
  final bool active;

  @override
  State<WeatherScene> createState() => _WeatherSceneState();
}

/// Loaded once for the whole app.
final Future<ui.FragmentProgram?> _program = ui.FragmentProgram.fromAsset('shaders/sky.frag').then<ui.FragmentProgram?>((p) => p).catchError((Object _) => null);

/// Precipitation needs smooth motion; slow drifting skies do not.
Duration _frameGapFor(WeatherKind kind) => switch (kind) {
  WeatherKind.drizzle || WeatherKind.rain || WeatherKind.thunder || WeatherKind.snow => const Duration(milliseconds: 40),
  _ => const Duration(milliseconds: 200),
};

class _WeatherSceneState extends State<WeatherScene> with WidgetsBindingObserver {
  final ValueNotifier<double> _seconds = ValueNotifier<double>(0);
  final Stopwatch _clock = Stopwatch();
  ui.FragmentShader? _shader;
  Timer? _timer;
  bool _animated = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _program.then((program) {
      if (!mounted || program == null) return;
      setState(() => _shader = program.fragmentShader());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animated = !MediaQuery.disableAnimationsOf(context);
    _restart();
  }

  @override
  void didUpdateWidget(WeatherScene old) {
    super.didUpdateWidget(old);
    if (old.kind != widget.kind || old.active != widget.active) _restart();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _restart();
    } else {
      _timer?.cancel();
      _timer = null;
      _clock.stop();
    }
  }

  /// A plain timer, not a vsync Ticker: a Ticker asks for a frame on every display refresh
  /// and the whole screen would be re-rendered at 60-90 fps for nothing.
  void _restart() {
    _timer?.cancel();
    _timer = null;
    if (!_animated) {
      _clock.stop();
      _seconds.value = 0;
      return;
    }
    if (!widget.active) {
      _clock.stop();
      return;
    }
    _clock.start();
    _timer = Timer.periodic(_frameGapFor(widget.kind), (_) {
      // Wrap hourly to keep shader float precision high.
      _seconds.value = (_clock.elapsedMilliseconds / 1000.0) % 3600.0;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _seconds.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _SkyPainter(
            shader: _shader,
            kind: widget.kind,
            phase: widget.phase,
            seconds: _seconds,
          ),
        ),
      ),
    );
  }
}

class _SkyPainter extends CustomPainter {
  _SkyPainter({
    required this.shader,
    required this.kind,
    required this.phase,
    required this.seconds,
  }) : super(repaint: seconds);

  final ui.FragmentShader? shader;
  final WeatherKind kind;
  final DayPhase phase;
  final ValueListenable<double> seconds;

  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final (top, bottom) = skyColors(kind, phase);
    final s = shader;
    if (s == null) {
      _paint.shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [top, bottom]);
      canvas.drawRect(Offset.zero & size, _paint);
      return;
    }
    final cloud = cloudColor(kind, phase);
    s
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, seconds.value)
      ..setFloat(3, kind.index.toDouble())
      ..setFloat(4, shaderPhase(phase))
      ..setFloat(5, top.r)
      ..setFloat(6, top.g)
      ..setFloat(7, top.b)
      ..setFloat(8, bottom.r)
      ..setFloat(9, bottom.g)
      ..setFloat(10, bottom.b)
      ..setFloat(11, cloud.r)
      ..setFloat(12, cloud.g)
      ..setFloat(13, cloud.b)
      ..setFloat(14, cloud.a);
    _paint.shader = s;
    canvas.drawRect(Offset.zero & size, _paint);
  }

  @override
  bool shouldRepaint(covariant _SkyPainter old) =>
      old.shader != shader || old.kind != kind || old.phase != phase;
}
