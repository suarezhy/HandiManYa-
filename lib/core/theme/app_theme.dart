import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'tokens.dart';

abstract final class AppTheme {
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: HyColors.primary,
      primary: HyColors.primary,
      onPrimary: HyColors.onPrimary,
      surface: HyColors.surface,
      onSurface: HyColors.text,
      error: HyColors.danger,
    );

    const base = TextTheme(
      displaySmall: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, height: 1.15, letterSpacing: -0.5),
      headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.2, letterSpacing: -0.3),
      headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, height: 1.3),
      titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.3),
      titleSmall: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3),
      bodyLarge: TextStyle(fontSize: 17, height: 1.45),
      bodyMedium: TextStyle(fontSize: 16, height: 1.45),
      bodySmall: TextStyle(fontSize: 14, height: 1.4),
      labelLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      labelMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
    final text = base.apply(fontFamily: 'Nunito', bodyColor: HyColors.text, displayColor: HyColors.text);

    final roundedMd = RoundedRectangleBorder(borderRadius: BorderRadius.circular(HyRadii.md));

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Nunito',
      colorScheme: scheme,
      scaffoldBackgroundColor: HyColors.background,
      textTheme: text,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      // Atrás con gesto: en iOS se desliza desde el borde izquierdo; en
      // Android el gesto atrás predictivo muestra la pantalla anterior
      // (android:enableOnBackInvokedCallback en AndroidManifest.xml).
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: HyColors.background,
        foregroundColor: HyColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: HyColors.primary,
          foregroundColor: HyColors.onPrimary,
          disabledBackgroundColor: HyColors.border,
          minimumSize: const Size(64, HySizes.buttonHeight),
          padding: const EdgeInsets.symmetric(horizontal: HySpacing.xl),
          textStyle: text.labelLarge,
          shape: roundedMd,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: HyColors.text,
          minimumSize: const Size(64, HySizes.buttonHeight),
          padding: const EdgeInsets.symmetric(horizontal: HySpacing.xl),
          side: const BorderSide(color: HyColors.border, width: 1.5),
          textStyle: text.labelLarge,
          shape: roundedMd,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: HyColors.primaryDark,
          minimumSize: const Size(48, HySizes.touch),
          textStyle: text.labelLarge,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: HyColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: 18),
        labelStyle: const TextStyle(color: HyColors.textSecondary, fontSize: 16),
        floatingLabelStyle: const TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w600),
        hintStyle: const TextStyle(color: HyColors.textMuted, fontSize: 16),
        errorStyle: const TextStyle(fontSize: 14, color: HyColors.danger),
        errorMaxLines: 3,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HyRadii.md),
          borderSide: const BorderSide(color: HyColors.border, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HyRadii.md),
          borderSide: const BorderSide(color: HyColors.border, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HyRadii.md),
          borderSide: const BorderSide(color: HyColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HyRadii.md),
          borderSide: const BorderSide(color: HyColors.danger, width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        color: HyColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HyRadii.lg),
          side: const BorderSide(color: HyColors.border),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: HyColors.surface,
        selectedColor: HyColors.primarySoft,
        side: const BorderSide(color: HyColors.border),
        labelStyle: text.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: HySpacing.xs),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HyRadii.pill)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: HyColors.surface,
        indicatorColor: HyColors.greenSoft,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 13,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? HyColors.navy : HyColors.textSecondary,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 26,
            color: states.contains(WidgetState.selected) ? HyColors.navy : HyColors.textSecondary,
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(color: HyColors.border, thickness: 1, space: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: HyColors.text,
        contentTextStyle: const TextStyle(fontSize: 16, color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HyRadii.md)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: HyColors.surface,
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(HyRadii.xl))),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : HyColors.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? HyColors.success : HyColors.surfaceMuted,
        ),
      ),
    );
  }
}
