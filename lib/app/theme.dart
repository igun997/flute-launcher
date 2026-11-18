import 'package:material_ui/material_ui.dart';

/// Dark, calm, text-first palette.
abstract final class FluteColors {
  static const bg = Color(0xFF050809);
  static const surface = Color(0xFF0E1417);
  static const surfaceHigh = Color(0xFF151D21);
  static const line = Color(0xFF1F2A2F);
  static const text = Color(0xFFE8F1F2);
  static const muted = Color(0xFF8A9BA0);

  /// Secondary text that sits directly on the sky: brighter than [muted] so it reads on any light.
  static const softText = Color(0xFFCBD7DB);
  static const accent = Color(0xFF5EEAD4);
  static const warn = Color(0xFFF5B86B);
}

ThemeData fluteTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: FluteColors.bg,
    colorScheme: const ColorScheme.dark(
      surface: FluteColors.surface,
      primary: FluteColors.accent,
      onPrimary: Color(0xFF00201B),
      onSurface: FluteColors.text,
      secondary: FluteColors.accent,
    ),
    textTheme: base.textTheme.apply(bodyColor: FluteColors.text, displayColor: FluteColors.text),
    splashFactory: NoSplash.splashFactory,
    dividerColor: FluteColors.line,
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: FluteColors.surface,
      modalBackgroundColor: FluteColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
  );
}
