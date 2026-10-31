import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/demo/demo_data.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/security/app_lock.dart';
import 'package:handimanya/features/security/confirm_identity.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

class _FakeDeviceAuth implements DeviceAuth {
  _FakeDeviceAuth(this.results);

  final List<DeviceAuthResult> results;
  int calls = 0;

  @override
  Future<Set<DeviceBiometric>> available() async => const {DeviceBiometric.face};

  @override
  Future<DeviceAuthResult> authenticate(String reason) async {
    calls++;
    return results.isEmpty ? DeviceAuthResult.success : results.removeAt(0);
  }
}

const _newPhone = '+59167778888';

final _locked = <String, Object>{
  'onboarding_seen_v1': true,
  biometricPrefKey('demo-cliente'): true,
  appLockPrefKey('demo-cliente'): true,
};

void main() {
  group('ingreso con celular (demostración, igual que Supabase)', () {
    late DemoBackend backend;
    setUp(() => backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero));
    tearDown(() => backend.dispose());

    test('un número nuevo crea la cuenta y pide completar el perfil', () async {
      await backend.signInAs(_newPhone, channel: CodeChannel.sms);
      final me = await backend.myAccount();
      expect(me.phone, _newPhone);
      expect(me.email, isEmpty, reason: 'no se pide correo');
      expect(me.profileComplete, isFalse);
      expect(me.roles, {AppRole.customer});
      await expectLater(
        backend.completeSignup(fullName: 'Jo', cityId: 1, acceptTerms: true),
        _code('HMY_INVALID_NAME'),
      );
      await expectLater(
        backend.completeSignup(fullName: 'Juana Mamani', cityId: 1, acceptTerms: false),
        _code('HMY_TERMS_REQUIRED'),
      );
      await backend.completeSignup(fullName: '  Juana   Mamani ', cityId: 1, acceptTerms: true);
      expect((await backend.myAccount()).profileComplete, isTrue);
      expect((await backend.myAccount()).fullName, 'Juana Mamani');
    });

    test('un número que ya existe entra a su cuenta, sin duplicados', () async {
      await backend.signInAs(_newPhone);
      final id = backend.currentUser!.id;
      await backend.signOut();
      await backend.signInAs(_newPhone, channel: CodeChannel.sms);
      expect(backend.currentUser!.id, id, reason: 'un número, una cuenta');

      await backend.signInAs(DemoBackend.customerPhone);
      expect(backend.currentUser!.id, 'demo-cliente');
      expect((await backend.myAccount()).profileComplete, isTrue, reason: 'quien vuelve no repite el perfil');

      await backend.signInAs(DemoBackend.adminPhone);
      final same = (await backend.adminUsers(_newPhone.substring(4))).where((u) => u.phone == _newPhone);
      expect(same, hasLength(1));
    });

    test('WhatsApp y SMS funcionan igual', () async {
      for (final c in CodeChannel.values) {
        await backend.sendPhoneCode(phone: DemoBackend.customerPhone, channel: c);
        await backend.verifyPhoneCode(phone: DemoBackend.customerPhone, code: DemoBackend.demoCode);
        expect(backend.currentUser?.id, 'demo-cliente', reason: c.label);
      }
    });

    test('solo celulares de Bolivia', () async {
      for (final p in ['+59121234567', '+5917123456', '+5491112345678']) {
        await expectLater(backend.sendPhoneCode(phone: p, channel: CodeChannel.sms), _code('HMY_INVALID_PHONE'));
      }
    });

    test('código incorrecto no entra; tras 5 intentos fallidos hay que pedir otro', () async {
      await backend.sendPhoneCode(phone: _newPhone, channel: CodeChannel.whatsapp);
      for (var i = 0; i < DemoBackend.maxCodeAttempts - 1; i++) {
        await expectLater(backend.verifyPhoneCode(phone: _newPhone, code: '000000'), _code('otp_invalid'));
      }
      await expectLater(backend.verifyPhoneCode(phone: _newPhone, code: '000000'), _code('HMY_OTP_TOO_MANY_ATTEMPTS'));
      await expectLater(
        backend.verifyPhoneCode(phone: _newPhone, code: DemoBackend.demoCode),
        _code('otp_expired'),
        reason: 'el código quedó anulado',
      );
      expect(backend.currentUser, isNull);
    });

    test('sin pedir código no se puede entrar', () async {
      await expectLater(
        backend.verifyPhoneCode(phone: DemoBackend.customerPhone, code: DemoBackend.demoCode),
        _code('otp_expired'),
      );
    });

    test('reenvío: espera un minuto y máximo 5 por hora', () async {
      final strict = DemoBackend(simulateDelays: false);
      addTearDown(strict.dispose);
      await strict.sendPhoneCode(phone: _newPhone, channel: CodeChannel.sms);
      await expectLater(
        strict.sendPhoneCode(phone: _newPhone, channel: CodeChannel.whatsapp),
        throwsA(isA<AppError>().having((e) => e.message, 'mensaje', matches(RegExp(r'^Espera \d+ segundos')))),
      );
      for (var i = 0; i < 4; i++) {
        await backend.sendPhoneCode(phone: _newPhone, channel: CodeChannel.sms);
      }
      await backend.sendPhoneCode(phone: _newPhone, channel: CodeChannel.sms);
      await expectLater(backend.sendPhoneCode(phone: _newPhone, channel: CodeChannel.sms), _code('HMY_OTP_LIMIT'));
    });

    test('una cuenta con los dos roles cambia de rol sin volver a entrar', () async {
      await backend.signInAs(DemoBackend.professionalPhone);
      await backend.setActiveRole(AppRole.customer);
      expect((await backend.myAccount()).activeRole, AppRole.customer);
      await backend.setActiveRole(AppRole.professional);
      expect((await backend.myAccount()).isProfessionalMode, isTrue);
      expect(backend.currentUser!.id, 'demo-pro', reason: 'misma sesión');

      await backend.signInAs(DemoBackend.customerPhone);
      await expectLater(backend.setActiveRole(AppRole.professional), _code('HMY_ROLE_NOT_GRANTED'));
    });

    test('recuperar la cuenta con el correo y cambiar de número', () async {
      await backend.signInAs(DemoBackend.customerPhone);
      await backend.requestEmailChange('carla@correo.bo');
      await expectLater(backend.verifyEmailChange(email: 'carla@correo.bo', code: '999999'), _code('otp_invalid'));
      await backend.verifyEmailChange(email: 'carla@correo.bo', code: DemoBackend.demoCode);
      expect((await backend.myAccount()).email, 'carla@correo.bo');
      await backend.signOut();

      // Perdió el celular: entra con el correo, sin contraseña.
      await backend.sendEmailLoginCode('Carla@Correo.bo');
      await backend.verifyEmailLoginCode(email: 'carla@correo.bo', code: DemoBackend.demoCode);
      expect(backend.currentUser!.id, 'demo-cliente');

      await expectLater(
        backend.requestPhoneChange(phone: DemoBackend.professionalPhone, channel: CodeChannel.sms),
        _code('phone_exists'),
      );
      await backend.requestPhoneChange(phone: _newPhone, channel: CodeChannel.whatsapp);
      await backend.verifyPhoneChange(phone: _newPhone, code: DemoBackend.demoCode);
      expect(backend.currentUser!.phone, _newPhone);
      await backend.signOut();

      await backend.signInAs(_newPhone);
      expect(backend.currentUser!.id, 'demo-cliente', reason: 'el número nuevo entra a la misma cuenta');
      await backend.signInAs(DemoBackend.customerPhone);
      expect(backend.currentUser!.id, isNot('demo-cliente'), reason: 'el número viejo ya no es de esa cuenta');
    });

    test('un correo desconocido no crea cuentas', () async {
      await backend.sendEmailLoginCode('nadie@correo.bo');
      await expectLater(
        backend.verifyEmailLoginCode(email: 'nadie@correo.bo', code: DemoBackend.demoCode),
        _code('otp_invalid'),
      );
      expect(backend.currentUser, isNull);
    });
  });

  group('mensajes de error del envío de códigos', () {
    test('se muestran claros en español', () {
      expect(AppError.from(Exception('HMY_OTP_TOO_SOON:42')).message, 'Espera 42 segundos para pedir otro código.');
      expect(
        AppError.from(Exception('For security purposes, you can only request this after 37 seconds.')).message,
        'Espera 37 segundos para pedir otro código.',
      );
      expect(
        AppError.from(Exception('HMY_OTP_CHANNEL_OFF:whatsapp')).message,
        'Todavía no enviamos códigos por WhatsApp. Prueba por SMS.',
      );
      expect(AppError.from(Exception('HMY_OTP_SEND_FAILED:sms')).message, contains('prueba por WhatsApp'));
      expect(AppError.from(Exception('Token has expired or is invalid')).code, 'otp_invalid');
      expect(AppError.from(Exception('HMY_OTP_LIMIT')).code, 'HMY_OTP_LIMIT');
    });
  });

  group('pantallas', () {
    Future<DemoAppBackend> pumpApp(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
      DeviceAuth? deviceAuth,
      Future<void> Function(DemoAppBackend)? before,
    }) async {
      await initializeDateFormatting('es');
      SharedPreferences.setMockInitialValues(prefs);
      final p = await SharedPreferences.getInstance();
      final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(backend.dispose);
      await before?.call(backend);
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(p),
            backendProvider.overrideWithValue(backend),
            if (deviceAuth != null) deviceAuthProvider.overrideWithValue(deviceAuth),
          ],
          child: const HandiManYaApp(),
        ),
      );
      await tester.pumpAndSettle();
      return backend;
    }

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('una sola pantalla: número nuevo por SMS, perfil de cliente y al inicio', (tester) async {
      final backend = await pumpApp(tester);
      await loginWithPhone(tester, _newPhone, channel: CodeChannel.sms);
      expect(find.text('Ya casi terminamos'), findsOneWidget);
      expect(
        find.byType(TextFormField),
        findsOneWidget,
        reason: 'solo nombre (el municipio se elige en un buscador); sin correo ni contraseña',
      );

      await tap(tester, find.byKey(const Key('profile-continue')));
      expect(find.text('Debes aceptar para continuar'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('profile-name')), 'Juana Mamani');
      // Fuera de las tres ciudades grandes: se busca el municipio por nombre.
      await tap(tester, find.byKey(const Key('profile-city')));
      await tester.enterText(find.byKey(const Key('city-search')), 'uyuni');
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('city-uyuni-pt')));
      expect(find.text('Prov. Antonio Quijarro · Potosí'), findsOneWidget);
      await tap(tester, find.byKey(const Key('profile-terms')));
      await tap(tester, find.byKey(const Key('profile-continue')));

      expect(find.text('¡Hola, Juana!'), findsOneWidget);
      final account = await backend.myAccount();
      expect(account.profileComplete, isTrue);
      expect(DemoData.cities.firstWhere((c) => c.id == account.cityId).name, 'Uyuni');
      expect(tester.takeException(), isNull);
    });

    testWidgets('profesional nuevo: después del perfil sigue con servicios y documentos', (tester) async {
      await pumpApp(tester);
      await loginWithPhone(tester, _newPhone);
      await tester.enterText(find.byKey(const Key('profile-name')), 'Pedro Quispe');
      await tap(tester, find.byKey(const Key('profile-city')));
      await tap(tester, find.text('Santa Cruz de la Sierra').last);
      await tap(tester, find.byKey(const Key('role-professional')));
      await tap(tester, find.byKey(const Key('profile-terms')));
      await tap(tester, find.byKey(const Key('profile-continue')));
      expect(find.text('Ser profesional'), findsOneWidget);
    });

    testWidgets('código incorrecto: avisa y no entra', (tester) async {
      final backend = await pumpApp(tester);
      await tap(tester, find.text('Omitir'));
      await tester.enterText(find.byKey(const Key('phone-field')), '7123 4567');
      await tap(tester, find.byKey(const Key('auth-continue')));
      expect(find.text('Escribe el código'), findsOneWidget);
      expect(find.textContaining('WhatsApp al +591\u00A07123\u00A04567'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('code-field')), '111111');
      await tester.pumpAndSettle();
      expect(find.text('El código no es correcto. Revísalo y vuelve a intentar.'), findsOneWidget);
      expect(backend.currentUser, isNull);

      await tester.pump(const Duration(seconds: 61)); // un minuto entre envíos
      await tap(tester, find.byKey(const Key('code-other-channel')));
      expect(find.textContaining('SMS al +591\u00A07123\u00A04567'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('code-field')), DemoBackend.demoCode);
      await tester.pumpAndSettle();
      expect(find.text('¡Hola, Carla!'), findsOneWidget);
    });

    testWidgets('quien ya entró sigue con la sesión abierta, sin código', (tester) async {
      await pumpApp(tester, prefs: {'onboarding_seen_v1': true}, before: (b) => b.signInAs(DemoBackend.customerPhone));
      expect(find.text('Bienvenido a HandiMan ¡Ya!'), findsNothing);
      expect(find.text('¡Hola, Carla!'), findsOneWidget);
    });

    testWidgets('con el bloqueo activado, la app se abre con el rostro', (tester) async {
      await pumpApp(
        tester,
        prefs: {
          'onboarding_seen_v1': true,
          biometricPrefKey('demo-cliente'): true,
          appLockPrefKey('demo-cliente'): true,
        },
        // El cuadro se abre solo y falla; después, el botón.
        deviceAuth: _FakeDeviceAuth([DeviceAuthResult.failed]),
        before: (b) => b.signInAs(DemoBackend.customerPhone),
      );
      expect(find.byKey(const Key('app-lock')), findsOneWidget, reason: 'falló: sigue bloqueada');
      expect(find.textContaining('No pudimos confirmar'), findsOneWidget);
      await tap(tester, find.byKey(const Key('app-unlock')));
      expect(find.byKey(const Key('app-lock')), findsNothing);
      expect(find.text('¡Hola, Carla!'), findsOneWidget);
    });

    testWidgets('con el bloqueo activado, el cuadro de huella se abre solo y entra sin tocar nada', (tester) async {
      final auth = _FakeDeviceAuth([DeviceAuthResult.success]);
      await pumpApp(
        tester,
        prefs: {
          'onboarding_seen_v1': true,
          biometricPrefKey('demo-cliente'): true,
          appLockPrefKey('demo-cliente'): true,
        },
        deviceAuth: auth,
        before: (b) => b.signInAs(DemoBackend.customerPhone),
      );
      expect(auth.calls, 1, reason: 'se pidió la huella una vez, sin tocar el botón');
      expect(find.byKey(const Key('app-lock')), findsNothing);
      expect(find.text('¡Hola, Carla!'), findsOneWidget);
    });

    testWidgets('bloqueada: "Entrar con un código" cierra la sesión y no deja entrar sin código', (tester) async {
      await pumpApp(
        tester,
        prefs: {
          'onboarding_seen_v1': true,
          biometricPrefKey('demo-cliente'): true,
          appLockPrefKey('demo-cliente'): true,
        },
        deviceAuth: _FakeDeviceAuth([DeviceAuthResult.canceled]),
        before: (b) => b.signInAs(DemoBackend.customerPhone),
      );
      expect(find.byKey(const Key('app-lock')), findsOneWidget, reason: 'cancelada: no se vuelve a abrir sola');
      await tap(tester, find.text('Entrar con un código'));
      expect(find.byKey(const Key('app-lock')), findsNothing);
      expect(find.text('¡Hola, Carla!'), findsNothing, reason: 'sin sesión no se ve la cuenta');
    });

    testWidgets('volver a la app enseguida no vuelve a pedir la biometría', (tester) async {
      final auth = _FakeDeviceAuth([]);
      await pumpApp(
        tester,
        prefs: {
          'onboarding_seen_v1': true,
          biometricPrefKey('demo-cliente'): true,
          appLockPrefKey('demo-cliente'): true,
        },
        deviceAuth: auth,
        before: (b) => b.signInAs(DemoBackend.customerPhone),
      );
      expect(find.byKey(const Key('app-lock')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-lock')), findsNothing);
      expect(find.text('¡Hola, Carla!'), findsOneWidget);
      expect(auth.calls, 1, reason: 'solo la vez de abrir la app');
    });

    testWidgets('al volver después de un rato el cuadro se abre solo, sin tocar "Desbloquear"', (tester) async {
      final saved = AppLockGate.relockAfter;
      AppLockGate.relockAfter = Duration.zero;
      addTearDown(() => AppLockGate.relockAfter = saved);
      final auth = _FakeDeviceAuth([]);
      await pumpApp(tester, prefs: _locked, deviceAuth: auth, before: (b) => b.signInAs(DemoBackend.customerPhone));
      expect(auth.calls, 1);
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
      expect(auth.calls, 2, reason: 'se volvió a pedir sola');
      expect(find.byKey(const Key('app-lock')), findsNothing);
      expect(find.text('¡Hola, Carla!'), findsOneWidget, reason: 'la sesión sigue abierta');
    });

    testWidgets('al reiniciar el teléfono la sesión sigue y vuelve a pedir la biometría', (tester) async {
      // Reiniciar = abrir la app de cero con la sesión y las preferencias guardadas.
      final auth = _FakeDeviceAuth([DeviceAuthResult.success]);
      await pumpApp(tester, prefs: _locked, deviceAuth: auth, before: (b) => b.signInAs(DemoBackend.customerPhone));
      expect(auth.calls, 1);
      expect(find.text('¡Hola, Carla!'), findsOneWidget);
      expect(find.byKey(const Key('code-field')), findsNothing, reason: 'no pide código otra vez');
    });

    testWidgets('si quitaron la huella del teléfono: lo dice y ofrece entrar con un código', (tester) async {
      await pumpApp(
        tester,
        prefs: _locked,
        deviceAuth: _FakeDeviceAuth([DeviceAuthResult.unavailable]),
        before: (b) => b.signInAs(DemoBackend.customerPhone),
      );
      expect(find.byKey(const Key('app-lock')), findsOneWidget, reason: 'no se abre sin biometría');
      expect(find.textContaining('ya no tiene huella ni rostro'), findsOneWidget);
      expect(find.text('Entrar con un código'), findsOneWidget);
      expect(find.text('¡Hola, Carla!'), findsNothing);
    });

    testWidgets('demasiados intentos: sigue bloqueada y lo explica', (tester) async {
      await pumpApp(
        tester,
        prefs: _locked,
        deviceAuth: _FakeDeviceAuth([DeviceAuthResult.lockedOut]),
        before: (b) => b.signInAs(DemoBackend.customerPhone),
      );
      expect(find.byKey(const Key('app-lock')), findsOneWidget);
      expect(find.textContaining('demasiados intentos'), findsOneWidget);
    });
  });
}
