import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'local_store.dart';
import 'zbx_theme.dart';

// ─── Color scheme options ──────────────────────────────────────────────────────
enum AppColorScheme { navyBlue, darkTeal, darkSlate, deepPurple, midnightGreen }

extension AppColorSchemeExt on AppColorScheme {
  String get label {
    switch (this) {
      case AppColorScheme.navyBlue:
        return 'Navy Blue (Default)';
      case AppColorScheme.darkTeal:
        return 'Dark Teal';
      case AppColorScheme.darkSlate:
        return 'Dark Slate';
      case AppColorScheme.deepPurple:
        return 'Deep Purple';
      case AppColorScheme.midnightGreen:
        return 'Midnight Green';
    }
  }

  Color get seed {
    switch (this) {
      case AppColorScheme.navyBlue:
        return const Color(0xFF0A1B3A);
      case AppColorScheme.darkTeal:
        return const Color(0xFF0A2A2A);
      case AppColorScheme.darkSlate:
        return const Color(0xFF1A2030);
      case AppColorScheme.deepPurple:
        return const Color(0xFF1A0A3A);
      case AppColorScheme.midnightGreen:
        return const Color(0xFF071A12);
    }
  }

  Color get scaffold {
    switch (this) {
      case AppColorScheme.navyBlue:
        return const Color(0xFF060E1C);
      case AppColorScheme.darkTeal:
        return const Color(0xFF061414);
      case AppColorScheme.darkSlate:
        return const Color(0xFF0F1520);
      case AppColorScheme.deepPurple:
        return const Color(0xFF0E061C);
      case AppColorScheme.midnightGreen:
        return const Color(0xFF040E09);
    }
  }

  Color get card {
    switch (this) {
      case AppColorScheme.navyBlue:
        return const Color(0xFF0D1B32);
      case AppColorScheme.darkTeal:
        return const Color(0xFF0D2424);
      case AppColorScheme.darkSlate:
        return const Color(0xFF151E2E);
      case AppColorScheme.deepPurple:
        return const Color(0xFF170D2C);
      case AppColorScheme.midnightGreen:
        return const Color(0xFF091408);
    }
  }

  Color get accent {
    switch (this) {
      case AppColorScheme.navyBlue:
        return const Color(0xFF29B6F6);
      case AppColorScheme.darkTeal:
        return const Color(0xFF26C67C);
      case AppColorScheme.darkSlate:
        return const Color(0xFF7EB8F7);
      case AppColorScheme.deepPurple:
        return const Color(0xFFCE93D8);
      case AppColorScheme.midnightGreen:
        return const Color(0xFF66BB6A);
    }
  }
}

// ─── Font size options ─────────────────────────────────────────────────────────
enum AppFontSize { small, medium, large, extraLarge, huge }

extension AppFontSizeExt on AppFontSize {
  String get label {
    switch (this) {
      case AppFontSize.small:
        return 'Small';
      case AppFontSize.medium:
        return 'Medium (Default)';
      case AppFontSize.large:
        return 'Large';
      case AppFontSize.extraLarge:
        return 'Extra Large';
      case AppFontSize.huge:
        return 'Huge';
    }
  }

  /// textScaleFactor equivalent
  double get scale {
    switch (this) {
      case AppFontSize.small:
        return 0.85;
      case AppFontSize.medium:
        return 1.0;
      case AppFontSize.large:
        return 1.15;
      case AppFontSize.extraLarge:
        return 1.30;
      case AppFontSize.huge:
        return 1.50;
    }
  }

  String get preview => 'Aa';
}

// ─── Theme mode ───────────────────────────────────────────────────────────────
enum AppThemeMode { system, light, dark }

extension AppThemeModeExt on AppThemeMode {
  String get label {
    switch (this) {
      case AppThemeMode.system:
        return 'System Default';
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.dark:
        return 'Dark';
    }
  }

  IconData get icon {
    switch (this) {
      case AppThemeMode.system:
        return Icons.brightness_auto_outlined;
      case AppThemeMode.light:
        return Icons.light_mode_outlined;
      case AppThemeMode.dark:
        return Icons.dark_mode_outlined;
    }
  }

  ThemeMode get flutterMode {
    switch (this) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }
}

// ─── Notification filter ───────────────────────────────────────────────────────
class NotifFilter {
  Set<int> severities;
  Set<String> hostgroups;
  Set<String> vrfs;
  Set<String> customers;
  Set<String> hosts;

  NotifFilter({
    Set<int>? severities,
    Set<String>? hostgroups,
    Set<String>? vrfs,
    Set<String>? customers,
    Set<String>? hosts,
  }) : severities = severities ?? {0, 1, 2, 3, 4, 5},
       hostgroups = hostgroups ?? {},
       vrfs = vrfs ?? {},
       customers = customers ?? {},
       hosts = hosts ?? {};

  Map<String, dynamic> toJson() => {
    'severities': severities.toList(),
    'hostgroups': hostgroups.toList(),
    'vrfs': vrfs.toList(),
    'customers': customers.toList(),
    'hosts': hosts.toList(),
  };

