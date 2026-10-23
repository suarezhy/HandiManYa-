import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Las pruebas de Flutter dibujan con una letra de cuadritos; cargamos Nunito
/// (la letra real de la app) para medir los textos como en el teléfono.
Future<void> loadAppFonts(WidgetTester tester) => tester.runAsync(() async {
  final loader = FontLoader('Nunito');
  for (final w in [400, 600, 700, 800, 900]) {
    loader.addFont(rootBundle.load('assets/fonts/Nunito-$w.ttf'));
  }
  await loader.load();
});

bool _isLetter(String c) => RegExp(r'[A-Za-zÁÉÍÓÚÜÑáéíóúüñ0-9]').hasMatch(c);

/// Palabras partidas entre dos líneas ("Profesiona / les") en un párrafo.
List<String> brokenWords(RenderParagraph p) {
  final text = p.text.toPlainText();
  if (text.contains('￼') || !p.hasSize || p.size.height <= 0) return const [];
  final broken = <String>[];
  double? lastTop;
  for (var i = 0; i < text.length; i++) {
    final boxes = p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
    if (boxes.isEmpty) continue;
    final top = boxes.first.top;
    if (lastTop != null && (top - lastTop).abs() > 1 && _isLetter(text[i - 1]) && _isLetter(text[i])) {
      final start = text.lastIndexOf(RegExp(r'\s'), i - 1) + 1;
      final end = text.indexOf(RegExp(r'\s'), i);
      broken.add('${text.substring(start, i)}|${text.substring(i, end < 0 ? text.length : end)}');
    }
    lastTop = top;
  }
  return broken;
}

/// Dentro de una pestaña que no se ve (las otras pestañas siguen armadas, ocultas).
bool _hidden(RenderObject o) {
  for (RenderObject? r = o.parent; r != null; r = r.parent) {
    if (r is RenderOffstage && r.offstage) return true;
    if (r is RenderSliverOffstage && r.offstage) return true;
  }
  return false;
}

/// Todos los textos visibles en pantalla con una palabra partida o cortados
/// con "…" (cuando no son de una sola línea a propósito).
List<String> textProblems(WidgetTester tester, Size screen) {
  final problems = <String>[];
  for (final p in tester.allRenderObjects.whereType<RenderParagraph>()) {
    if (!p.attached || !p.hasSize || _hidden(p)) continue;
    final box = p.localToGlobal(Offset.zero) & p.size;
    // Solo lo que está en pantalla (las listas arman también lo de afuera).
    if (box.bottom < 0 || box.top > screen.height || box.right < 0 || box.left > screen.width) continue;
    for (final w in brokenWords(p)) {
      problems.add('palabra partida "$w" en "${p.text.toPlainText()}"');
    }
    if (p.didExceedMaxLines && p.maxLines != 1) {
      problems.add('texto cortado: "${p.text.toPlainText()}"');
    }
  }
  return problems;
}
