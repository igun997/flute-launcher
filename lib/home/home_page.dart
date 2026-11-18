import 'package:flutter/foundation.dart' show Uint8List, ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../app/flute.dart';
import '../core/day_style.dart';
import '../core/models.dart';
import '../native/flute_native.dart';
import '../widgets/flute_clock.dart';
import '../widgets/gray_icon.dart';
import '../widgets/mode_transition.dart';
import '../widgets/sky_ink.dart';
import '../widgets/weather_chip.dart';
import '../widgets/weather_scene.dart';
import '../pets/pet_stage.dart';
import 'apps_page.dart';
import 'inbox_page.dart';
import 'mode_sheet.dart';
import 'settings_page.dart';

/// Home: clock, weather, mode, a one-line inbox summary and a compact grid of pinned apps.
///
/// It never scrolls, so a drag up anywhere always opens the app list.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.flute, required this.onOpenInbox, required this.visible});
  final Flute flute;
  final VoidCallback onOpenInbox;

  /// True while the home page is on screen; the sky animation pauses otherwise.
  final ValueListenable<bool> visible;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ListenableBuilder(
          listenable: flute.style,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (context, shown, _) =>
                    WeatherScene(kind: flute.style.kind, phase: flute.style.phase, active: shown),
              ),
              SkyScrim(style: flute.style.style),
            ],
          ),
        ),
        SafeArea(
          child: DefaultTextStyle.merge(
            // A soft glow keeps text readable on every sky: dark on dark skies, white on bright ones.
            style: TextStyle(
              color: SkyInk.of(context).ink,
              shadows: [Shadow(color: SkyInk.of(context).shadow, blurRadius: 10), Shadow(color: SkyInk.of(context).shadow, blurRadius: 2)],
            ),
            child: _SwipeUp(
              onTriggered: () => openApps(context, flute),
              onLongPress: () => openSettings(context, flute),
              onDoubleTap: () => _lockScreen(context, flute),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(child: FluteClock()),
                    const SizedBox(height: 10),
                    Row(children: [WeatherChip(flute.weather), const Spacer(), _ModeChip(flute: flute)]),
                    Expanded(child: PetStage(flute: flute, visible: visible)),
                    _InboxHint(flute: flute, onTap: onOpenInbox),
                    const SizedBox(height: 14),
                    PinGrid(flute: flute),
                    const SizedBox(height: 18),
                    Center(
                      child: Text('Swipe up for apps  ·  right to ask', style: TextStyle(color: SkyInk.of(context).inkSoft, fontSize: 12, letterSpacing: 0.6)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Darkens the sky just enough for text to stay readable; lighter by day than by night.
class SkyScrim extends StatelessWidget {
  const SkyScrim({super.key, required this.style});
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

/// Opens [onTriggered] on an upward drag or fling anywhere in [child]; taps and long-presses
/// still reach the widgets inside.
class _SwipeUp extends StatefulWidget {
  const _SwipeUp({required this.onTriggered, required this.onLongPress, required this.onDoubleTap, required this.child});
  final VoidCallback onTriggered;
  final VoidCallback onLongPress;
  final VoidCallback onDoubleTap;
  final Widget child;

  @override
  State<_SwipeUp> createState() => _SwipeUpState();
}

class _SwipeUpState extends State<_SwipeUp> {
  double _dy = 0;

  /// Pure thresholds so the gesture feels the same everywhere: a drag of 64 px or a quick fling.
  static bool shouldOpen(double dragDy, double velocityY) => dragDy < -64 || velocityY < -450;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: widget.onLongPress,
      onDoubleTap: widget.onDoubleTap,
      onVerticalDragStart: (_) => _dy = 0,
      onVerticalDragUpdate: (d) => _dy += d.delta.dy,
      onVerticalDragEnd: (d) {
        if (shouldOpen(_dy, d.primaryVelocity ?? 0)) widget.onTriggered();
        _dy = 0;
      },
      child: widget.child,
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.flute});
  final Flute flute;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([flute.modes, flute.style]),
      builder: (context, _) {
        final mode = flute.modes.current;
        final until = flute.modes.overrideUntil;
        final timed = until != null && flute.modes.current.id != flute.modes.base.id;
        final suffix = timed ? ' · until ${_hm(until)}' : '';
        final st = flute.style.style;
        final accent = st.accent;
        final free = mode.id == 'free';
        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => showModeSheet(context, flute),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: st.pill,
              border: Border.all(color: free ? st.inkSoft.withValues(alpha: 0.5) : accent.withValues(alpha: 0.8)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: ModeTransition(
              mode: '${mode.name}$suffix',
              style: TextStyle(color: free ? st.ink : accent, fontSize: 13, letterSpacing: 0.4),
            ),
          ),
        );
      },
    );
  }

  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// One line: what is waiting in the inbox, or what is missing to show it. Tap opens the inbox.
class _InboxHint extends StatelessWidget {
  const _InboxHint({required this.flute, required this.onTap});
  final Flute flute;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([flute.messages, flute.notificationAccess, flute.email, flute.usageAccess, flute.repo]),
      builder: (context, _) {
        final chats = inboxChatCount(flute.messages.value);
        final mail = flute.email.summary.unread;
        final parts = <String>[
          if (chats > 0) '$chats ${chats == 1 ? 'chat' : 'chats'}',
          if (mail > 0) '$mail unread mail',
        ];
        final st = SkyInk.of(context);
        final String text;
        final bool attention;
        if (!flute.notificationAccess.value) {
          text = 'Allow notification access for messages';
          attention = true;
        } else if (parts.isEmpty) {
          text = 'Inbox is clear';
          attention = false;
        } else {
          text = parts.join('  ·  ');
          attention = false;
        }
        final usage = flute.repo.usageByCategory.take(2).map((e) => '${e.$1.label} ${_fmt(e.$2)}').join('  ·  ');
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: attention ? FluteNative.openNotificationAccessSettings : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(text, style: TextStyle(color: attention ? st.warn : st.ink, fontSize: 15)),
                      if (usage.isNotEmpty && flute.usageAccess.value)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('Today ${_fmt(flute.repo.totalUsage)}  ·  $usage', style: TextStyle(color: st.inkSoft, fontSize: 12)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!attention) Text('›  swipe left', style: TextStyle(color: st.inkSoft, fontSize: 12)),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _fmt(Duration d) {
    if (d.inMinutes < 1) return '<1m';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}

/// Pinned apps as small gray icons, four per row.
class PinGrid extends StatelessWidget {
  const PinGrid({super.key, required this.flute});
  final Flute flute;

  static const columns = 4;
  static const gap = 6.0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([flute.repo, flute.modes, flute.icons]),
      builder: (context, _) {
        final favs = flute.repo.favorites;
        if (favs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Long-press an app in the list to pin it here.', style: TextStyle(color: SkyInk.of(context).inkSoft, fontSize: 13)),
          );
        }
        return LayoutBuilder(
          builder: (context, c) {
            final cell = (c.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: 10,
              children: [
                for (final app in favs)
                  SizedBox(
                    width: cell,
                    child: _Pin(
                      app: app,
                      rule: flute.modes.ruleFor(app),
                      icon: flute.icons.of(app.package),
                      onTap: () => FluteNative.launchApp(app.package),
                      onLongPress: () => showAppSheet(context, flute, app),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.app, required this.rule, required this.icon, required this.onTap, required this.onLongPress});
  final FluteApp app;
  final Rule rule;
  final Uint8List? icon;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final dim = rule != Rule.show;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PinIcon(package: app.package, bytes: icon, ink: SkyInk.of(context).ink, light: SkyInk.of(context).light, size: 44, dim: dim),
            const SizedBox(height: 5),
            Text(
              app.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: SkyInk.of(context).inkSoft.withValues(alpha: dim ? 0.55 : 1)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Double-tap on an empty spot: turn the screen off. Needs the Accessibility lock service; when it
/// is not on yet, say how to enable it.
Future<void> _lockScreen(BuildContext context, Flute flute) async {
  // A double-tap on a character is for the character, not for the lock.
  if (flute.pets.hitRecently) return;
  final locked = await FluteNative.lockScreen();
  if (locked || !context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: const Text('Turn on the Flute lock service to lock with a double-tap'),
        action: SnackBarAction(label: 'Open', onPressed: FluteNative.openAccessibilitySettings),
      ),
    );
}
