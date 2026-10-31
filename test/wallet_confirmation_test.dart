import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/core/utils/formatters.dart';
import 'package:handimanya/core/widgets/common.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/models/wallet.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/pro_mode/wallet_page.dart';
import 'package:handimanya/features/security/confirm_identity.dart';
import 'package:handimanya/features/security/security_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Biometría simulada: devuelve los resultados en orden y cuenta las llamadas.
class _FakeDeviceAuth implements DeviceAuth {
  _FakeDeviceAuth({this.types = const {DeviceBiometric.fingerprint}, List<DeviceAuthResult>? results})
    : results = results ?? [];

  final Set<DeviceBiometric> types;
  final List<DeviceAuthResult> results;
  int calls = 0;

  @override
  Future<Set<DeviceBiometric>> available() async => types;

  @override
  Future<DeviceAuthResult> authenticate(String reason) async {
    calls++;
    return results.isEmpty ? DeviceAuthResult.success : results.removeAt(0);
  }
}

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

Future<({DemoAppBackend backend, SharedPreferences prefs})> _pump(
  WidgetTester tester,
  Widget page, {
  required DeviceAuth deviceAuth,
  bool biometricOn = false,
}) async {
  await initializeDateFormatting('es');
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  await backend.signInAs(DemoBackend.professionalPhone);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  if (biometricOn) {
    await backend.confirmWithCode();
    await backend.setBiometricEnabled(true);
    await prefs.setBool(biometricPrefKey(backend.currentUser!.id), true);
  }
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        backendProvider.overrideWithValue(backend),
        deviceAuthProvider.overrideWithValue(deviceAuth),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('es', 'BO'),
        supportedLocales: const [Locale('es', 'BO')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (backend: backend, prefs: prefs);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// "Enviarme el código" y luego las 6 cifras (se envía sola al completarlas).
Future<void> _confirmWithCode(WidgetTester tester, {String code = DemoBackend.demoCode}) async {
  await _tap(tester, find.byKey(const Key('confirm-submit')));
  expect(find.byKey(const Key('confirm-code-field')), findsOneWidget);
  await tester.enterText(find.byKey(const Key('confirm-code-field')), code);
  await tester.pumpAndSettle();
}

/// Recargar saldo → Transferencia bancaria.
Future<void> _openTransfer(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('wallet-recharge')));
  await _tap(tester, find.byKey(const Key('recharge-transfer')));
}

/// Abre la transferencia bancaria, llena el formulario y toca Continuar.
Future<void> _startTopup(WidgetTester tester, {String amount = '150'}) async {
  await _openTransfer(tester);
  await _tap(tester, find.text('QR (ejemplo)'));
  await tester.enterText(find.widgetWithText(TextFormField, 'Monto'), amount);
  await tester.enterText(find.widgetWithText(TextFormField, 'Número de comprobante (opcional)'), 'TX-77');
  await _tap(tester, find.byKey(const Key('topup-continue')));
}

Future<List<TopupRequest>> _pending(DemoAppBackend b) async =>
    (await b.topups()).where((t) => t.status == TopupStatus.pending).toList();

