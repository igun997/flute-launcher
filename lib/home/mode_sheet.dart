import 'package:material_ui/material_ui.dart';

import '../app/flute.dart';
import '../app/theme.dart';
import '../core/models.dart';

Future<void> showModeSheet(BuildContext context, Flute flute) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ModeSheet(flute: flute),
  );
}

class _ModeSheet extends StatefulWidget {
  const _ModeSheet({required this.flute});
  final Flute flute;

  @override
  State<_ModeSheet> createState() => _ModeSheetState();
}

class _ModeSheetState extends State<_ModeSheet> {
  Duration? _timer;

  static const _timers = <(String, Duration?)>[
    ('Until I change it', null),
    ('25 min', Duration(minutes: 25)),
    ('1 hour', Duration(hours: 1)),
    ('2 hours', Duration(hours: 2)),
    ('4 hours', Duration(hours: 4)),
  ];

  @override
  Widget build(BuildContext context) {
    final modes = widget.flute.modes;
    return SafeArea(
      child: ListenableBuilder(
        listenable: modes,
        builder: (context, _) {
          final active = modes.current;
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Mode', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w300)),
                const SizedBox(height: 14),
                if (active.id == 'sleep') ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        await modes.wakeUp();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      child: const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Wake up')),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (label, d) in _timers)
                      ChoiceChip(
                        label: Text(label),
                        selected: _timer == d,
                        onSelected: (_) => setState(() => _timer = d),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                for (final m in Mode.all)
                  _ModeTile(
                    mode: m,
                    active: active.id == m.id,
                    onTap: () async {
                      final d = _timer;
                      if (d == null) {
                        await modes.setMode(m);
                      } else {
                        await modes.startTimer(m, d);
                      }
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                if (modes.schedules.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Scheduled modes switch on automatically. Edit them in settings (long-press home).',
                    style: TextStyle(color: FluteColors.muted, fontSize: 12),
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
  const _ModeTile({required this.mode, required this.active, required this.onTap});
  final Mode mode;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: active ? FluteColors.surfaceHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? FluteColors.accent.withValues(alpha: 0.7) : FluteColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(mode.name, style: TextStyle(fontSize: 18, color: active ? FluteColors.accent : FluteColors.text)),
            const SizedBox(height: 2),
            Text(mode.tagline, style: const TextStyle(color: FluteColors.muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
