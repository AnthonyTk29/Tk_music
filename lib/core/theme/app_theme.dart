import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const _background = Color(0xFF070B14);
  static const _surface = Color(0xFF121A2C);
  static const _accent = Color(0xFF2F7FFF);

  /// Degradado de marca: azul eléctrico a azul profundo. Se usa en el logo,
  /// el splash y otros momentos destacados; el resto de la UI usa los
  /// colores sólidos derivados de [_accent] vía [ColorScheme.fromSeed].
  static const accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3FD3FF), Color(0xFF1046D6)],
  );

  static final light = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: _accent),
    useMaterial3: true,
  );

  static final dark = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: Brightness.dark,
      surface: _surface,
    ).copyWith(surface: _surface),
    scaffoldBackgroundColor: _background,
    appBarTheme: const AppBarTheme(
      backgroundColor: _background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: const BorderSide(color: _accent),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFF1B2438),
      selectedColor: _accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      side: BorderSide.none,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: const Color(0xFF1B2438),
        foregroundColor: Colors.white70,
        selectedBackgroundColor: _accent,
        selectedForegroundColor: Colors.white,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    useMaterial3: true,
  );
}
