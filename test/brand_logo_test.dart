import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/widgets/brand_logo.dart';

/// "HandiMan" y "¡Ya!" juntos, como una sola marca, sin cambiar letra, colores
/// ni signos. En el teléfono la separación con un espacio normal se veía
/// demasiado grande.
void main() {
  Text wordmark(WidgetTester tester) =>
      tester.widgetList<Text>(find.byType(Text)).firstWhere((t) => t.textSpan?.toPlainText().contains('¡Ya!') ?? false);

  for (final (name, size) in const [
    ('Galaxy A15', Size(384, 832)),
    ('Galaxy S24', Size(360, 780)),
    ('iPhone SE', Size(320, 568)),
    ('iPhone 15', Size(393, 852)),
  ]) {
    testWidgets('marca en la pantalla de inicio: $name', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = size * 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: BrandLogo(height: 56))),
        ),
      );
      final text = wordmark(tester);
      final span = text.textSpan! as TextSpan;
      final parts = span.children!;
      // Las mismas palabras y signos, sin espacio entre ellas.
      expect((parts.first as TextSpan).text, 'HandiMan');
      expect((parts.last as TextSpan).text, '¡Ya!');
      expect(span.toPlainText().contains('HandiMan '), isFalse);
      // La separación es menor que un espacio normal (~0,25 de la letra).
      final gap = (parts[1] as WidgetSpan).child as SizedBox;
      final fontSize = text.style!.fontSize!;
      expect(gap.width! / fontSize, BrandLogo.wordGap);
      expect(BrandLogo.wordGap, lessThan(0.2));
      // Colores y peso de siempre; el lector de pantalla oye la marca entera.
      expect((parts.last as TextSpan).style!.color, isNot((parts.first as TextSpan).style!.color));
      expect(text.style!.fontWeight, FontWeight.w900);
      expect(find.bySemanticsLabel('HandiMan ¡Ya!'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