  factory NotifFilter.fromJson(Map<String, dynamic> j) => NotifFilter(
    severities: Set<int>.from(
      (j['severities'] as List? ?? []).map((e) => (e as num).toInt()),
    ),
    hostgroups: Set<String>.from(
      (j['hostgroups'] as List? ?? []).map((e) => e.toString()),
    ),
    vrfs: Set<String>.from((j['vrfs'] as List? ?? []).map((e) => e.toString())),
    customers: Set<String>.from(
      (j['customers'] as List? ?? []).map((e) => e.toString()),
    ),
    hosts: Set<String>.from(
      (j['hosts'] as List? ?? []).map((e) => e.toString()),
    ),
  );
}

// ─── Central settings (ChangeNotifier) ────────────────────────────────────────
class AppSettings extends ChangeNotifier {
  static const _storeKey = 'settings:v2';

  AppColorScheme _colorScheme = AppColorScheme.navyBlue;
  AppFontSize _fontSize = AppFontSize.medium;
  AppThemeMode _themeMode = AppThemeMode.dark;
  NotifFilter _notifFilter = NotifFilter();
  bool _rememberMe = true;
  bool _allowSelfSignedCertificates = false;
  bool _loaded = false;

  AppColorScheme get colorScheme => _colorScheme;
  AppFontSize get fontSize => _fontSize;
  AppThemeMode get themeMode => _themeMode;
  NotifFilter get notifFilter => _notifFilter;
  bool get rememberMe => _rememberMe;
  bool get allowSelfSignedCertificates => _allowSelfSignedCertificates;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      final raw = await LocalStore.readMap(_storeKey);
      if (raw != null) {
        final si = raw['colorScheme'] as int? ?? 0;
        _colorScheme = AppColorScheme
            .values[si.clamp(0, AppColorScheme.values.length - 1)];
        final fi = raw['fontSize'] as int? ?? 1;
        _fontSize =
            AppFontSize.values[fi.clamp(0, AppFontSize.values.length - 1)];
        final ti = raw['themeMode'] as int? ?? 2; // default dark
        _themeMode =
            AppThemeMode.values[ti.clamp(0, AppThemeMode.values.length - 1)];
        _rememberMe = raw['rememberMe'] as bool? ?? true;
        _allowSelfSignedCertificates =
            raw['allowSelfSignedCertificates'] as bool? ?? false;
        if (raw['notifFilter'] is Map<String, dynamic>) {
          _notifFilter = NotifFilter.fromJson(
            raw['notifFilter'] as Map<String, dynamic>,
          );
        }
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    await LocalStore.writeMap(_storeKey, {
      'colorScheme': _colorScheme.index,
      'fontSize': _fontSize.index,
      'themeMode': _themeMode.index,
      'rememberMe': _rememberMe,
      'allowSelfSignedCertificates': _allowSelfSignedCertificates,
      'notifFilter': _notifFilter.toJson(),
    });
  }

  Future<void> setColorScheme(AppColorScheme s) async {
    if (_colorScheme == s) return;
    _colorScheme = s;
    notifyListeners();
    await _save();
  }

  Future<void> setFontSize(AppFontSize s) async {
    if (_fontSize == s) return;
    _fontSize = s;
    notifyListeners();
    await _save();
  }

  Future<void> setThemeMode(AppThemeMode m) async {
    if (_themeMode == m) return;
    _themeMode = m;
    notifyListeners();
    await _save();
  }

  Future<void> setRememberMe(bool v) async {
    _rememberMe = v;
    await _save();
  }

  Future<void> setAllowSelfSignedCertificates(bool v) async {
    if (_allowSelfSignedCertificates == v) return;
    _allowSelfSignedCertificates = v;
    notifyListeners();
    await _save();
  }

  Future<void> setNotifFilter(NotifFilter f) async {
    _notifFilter = f;
    notifyListeners();
    await _save();
  }

  /// Dark theme
  ThemeData _buildDark() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: ZbxPalette.scaffoldDark,
    cardColor: ZbxPalette.cardDark,
    colorScheme: const ColorScheme.dark(
      primary: ZbxPalette.rxBlue,
      secondary: ZbxPalette.txGreen,
      surface: ZbxPalette.cardDark,
      onSurface: ZbxPalette.textPriDark,
      error: ZbxPalette.downRed,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: ZbxPalette.cardDark,
      foregroundColor: ZbxPalette.textPriDark,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: ZbxPalette.scaffoldDark,
    ),
    textTheme: GoogleFonts.interTextTheme(
      ThemeData.dark(useMaterial3: true).textTheme,
    ),
  );

  /// Light theme - white/light grey backgrounds, dark text
  ThemeData _buildLight() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: ZbxPalette.scaffoldLight,
    cardColor: ZbxPalette.cardLight,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF0277BD),
      brightness: Brightness.light,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: ZbxPalette.cardLight,
      foregroundColor: ZbxPalette.textPriLight,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: ZbxPalette.scaffoldLight,
    ),
    textTheme: GoogleFonts.interTextTheme(
      ThemeData.light(useMaterial3: true).textTheme,
    ),
  );

  ThemeData buildTheme() => _buildDark();
  ThemeData buildLightTheme() => _buildLight();
}
