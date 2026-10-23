import 'package:flutter/material.dart';

/// Tokens de diseño de HandiMan ¡Ya!. Toda la interfaz toma de aquí sus
/// colores, espacios, radios y tipografía.
abstract final class HyColors {
  // Colores de marca tomados del logo de HandiManYa.
  /// Azul marino: textos fuertes, encabezados y superficies oscuras.
  static const navy = Color(0xFF02173A);
  static const navySoft = Color(0xFF1B2B4F);

  /// Naranja "¡Ya!": acciones principales. Las etiquetas sobre este color
  /// van en negrita de 18 px o más (contraste AA para texto grande).
  static const primary = Color(0xFFF25500);
  static const primaryDark = Color(0xFFB33F00);
  static const primarySoft = Color(0xFFFFEFE5);
  static const onPrimary = Color(0xFFFFFFFF);

  /// Verde: verificación, confianza y estados positivos.
  static const green = Color(0xFF57A909);
  static const greenDark = Color(0xFF3B7405);
  static const greenSoft = Color(0xFFEEF7E4);

  static const background = Color(0xFFF7F8FA);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFEFF1F5);
  static const border = Color(0xFFDDE1E8);

  static const text = navy;
  static const textSecondary = Color(0xFF4A5468);
  static const textMuted = Color(0xFF6B7488);

  static const success = greenDark;
  static const successSoft = greenSoft;
  static const warning = Color(0xFF8A5A00);
  static const warningSoft = Color(0xFFFFF4D6);
  static const danger = Color(0xFFB3261E);
  static const dangerSoft = Color(0xFFFDECEA);
  static const info = Color(0xFF1F5FA8);
  static const infoSoft = Color(0xFFE7F0FB);

  static const star = Color(0xFFF2A516);
  static const verified = greenDark;
}

abstract final class HySpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;

  /// Margen lateral estándar de las páginas.
  static const page = 20.0;
}

abstract final class HyRadii {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const pill = 999.0;
}

abstract final class HySizes {
  /// Altura mínima de cualquier control táctil (más grande que el mínimo de
  /// 48 para que sea cómodo para personas mayores).
  static const touch = 52.0;
  static const buttonHeight = 56.0;
  static const iconTile = 56.0;
  static const maxContentWidth = 640.0;
}

abstract final class HyShadows {
  static const card = [BoxShadow(color: Color(0x0F000000), blurRadius: 12, offset: Offset(0, 4))];
  static const raised = [BoxShadow(color: Color(0x1A000000), blurRadius: 20, offset: Offset(0, 8))];
}
