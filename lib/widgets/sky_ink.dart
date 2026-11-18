import 'package:material_ui/material_ui.dart';

import '../core/day_style.dart';

/// Hands the current [DayStyle] (ink colours, pill fill, shadow) to everything drawn on the sky,
/// so text turns dark on a bright morning sky and light at night.
class SkyInk extends InheritedWidget {
  const SkyInk({super.key, required this.style, required super.child});

  final DayStyle style;

  /// The style in effect; the night style when there is no [SkyInk] above.
  static DayStyle of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SkyInk>()?.style ?? DayStyle.night;

  @override
  bool updateShouldNotify(SkyInk old) =>
      old.style.light != style.light || old.style.accent != style.accent || old.style.scrim != style.scrim;
}
