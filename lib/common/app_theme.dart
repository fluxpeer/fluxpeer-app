// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'design/tokens.dart';

/// Builds the theme from the currently-active [Fx] scheme (call after
/// [Fx.applyDark]). On theme switch, rebuild via Get.changeTheme(buildFluxpeerTheme()).
ThemeData buildFluxpeerTheme() {
  final dark = Fx.isDark;
  final base =
      dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
  final scheme = ColorScheme.fromSeed(
    seedColor: Fx.brand,
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    surface: Fx.bgCanvas,
    primary: Fx.brand,
    secondary: Fx.accent,
    error: Fx.danger,
    onPrimary: Fx.fgOnBrand,
    onSurface: Fx.fgPrimary,
  );
  return base.copyWith(
    scaffoldBackgroundColor: Fx.bgCanvas,
    colorScheme: scheme,
    textTheme: GoogleFonts.dmSansTextTheme(base.textTheme).apply(
      bodyColor: Fx.fgPrimary,
      displayColor: Fx.fgPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Fx.bgCanvas,
      surfaceTintColor: Colors.transparent,
      foregroundColor: Fx.fgPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: FxText.title,
    ),
    cardTheme: CardThemeData(
      color: Fx.bgSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FxRadius.lg),
        side: BorderSide(color: Fx.border),
      ),
      margin: EdgeInsets.zero,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: Fx.bgSurface,
      selectedItemColor: Fx.brandGlow,
      unselectedItemColor: Fx.fgMuted,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
    dividerColor: Fx.border,
    iconTheme: IconThemeData(color: Fx.fgSecondary),
  );
}
