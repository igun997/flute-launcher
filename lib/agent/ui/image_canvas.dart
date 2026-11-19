import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../runtime/agent_runtime.dart';
import 'chat_bubbles.dart' show motion;

/// Loaded once for the whole app. Null when the shader cannot be loaded; a plain gradient is drawn then.
final Future<ui.FragmentProgram?> _program = ui.FragmentProgram.fromAsset('shaders/imagine.frag')
    .then<ui.FragmentProgram?>((p) => p)
    .catchError((Object _) => null);

const _loopSeconds = 60.0;

/// What sits under an image tool call: the working canvas while it runs, then the picture.
class ToolImages extends StatelessWidget {
  const ToolImages({super.key, required this.item});

  final ToolItem item;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (item.state == ToolState.running) {
      child = const CreatingImage(key: ValueKey('creating'));
    } else if (item.images.isNotEmpty) {
      child = Column(
        key: ValueKey('images-${item.id}'),
        children: [
          for (final path in item.images)
            Padding(padding: const EdgeInsets.only(top: 10), child: GeneratedImage(path: path)),
        ],
      );
    } else {
      child = const SizedBox(key: ValueKey('none'), width: double.infinity);
    }
    return AnimatedSwitcher(
      duration: motion(context, 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      child: child,
    );
  }
}

/// The animated canvas shown while a picture is being made. The shader runs on the GPU; the clock
/// stops with TickerMode and is a single still frame when the system asks for reduced motion.
/// The seconds label ticks once a second, so the text itself is not rebuilt every frame.
class CreatingImage extends StatefulWidget {
  const CreatingImage({super.key});

  @override
  State<CreatingImage> createState() => _CreatingImageState();
}

class _CreatingImageState extends State<CreatingImage> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 60),
  );
  final _watch = Stopwatch()..start();
  Timer? _ticker;
  int _seconds = 0;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _program.then((program) {
      if (!mounted) return;
      setState(() => _shader = program?.fragmentShader());
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds = _watch.elapsed.inSeconds);
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
    _ticker?.cancel();
    _clock.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        container: true,
        label: 'Creating an image',
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _CanvasPainter(shader: _shader, clock: _clock, color: FluteColors.accent),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      'Creating image · ${_seconds}s',
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 13,
                        letterSpacing: 0.3,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter({required this.shader, required this.clock, required this.color})
      : super(repaint: clock);

  final ui.FragmentShader? shader;
  final Animation<double> clock;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = this.shader;
    final paint = Paint();
    if (shader == null) {
      paint.shader = ui.Gradient.linear(
        Offset.zero,
        size.bottomRight(Offset.zero),
        [const Color(0xFF0B1020), Color.lerp(const Color(0xFF283377), color, clock.value) ?? color],
      );
      canvas.drawRect(Offset.zero & size, paint);
      return;
    }
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, clock.value * _loopSeconds)
      ..setFloat(3, color.r)
      ..setFloat(4, color.g)
      ..setFloat(5, color.b);
    paint.shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.shader != shader || old.clock != clock || old.color != color;
}

/// A finished picture. It fades and settles in once decoded; a tap opens it full screen.
class GeneratedImage extends StatelessWidget {
  const GeneratedImage({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Generated image. Opens full screen.',
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          PageRouteBuilder<void>(
            opaque: false,
            barrierColor: Colors.black,
            transitionDuration: motion(context, 220),
            reverseTransitionDuration: motion(context, 180),
            pageBuilder: (_, _, _) => _FullImage(path: path),
            transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
          ),
        ),
        child: Hero(
          tag: path,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(
              File(path),
              width: double.infinity,
              fit: BoxFit.fitWidth,
              cacheWidth: 1080,
              excludeFromSemantics: true,
              frameBuilder: (context, child, frame, sync) {
                if (sync) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: motion(context, 420),
                  curve: Curves.easeOut,
                  child: AnimatedScale(
                    scale: frame == null ? 0.97 : 1,
                    duration: motion(context, 420),
                    curve: Curves.easeOutCubic,
                    child: child,
                  ),
                );
              },
              errorBuilder: (_, _, _) => const _MissingImage(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when a saved picture's file has gone from the phone. Quiet, one line.
class _MissingImage extends StatelessWidget {
  const _MissingImage();

  @override
  Widget build(BuildContext context) => Container(
        height: 72,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: FluteColors.surfaceHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 18, color: FluteColors.muted),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                'This image is no longer on the phone.',
                style: TextStyle(color: FluteColors.muted, fontSize: 13),
              ),
            ),
          ],
        ),
      );
}

class _FullImage extends StatelessWidget {
  const _FullImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Positioned.fill(
              child: Hero(
                tag: path,
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Image.file(File(path), fit: BoxFit.contain, errorBuilder: (_, _, _) => const _MissingImage()),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
