import 'package:flutter/material.dart';

/// Design tokens. Neutral surfaces, one accent, status colours used only for meaning.
class Tokens {
  static const accent = Color(0xFF4F46E5);
  static const success = Color(0xFF15803D);
  static const warning = Color(0xFFB45309);
  static const danger = Color(0xFFB91C1C);

  static const radius = 14.0;
  static const gap = 12.0;
  static const pad = 16.0;
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: Tokens.accent, brightness: b).copyWith(
    primary: dark ? const Color(0xFF818CF8) : Tokens.accent,
    surface: dark ? const Color(0xFF111418) : Colors.white,
    surfaceContainerLowest: dark ? const Color(0xFF0B0D10) : const Color(0xFFF6F7F9),
    outlineVariant: dark ? const Color(0xFF2A2F37) : const Color(0xFFE5E7EB),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF181C21) : const Color(0xFFF3F4F6),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      labelTextStyle: WidgetStatePropertyAll(base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
  );
}
