import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../agent/ui/chat_bubbles.dart';
import '../app/flute.dart';
import '../app/theme.dart';
import '../core/models.dart';
import 'press_scale.dart';

Future<void> showModeSheet(BuildContext context, Flute flute) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ModeSheet(flute: flute),
  );
}

/// Timer choices in the mode sheet. A null duration is 'Until I change it', meaning no timer.
const modeTimerChoices = <(String, Duration?)>[
  ('Until I change it', null),
  ('25 min', Duration(minutes: 25)),
  ('1 hour', Duration(hours: 1)),
  ('2 hours', Duration(hours: 2)),
  ('4 hours', Duration(hours: 4)),
];

/// Time left on the timer running at [now], or null when no timer runs.
Duration? timerRemaining(DateTime? until, DateTime now) {
  if (until == null || !until.isAfter(now)) return null;
  return until.difference(now);
}

/// The chip that matches a running timer: the smallest preset that still covers [remaining], or the
/// longest preset when more time is left than any preset. Null (Until I change it) when no timer runs.
Duration? presetForRemaining(Duration? remaining) {
  if (remaining == null) return null;
  for (final (_, d) in modeTimerChoices) {
    if (d != null && d >= remaining) return d;
  }
  return modeTimerChoices.last.$2;
}

class _ModeSheet extends StatefulWidget {
  const _ModeSheet({required this.flute});
  final Flute flute;

  @override
  State<_ModeSheet> createState() => _ModeSheetState();
}

class _ModeSheetState extends State<_ModeSheet> {
  /// Set once the user taps a chip in this visit. Until then the chip follows the running timer.
  bool _picked = false;
  Duration? _choice;

  @override
  Widget build(BuildContext context) {
    final modes = widget.flute.modes;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return SafeArea(
      child: ListenableBuilder(
        listenable: modes,
        builder: (context, _) {
          final active = modes.current;
          final selected = _picked ? _choice : presetForRemaining(timerRemaining(modes.overrideUntil, DateTime.now()));
          return Padding(
            padding: const EdgeInsets.fromLTRB(FluteSpace.lg, 0, FluteSpace.lg, FluteSpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mode', style: FluteText.title),
                const SizedBox(height: FluteSpace.lg),
                AnimatedSize(
                  duration: motion(context, 240),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: active.id == 'sleep'
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: () async {
                                  HapticFeedback.lightImpact();
                                  await modes.wakeUp();
                                  if (context.mounted) Navigator.of(context).pop();
                                },
                                child: const Text('Wake up'),
                              ),
                            ),
                            const SizedBox(height: FluteSpace.lg),
                          ],
                        )
                      : const SizedBox(width: double.infinity),
                ),
                Text('How long', style: FluteText.overline),
                const SizedBox(height: FluteSpace.sm),
                Wrap(
                  spacing: FluteSpace.sm,
                  runSpacing: FluteSpace.sm,
                  children: [
                    for (final (label, d) in modeTimerChoices)
                      ChoiceChip(
                        label: Text(label),
                        selected: selected == d,
                        onSelected: (_) {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _picked = true;
                            _choice = d;
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: FluteSpace.lg),
                for (final m in Mode.all)
                  _ModeTile(
                    mode: m,
                    active: active.id == m.id,
                    reduced: reduced,
                    onTap: () async {
                      HapticFeedback.lightImpact();
                      if (selected == null) {
                        await modes.setMode(m);
                      } else {
                        await modes.startTimer(m, selected);
                      }
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                if (modes.schedules.isNotEmpty) ...[
                  const SizedBox(height: FluteSpace.sm),
                  Text(
                    'Scheduled modes switch on automatically. Edit them in settings (long-press home).',
                    style: FluteText.caption,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.mode, required this.active, required this.reduced, required this.onTap});
  final Mode mode;
  final bool active;
  final bool reduced;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: '${mode.name}. ${mode.tagline}',
      excludeSemantics: true,
      child: PressScale(
        borderRadius: FluteRadius.lgAll,
        onTap: onTap,
        child: AnimatedContainer(
          duration: reduced ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: FluteSpace.sm),
          padding: const EdgeInsets.symmetric(horizontal: FluteSpace.lg, vertical: FluteSpace.md),
          decoration: fluteSurface(
            color: active ? FluteColors.accentSoft : FluteColors.surface,
            border: active ? FluteColors.accent.withValues(alpha: 0.6) : FluteColors.line,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(mode.name, style: FluteText.heading.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: FluteSpace.xs),
              Text(mode.tagline, style: FluteText.caption),
            ],
          ),
        ),
      ),
    );
  }
}
