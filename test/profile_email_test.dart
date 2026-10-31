import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/core/utils/validators.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

Future<DemoAppBackend> _openEditProfile(WidgetTester tester, String phone, {Size size = const Size(390, 844)}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = size * 3;
  tester.view.viewPadding = const FakeViewPadding(bottom: 48 * 3);
  tester.view.padding = const FakeViewPadding(bottom: 48 * 3);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
  await loginWithPhone(tester, phone);
  GoRouter.of(tester.element(find.byType(Scaffold).first)).push(Routes.editProfile);
  await tester.pumpAndSettle();
  expect(find.text('Información personal'), findsOneWidget);
  return backend;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String _rowText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byKey(const Key('profile-email')), matching: find.byType(Text)))
    .map((t) => t.data)
    .join(' | ');

void main() {
  group('Correo opcional en Información personal', () {
    // Las tres clases de cuenta usan la misma pantalla.
    const accounts = {
      'cliente': DemoBackend.customerPhone,
      'profesional': DemoBackend.professionalPhone,
      'administrador': DemoBackend.adminPhone,
    };
    for (final a in accounts.entries) {
      testWidgets('${a.key}: agregar, confirmar, cambiar y quitar el correo', (tester) async {
        final backend = await _openEditProfile(tester, a.value);
        // Empezar sin correo, como las cuentas que entran con el celular.
        if ((await backend.myAccount()).email.isNotEmpty) {
          await backend.removeEmail();
          GoRouter.of(tester.element(find.byType(Scaffold).first)).pop();
          await tester.pumpAndSettle();
          GoRouter.of(tester.element(find.byType(Scaffold).first)).push(Routes.editProfile);
          await tester.pumpAndSettle();
        }
        expect(_rowText(tester), contains('Sin correo'));

        // Tocar la fila (no solo el botón) abre el formulario con el teclado.
        await _tap(tester, find.text('Sin correo'));
        final field = find.byKey(const Key('email-field'));
        expect(field, findsOneWidget);
        expect(
          tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).autofocus,
          isTrue,
        );
        expect(
          tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).keyboardType,
          TextInputType.emailAddress,
        );

        // Formato con mensajes claros.
        await tester.enterText(field, 'carla correo.bo');
        await _tap(tester, find.byKey(const Key('email-send')));
        expect(find.text('Escribe el correo sin espacios'), findsOneWidget);
        await tester.enterText(field, 'carlacorreo.bo');
        await _tap(tester, find.byKey(const Key('email-send')));
        expect(find.text('Al correo le falta la @, por ejemplo nombre@correo.com'), findsOneWidget);
        await tester.enterText(field, 'carla@correo');
        await _tap(tester, find.byKey(const Key('email-send')));
        expect(find.text('Revisa tu correo, parece incompleto'), findsOneWidget);

        // Enviar con la tecla "Listo" del teclado también funciona.
        await tester.enterText(field, '  Carla.${a.key}@Correo.bo ');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        final email = 'carla.${a.key}@correo.bo';
        expect(find.byKey(const Key('email-code-field')), findsOneWidget);
        expect((await backend.myAccount()).email, isEmpty, reason: 'sin el código, el correo no queda en la cuenta');
        expect((await backend.myAccount()).emailPending, email);

        // Código incorrecto: no se guarda.
        await tester.enterText(find.byKey(const Key('email-code-field')), '999999');
        await tester.pumpAndSettle();
        expect((await backend.myAccount()).email, isEmpty);
        await tester.enterText(find.byKey(const Key('email-code-field')), DemoBackend.demoCode);
        await tester.pumpAndSettle();
        // Al completar los 6 números se confirma solo.
        expect(find.byKey(const Key('email-field')), findsNothing, reason: 'la hoja se cierra');
        expect(_rowText(tester), contains(email), reason: 'se ve enseguida');
        expect((await backend.myAccount()).emailConfirmed, isTrue);

        // Cambiar: el mismo correo no hace nada; otro pide código otra vez.
        await _tap(tester, find.text('Cambiar').last);
        await _tap(tester, find.byKey(const Key('email-send')));
        expect(find.text('Ese ya es tu correo.'), findsOneWidget);

        // Quitar pide confirmación; "Volver" no quita nada.
        await _tap(tester, find.byKey(const Key('email-remove')));
        await _tap(tester, find.text('Volver'));
        expect((await backend.myAccount()).email, email);
        await _tap(tester, find.byKey(const Key('email-remove')));
        await _tap(tester, find.byKey(const Key('email-remove-confirm')));
        expect(_rowText(tester), contains('Sin correo'));
        final me = await backend.myAccount();
        expect(me.email, isEmpty);
        expect(me.phone, a.value, reason: 'se sigue entrando con el celular');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('pantalla chica con letra grande: el formulario y su botón se ven', (tester) async {
      await _openEditProfile(tester, DemoBackend.customerPhone, size: const Size(320, 568));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('profile-email')));
      final send = find.byKey(const Key('email-send'));
      await tester.ensureVisible(send);
      await tester.pumpAndSettle();
      expect(tester.getRect(send).bottom, lessThanOrEqualTo(568 - 48));
      expect(tester.takeException(), isNull);
    });
  });

  test('validación del correo', () {
    expect(Validators.email('ana@correo.bo'), isNull);
    expect(Validators.email(''), 'Escribe tu correo electrónico');
    expect(Validators.email('a b@c.bo'), 'Escribe el correo sin espacios');
    expect(Validators.email('${'a' * 250}@c.bo'), 'Ese correo es demasiado largo');
  });

  test('errores de Supabase Auth al enviar el correo, en español', () {
    expect(
      AppError.from('AuthApiException(message: Error sending email change email, statusCode: 500)').code,
      'HMY_EMAIL_UNAVAILABLE',
    );
    expect(AppError.from('AuthApiException(code: email_address_not_authorized)').code, 'HMY_EMAIL_UNAVAILABLE');
    expect(AppError.from('AuthApiException(code: over_email_send_rate_limit)').code, 'HMY_EMAIL_UNAVAILABLE');
    expect(AppError.from('Unable to validate email address: invalid format').code, 'HMY_INVALID_EMAIL');
    expect(AppError.from('A user with this email address has already been registered').code, 'email_exists');
  });

  test('quitar el correo sin celular no deja la cuenta sin forma de entrar', () async {
    final backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    await backend.signInAs(DemoBackend.customerPhone);
    await backend.requestEmailChange('nuevo@correo.bo');
    expect((await backend.myAccount()).emailPending, 'nuevo@correo.bo');
    await backend.removeEmail();
    expect((await backend.myAccount()).emailPending, isNull, reason: 'quitar cancela el pendiente');
  });
}
