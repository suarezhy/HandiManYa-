import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/data/providers.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'onboarding_layout_test.dart' show inside, loadAppFonts, sizes;

Future<void> pumpLogin(WidgetTester tester, Size size, double textScale) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true});
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

/// Abre el teclado (40 % de la pantalla, como en un Android chico).
Future<Rect> openKeyboard(WidgetTester tester, Finder field, Size size) async {
  await tester.showKeyboard(field);
  tester.view.viewInsets = FakeViewPadding(bottom: size.height * 3 * 0.4);
  await tester.pumpAndSettle();
  return Offset.zero & Size(size.width, size.height * 0.6);
}

Future<void> closeKeyboard(WidgetTester tester) async {
  tester.view.resetViewInsets();
  await tester.pumpAndSettle();
}

/// Se alcanza desplazando y, una vez a la vista, entra entero en la pantalla.
Future<void> expectReachable(WidgetTester tester, Finder f, Rect screen, String what) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  expect(inside(screen, tester.getRect(f)), isTrue, reason: '$what: ${tester.getRect(f)}');
}

void main() {
  setUpAll(loadAppFonts);

  for (final scale in [1.0, 1.3, 2.0]) {
    for (final entry in sizes.entries) {
      testWidgets('ingreso con celular en ${entry.key}, letra x$scale', (tester) async {
        final size = entry.value;
        final screen = Offset.zero & size;
        // Con el teclado abierto en el teléfono más chico y letra enorme no
        // caben campo y botón a la vez: manda el campo.
        final bothFitOverKeyboard = scale <= 1.3 || size.height >= 640;
        await pumpLogin(tester, size, scale);
        expect(tester.takeException(), isNull);

        final phone = find.byKey(const Key('phone-field'));
        final next = find.byKey(const Key('auth-continue'));
        final whatsapp = find.byKey(const Key('channel-whatsapp'));
        final sms = find.byKey(const Key('channel-sms'));

        // Paso 1: todo se ve entero (desplazando si hace falta).
        await expectReachable(tester, find.text('Bienvenido a HandiMan ¡Ya!'), screen, 'título');
        await expectReachable(tester, phone, screen, 'celular');
        await expectReachable(tester, whatsapp, screen, 'WhatsApp');
        await expectReachable(tester, next, screen, 'Continuar');
        await expectReachable(tester, find.text('¿Ya no tienes tu número? Recupera tu cuenta'), screen, 'recuperar');
        expect(tester.getRect(next).height, greaterThanOrEqualTo(48));
        // "WhatsApp" en un solo renglón, igual que "SMS".
        expect(tester.getSize(whatsapp).height, closeTo(tester.getSize(sms).height, 1), reason: 'WhatsApp partido');
        expect(tester.takeException(), isNull);

        // Con el teclado abierto: el campo y "Continuar" quedan encima.
        var visible = await openKeyboard(tester, phone, size);
        expect(inside(visible, tester.getRect(phone)), isTrue, reason: 'celular tapado: ${tester.getRect(phone)}');
        if (bothFitOverKeyboard) {
          expect(inside(visible, tester.getRect(next)), isTrue, reason: 'Continuar tapado: ${tester.getRect(next)}');
        }
        expect(tester.takeException(), isNull);
        await closeKeyboard(tester);

        // Paso 2: el código.
        await tester.enterText(phone, '71234567');
        await tester.ensureVisible(next);
        await tester.pumpAndSettle();
        await tester.tap(next);
        await tester.pumpAndSettle();
        expect(find.text('Escribe el código'), findsOneWidget);
        final code = find.byKey(const Key('code-field'));
        visible = await openKeyboard(tester, code, size);
        expect(inside(visible, tester.getRect(code)), isTrue, reason: 'código tapado: ${tester.getRect(code)}');
        if (bothFitOverKeyboard) {
          expect(inside(visible, tester.getRect(next)), isTrue, reason: 'Continuar tapado: ${tester.getRect(next)}');
        }
        await closeKeyboard(tester);
        await expectReachable(tester, find.byKey(const Key('code-resend')), screen, 'reenviar');
        await expectReachable(tester, find.byKey(const Key('code-other-channel')), screen, 'otro canal');
        await expectReachable(tester, find.text('Cambiar número'), screen, 'cambiar número');
        expect(tester.takeException(), isNull);

        // Recuperar la cuenta.
        await tester.tap(find.text('Cambiar número'));
        await tester.pumpAndSettle();
        final recover = find.text('¿Ya no tienes tu número? Recupera tu cuenta');
        await tester.ensureVisible(recover);
        await tester.pumpAndSettle();
        await tester.tap(recover);
        await tester.pumpAndSettle();
        expect(find.text('Recupera tu cuenta'), findsOneWidget);
        final email = find.byKey(const Key('recover-email'));
        visible = await openKeyboard(tester, email, size);
        expect(inside(visible, tester.getRect(email)), isTrue, reason: 'correo tapado');
        final recoverNext = find.widgetWithText(FilledButton, 'Continuar');
        if (bothFitOverKeyboard) {
          expect(inside(visible, tester.getRect(recoverNext)), isTrue, reason: 'Continuar tapado (recuperar)');
        }
        await closeKeyboard(tester);
        await expectReachable(tester, recoverNext, screen, 'Continuar (recuperar)');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
