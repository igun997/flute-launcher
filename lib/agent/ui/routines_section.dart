import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import 'routines_page.dart';
import 'settings_widgets.dart';

/// The "Routines" row on the agent settings hub. Shows how many are saved and on; opens the
/// Routines page directly.
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
        final status = all.isEmpty
            ? 'None yet'
            : '${all.length} ${all.length == 1 ? 'routine' : 'routines'} · $on on';
        return SettingsHubRow(
          key: const ValueKey('routines-row'),
          icon: Icons.repeat,
          title: 'Routines',
          status: status,
          onTap: () => Navigator.of(context).push(
            settingsRoute<void>(context, (_) => RoutinesPage(flute: flute)),
          ),
        );
      },
    );
  }
}
