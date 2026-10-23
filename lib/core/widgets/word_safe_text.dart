import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Texto que corta líneas solo entre palabras: si la palabra más larga no
/// entra en el ancho disponible (pantalla chica o letra grande del teléfono),
/// se achica la letra lo justo para que entre, en vez de partirla
/// ("Profesiona / les"). Nunca se corta con "…": la altura crece.
class WordSafeText extends StatelessWidget {
  const WordSafeText(this.text, {super.key, this.style, this.textAlign, this.minScale = 0.7});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// Lo más que se achica (0,7 = 70 % del tamaño original).
  final double minScale;

  /// Ancho de la palabra más larga de [text] con [style].
  static double longestWord(String text, TextStyle style, TextScaler scaler) {
    var widest = 0.0;
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final p = TextPainter(
        text: TextSpan(text: word, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, p.width);
      p.dispose();
    }
    return widest;
  }

  /// El estilo con la letra achicada para que la palabra más larga entre en [maxWidth].
  static TextStyle fit(String text, TextStyle style, TextScaler scaler, double maxWidth, {double minScale = 0.7}) {
    if (!maxWidth.isFinite || maxWidth <= 0) return style;
    final widest = longestWord(text, style, scaler);
    if (widest <= maxWidth) return style;
    final size = style.fontSize ?? 14;
    // Un poco de margen: el ancho medido y el dibujado pueden diferir en décimas.
    final factor = math.max(minScale, (maxWidth - 0.5) / widest);
    return style.copyWith(fontSize: (size * factor * 2).floorToDouble() / 2);
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) => Text(
        text,
        textAlign: textAlign,
        softWrap: true,
        style: fit(text, base, scaler, box.maxWidth, minScale: minScale),
      ),
    );
  }
}
