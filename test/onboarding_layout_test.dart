import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/data/providers.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pantallas de Android y iPhone (puntos lógicos) y una tablet.
const sizes = <String, Size>{
  'iPhone SE 1 (320x568)': Size(320, 568),
  'Android chico (360x640)': Size(360, 640),
  'iPhone 8 / SE (375x667)': Size(375, 667),
  'iPhone 14 (390x844)': Size(390, 844),
  'Android grande (412x915)': Size(412, 915),
  'Tablet (800x1280)': Size(800, 1280),
};

const slides = [
  (
    image: 'assets/images/onboarding_1.jpg',
    title: 'Profesionales de confianza cerca de ti',
    body: 'Plomeros, electricistas, albañiles, limpieza y mucho más en toda Bolivia. Todos verificados.',
  ),
  (
    image: 'assets/images/onboarding_2.jpg',
    title: '¿Lo necesitas ahora? Pídelo ¡Ya!',
    body:
        'Toca "Lo necesito ahora", cuéntanos qué pasó y avisamos al instante a los profesionales disponibles '
        'más cerca de ti.',
  ),
  (
    image: 'assets/images/onboarding_3.jpg',
    title: 'Conversa y coordina desde la app',
    body: 'Chatea con el profesional, recibe su cotización y sigue el estado de tu solicitud en todo momento.',
  ),
  (
    image: 'assets/images/onboarding_4.jpg',
    title: 'Trabajo bien hecho, con tranquilidad',
    body:
        'Pagas directo al profesional en efectivo o QR cuando termina, y calificas su trabajo para ayudar a '
        'otros.',
  ),
];

/// Ancho y alto de un JPEG, leídos del encabezado SOF.
Size jpegSize(String path) {
  final b = File(path).readAsBytesSync();
  var i = 2;
  while (i < b.length) {
    final marker = b[i + 1];
    final len = (b[i + 2] << 8) | b[i + 3];
    if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return Size(w.toDouble(), h.toDouble());
    }
    i += 2 + len;
  }
  throw StateError('sin SOF: $path');
}

Future<void> pumpOnboarding(WidgetTester tester, Size size, double textScale) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// La letra real de la app (Nunito): con la letra de prueba de Flutter, que
/// es más ancha, las medidas no se parecen a un teléfono.
Future<void> loadAppFonts() async {
  final loader = FontLoader('Nunito');
  for (final w in [400, 600, 700, 800, 900]) {
    loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/Nunito-$w.ttf').readAsBytesSync())));
  }
  await loader.load();
}

bool inside(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;

void main() {
  setUpAll(loadAppFonts);

  test('cada foto declara la forma real de su archivo (no se estira)', () {
    // Las proporciones que usa onboarding_page.dart.
    const declared = [720 / 790, 518 / 570, 720 / 689, 720 / 1040];
    for (var i = 0; i < slides.length; i++) {
      final s = jpegSize(slides[i].image);
      expect(s.width / s.height, closeTo(declared[i], 0.001), reason: slides[i].image);
      expect(File(slides[i].image).lengthSync(), lessThan(300 * 1024), reason: '${slides[i].image} pesa demasiado');
    }
  });

  for (final scale in [1.0, 1.3, 2.0]) {
    for (final entry in sizes.entries) {
      testWidgets('bienvenida completa en ${entry.key}, letra x$scale', (tester) async {
        final screen = Offset.zero & entry.value;
        await pumpOnboarding(tester, entry.value, scale);
        // Con letra grande en el teléfono más chico la pantalla puede
        // desplazarse; en el resto todo cabe sin moverse.
        final mustFit = scale == 1.0 || (scale == 1.3 && entry.value.height >= 640);

        for (var i = 0; i < slides.length; i++) {
          final s = slides[i];
          expect(tester.takeException(), isNull);
          final page = tester.getRect(find.byType(PageView));
          final image = find.byKey(ValueKey('onboarding-image-${s.image}'));
          final title = find.text(s.title);
          final body = find.text(s.body);
          final dots = find.byKey(const Key('onboarding-dots'));
          final next = find.byKey(const Key('onboarding-next'));
          expect(image, findsOneWidget);
          expect(title, findsOneWidget);
          expect(body, findsOneWidget);
          expect(find.text(i == slides.length - 1 ? 'Empezar' : 'Continuar'), findsOneWidget);
          if (i < slides.length - 1) expect(find.text('Omitir'), findsOneWidget);

          // Puntos y botón: siempre a la vista, sin desplazar.
          expect(inside(screen, tester.getRect(dots)), isTrue, reason: 'puntos, paso ${i + 1}');
          expect(inside(screen, tester.getRect(next)), isTrue, reason: 'botón, paso ${i + 1}');
          expect(tester.getRect(next).height, greaterThanOrEqualTo(48));

          // La foto conserva su forma (sin estirar).
          final img = tester.getRect(image);
          final file = jpegSize(s.image);
          expect(img.width / img.height, closeTo(file.width / file.height, 0.01), reason: s.image);

          if (mustFit) {
            for (final (name, f) in [('foto', image), ('título', title), ('texto', body)]) {
              expect(
                inside(page, tester.getRect(f)),
                isTrue,
                reason: '$name, paso ${i + 1}: ${tester.getRect(f)} / $page',
              );
            }
            expect(img.height, greaterThanOrEqualTo(scale == 1.0 ? 140 : 110), reason: 'foto muy chica, paso ${i + 1}');
          } else {
            // Todo se alcanza desplazando: el final del texto entra en la
            // pantalla y la foto sigue con un tamaño útil.
            expect(img.height, greaterThanOrEqualTo(90));
            await tester.drag(find.byType(SingleChildScrollView).hitTestable().first, const Offset(0, -2000));
            await tester.pumpAndSettle();
            expect(inside(page, tester.getRect(body)), isTrue, reason: 'texto alcanzable, paso ${i + 1}');
          }

          if (i < slides.length - 1) {
            await tester.tap(next);
            await tester.pumpAndSettle();
          }
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Empezar'));
        await tester.pumpAndSettle();
        expect(find.text('Bienvenido a HandiMan ¡Ya!'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
