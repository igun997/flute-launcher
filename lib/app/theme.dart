import 'package:material_ui/material_ui.dart';

/// Flute's design tokens. The look is "confidently quiet": a near-black canvas lifted in four
/// tonal steps (no drop shadows), muted text, and ONE accent that is rationed to the thing that is
/// active, primary or alive. Everything else stays neutral. See docs/DESIGN.md.
abstract final class FluteColors {
  // Surfaces, lowest to highest. Depth is luminance plus a hairline border, never a shadow.
  static const bg = Color(0xFF050809);
  static const surface = Color(0xFF0E1417);
  static const surfaceHigh = Color(0xFF151D21);

  /// Overlays: sheets, menus, dialogs, pressed states.
  static const surfaceTop = Color(0xFF1C262B);

  static const line = Color(0xFF1F2A2F);
  static const lineStrong = Color(0xFF2E3C42);

  // Text, strongest to quietest.
  static const text = Color(0xFFE8F1F2);
  static const textSecondary = Color(0xFFB7C5C9);
  static const muted = Color(0xFF8A9BA0);
  static const faint = Color(0xFF5E6E73);

  /// Secondary text that sits directly on the sky: brighter than [muted] so it reads on any light.
  static const softText = Color(0xFFCBD7DB);

  /// The one accent: active, primary, alive.
  static const accent = Color(0xFF5EEAD4);

  /// The accent as a tinted container (selected chip, soft button, tag).
  static const accentSoft = Color(0x245EEAD4);
  static const onAccent = Color(0xFF00201B);
  static const warn = Color(0xFFF5B86B);

  /// Errors and destructive actions: calmer than red on the dark surfaces.
  static const danger = Color(0xFFE39A8C);
}

/// Radii on one scale: small controls, tiles, cards, sheets. Round things are pills.
abstract final class FluteRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static BorderRadius get smAll => BorderRadius.circular(sm);
  static BorderRadius get mdAll => BorderRadius.circular(md);
  static BorderRadius get lgAll => BorderRadius.circular(lg);
  static BorderRadius get xlAll => BorderRadius.circular(xl);
  static BorderRadius get pillAll => BorderRadius.circular(pill);
}

/// A 4 px spacing scale. Screens use [lg] gutters and [xl] between sections.
abstract final class FluteSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// The signature gradient. It is the single loud element: the voice orb, the creating-image canvas,
/// the send button. Never a large surface.
abstract final class FluteGradients {
  static const signature = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF5EEAD4), Color(0xFF7DB5FF), Color(0xFFB79CFF)],
  );
}

/// Type roles. Inter for reading and controls, Inter Display for titles. Headlines lean medium,
/// never heavy. The home clock stays thin (Roboto) on purpose.
abstract final class FluteText {
  static const _body = 'Inter';
  static const _display = 'InterDisplay';

  static const display = TextStyle(
    fontFamily: _display, fontWeight: FontWeight.w500, fontSize: 30, height: 1.2, letterSpacing: -0.4,
  );
  static const title = TextStyle(
    fontFamily: _display, fontWeight: FontWeight.w500, fontSize: 21, height: 1.25, letterSpacing: -0.2,
  );
  static const heading = TextStyle(fontFamily: _body, fontWeight: FontWeight.w600, fontSize: 16, height: 1.3);
  static const body = TextStyle(fontFamily: _body, fontWeight: FontWeight.w400, fontSize: 15, height: 1.45);
  static const label = TextStyle(fontFamily: _body, fontWeight: FontWeight.w500, fontSize: 14, height: 1.3);
  static const caption = TextStyle(
    fontFamily: _body, fontWeight: FontWeight.w400, fontSize: 12.5, height: 1.35, color: FluteColors.muted,
  );

  /// Small caps-style section label.
  static const overline = TextStyle(
    fontFamily: _body,
    fontWeight: FontWeight.w600,
    fontSize: 11.5,
    height: 1.2,
    letterSpacing: 1.0,
    color: FluteColors.muted,
  );
}

