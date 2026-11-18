import 'package:material_ui/material_ui.dart';

/// Shows a mode label (for example "Focus" or "Deep work") and cross-fades
/// with a small scale and slide when the label changes.
class ModeTransition extends StatelessWidget {
  const ModeTransition({super.key, required this.mode, this.style});

  final String mode;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 380),
      reverseDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(animation);
        final scale = Tween<double>(begin: 0.96, end: 1).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: slide,
            child: ScaleTransition(scale: scale, child: child),
          ),
        );
      },
      child: Text(
        mode,
        key: ValueKey<String>(mode),
        style: style,
        textAlign: TextAlign.center,
      ),
    );
  }
}
