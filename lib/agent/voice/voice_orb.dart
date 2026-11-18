import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import 'voice_controller.dart';

/// Loaded once for the whole app. Null when the shader cannot be loaded; a plain circle is drawn then.
final Future<ui.FragmentProgram?> _program = ui.FragmentProgram.fromAsset('shaders/orb.frag')
    .then<ui.FragmentProgram?>((p) => p)
    .catchError((Object _) => null);

const _loopSeconds = 3600.0;

/// The voice orb. Its shape follows the microphone level and the voice state. The clock is paused by
/// TickerMode; a single static frame is drawn when the platform asks for reduced motion.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({super.key, required this.voice, this.size = 220});

  final VoiceController voice;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3600),
  );
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _program.then((program) {
      if (!mounted) return;
      setState(() => _shader = program?.fragmentShader());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _clock.stop();
      _clock.value = 0;
    } else if (!_clock.isAnimating) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Voice orb',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _OrbPainter(
            shader: _shader,
            voice: widget.voice,
            clock: _clock,
            color: FluteColors.accent,
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.shader,
    required this.voice,
    required this.clock,
    required this.color,
  }) : super(repaint: Listenable.merge([clock, voice, voice.levels]));

  final ui.FragmentShader? shader;
  final VoiceController voice;
  final Animation<double> clock;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final level = voice.levels.value.clamp(0.0, 1.0).toDouble();
    final paint = Paint();
    final shader = this.shader;
    if (shader == null) {
      paint.color = color.withValues(alpha: 0.2 + 0.5 * level);
      canvas.drawCircle(size.center(Offset.zero), size.shortestSide * 0.38, paint);
      return;
    }
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, clock.value * _loopSeconds)
      ..setFloat(3, level)
      ..setFloat(4, voice.state.index.toDouble())
      ..setFloat(5, color.r)
      ..setFloat(6, color.g)
      ..setFloat(7, color.b);
    paint.shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.shader != shader || old.voice != voice || old.clock != clock || old.color != color;
}