ThemeData fluteTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  final text = base.textTheme
      .apply(fontFamily: 'Inter', bodyColor: FluteColors.text, displayColor: FluteColors.text)
      .copyWith(
        displaySmall: FluteText.display.copyWith(color: FluteColors.text),
        headlineMedium: FluteText.title.copyWith(fontSize: 24, color: FluteColors.text),
        titleLarge: FluteText.title.copyWith(color: FluteColors.text),
        titleMedium: FluteText.heading.copyWith(color: FluteColors.text),
        titleSmall: FluteText.label.copyWith(color: FluteColors.text),
        bodyLarge: FluteText.body.copyWith(fontSize: 16, height: 1.5, color: FluteColors.text),
        bodyMedium: FluteText.body.copyWith(color: FluteColors.text),
        bodySmall: FluteText.caption,
        labelLarge: FluteText.label.copyWith(fontWeight: FontWeight.w600, color: FluteColors.text),
        labelMedium: FluteText.label.copyWith(fontSize: 12.5, color: FluteColors.text),
        labelSmall: FluteText.overline,
      );

  RoundedRectangleBorder shape(double radius, {BorderSide side = BorderSide.none}) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: side);
  const hairline = BorderSide(color: FluteColors.line);
  const strongLine = BorderSide(color: FluteColors.lineStrong);

  return base.copyWith(
    scaffoldBackgroundColor: FluteColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: FluteColors.accent,
      onPrimary: FluteColors.onAccent,
      primaryContainer: Color(0xFF123B36),
      onPrimaryContainer: FluteColors.accent,
      secondary: FluteColors.accent,
      onSecondary: FluteColors.onAccent,
      secondaryContainer: Color(0xFF123B36),
      onSecondaryContainer: FluteColors.accent,
      surface: FluteColors.surface,
      onSurface: FluteColors.text,
      onSurfaceVariant: FluteColors.muted,
      surfaceContainerLowest: FluteColors.bg,
      surfaceContainerLow: FluteColors.surface,
      surfaceContainer: FluteColors.surfaceHigh,
      surfaceContainerHigh: FluteColors.surfaceHigh,
      surfaceContainerHighest: FluteColors.surfaceTop,
      outline: FluteColors.lineStrong,
      outlineVariant: FluteColors.line,
      error: FluteColors.danger,
      surfaceTint: Colors.transparent,
    ),
    textTheme: text,
    primaryTextTheme: text,
    splashFactory: NoSplash.splashFactory,
    dividerColor: FluteColors.line,
    dividerTheme: const DividerThemeData(color: FluteColors.line, thickness: 1, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: FluteColors.bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: FluteText.title.copyWith(color: FluteColors.text),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: FluteColors.surfaceHigh,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: FluteSpace.lg, vertical: 14),
      hintStyle: FluteText.body.copyWith(color: FluteColors.faint),
      labelStyle: FluteText.body.copyWith(color: FluteColors.muted),
      floatingLabelStyle: FluteText.label.copyWith(color: FluteColors.accent),
      helperStyle: FluteText.caption,
      errorStyle: FluteText.caption.copyWith(color: FluteColors.danger),
      border: OutlineInputBorder(borderRadius: FluteRadius.mdAll, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: FluteRadius.mdAll, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: FluteRadius.mdAll,
        borderSide: BorderSide(color: FluteColors.accent.withValues(alpha: 0.55), width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: FluteRadius.mdAll,
        borderSide: BorderSide(color: FluteColors.danger.withValues(alpha: 0.6)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: FluteRadius.mdAll,
        borderSide: const BorderSide(color: FluteColors.danger, width: 1.5),
      ),
    ),
    // One filled accent button per screen is the primary action; everything else is quieter.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: FluteColors.accent,
        foregroundColor: FluteColors.onAccent,
        disabledBackgroundColor: FluteColors.surfaceTop,
        disabledForegroundColor: FluteColors.faint,
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: FluteSpace.xl),
        shape: shape(FluteRadius.md),
        textStyle: FluteText.label.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: FluteColors.text,
        disabledForegroundColor: FluteColors.faint,
        side: strongLine,
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: FluteSpace.xl),
        shape: shape(FluteRadius.md),
        textStyle: FluteText.label.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: FluteColors.accent,
        disabledForegroundColor: FluteColors.faint,
        minimumSize: const Size(48, 48),
        shape: shape(FluteRadius.md),
        textStyle: FluteText.label.copyWith(fontWeight: FontWeight.w600, fontSize: 14.5),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: FluteColors.textSecondary,
        minimumSize: const Size(48, 48),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? FluteColors.onAccent : FluteColors.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? FluteColors.accent : FluteColors.surfaceTop,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? FluteColors.accent : Colors.transparent,
      ),
      checkColor: WidgetStateProperty.all(FluteColors.onAccent),
      side: strongLine,
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? FluteColors.accent : FluteColors.muted,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: FluteColors.accent,
      inactiveTrackColor: FluteColors.surfaceTop,
      thumbColor: FluteColors.accent,
      overlayColor: FluteColors.accentSoft,
      trackHeight: 4,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: FluteColors.accent,
      linearTrackColor: FluteColors.surfaceTop,
      circularTrackColor: Colors.transparent,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? FluteColors.accentSoft : FluteColors.surfaceHigh,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? FluteColors.accent : FluteColors.textSecondary,
        ),
        side: WidgetStateProperty.all(BorderSide.none),
        shape: WidgetStateProperty.all(shape(FluteRadius.md)),
        textStyle: WidgetStateProperty.all(FluteText.label),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: FluteColors.surfaceHigh,
      selectedColor: FluteColors.accentSoft,
      side: hairline,
      shape: shape(FluteRadius.sm),
      labelStyle: FluteText.label.copyWith(color: FluteColors.textSecondary),
      secondaryLabelStyle: FluteText.label.copyWith(color: FluteColors.accent),
      checkmarkColor: FluteColors.accent,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: FluteColors.textSecondary,
      titleTextStyle: FluteText.heading.copyWith(fontWeight: FontWeight.w500, color: FluteColors.text),
      subtitleTextStyle: FluteText.caption.copyWith(fontSize: 13),
      minVerticalPadding: FluteSpace.md,
      shape: shape(FluteRadius.md),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: FluteColors.surfaceTop,
      surfaceTintColor: Colors.transparent,
      shape: shape(FluteRadius.xl, side: hairline),
      titleTextStyle: FluteText.title.copyWith(color: FluteColors.text),
      contentTextStyle: FluteText.body.copyWith(color: FluteColors.textSecondary),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: FluteColors.surfaceHigh,
      modalBackgroundColor: FluteColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: FluteColors.lineStrong,
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FluteRadius.xl)),
        side: BorderSide(color: FluteColors.line),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: FluteColors.surfaceTop,
      contentTextStyle: FluteText.body.copyWith(fontSize: 14, color: FluteColors.text),
      actionTextColor: FluteColors.accent,
      shape: shape(FluteRadius.md, side: hairline),
      insetPadding: const EdgeInsets.fromLTRB(FluteSpace.lg, 0, FluteSpace.lg, FluteSpace.lg),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: FluteColors.surfaceTop,
      surfaceTintColor: Colors.transparent,
      shape: shape(FluteRadius.lg, side: hairline),
      textStyle: FluteText.body.copyWith(color: FluteColors.text),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStateProperty.all(FluteColors.surfaceTop),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shape: WidgetStateProperty.all(shape(FluteRadius.lg, side: hairline)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: FluteColors.surfaceTop, borderRadius: FluteRadius.smAll),
      textStyle: FluteText.caption.copyWith(color: FluteColors.text),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(3),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.all(FluteColors.lineStrong),
    ),
  );
}

/// A tonal surface for cards and tiles: a fill and a hairline, no shadow.
BoxDecoration fluteSurface({
  Color color = FluteColors.surface,
  double radius = FluteRadius.lg,
  Color border = FluteColors.line,
}) =>
    BoxDecoration(color: color, borderRadius: BorderRadius.circular(radius), border: Border.all(color: border));
