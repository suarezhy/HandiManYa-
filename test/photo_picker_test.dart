import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/features/common/photo_picker.dart';

// PNG de 1x1 píxel.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
);

Future<List<PhotoUpload>> _pump(WidgetTester tester, List<PhotoUpload> initial, {double scale = 1.3}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var photos = initial;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(320, 568), textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              padding: const EdgeInsets.all(16),
              children: [PhotoPickerRow(photos: photos, onChanged: (p) => setState(() => photos = p))],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return photos;
}

void main() {
  final five = [for (var i = 0; i < 5; i++) PhotoUpload(bytes: _png, fileName: 'f$i.png')];

  testWidgets('fotos en 320x568 con texto x1.3: se ven, se amplían y se quitan', (tester) async {
    await _pump(tester, five.take(2).toList());
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('photo-add')), findsOneWidget);

    // El botón de quitar está completo dentro de la caja de la foto, para que reciba el toque.
    final box = tester.getRect(find.byKey(const Key('photo-0')));
    final remove = tester.getRect(find.byKey(const Key('photo-remove-0')));
    expect(box.contains(remove.topLeft) && box.contains(remove.bottomRight - const Offset(0.1, 0.1)), isTrue);
    expect(remove.width, greaterThanOrEqualTo(36));

    // Vista previa.
    await tester.tap(find.bySemanticsLabel('Ver foto 1'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-preview-close')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    // Quitar.
    await tester.tap(find.byKey(const Key('photo-remove-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-1')), findsNothing);
    expect(find.byKey(const Key('photo-0')), findsOneWidget);
  });

  testWidgets('con 5 fotos ya no ofrece agregar y nada se desborda', (tester) async {
    await _pump(tester, five, scale: 1.6);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('photo-add')), findsNothing);
    for (var i = 0; i < 5; i++) {
      final r = tester.getRect(find.byKey(Key('photo-$i')));
      expect(r.right, lessThanOrEqualTo(320 - 16));
    }
  });
}
