import 'package:flutter/material.dart';

enum AppTone { neutral, discover, events, photos, social, profile, admin, danger }

class AppTheme {
  const AppTheme._();

  // Tek yerden kapatilip acilabilir. Gorsel tasarim geri alinmak istenirse false yapilabilir.
  static const bool useRevampedTheme = true;

  static const Color bgPrimary = Color(0xFF0A0B10);
  static const Color bgSecondary = Color(0xFF11131A);
  static const Color bgDeep = Color(0xFF07080C);

  static const Color surfacePrimary = Color(0xFF121520);
  static const Color surfaceSecondary = Color(0xFF171B28);
  static const Color surfaceElevated = Color(0xFF1D2332);

  static const Color borderSoft = Color(0xFF242B3B);
  static const Color borderStrong = Color(0xFF303A50);

  static const Color textPrimary = Color(0xFFF6F7FB);
  static const Color textSecondary = Color(0xFFB7BED0);
  static const Color textTertiary = Color(0xFF8189A0);

  static const Color violet = Color(0xFF8B5CF6);
  static const Color pink = Color(0xFFEC4899);
  static const Color cyan = Color(0xFF22D3EE);
  static const Color orange = Color(0xFFF97316);
  static const Color amber = Color(0xFFF59E0B);

  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF38BDF8);

  static ThemeData buildTheme() {
    return useRevampedTheme ? _buildRevampedTheme() : _buildLegacyTheme();
  }

  static ThemeData _buildLegacyTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF080B14),
      visualDensity: VisualDensity.compact,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFE53935),
        secondary: Color(0xFFFF5A5F),
        surface: Color(0xFF111827),
      ),
    );
  }

  static ThemeData _buildRevampedTheme() {
    const scheme = ColorScheme.dark(
      primary: violet,
      secondary: pink,
      surface: surfacePrimary,
      error: error,
      onPrimary: textPrimary,
      onSecondary: textPrimary,
      onSurface: textPrimary,
      onError: textPrimary,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgPrimary,
      visualDensity: VisualDensity.compact,
      colorScheme: scheme,
    );

    final textTheme = base.textTheme.copyWith(
      headlineSmall: const TextStyle(
        fontSize: 26,
        height: 1.12,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: textPrimary,
      ),
      titleLarge: const TextStyle(
        fontSize: 22,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.25,
        color: textPrimary,
      ),
      titleMedium: const TextStyle(
        fontSize: 17,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      titleSmall: const TextStyle(
        fontSize: 14,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      bodyLarge: const TextStyle(
        fontSize: 13,
        height: 1.45,
        color: textPrimary,
      ),
      bodyMedium: const TextStyle(
        fontSize: 12,
        height: 1.45,
        color: textPrimary,
      ),
      bodySmall: const TextStyle(
        fontSize: 10,
        height: 1.35,
        color: textSecondary,
      ),
      labelLarge: const TextStyle(
        fontSize: 13,
        height: 1.0,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      labelMedium: const TextStyle(
        fontSize: 10,
        height: 1.0,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: bgPrimary,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceSecondary,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: borderSoft),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surfaceSecondary,
        modalBackgroundColor: surfaceSecondary,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceElevated,
        contentTextStyle: const TextStyle(color: textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceElevated,
        labelStyle: const TextStyle(color: textSecondary, fontWeight: FontWeight.w500, fontSize: 12),
        hintStyle: const TextStyle(color: textTertiary),
        helperStyle: const TextStyle(color: textTertiary),
        errorStyle: const TextStyle(color: error, fontWeight: FontWeight.w500, fontSize: 11),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: _inputBorder(borderSoft),
        enabledBorder: _inputBorder(borderSoft),
        disabledBorder: _inputBorder(borderSoft.withOpacity(0.6)),
        focusedBorder: _inputBorder(violet),
        errorBorder: _inputBorder(error),
        focusedErrorBorder: _inputBorder(error),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          minimumSize: MaterialStateProperty.all(const Size(72, 52)),
          padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 18, vertical: 16)),
          shape: MaterialStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          textStyle: MaterialStateProperty.all(
            const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.1),
          ),
          backgroundColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.disabled)) return violet.withOpacity(0.35);
            return violet;
          }),
          foregroundColor: MaterialStateProperty.all(textPrimary),
          elevation: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.pressed)) return 1;
            return 0;
          }),
          overlayColor: MaterialStateProperty.all(textPrimary.withOpacity(0.08)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: MaterialStateProperty.all(const Size(64, 50)),
          padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
          shape: MaterialStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          side: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.disabled)) {
              return const BorderSide(color: borderSoft);
            }
            return BorderSide(color: borderStrong.withOpacity(0.9));
          }),
          backgroundColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.pressed)) return surfaceElevated;
            return surfaceSecondary;
          }),
          foregroundColor: MaterialStateProperty.all(textPrimary),
          textStyle: MaterialStateProperty.all(
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: MaterialStateProperty.all(textSecondary),
          textStyle: MaterialStateProperty.all(
            const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
          ),
          padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
          shape: MaterialStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceSecondary,
        disabledColor: surfacePrimary,
        selectedColor: violet.withOpacity(0.22),
        secondarySelectedColor: violet.withOpacity(0.22),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        labelStyle: const TextStyle(color: textSecondary, fontWeight: FontWeight.w500, fontSize: 12),
        secondaryLabelStyle: const TextStyle(color: textPrimary, fontWeight: FontWeight.w500, fontSize: 12),
        brightness: Brightness.dark,
        shape: StadiumBorder(side: BorderSide(color: borderStrong.withOpacity(0.92))),
        side: BorderSide(color: borderStrong.withOpacity(0.92)),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        side: const BorderSide(color: borderStrong),
        fillColor: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected)) return violet;
          return Colors.transparent;
        }),
        checkColor: MaterialStateProperty.all(textPrimary),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: violet,
        unselectedItemColor: textTertiary,
        selectedLabelStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
      ),
      dividerTheme: const DividerThemeData(color: borderSoft, thickness: 1, space: 1),
      splashFactory: InkRipple.splashFactory,
    );
  }

  static OutlineInputBorder _inputBorder(Color color) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: color, width: 1.1),
    );
  }

  static Color tonePrimary(AppTone tone) {
    switch (tone) {
      case AppTone.discover:
        return pink;
      case AppTone.events:
        return orange;
      case AppTone.photos:
        return cyan;
      case AppTone.social:
        return pink;
      case AppTone.profile:
        return violet;
      case AppTone.admin:
        return cyan;
      case AppTone.danger:
        return error;
      case AppTone.neutral:
        return violet;
    }
  }

  static Color toneSecondary(AppTone tone) {
    switch (tone) {
      case AppTone.discover:
        return violet;
      case AppTone.events:
        return amber;
      case AppTone.photos:
        return violet;
      case AppTone.social:
        return violet;
      case AppTone.profile:
        return pink;
      case AppTone.admin:
        return info;
      case AppTone.danger:
        return orange;
      case AppTone.neutral:
        return cyan;
    }
  }

  static List<Color> shellGradient([AppTone tone = AppTone.neutral]) {
    final primary = tonePrimary(tone);
    final secondary = toneSecondary(tone);
    return [
      Color.alphaBlend(primary.withOpacity(0.12), bgSecondary),
      Color.alphaBlend(secondary.withOpacity(0.06), bgPrimary),
      bgDeep,
    ];
  }

  static BoxDecoration panel({
    AppTone tone = AppTone.neutral,
    double radius = 18,
    bool elevated = false,
    bool subtle = false,
  }) {
    final primary = tonePrimary(tone);
    final secondary = toneSecondary(tone);
    final top = Color.alphaBlend(primary.withOpacity(subtle ? 0.04 : 0.12), surfaceSecondary);
    final bottom = Color.alphaBlend(secondary.withOpacity(subtle ? 0.02 : 0.08), surfaceElevated);
    final border = Color.alphaBlend(primary.withOpacity(subtle ? 0.08 : 0.18), borderSoft);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [top, bottom],
      ),
      border: Border.all(color: border),
      boxShadow: [
        BoxShadow(
          color: primary.withOpacity(elevated ? 0.14 : 0.08),
          blurRadius: elevated ? 24 : 18,
          offset: Offset(0, elevated ? 14 : 8),
        ),
        BoxShadow(
          color: Colors.black.withOpacity(0.22),
          blurRadius: elevated ? 28 : 18,
          offset: Offset(0, elevated ? 18 : 10),
        ),
      ],
    );
  }

  static BoxDecoration glassPanel({
    AppTone tone = AppTone.neutral,
    double radius = 18,
    double opacity = 1,
  }) {
    final primary = tonePrimary(tone);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: surfaceSecondary.withOpacity(0.92 * opacity),
      border: Border.all(color: primary.withOpacity(0.14)),
      boxShadow: [
        BoxShadow(
          color: primary.withOpacity(0.08 * opacity),
          blurRadius: 20,
          offset: const Offset(0, 10),
        ),
      ],
    );
  }

  static BoxDecoration glowCircle({
    required AppTone tone,
    double radius = 22,
  }) {
    final primary = tonePrimary(tone);
    final secondary = toneSecondary(tone);
    return BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [primary.withOpacity(0.22), secondary.withOpacity(0.18)],
      ),
      border: Border.all(color: primary.withOpacity(0.24)),
      boxShadow: [
        BoxShadow(
          color: primary.withOpacity(0.18),
          blurRadius: radius,
          offset: const Offset(0, 12),
        ),
      ],
    );
  }

  static Color readableText(Color baseColor) {
    return ThemeData.estimateBrightnessForColor(baseColor) == Brightness.dark ? textPrimary : bgPrimary;
  }
}
