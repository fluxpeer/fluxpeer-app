// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// fluxpeer raw color ramp (theme-independent).
/// The palette echoes the bagua/taiji brand mark: an indigo core with a cyan
/// accent for the "light" half of the taiji.
class FxColors {
  FxColors._();
  // Indigo brand ramp
  static const indigo50 = Color(0xFFEEF0FF);
  static const indigo100 = Color(0xFFE0E4FF);
  static const indigo200 = Color(0xFFC7CEFF);
  static const indigo300 = Color(0xFFA5B0FF);
  static const indigo400 = Color(0xFF818CF8);
  static const indigo500 = Color(0xFF6366F1);
  static const indigo600 = Color(0xFF4F46E5);
  static const indigo700 = Color(0xFF4338CA);
  static const indigo800 = Color(0xFF3730A3);
  static const indigo900 = Color(0xFF312E81);
  // Cyan accent
  static const cyan300 = Color(0xFF67E8F9);
  static const cyan400 = Color(0xFF22D3EE);
  static const cyan500 = Color(0xFF06B6D4);
  // Neutral
  static const neutral0 = Color(0xFFFFFFFF);
  static const neutral200 = Color(0xFFD4D6E0);
  static const neutral400 = Color(0xFF9AA0B4);
  static const neutral500 = Color(0xFF6B7186);
  static const neutral700 = Color(0xFF2A2D3C);
  static const neutral800 = Color(0xFF1A1C28);
  static const neutral900 = Color(0xFF12131C);
  static const neutral950 = Color(0xFF0B0C12);
  // Semantic
  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFF87171);
}

/// A resolved semantic color set (one per brightness).
class FxScheme {
  final Color bgCanvas,
      bgSurface,
      bgElevated,
      border,
      brand,
      brandGlow,
      accent,
      fgPrimary,
      fgSecondary,
      fgMuted,
      fgOnBrand,
      success,
      warning,
      danger;
  const FxScheme({
    required this.bgCanvas,
    required this.bgSurface,
    required this.bgElevated,
    required this.border,
    required this.brand,
    required this.brandGlow,
    required this.accent,
    required this.fgPrimary,
    required this.fgSecondary,
    required this.fgMuted,
    required this.fgOnBrand,
    required this.success,
    required this.warning,
    required this.danger,
  });
}

const _fxDark = FxScheme(
  bgCanvas: FxColors.neutral950,
  bgSurface: FxColors.neutral900,
  bgElevated: FxColors.neutral800,
  border: FxColors.neutral700,
  brand: FxColors.indigo500,
  brandGlow: FxColors.indigo400,
  accent: FxColors.cyan400,
  fgPrimary: Color(0xFFECEDF5),
  fgSecondary: FxColors.neutral400,
  fgMuted: Color(0xFF8E94AB),
  fgOnBrand: Color(0xFFFFFFFF),
  success: FxColors.success,
  warning: FxColors.warning,
  danger: FxColors.danger,
);

const _fxLight = FxScheme(
  bgCanvas: Color(0xFFF5F6FB),
  bgSurface: Color(0xFFFFFFFF),
  bgElevated: Color(0xFFEDEFF6),
  border: Color(0xFFDADDE8),
  brand: FxColors.indigo600,
  brandGlow: FxColors.indigo500,
  accent: FxColors.cyan500,
  fgPrimary: Color(0xFF14161F),
  fgSecondary: Color(0xFF565C70),
  fgMuted: Color(0xFF767C90),
  fgOnBrand: Color(0xFFFFFFFF),
  success: Color(0xFF059669),
  warning: Color(0xFFB45309),
  danger: Color(0xFFDC2626),
);

/// Semantic tokens, resolved against the currently-active [FxScheme].
/// Swap with [Fx.applyDark]; values are getters so widgets pick up the change
/// on the next rebuild.
class Fx {
  Fx._();
  static FxScheme _s = _fxDark;
  static bool _dark = true;
  static bool get isDark => _dark;
  static void applyDark(bool dark) {
    _dark = dark;
    _s = dark ? _fxDark : _fxLight;
  }

  static Color get bgCanvas => _s.bgCanvas;
  static Color get bgSurface => _s.bgSurface;
  static Color get bgElevated => _s.bgElevated;
  static Color get border => _s.border;
  static Color get brand => _s.brand;
  static Color get brandGlow => _s.brandGlow;
  static Color get accent => _s.accent;
  static Color get fgPrimary => _s.fgPrimary;
  static Color get fgSecondary => _s.fgSecondary;
  static Color get fgMuted => _s.fgMuted;
  static Color get fgOnBrand => _s.fgOnBrand;
  static Color get success => _s.success;
  static Color get warning => _s.warning;
  static Color get danger => _s.danger;
}

class FxSpace {
  FxSpace._();
  static const x1 = 4.0,
      x2 = 8.0,
      x3 = 12.0,
      x4 = 16.0,
      x5 = 20.0,
      x6 = 24.0,
      x8 = 32.0,
      x10 = 40.0,
      x12 = 48.0,
      x16 = 64.0;
}

class FxRadius {
  FxRadius._();
  static const sm = 8.0, md = 12.0, lg = 16.0, xl = 20.0, xl2 = 24.0, pill = 999.0;
}

class FxMotion {
  FxMotion._();
  static const fast = Duration(milliseconds: 150);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 320);
}

/// Type scale — Sora (display/heading), DM Sans (body/label), JetBrains Mono
/// (addresses/keys). Colors resolve against the active scheme at call time.
class FxText {
  FxText._();
  static TextStyle get display =>
      GoogleFonts.sora(fontSize: 28, fontWeight: FontWeight.w700, color: Fx.fgPrimary);
  static TextStyle get title =>
      GoogleFonts.sora(fontSize: 20, fontWeight: FontWeight.w600, color: Fx.fgPrimary);
  static TextStyle get heading =>
      GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600, color: Fx.fgPrimary);
  static TextStyle get body =>
      GoogleFonts.dmSans(fontSize: 15, color: Fx.fgPrimary);
  static TextStyle get label => GoogleFonts.dmSans(
      fontSize: 13, fontWeight: FontWeight.w600, color: Fx.fgSecondary);
  static TextStyle get caption =>
      GoogleFonts.dmSans(fontSize: 12, color: Fx.fgMuted);
  static TextStyle get mono =>
      GoogleFonts.jetBrainsMono(fontSize: 13, color: Fx.fgPrimary);
  static TextStyle get monoMuted =>
      GoogleFonts.jetBrainsMono(fontSize: 12, color: Fx.fgMuted);
}