void main() {
  group('reglas de confirmación (demostración, igual que la base)', () {
    late DemoBackend backend;
    setUp(() async {
      backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
      await backend.signInAs(DemoBackend.professionalPhone);
    });
    tearDown(() => backend.dispose());

    Future<int> topup(String method, String key) =>
        backend.requestTopup(amount: 50, methodId: 1, authMethod: method, clientKey: key);

    test('el código recién verificado confirma una sola recarga; repetir el intento no duplica', () async {
      final before = (await backend.wallet()).available;
      final id = await topup('otp', 'k1');
      expect(await topup('otp', 'k1'), id, reason: 'mismo intento = misma solicitud');
      await expectLater(topup('otp', 'k2'), _code('HMY_CONFIRMATION_EXPIRED'));
      expect(await backend.topups(), hasLength(1));
      expect((await backend.wallet()).available, before, reason: 'pedir no acredita saldo');
    });

    test('sin confirmar no se crea la recarga', () async {
      await topup('otp', 'usado');
      await expectLater(topup('otp', 'a'), _code('HMY_CONFIRMATION_EXPIRED'));
      await expectLater(topup('biometric', 'a'), _code('HMY_BIOMETRIC_DISABLED'));
      await expectLater(topup('password', 'a'), _code('HMY_CONFIRMATION_REQUIRED'), reason: 'ya no hay contraseñas');
      await expectLater(topup('pin', 'a'), _code('HMY_CONFIRMATION_REQUIRED'));
      expect(await backend.topups(), hasLength(1));
    });

    test('código incorrecto: falla y no confirma', () async {
      await topup('otp', 'usado');
      await backend.sendPhoneCode(phone: DemoBackend.professionalPhone, channel: CodeChannel.sms);
      await expectLater(
        backend.verifyPhoneCode(phone: DemoBackend.professionalPhone, code: '000000'),
        _code('otp_invalid'),
      );
      await expectLater(topup('otp', 'a'), _code('HMY_CONFIRMATION_EXPIRED'));
    });

    test('huella o rostro: activar exige un código nuevo; desactivar, no', () async {
      await topup('otp', 'usado');
      await expectLater(backend.setBiometricEnabled(true), _code('HMY_CONFIRMATION_EXPIRED'));
      await backend.confirmWithCode();
      await backend.setBiometricEnabled(true);
      expect(await backend.biometricEnabled(), isTrue);
      await topup('biometric', 'b1');
      await backend.setBiometricEnabled(false);
      await expectLater(topup('biometric', 'b2'), _code('HMY_BIOMETRIC_DISABLED'));
      await backend.signInAs(DemoBackend.adminPhone);
      final audit = await backend.auditLog();
      expect(
        audit.where((e) => e.action == 'topup.request').map((e) => e.details['auth_method']),
        unorderedEquals(['otp', 'biometric']),
      );
      expect(audit.map((e) => e.action), containsAll(['security.biometric_on', 'security.biometric_off']));
    });
  });

  group('pantalla de recarga', () {
    testWidgets('con código: muestra el monto en Bs, envía y muestra el comprobante', (tester) async {
      final r = await _pump(tester, const WalletPage(), deviceAuth: _FakeDeviceAuth(types: const {}));
      final before = (await r.backend.wallet()).available;
      await _startTopup(tester);
      expect(find.text('Confirma que eres tú'), findsOneWidget);
      expect(find.byKey(const Key('confirm-amount')), findsOneWidget);
      expect(find.text(Fmt.bs(150)), findsOneWidget);
      expect(find.byKey(const Key('confirm-face')), findsNothing, reason: 'sin biometría solo hay código');
      expect(find.text('Código por celular'), findsOneWidget);
      expect(find.text('+591\u00A07654\u00A03210'), findsOneWidget);
      expect(await _pending(r.backend), isEmpty, reason: 'nada se envía antes de confirmar');

      await _confirmWithCode(tester);

      expect(find.byKey(const Key('topup-receipt')), findsOneWidget);
      expect(find.text('Pendiente de verificación'), findsOneWidget);
      expect(find.text('Código'), findsOneWidget);
      expect(find.text('TX-77'), findsOneWidget);
      final pending = await _pending(r.backend);
      expect(pending.single.amount, 150);
      expect((await r.backend.wallet()).available, before, reason: 'el saldo sube solo cuando el equipo aprueba');
      await _tap(tester, find.text('Listo'));
      expect(find.byKey(const Key('topup-receipt')), findsNothing);
    });

    testWidgets('código incorrecto: avisa y no envía nada', (tester) async {
      final r = await _pump(tester, const WalletPage(), deviceAuth: _FakeDeviceAuth(types: const {}));
      await _startTopup(tester);
      await _confirmWithCode(tester, code: '000000');
      expect(find.text('El código no es correcto. Revísalo y vuelve a intentar. No se envió nada.'), findsOneWidget);
      expect(find.byKey(const Key('topup-receipt')), findsNothing);
      expect(await r.backend.topups(), isEmpty);
    });

    testWidgets('cancelar la confirmación no envía nada', (tester) async {
      final r = await _pump(tester, const WalletPage(), deviceAuth: _FakeDeviceAuth(types: const {}));
      await _startTopup(tester);
      await _tap(tester, find.text('Cancelar'));
      expect(find.text('Confirma que eres tú'), findsNothing);
      expect(find.byKey(const Key('topup-receipt')), findsNothing);
      expect(await r.backend.topups(), isEmpty);
    });

    testWidgets('huella cancelada o fallida no envía; con huella correcta sí', (tester) async {
      final device = _FakeDeviceAuth(
        results: [DeviceAuthResult.canceled, DeviceAuthResult.failed, DeviceAuthResult.success],
      );
      final r = await _pump(tester, const WalletPage(), deviceAuth: device, biometricOn: true);
      await _startTopup(tester);
      expect(find.byKey(const Key('confirm-fingerprint')), findsOneWidget);
      expect(find.byKey(const Key('confirm-code-field')), findsNothing, reason: 'la huella viene elegida');

      await _tap(tester, find.byKey(const Key('confirm-submit')));
      expect(find.text('Cancelaste la confirmación. No se envió nada.'), findsOneWidget);
      expect(await r.backend.topups(), isEmpty);

      await _tap(tester, find.byKey(const Key('confirm-submit')));
      expect(find.text('No pudimos confirmar que eres tú. No se envió nada.'), findsOneWidget);
      expect(await r.backend.topups(), isEmpty);

      await _tap(tester, find.byKey(const Key('confirm-submit')));
      expect(find.byKey(const Key('topup-receipt')), findsOneWidget);
      expect(find.text('Huella digital'), findsOneWidget);
      expect(device.calls, 3, reason: 'cada intento pide la huella de nuevo');
      expect(await _pending(r.backend), hasLength(1));
    });

    testWidgets('huella bloqueada: pide usar un código, que también funciona', (tester) async {
      final r = await _pump(
        tester,
        const WalletPage(),
        deviceAuth: _FakeDeviceAuth(types: const {DeviceBiometric.face}, results: [DeviceAuthResult.lockedOut]),
        biometricOn: true,
      );
      await _startTopup(tester);
      await _tap(tester, find.byKey(const Key('confirm-submit')));
      expect(find.textContaining('Usa un código'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('confirm-code')));
      await _confirmWithCode(tester);
      expect(find.byKey(const Key('topup-receipt')), findsOneWidget);
      expect(await _pending(r.backend), hasLength(1));
    });

    testWidgets('toques repetidos crean una sola solicitud', (tester) async {
      final device = _FakeDeviceAuth();
      final r = await _pump(tester, const WalletPage(), deviceAuth: device, biometricOn: true);
      await _openTransfer(tester);
      await _tap(tester, find.text('QR (ejemplo)'));
      await tester.enterText(find.widgetWithText(TextFormField, 'Monto'), '80');
      final cont = find.byKey(const Key('topup-continue'));
      await tester.ensureVisible(cont);
      await tester.pumpAndSettle();
      await tester.tap(cont);
      await tester.tap(cont, warnIfMissed: false);
      await tester.tap(cont, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Confirma que eres tú'), findsOneWidget, reason: 'una sola pantalla de confirmación');

      final submit = find.byKey(const Key('confirm-submit'));
      await tester.tap(submit);
      await tester.tap(submit, warnIfMissed: false);
      await tester.tap(submit, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('topup-receipt')), findsOneWidget);
      expect(await _pending(r.backend), hasLength(1));
      expect(device.calls, 1);
    });
  });

  group('Perfil → Seguridad', () {
    testWidgets('activar pide un código y la huella; desactivar vuelve al código', (tester) async {
      final device = _FakeDeviceAuth();
      final r = await _pump(tester, const SecurityPage(), deviceAuth: device);
      final sw = find.byKey(const Key('biometric-switch'));
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);

      await _tap(tester, sw);
      expect(find.text('Confirma que eres tú'), findsOneWidget);
      expect(find.byKey(const Key('confirm-fingerprint')), findsNothing, reason: 'activar exige un código');
      await _confirmWithCode(tester);
      expect(device.calls, 1);
      expect(tester.widget<SwitchListTile>(sw).value, isTrue);
      expect(await r.backend.biometricEnabled(), isTrue);
      expect(r.prefs.getBool(biometricPrefKey(r.backend.currentUser!.id)), isTrue);

      await _tap(tester, sw);
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
      expect(await r.backend.biometricEnabled(), isFalse);
    });

    testWidgets('si la huella falla al activar, queda desactivada', (tester) async {
      final r = await _pump(
        tester,
        const SecurityPage(),
        deviceAuth: _FakeDeviceAuth(results: [DeviceAuthResult.canceled]),
      );
      await _tap(tester, find.byKey(const Key('biometric-switch')));
      await _confirmWithCode(tester);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('biometric-switch'))).value, isFalse);
      expect(await r.backend.biometricEnabled(), isFalse);
    });

    for (final (size, scale) in [
      (const Size(320, 568), 1.3),
      (const Size(360, 640), 1.0),
      (const Size(412, 915), 1.6),
    ]) {
      testWidgets('nota breve sin recuadro azul en ${size.width.toInt()}x${size.height.toInt()} texto x$scale', (
        tester,
      ) async {
        await _pump(tester, const SecurityPage(), deviceAuth: _FakeDeviceAuth());
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(InfoBanner), findsNothing);
        final note = find.text(
          'Tu huella y rostro se verifican de forma segura en tu dispositivo. '
          'HandiMan ¡Ya! no almacena tus datos biométricos.',
        );
        await tester.ensureVisible(note);
        await tester.pumpAndSettle();
        expect(note, findsOneWidget);
        expect(
          find.descendant(of: find.byKey(const Key('security-note')), matching: find.byIcon(Icons.shield_outlined)),
          findsOneWidget,
        );
        expect(tester.getRect(note).right, lessThanOrEqualTo(size.width));
      });
    }

    testWidgets('sin biometría en el teléfono solo explica que se usa un código', (tester) async {
      await _pump(tester, const SecurityPage(), deviceAuth: _FakeDeviceAuth(types: const {}));
      expect(find.byKey(const Key('biometric-switch')), findsNothing);
      expect(find.textContaining('Confirmarás con un código a tu celular'), findsOneWidget);
    });
  });
}
