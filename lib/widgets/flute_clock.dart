import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'sky_ink.dart';

const _weekdays = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _months = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];


/// Large, text-first clock: HH:mm with per-digit slide and fade, and a date
/// line underneath. Ticks once per minute, aligned to the minute boundary.
class FluteClock extends StatefulWidget {
  const FluteClock({super.key, this.animate = true});

  /// When false, digits change instantly. Also forced off when the platform
  /// requests reduced motion.
  final bool animate;

  @override
  State<FluteClock> createState() => _FluteClockState();
}

class _FluteClockState extends State<FluteClock> {
  DateTime _now = DateTime.now();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleNextMinute();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleNextMinute() {
    final now = DateTime.now();
    final untilNextMinute = Duration(
      milliseconds: 60000 - (now.second * 1000 + now.millisecond),
    );
    _timer = Timer(untilNextMinute, _onMinute);
  }

  void _onMinute() {
    if (!mounted) return;
    setState(() => _now = DateTime.now());
    _scheduleNextMinute();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        !widget.animate || MediaQuery.disableAnimationsOf(context);
    final switchDuration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 420);

    final hh = _two(_now.hour);
    final mm = _two(_now.minute);
    final date =
        '${_weekdays[_now.weekday - 1]}, '
        '${_months[_now.month - 1]} ${_now.day}';

    final ink = SkyInk.of(context);
    final digitStyle = TextStyle(
      fontSize: 112,
      height: 1.0,
      fontWeight: FontWeight.w200,
      letterSpacing: -2,
      color: ink.ink,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Semantics(
      label: 'Time $hh:$mm, $date',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Digit(char: hh[0], duration: switchDuration, style: digitStyle),
              _Digit(char: hh[1], duration: switchDuration, style: digitStyle),
              Text(':', style: digitStyle),
              _Digit(char: mm[0], duration: switchDuration, style: digitStyle),
              _Digit(char: mm[1], duration: switchDuration, style: digitStyle),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            date,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.4,
              color: ink.inkSoft,
            ),
          ),
        ],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _Digit extends StatelessWidget {
  const _Digit({
    required this.char,
    required this.duration,
    required this.style,
  });

  final String char;
  final Duration duration;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.22),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: Text(char, key: ValueKey<String>(char), style: style),
    );
  }
}
