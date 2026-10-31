import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/onboarding/onboarding_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pantallas de Android y iPhone (puntos lógicos) y una tablet.
const sizes = <String, Size>{
  'iPhone SE 1 (320x568)': Size(320, 568),
  'Android chico (360x640)': Size(360, 640),
  // Samsung Galaxy A (720x1600 a 2,0) y Galaxy A/S (1080x2340 a 2,8125).
  'Samsung A chico (360x800)': Size(360, 800),
  'Samsung A/S (384x832)': Size(384, 832),
  'iPhone 8 / SE (375x667)': Size(375, 667),
  'iPhone 14 (390x844)': Size(390, 844),
  'Android grande (412x915)': Size(412, 915),
  'Tablet (800x1280)': Size(800, 1280),
};

const slides = [
  (
    image: 'assets/images/onboarding_1.jpg',
    title: 'Profesionales de confianza cerca de ti',
    body: 'Plomeros, electricistas, limpieza y más en toda Bolivia. Revisamos sus documentos antes de aprobarlos.',
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
    body: 'Chatea con el profesional, acuerden el precio antes de empezar y sigue tu solicitud en todo momento.',
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

Future<void> pumpOnboarding(
  WidgetTester tester,
  Size size,
  double textScale, {
  bool bold = false,
  bool android = false,
}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  // Barra de estado y, en Android, la barra de navegación (24 y 48 puntos).
  tester.view.padding = android
      ? const FakeViewPadding(top: 24 * 3, bottom: 48 * 3)
      : const FakeViewPadding(top: 20 * 3);
  if (bold) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(boldText: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
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
    expect([for (final i in onboardingImages) i.$1], [for (final s in slides) s.image]);
    for (final (path, ratio) in onboardingImages) {
      final s = jpegSize(path);
      expect(s.width / s.height, closeTo(ratio, 0.001), reason: path);
      expect(File(path).lengthSync(), lessThan(300 * 1024), reason: '$path pesa demasiado');
      // Casi cuadradas: al llenar el marco cuadrado se pierde poco y nunca las caras.
      expect(ratio, inInclusiveRange(0.85, 1.1), reason: '$path se recortaría demasiado');
    }
  });

  test('los cuatro pasos usan cuatro fotos distintas, incluidas en la app', () {
    final paths = [for (final i in onboardingImages) i.$1];
    expect(paths, hasLength(4));
    expect(paths.toSet(), hasLength(4), reason: 'dos pasos apuntan al mismo archivo');
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final p in paths) {
      expect(File(p).existsSync(), isTrue, reason: p);
      expect(pubspec.contains('- ${p.substring(0, p.lastIndexOf('/') + 1)}'), isTrue, reason: '$p no se empaqueta');
    }
    final bytes = [for (final p in paths) File(p).readAsBytesSync()];
    for (var a = 0; a < 4; a++) {
      for (var b = a + 1; b < 4; b++) {
        expect(listEquals(bytes[a], bytes[b]), isFalse, reason: '${paths[a]} y ${paths[b]} son el mismo archivo');
      }
    }
    // Dos recortes de una misma foto pasan esta prueba: eso se revisa a ojo
    // (docs/LESSONS.md, "Bienvenida").
  });

  for (final (scale, bold) in [(1.0, false), (1.0, true), (1.3, false), (1.3, true), (2.0, false)]) {
    for (final entry in sizes.entries) {
      testWidgets('bienvenida completa en ${entry.key}, letra x$scale${bold ? ' en negrita' : ''}', (tester) async {
        final screen = Offset.zero & entry.value;
        await pumpOnboarding(tester, entry.value, scale, bold: bold, android: entry.key.startsWith('Samsung'));
        Rect? firstFrame;
        // Con letra grande en el teléfono más chico la pantalla puede
        // desplazarse; en el resto todo cabe sin moverse.
        final mustFit = scale == 1.0 || (scale == 1.3 && entry.value.height >= 800);

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

          // Mismo marco cuadrado en los cuatro pasos; las cuatro fotos lo
          // llenan igual (cover, sin franjas) y sin estirar.
          final img = tester.getRect(image);
          expect(img.width, closeTo(img.height, 0.5), reason: 'marco cuadrado, paso ${i + 1}');
          firstFrame ??= img;
          expect(
            img.size.width,
            closeTo(firstFrame.size.width, 0.5),
            reason: 'mismo tamaño que el paso 1, paso ${i + 1}',
          );
          final picture = tester.widget<Image>(find.descendant(of: image, matching: find.byType(Image)));
          expect(picture.fit, BoxFit.cover, reason: s.image);

          if (mustFit) {
            for (final (name, f) in [('foto', image), ('título', title), ('texto', body)]) {
              expect(
                inside(page, tester.getRect(f)),
                isTrue,
                reason: '$name, paso ${i + 1}: ${tester.getRect(f)} / $page',
              );
            }
            expect(img.height, greaterThanOrEqualTo(scale == 1.0 ? 130 : 110), reason: 'foto muy chica, paso ${i + 1}');
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
