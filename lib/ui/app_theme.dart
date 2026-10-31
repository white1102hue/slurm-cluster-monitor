import 'package:flutter/material.dart';
import '../models/app_skin.dart';

extension AppColors on BuildContext {
  Color get muted => Theme.of(this).colorScheme.onSurfaceVariant;
  Color get ink => Theme.of(this).colorScheme.onSurface;
  Color get track => Theme.of(this).colorScheme.surfaceContainerHighest;
}

ThemeData buildAppTheme(AppSkin skin) {
  final light = skin == AppSkin.daylight;
  final violet = skin == AppSkin.violet;
  final primary = light
      ? const Color(0xFF087E74)
      : violet
      ? const Color(0xFFCAA5FF)
      : const Color(0xFF63DFC5);
  final background = light
      ? Colors.white
      : violet
      ? const Color(0xFF110E1D)
      : const Color(0xFF0A121D);
  final card = light
      ? Colors.white
      : violet
      ? const Color(0xFF20192F)
      : const Color(0xFF131E2C);
  final scheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: light ? Brightness.light : Brightness.dark,
    primary: primary,
    secondary: light ? const Color(0xFF245FA5) : const Color(0xFF79AEFF),
    tertiary: light ? const Color(0xFF95600B) : const Color(0xFFECC47D),
    surface: card,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: light
              ? const Color(0xFFDDE5ED)
              : violet
              ? const Color(0xFF3A2C50)
              : const Color(0xFF243142),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: light
          ? const Color(0xFFF5F7FA)
          : scheme.surfaceContainerLowest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: card,
      height: 66,
      labelTextStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 11)),
    ),
    dividerColor: light ? const Color(0xFFDDE5ED) : const Color(0xFF2C3545),
  );
}
