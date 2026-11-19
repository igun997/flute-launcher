import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import 'voice_controller.dart';

/// Loaded once for the whole app. Null when the shader cannot be loaded; a plain circle is drawn then.
final Future<ui.FragmentProgram?> _program = ui.FragmentProgram.fromAsset('shaders/orb.frag')
    .then<ui.FragmentProgram?>((p) => p)
    .catchError((Object _) => null);

/// Seconds per loop. Must match the shader's W = 2 * pi / 12.
const _loopSeconds = 12.0;

const _morphDuration = Duration(milliseconds: 360);

/// One weight per [VoiceState], in enum order: idle, listening, thinking, speaking. The shader reads them
/// in that order.
List<double> _weights(VoiceState state) => [
  for (final s in VoiceState.values) s == state ? 1.0 : 0.0,
];

List<double> _mix(List<double> from, List<double> to, double t) => [
  for (var i = 0; i < from.length; i++) from[i] + (to[i] - from[i]) * t,
];

/// The voice orb. Its shape follows the microphone level and the voice state, and it morphs between states.
/// The clock is paused by TickerMode; a single static frame is drawn when the platform asks for reduced motion.
/// When [onTap] is set, the orb is a button: it dips slightly while pressed.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.voice,
    this.size = 220,
    this.onTap,
    this.label = 'Voice orb',
  });

  final VoiceController voice;
  final double size;
  final VoidCallback? onTap;
  final String label;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with TickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: _morphDuration,
    value: 1,
  );
  ui.FragmentShader? _shader;
  late VoiceState _state = widget.voice.state;
  late List<double> _from = _weights(_state);
  late List<double> _to = _from;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    widget.voice.addListener(_onVoice);
    _program.then((program) {
      if (!mounted) return;
      setState(() => _shader = program?.fragmentShader());
    });
  }

  @override
  void didUpdateWidget(covariant VoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.voice != widget.voice) {
      oldWidget.voice.removeListener(_onVoice);
      widget.voice.addListener(_onVoice);
      setState(() {
        _state = widget.voice.state;
        _from = _weights(_state);
        _to = _from;
        _morph.value = 1;
      });
    }
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
    widget.voice.removeListener(_onVoice);
    _clock.dispose();
    _morph.dispose();
    _shader?.dispose();
    super.dispose();
  }

  void _onVoice() {
    final state = widget.voice.state;
    if (state == _state) return;
    setState(() {
      _from = _mix(_from, _to, Curves.easeInOutCubic.transform(_morph.value));
      _to = _weights(state);
      _state = state;
      if (MediaQuery.disableAnimationsOf(context)) {
        _morph.value = 1;
      } else {
        _morph.forward(from: 0);
      }
    });
  }

  void _setPressed(bool value) {
    if (_pressed == value || widget.onTap == null) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final orb = SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _OrbPainter(
          shader: _shader,
          voice: widget.voice,
          clock: _clock,
          morph: _morph,
          from: _from,
          to: _to,
          color: FluteColors.accent,
        ),
      ),
    );
    return Semantics(
      button: widget.onTap != null,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _pressed ? 0.94 : 1,
            duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: orb,
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
    required this.morph,
    required this.from,
    required this.to,
    required this.color,
  }) : super(repaint: Listenable.merge([clock, morph, voice.levels]));

  final ui.FragmentShader? shader;
  final VoiceController voice;
  final Animation<double> clock;
  final Animation<double> morph;
  final List<double> from;
  final List<double> to;
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
    final w = _mix(from, to, Curves.easeInOutCubic.transform(morph.value));
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, clock.value * _loopSeconds)
      ..setFloat(3, level)
      ..setFloat(4, w[0])
      ..setFloat(5, w[1])
      ..setFloat(6, w[2])
      ..setFloat(7, w[3])
      ..setFloat(8, color.r)
      ..setFloat(9, color.g)
      ..setFloat(10, color.b);
    paint.shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.shader != shader ||
      old.voice != voice ||
      old.clock != clock ||
      old.morph != morph ||
      !identical(old.from, from) ||
      !identical(old.to, to) ||
      old.color != color;
}
