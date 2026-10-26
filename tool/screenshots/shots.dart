// Capturas para revisar a ojo (no son pruebas). Se corren a mano:
//   HMY_SHOTS=/ruta/salida flutter test tool/screenshots/home_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String get shotsDir => Platform.environment['HMY_SHOTS'] ?? '';

Future<void> loadShotFonts() async {
  final loader = FontLoader('Nunito');
  for (final w in [400, 600, 700, 800, 900]) {
    loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/Nunito-$w.ttf').readAsBytesSync())));
  }
  await loader.load();
  final icons = FontLoader('MaterialIcons');
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter-sdk/flutter';
  final font = File('$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (font.existsSync()) {
    icons.addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
    await icons.load();
  }
}

/// Guarda la pantalla actual como `<shotsDir>/<name>.png` (a la mitad de la
/// resolución física, para que pese poco).
Future<void> shot(WidgetTester tester, String name) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  
  await tester.runAsync(() async {
    final image = await layer.toImage(Offset.zero & tester.view.physicalSize, pixelRatio: 0.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$shotsDir/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
