import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/booking/booking_detail_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

const _draft = BookingDraft(
  categoryId: 2, // Electricidad
  cityId: 1,
  zoneId: 12,
  mode: BookingMode.now,
  description: 'Se cortó la luz en la cocina',
  address: 'Calle Los Pinos 123',
);

/// Un pedido ¡Ya! aceptado por el profesional de demostración y "en camino".
Future<String> _onTheWay(DemoBackend backend) async {
  await backend.signInAs(DemoBackend.professionalPhone);
  await backend.setAvailability(true);
  await backend.signInAs(DemoBackend.customerPhone);
  final id = await backend.create(_draft);
  await backend.signInAs(DemoBackend.professionalPhone);
  await backend.accept(id, isOffer: true);
  await backend.updateProgress(id, BookingStatus.onTheWay);
  return id;
}

String _other(String pin) => pin == '000000' ? '000001' : '000000';

void main() {
  late DemoBackend backend;

  setUp(() => backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero));
  tearDown(() => backend.dispose());

  Future<void> asPro() => backend.signInAs(DemoBackend.professionalPhone);
  Future<void> asCustomer() => backend.signInAs(DemoBackend.customerPhone);

  group('código de llegada', () {
    test('correcto: verifica la llegada y recién entonces empieza el trabajo', () async {
      final id = await _onTheWay(backend);
      await expectLater(backend.updateProgress(id, BookingStatus.inProgress), _code('HMY_ARRIVAL_NOT_VERIFIED'));
      final pin = await backend.markArrived(id);
      expect(pin.pin, matches(RegExp(r'^[0-9]{6}$')));
      expect((await backend.arrival(id)).stage, ArrivalStage.waitingPin);

      await asCustomer();
      expect((await backend.verifyArrivalPin(id, pin.pin)).result, ArrivalCheckResult.verified);
      expect((await backend.arrival(id)).verified, isTrue);
      // Sin repetición: el mismo código ya no sirve.
      await expectLater(backend.verifyArrivalPin(id, pin.pin), _code('HMY_ARRIVAL_ALREADY_VERIFIED'));

      await asPro();
      await backend.updateProgress(id, BookingStatus.inProgress);
      expect((await backend.detail(id)).status, BookingStatus.inProgress);
    });

    test('incorrecto: cuenta los intentos y a los 5 bloquea el código', () async {
      final id = await _onTheWay(backend);
      final pin = await backend.markArrived(id);
      await asCustomer();
      await expectLater(backend.verifyArrivalPin(id, '12a456'), _code('HMY_INVALID_PIN'));
      final first = await backend.verifyArrivalPin(id, _other(pin.pin));
      expect(first.result, ArrivalCheckResult.wrong);
      expect(first.attemptsLeft, 4);
      for (var i = 0; i < 3; i++) {
        await backend.verifyArrivalPin(id, _other(pin.pin));
      }
      expect((await backend.verifyArrivalPin(id, _other(pin.pin))).result, ArrivalCheckResult.locked);
      await expectLater(backend.verifyArrivalPin(id, pin.pin), _code('HMY_ARRIVAL_NO_PIN'));
    });

    test('vencido: no sirve y el profesional genera otro (máximo 3, con espera)', () async {
      final id = await _onTheWay(backend);
      final first = await backend.markArrived(id);
      await expectLater(backend.markArrived(id), _code('HMY_ARRIVAL_PIN_TOO_SOON'));
      backend.debugAgeArrivalPin(id, const Duration(minutes: 11));
      await asCustomer();
      expect((await backend.verifyArrivalPin(id, first.pin)).result, ArrivalCheckResult.expired);

      await asPro();
      await backend.markArrived(id);
      backend.debugAgeArrivalPin(id, const Duration(seconds: 31));
      final third = await backend.markArrived(id);
      expect(third.pinsLeft, 0);
      backend.debugAgeArrivalPin(id, const Duration(seconds: 31));
      await expectLater(backend.markArrived(id), _code('HMY_ARRIVAL_PIN_LIMIT'));
      await asCustomer();
      expect((await backend.verifyArrivalPin(id, third.pin)).result, ArrivalCheckResult.verified);
    });

    test('no autorizados: el profesional no se verifica solo, otro cliente tampoco', () async {
      final id = await _onTheWay(backend);
      final pin = await backend.markArrived(id);
      await expectLater(backend.verifyArrivalPin(id, pin.pin), _code('HMY_FORBIDDEN'));
      await asCustomer();
      await expectLater(backend.markArrived(id), _code('HMY_FORBIDDEN'));
      await backend.signInAs('+59171112233');
      await expectLater(backend.verifyArrivalPin(id, pin.pin), _code('HMY_FORBIDDEN'));
      await expectLater(backend.arrival(id), _code('HMY_FORBIDDEN'));
    });

    test('cancelación: el código deja de servir', () async {
      final id = await _onTheWay(backend);
      final pin = await backend.markArrived(id);
      await backend.cancel(id, 'No encontré la dirección');
      await asCustomer();
      await expectLater(backend.verifyArrivalPin(id, pin.pin), _code('HMY_INVALID_TRANSITION'));
    });

    test('excepción del equipo: solo admin, con motivo, y queda en la auditoría', () async {
      final id = await _onTheWay(backend);
      final code = (await backend.detail(id)).code;
      await expectLater(backend.adminVerifyArrival(code, 'Llamé al cliente'), _code('HMY_FORBIDDEN'));
      await backend.signInAs(DemoBackend.adminPhone);
      await expectLater(backend.adminVerifyArrival(code, ''), _code('HMY_REASON_REQUIRED'));
      await expectLater(backend.adminVerifyArrival('NOEXISTE', 'Llamé al cliente'), _code('HMY_NOT_FOUND'));
      await backend.adminVerifyArrival(code.toLowerCase(), 'El cliente confirmó por teléfono');
      expect((await backend.auditLog()).first.action, 'arrival.admin_verified');

      await asPro();
      final a = await backend.arrival(id);
      expect(a.verified, isTrue);
      expect(a.byTeam, isTrue);
      await backend.updateProgress(id, BookingStatus.inProgress);
    });
  });

  group('pantallas', () {
    Future<void> pumpDetail(WidgetTester tester, DemoAppBackend app, String id) async {
      await initializeDateFormatting('es');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(app)],
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('es', 'BO'),
            supportedLocales: const [Locale('es', 'BO')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: BookingDetailPage(id: id),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('"He llegado" muestra el código al profesional y el cliente lo escribe en 6 casillas', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = await tester.runAsync(() => _onTheWay(app));

      // Profesional: sin llegada verificada no aparece "Empecé el trabajo".
      await pumpDetail(tester, app, id!);
      expect(find.byKey(const Key('start-work')), findsNothing);
      await tester.tap(find.byKey(const Key('arrival-mark')));
      await tester.pumpAndSettle();
      expect(find.text('Proporciona este código al cliente para verificar tu llegada.'), findsOneWidget);
      final shown = tester.widget<Text>(find.byKey(const Key('arrival-pin'))).data!.replaceAll(' ', '');
      expect(shown, matches(RegExp(r'^[0-9]{6}$')));
      await tester.tap(find.text('Listo'));
      await tester.pumpAndSettle();
      expect(find.text('Generar otro código'), findsOneWidget);

      // Cliente: escribe un código equivocado y luego el correcto.
      await tester.runAsync(() => app.signInAs(DemoBackend.customerPhone));
      await pumpDetail(tester, app, id);
      await tester.tap(find.byKey(const Key('arrival-verify')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('arrival-code-field')), _other(shown));
      await tester.pumpAndSettle();
      expect(find.textContaining('Te quedan 4 intentos'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('arrival-code-field')), shown);
      await tester.pumpAndSettle();
      expect(find.text('Llegada verificada'), findsWidgets);
      expect(find.byKey(const Key('arrival-verified')), findsOneWidget);

      // Profesional: ahora sí puede empezar.
      await tester.runAsync(() => app.signInAs(DemoBackend.professionalPhone));
      await pumpDetail(tester, app, id);
      expect(find.byKey(const Key('start-work')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
