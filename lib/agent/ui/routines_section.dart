import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import 'routines_page.dart';
import 'settings_widgets.dart';

/// The "Routines" row in agent settings: how many are saved and on, and opens the Routines page.
class RoutinesSection extends StatelessWidget {
  const RoutinesSection({super.key, required this.flute});
  final Flute flute;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: flute.routines,
      builder: (context, _) {
        final all = flute.routines.routines;
        final on = all.where((r) => r.enabled).length;
        final summary = all.isEmpty ? 'None yet' : '${all.length} saved · $on on';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              key: const ValueKey('routines-row'),
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => RoutinesPage(flute: flute)),
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                decoration: BoxDecoration(
                  color: FluteColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: FluteColors.line),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Routines', style: TextStyle(color: FluteColors.text, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(summary, style: settingsMuted),
                        ],
                      ),
                    ),
                    const Text('›', style: TextStyle(color: FluteColors.muted, fontSize: 20)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'A routine is a saved prompt that runs by itself on a schedule and sends the answer as a '
              'notification. It only reads unless you allow changes for that routine.',
              style: settingsMuted,
            ),
          ],
        );
      },
    );
  }
}
