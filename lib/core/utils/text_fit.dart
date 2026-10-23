import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// El estilo con que [Text] dibuja de verdad: el de [context] más [style] y,
/// si el teléfono tiene "Fuente en negrita" (Samsung, Android), en negrita.
/// Medir sin la negrita hacía que las palabras se partieran (Issue #12, Dev-17).
TextStyle effectiveTextStyle(BuildContext context, TextStyle? style) {
  final base = DefaultTextStyle.of(context).style.merge(style);
  return MediaQuery.boldTextOf(context) ? base.merge(const TextStyle(fontWeight: FontWeight.bold)) : base;
}

/// Ancho de [text] en una sola línea, con la letra de [context] y sin escalar.
double textWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: effectiveTextStyle(context, style)),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    maxLines: 1,
  )..layout();
  final w = painter.width;
  painter.dispose();
  return w;
}

/// Escala de texto más grande (sin pasar la del usuario ni [max]) con la que
/// cada palabra de [texts] cabe entera en [width]. Así una palabra nunca se
/// parte en dos líneas ("Electricida-d"): si no cabe, la letra se achica un
/// poco en vez de cortarse.
double wordFitScale(
  BuildContext context, {
  required Iterable<String> texts,
  required TextStyle style,
  required double width,
  double max = double.infinity,
}) {
  final user = MediaQuery.textScalerOf(context).scale(100) / 100;
  var widest = 0.0;
  for (final t in texts) {
    for (final word in t.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      widest = math.max(widest, textWidth(context, word, style));
    }
  }
  final limit = math.min(user, max);
  if (widest <= 0 || width <= 0) return limit;
  return math.min(limit, width / widest);
}
