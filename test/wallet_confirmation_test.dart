import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/core/utils/formatters.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/wallet.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/pro_mode/wallet_page.dart';
import 'package:handimanya/features/security/confirm_identity.dart';
import 'package:handimanya/features/security/security_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final backend = DemoAppBackend(simulateDelays: false);
  addTearDown(backend.dispose);
  await backend.signIn(email: DemoBackend.professionalEmail, password: DemoBackend.demoPassword);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  if (biometricOn) {
    await backend.confirmPassword(DemoBackend.demoPassword);
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

/// Abre "Recargar saldo", llena el formulario y toca Continuar.
Future<void> _startTopup(WidgetTester tester, {String amount = '150'}) async {
  await _tap(tester, find.text('Recargar saldo'));
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
      backend = DemoBackend(simulateDelays: false);
      await backend.signIn(email: DemoBackend.professionalEmail, password: DemoBackend.demoPassword);
    });
    tearDown(() => backend.dispose());

    Future<int> topup(String method, String key) =>
        backend.requestTopup(amount: 50, methodId: 1, authMethod: method, clientKey: key);

    test('sin confirmar no se crea la recarga', () async {
      await expectLater(topup('password', 'a'), _code('HMY_CONFIRMATION_EXPIRED'));
      await expectLater(topup('biometric', 'a'), _code('HMY_BIOMETRIC_DISABLED'));
      await expectLater(topup('pin', 'a'), _code('HMY_CONFIRMATION_REQUIRED'));
      expect(await backend.topups(), isEmpty);
    });

    test('contraseña incorrecta: falla y no confirma', () async {
      await expectLater(backend.confirmPassword('otra'), _code('invalid_credentials'));
      await expectLater(topup('password', 'a'), _code('HMY_CONFIRMATION_EXPIRED'));
    });

    test('cada confirmación sirve para una sola recarga; repetir el intento no duplica', () async {
      final before = (await backend.wallet()).available;
      await backend.confirmPassword(DemoBackend.demoPassword);
      final id = await topup('password', 'k1');
      expect(await topup('password', 'k1'), id, reason: 'mismo intento = misma solicitud');
      await expectLater(topup('password', 'k2'), _code('HMY_CONFIRMATION_EXPIRED'));
      expect(await backend.topups(), hasLength(1));
      expect((await backend.wallet()).available, before, reason: 'pedir no acredita saldo');
    });

    test('huella o rostro: activar exige la contraseña; desactivar, no', () async {
      await expectLater(backend.setBiometricEnabled(true), _code('HMY_CONFIRMATION_EXPIRED'));
      await backend.confirmPassword(DemoBackend.demoPassword);
      await backend.setBiometricEnabled(true);
      expect(await backend.biometricEnabled(), isTrue);
      await topup('biometric', 'b1');
      await backend.setBiometricEnabled(false);
      await expectLater(topup('biometric', 'b2'), _code('HMY_BIOMETRIC_DISABLED'));
      await backend.signIn(email: DemoBackend.adminEmail, password: DemoBackend.demoPassword);
      final audit = await backend.auditLog();
      expect(audit.where((e) => e.action == 'topup.request').single.details['auth_method'], 'biometric');
      expect(audit.map((e) => e.action), containsAll(['security.biometric_on', 'security.biometric_off']));
    });
  });

  group('pantalla de recarga', () {
    testWidgets('con contraseña: muestra el monto en Bs, envía y muestra el comprobante', (tester) async {
      final r = await _pump(tester, const WalletPage(), deviceAuth: _FakeDeviceAuth(types: const {}));
      final before = (await r.backend.wallet()).available;
      await _startTopup(tester);
      expect(find.text('Confirma que eres tú'), findsOneWidget);
      expect(find.byKey(const Key('confirm-amount')), findsOneWidget);
      expect(find.text(Fmt.bs(150)), findsOneWidget);
      expect(find.byKey(const Key('confirm-face')), findsNothing, reason: 'sin biometría solo hay contraseña');
      expect(await _pending(r.backend), isEmpty, reason: 'nada se envía antes de confirmar');

      await tester.enterText(find.byKey(const Key('confirm-password-field')), DemoBackend.demoPassword);
      await _tap(tester, find.byKey(const Key('confirm-submit')));

      expect(find.byKey(const Key('topup-receipt')), findsOneWidget);
      expect(find.text('Pendiente de verificación'), findsOneWidget);
      expect(find.text('Contraseña'), findsOneWidget);
      expect(find.text('TX-77'), findsOneWidget);
      final pending = await _pending(r.backend);
      expect(pending.single.amount, 150);
      expect((await r.backend.wallet()).available, before, reason: 'el saldo sube solo cuando el equipo aprueba');
      await _tap(tester, find.text('Listo'));
      expect(find.byKey(const Key('topup-receipt')), findsNothing);
    });

    testWidgets('contraseña incorrecta: avisa y no envía nada', (tester) async {
      final r = await _pump(tester, const WalletPage(), deviceAuth: _FakeDeviceAuth(types: const {}));
      await _startTopup(tester);
      await tester.enterText(find.byKey(const Key('confirm-password-field')), 'equivocada');
      await _tap(tester, find.byKey(const Key('confirm-submit')));
      expect(find.text('La contraseña no es correcta. No se envió nada.'), findsOneWidget);
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
      expect(find.byKey(const Key('confirm-password-field')), findsNothing, reason: 'la huella viene elegida');

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

    testWidgets('huella bloqueada: pide usar la contraseña, que también funciona', (tester) async {
      final r = await _pump(
        tester,
        const WalletPage(),
        deviceAuth: _FakeDeviceAuth(types: const {DeviceBiometric.face}, results: [DeviceAuthResult.lockedOut]),
        biometricOn: true,
      );
      await _startTopup(tester);
      await _tap(tester, find.byKey(const Key('confirm-submit')));
      expect(find.textContaining('Usa tu contraseña'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('confirm-password')));
      await tester.enterText(find.byKey(const Key('confirm-password-field')), DemoBackend.demoPassword);
      await _tap(tester, find.byKey(const Key('confirm-submit')));
      expect(find.byKey(const Key('topup-receipt')), findsOneWidget);
      expect(await _pending(r.backend), hasLength(1));
    });

    testWidgets('toques repetidos crean una sola solicitud', (tester) async {
      final device = _FakeDeviceAuth();
      final r = await _pump(tester, const WalletPage(), deviceAuth: device, biometricOn: true);
      await _tap(tester, find.text('Recargar saldo'));
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
    testWidgets('activar pide contraseña y huella; desactivar vuelve a la contraseña', (tester) async {
      final device = _FakeDeviceAuth();
      final r = await _pump(tester, const SecurityPage(), deviceAuth: device);
      final sw = find.byKey(const Key('biometric-switch'));
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);

      await _tap(tester, sw);
      expect(find.text('Confirma que eres tú'), findsOneWidget);
      expect(find.byKey(const Key('confirm-fingerprint')), findsNothing, reason: 'activar exige la contraseña');
      await tester.enterText(find.byKey(const Key('confirm-password-field')), DemoBackend.demoPassword);
      await _tap(tester, find.byKey(const Key('confirm-submit')));
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
      await tester.enterText(find.byKey(const Key('confirm-password-field')), DemoBackend.demoPassword);
      await _tap(tester, find.byKey(const Key('confirm-submit')));
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('biometric-switch'))).value, isFalse);
      expect(await r.backend.biometricEnabled(), isFalse);
    });

    testWidgets('sin biometría en el teléfono solo explica que se usa la contraseña', (tester) async {
      await _pump(tester, const SecurityPage(), deviceAuth: _FakeDeviceAuth(types: const {}));
      expect(find.byKey(const Key('biometric-switch')), findsNothing);
      expect(find.textContaining('Confirmarás con tu contraseña'), findsOneWidget);
    });
  });
}
