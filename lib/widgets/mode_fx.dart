import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../core/mode_engine.dart';

/// What the mode change looks like, or null for none.
enum ModeFxKind {
  /// Going into Sleep: the edges close in on a moon, stars wake, then it clears to the night sky.
  sleep(Duration(milliseconds: 2200)),

  /// Coming out of Sleep (back to Free or any other mode): light blooms up from the bottom.
  wake(Duration(milliseconds: 1700));

  const ModeFxKind(this.duration);
  final Duration duration;
}

/// Which animation, if any, to play when the mode changes from [from] to [to] (mode ids).
ModeFxKind? fxForChange(String from, String to) {
  if (from == to) return null;
  if (to == 'sleep') return ModeFxKind.sleep;
  if (from == 'sleep') return ModeFxKind.wake;
  return null;
}

/// Loaded once for the whole app.
final Future<ui.FragmentProgram?> _program = ui.FragmentProgram.fromAsset('shaders/transition.frag').then<ui.FragmentProgram?>((p) => p).catchError((Object _) => null);

/// Plays a GPU shader animation over [child] when the mode enters or leaves Sleep. The overlay does
/// not take touches and disappears when the animation ends. Skipped when the platform asks for
/// reduced motion.
class ModeFx extends StatefulWidget {
  const ModeFx({super.key, required this.modes, required this.child});
  final ModeEngine modes;
  final Widget child;

  @override
  State<ModeFx> createState() => _ModeFxState();
}

class _ModeFxState extends State<ModeFx> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late String _lastId = widget.modes.current.id;
  ui.FragmentShader? _shader;
  ModeFxKind? _playing;

  @override
  void initState() {
    super.initState();
    widget.modes.addListener(_onModeChanged);
    _program.then((p) {
      if (mounted && p != null) _shader = p.fragmentShader();
    });
  }

  @override
  void dispose() {
    widget.modes.removeListener(_onModeChanged);
    _controller.dispose();
    _shader?.dispose();
    super.dispose();
  }

  void _onModeChanged() {
    final now = widget.modes.current.id;
    final fx = fxForChange(_lastId, now);
    _lastId = now;
    if (fx == null || _shader == null) return;
    if (MediaQuery.disableAnimationsOf(context)) return;
    setState(() => _playing = fx);
    _controller
      ..duration = fx.duration
      ..forward(from: 0).whenComplete(() {
        if (mounted) setState(() => _playing = null);
      });
  }

  @override
  Widget build(BuildContext context) {
    final fx = _playing;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (fx != null)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _FxPainter(shader: _shader!, kind: fx, progress: _controller)),
              ),
            ),
          ),
      ],
    );
  }
}

class _FxPainter extends CustomPainter {
  _FxPainter({required this.shader, required this.kind, required this.progress}) : super(repaint: progress);

  final ui.FragmentShader shader;
  final ModeFxKind kind;
  final Animation<double> progress;
  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, progress.value)
      ..setFloat(3, kind == ModeFxKind.sleep ? 0 : 1);
    _paint.shader = shader;
    canvas.drawRect(Offset.zero & size, _paint);
  }

  @override
  bool shouldRepaint(covariant _FxPainter old) => old.kind != kind || old.shader != shader;
}
