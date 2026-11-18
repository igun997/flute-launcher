import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app/flute.dart';
import '../app/theme.dart';
import '../core/day_style.dart';
import '../native/flute_native.dart';
import '../widgets/sky_ink.dart';
import '../widgets/flute_clock.dart';
import '../widgets/weather_scene.dart';
import 'lock_settings.dart';
import 'lock_summary.dart';

/// A flick faster than this (logical px per second, upward) unlocks.
const _flickVelocity = 500.0;

/// A drag further than this (logical px, upward) unlocks.
const _pullDistance = 120.0;

const _cancelledFor = Duration(seconds: 2);

/// Full-screen lockscreen drawn over the keyguard: sky, clock, weather, a privacy-aware summary
/// and an unlock gesture. Shows message text only when [LockSettings.showPreviews] is on.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.flute, required this.settings, this.onPreviewClose});

  final Flute flute;
  final LockSettings settings;

  /// Set when this is only a preview inside the app (Settings > Preview lockscreen): swiping up
  /// calls this instead of asking the system to unlock.
  final VoidCallback? onPreviewClose;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _unlocking = false;
  bool _cancelled = false;
  double _dragDy = 0;
  Timer? _cancelTimer;

  @override
  void dispose() {
    _cancelTimer?.cancel();
    super.dispose();
  }

  void _dragStart(DragStartDetails _) => _dragDy = 0;

  void _dragUpdate(DragUpdateDetails details) => _dragDy += details.primaryDelta ?? 0;

  void _dragEnd(DragEndDetails details) {
    final flick = details.velocity.pixelsPerSecond.dy < -_flickVelocity;
    final pulled = _dragDy < -_pullDistance;
    _dragDy = 0;
    if (flick || pulled) unawaited(_unlock());
  }

  Future<void> _unlock() async {
    if (_unlocking) return;
    _unlocking = true;
    final preview = widget.onPreviewClose;
    if (preview != null) {
      _unlocking = false;
      preview();
      return;
    }
    try {
      final unlocked = await FluteNative.dismissKeyguard();
      if (!unlocked && mounted) _flashCancelled();
    } finally {
      _unlocking = false;
    }
  }

  void _flashCancelled() {
    _cancelTimer?.cancel();
    setState(() => _cancelled = true);
    _cancelTimer = Timer(_cancelledFor, () {
      if (mounted) setState(() => _cancelled = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final flute = widget.flute;
    return Stack(
      fit: StackFit.expand,
      children: [
        ListenableBuilder(
          listenable: flute.style,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              WeatherScene(kind: flute.style.kind, phase: flute.style.phase, active: true),
              _LockScrim(style: flute.style.style),
            ],
          ),
        ),
        SafeArea(
          child: DefaultTextStyle.merge(
            // Same soft shadow as the home page, so text stays readable over bright skies.
            style: TextStyle(
              color: SkyInk.of(context).ink,
              shadows: [Shadow(color: SkyInk.of(context).shadow, blurRadius: 10), Shadow(color: SkyInk.of(context).shadow, blurRadius: 2)],
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: _dragStart,
              onVerticalDragUpdate: _dragUpdate,
              onVerticalDragEnd: _dragEnd,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    const FluteClock(),
                    const SizedBox(height: 14),
                    _weatherLine(),
                    const Spacer(),
                    ListenableBuilder(
                      listenable: Listenable.merge([flute.messages, flute.email, flute.style, widget.settings]),
                      builder: (context, _) {
                        final previews = widget.settings.showPreviews;
                        final mail = flute.email.summary;
                        final summary = summarize(
                          messages: flute.messages.value,
                          unreadMail: mail.unread,
                          previews: previews,
                        );
                        return _SummaryCard(
                          summary: summary,
                          mailSubjects: mailSubjectLines(latest: mail.latest, previews: previews),
                          alpha: flute.style.style.cardAlpha,
                        );
                      },
                    ),
                    const SizedBox(height: 28),
                    _UnlockHint(cancelled: _cancelled),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _weatherLine() {
    final weather = widget.flute.weather;
    return ListenableBuilder(
      listenable: weather,
      builder: (context, _) {
        final now = weather.now;
        if (now == null) return const SizedBox.shrink();
        return Text(
          '${now.tempC.round()}°  ·  ${weather.city.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w300, color: SkyInk.of(context).ink),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.mailSubjects, required this.alpha});

  final LockSummary summary;
  final List<String> mailSubjects;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    final previews = summary.previews;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: (SkyInk.of(context).light ? const Color(0xFFFFFFFF) : FluteColors.surface).withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: SkyInk.of(context).light ? const Color(0x33000000) : FluteColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            summary.countLine,
            style: TextStyle(fontSize: 18, letterSpacing: 0.3, color: SkyInk.of(context).ink),
          ),
          if (summary.hasContent) ...[
            const SizedBox(height: 10),
            if (previews.isNotEmpty || mailSubjects.isNotEmpty) ...[
              for (final row in previews)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.sender, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                      Text(
                        row.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: SkyInk.of(context).inkSoft),
                      ),
                    ],
                  ),
                ),
              for (final subject in mailSubjects)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: SkyInk.of(context).inkSoft),
                  ),
                ),
            ] else ...[
              if (summary.senderLine.isNotEmpty)
                Text(
                  summary.senderLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: SkyInk.of(context).inkSoft),
                ),
              if (summary.chatCount > 0 || summary.unreadMail > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Unlock to read',
                    style: TextStyle(fontSize: 13, letterSpacing: 0.4, color: SkyInk.of(context).inkSoft),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

class _UnlockHint extends StatelessWidget {
  const _UnlockHint({required this.cancelled});

  final bool cancelled;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 20,
          child: cancelled
              ? Center(
                  child: Text(
                    'Unlock cancelled',
                    style: TextStyle(fontSize: 13, color: SkyInk.of(context).inkSoft),
                  ),
                )
              : null,
        ),
        const SizedBox(height: 4),
        Text(
          'Swipe up to unlock',
          style: TextStyle(fontSize: 14, letterSpacing: 0.4, color: SkyInk.of(context).inkSoft),
        ),
        const SizedBox(height: 4),
        const _Chevron(),
      ],
    );
  }
}

/// Gently bobbing chevron. Holds still when the platform asks for reduced motion.
class _Chevron extends StatefulWidget {
  const _Chevron();

  @override
  State<_Chevron> createState() => _ChevronState();
}

class _ChevronState extends State<_Chevron> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Transform.translate(offset: Offset(0, -6 * t), child: child);
      },
      child: Icon(Icons.keyboard_arrow_up, size: 30, color: SkyInk.of(context).inkSoft),
    );
  }
}

/// Darkens the sky just enough for text to stay readable; the same as the home page scrim.
class _LockScrim extends StatelessWidget {
  const _LockScrim({required this.style});

  final DayStyle style;

  @override
  Widget build(BuildContext context) {
    final (top, mid, bottom) = style.scrimAlpha;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            style.scrim.withValues(alpha: top),
            style.scrim.withValues(alpha: mid),
            style.scrim.withValues(alpha: bottom),
          ],
          stops: const [0, 0.45, 1],
        ),
      ),
    );
  }
}
