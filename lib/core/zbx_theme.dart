import 'package:flutter/material.dart';

class ZbxPalette {
  const ZbxPalette._();

  static const Color scaffoldDark = Color(0xFF060E1C);
  static const Color scaffoldLight = Color(0xFFF0F4F8);
  static const Color cardDark = Color(0xFF0D1B32);
  static const Color cardLight = Colors.white;
  static const Color liftDark = Color(0xFF132340);
  static const Color liftLight = Color(0xFFEAEFF6);
  static const Color panelDark = Color(0xFF0A1628);
  static const Color panelLight = Color(0xFFF5F7FA);
  static const Color rimDark = Color(0xFF1E3358);
  static const Color rimLight = Color(0xFFDDE3EC);
  static const Color textPriDark = Color(0xFFE8EEF8);
  static const Color textPriLight = Color(0xFF0F1C2E);
  static const Color textSecDark = Color(0xFF7A90B4);
  static const Color textSecLight = Color(0xFF5A6A80);
  static const Color textMonoDark = Color(0xFF9DB8D8);
  static const Color textMonoLight = Color(0xFF3A5070);

  static const Color rxBlue = Color(0xFF29B6F6);
  static const Color txGreen = Color(0xFF26C67C);
  static const Color upGreen = Color(0xFF1BD96A);
  static const Color downRed = Color(0xFFEF5350);
  static const Color warnAmb = Color(0xFFFFAB40);
}

/// Semantic colour tokens that switch between dark and light palettes
/// depending on the current [Brightness] from [BuildContext].
///
/// Usage:
///   final t = ZbxTheme.of(context);
///   Container(color: t.bgCard, child: Text('…', style: TextStyle(color: t.textPri)));
class ZbxTheme {
  final bool isDark;

  const ZbxTheme._(this.isDark);

  factory ZbxTheme.of(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return ZbxTheme._(brightness == Brightness.dark);
  }

  // ── Backgrounds ──────────────────────────────────────────────────────────────
  Color get scaffold =>
      isDark ? ZbxPalette.scaffoldDark : ZbxPalette.scaffoldLight;
  Color get bgCard => isDark ? ZbxPalette.cardDark : ZbxPalette.cardLight;
  Color get bgLift => isDark ? ZbxPalette.liftDark : ZbxPalette.liftLight;
  Color get bgPanel => isDark ? ZbxPalette.panelDark : ZbxPalette.panelLight;

  // ── Borders / dividers ───────────────────────────────────────────────────────
  Color get rim => isDark ? ZbxPalette.rimDark : ZbxPalette.rimLight;

  // ── Text ─────────────────────────────────────────────────────────────────────
  Color get textPri =>
      isDark ? ZbxPalette.textPriDark : ZbxPalette.textPriLight;
  Color get textSec =>
      isDark ? ZbxPalette.textSecDark : ZbxPalette.textSecLight;
  Color get textMono =>
      isDark ? ZbxPalette.textMonoDark : ZbxPalette.textMonoLight;

  // ── Accent / brand colours (same in both modes) ──────────────────────────────
  Color get rxBlue => ZbxPalette.rxBlue;
  Color get txGreen => ZbxPalette.txGreen;
  Color get upGreen => ZbxPalette.upGreen;
  Color get downRed => ZbxPalette.downRed;
  Color get warnAmb => ZbxPalette.warnAmb;

  // ── AppBar ────────────────────────────────────────────────────────────────────
  Color get appBarBg => bgCard;
  Color get appBarFg => textPri;
}

/// Public colour-helper that replaces the private `_T` class that was
/// duplicated in every screen file.  Import `zbx_theme.dart` and call
/// `ZbxT.card(ctx)`, `ZbxT.textPri(ctx)`, etc.
class ZbxT {
  const ZbxT._();
  static Color card(BuildContext ctx)     => ZbxTheme.of(ctx).bgCard;
  static Color lift(BuildContext ctx)     => ZbxTheme.of(ctx).bgLift;
  static Color panel(BuildContext ctx)    => ZbxTheme.of(ctx).bgPanel;
  static Color rim(BuildContext ctx)      => ZbxTheme.of(ctx).rim;
  static Color textPri(BuildContext ctx)  => ZbxTheme.of(ctx).textPri;
  static Color textSec(BuildContext ctx)  => ZbxTheme.of(ctx).textSec;
  static Color textMono(BuildContext ctx) => ZbxTheme.of(ctx).textMono;
}
