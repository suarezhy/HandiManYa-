import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/core/utils/formatters.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/admin.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/admin/finance_pages.dart';
import 'package:handimanya/features/booking/booking_detail_page.dart';
import 'package:handimanya/features/booking/price_panel.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';
import 'support/price_helpers.dart';

// Reglas finales del dueño (0066): nada se reserva; el 10 % se cobra una sola
// vez cuando el cliente marca "Ya pagué". Confirmar el trabajo o "Recibí el
// pago" no cobran. "No recibí el pago" abre una revisión del propietario.

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

const _draft = BookingDraft(
  categoryId: 2, // Electricidad
  cityId: 1,
  zoneId: 12,
  mode: BookingMode.now,
  description: 'Se cortó la luz en la cocina',
  address: 'Calle Los Pinos 123',
  budget: 150,
);

// La demostración limita a 5 códigos por hora por celular; pasado eso se
// entra con el correo (otro límite), como podría hacerlo la persona.
final _logins = <String, int>{};
Future<void> _pro(DemoBackend b) => _login(b, DemoBackend.professionalPhone, DemoBackend.professionalEmail);
Future<void> _customer(DemoBackend b) => _login(b, DemoBackend.customerPhone, DemoBackend.customerEmail);
Future<void> _login(DemoBackend b, String phone, String email) async {
  final n = _logins[phone] = (_logins[phone] ?? 0) + 1;
  if (n <= 5) return b.signInAs(phone);
  await b.sendEmailLoginCode(email);
  await b.verifyEmailLoginCode(email: email, code: DemoBackend.demoCode);
}

/// Un pedido ¡Ya! de Bs 150 acordado y terminado por el profesional de demostración.
Future<String> _finished(DemoBackend backend) async {
  await _pro(backend);
  await backend.setAvailability(true);
  await _customer(backend);
  final id = await backend.create(_draft);
  await _pro(backend);
  await agreeAsPro(backend, id); // acepta el precio del cliente (Bs 150), sin cambiar de cuenta
  await backend.updateProgress(id, BookingStatus.onTheWay);
  final pin = await backend.markArrived(id);
  await _customer(backend);
  await backend.verifyArrivalPin(id, pin.pin);
  await _pro(backend);
  await backend.updateProgress(id, BookingStatus.inProgress);
  await backend.updateProgress(id, BookingStatus.workFinished);
  return id;
}

void main() {
  late DemoBackend backend;

  setUp(() {
    _logins.clear();
    backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
  });
  tearDown(() => backend.dispose());

  Future<void> asPro() => _pro(backend);
  Future<void> asCustomer() => _customer(backend);

  test('acordar, empezar, terminar, confirmar y "Recibí el pago" no cobran; "Ya pagué" cobra una vez', () async {
    await asPro();
    final start = (await backend.wallet()).available;
    final id = await _finished(backend);
    expect((await backend.wallet()).available, start, reason: 'nada reservado ni descontado hasta aquí');

    await backend.acknowledgePayment(id, PaymentMethod.cash);
    expect((await backend.wallet()).available, start, reason: '"Recibí el pago" no cobra');

    await asCustomer();
    await backend.confirmCompletion(id);
    await asPro();
    expect((await backend.wallet()).available, start, reason: '"Confirmar trabajo terminado" no cobra');

    await asCustomer();
    await backend.acknowledgePayment(id, PaymentMethod.qr);
    await backend.acknowledgePayment(id, PaymentMethod.qr);
    expect((await backend.detail(id)).commissionCharged, isNull, reason: 'el cliente no ve la comisión');
    await asPro();
    final w = await backend.wallet();
    expect(w.available, start - 15);
    expect(w.reserved, 0);
    expect(w.commissionsCollected, 15);
    expect((await backend.ledger()).where((e) => e.note?.contains('Ya pagué') ?? false), hasLength(1));
  });

  test('"Ya pagué" antes de que el profesional termine no se puede', () async {
    await asPro();
    await backend.setAvailability(true);
    await asCustomer();
    final id = await backend.create(_draft);
    await asPro();
    await agreeAsPro(backend, id);
    await asCustomer();
    await expectLater(backend.acknowledgePayment(id, PaymentMethod.cash), _code('HMY_INVALID_TRANSITION'));
  });

  test('el saldo tiene que cubrir las comisiones de todos los trabajos sin cobrar', () async {
    await asPro();
    await backend.setAvailability(true);
    final available = (await backend.wallet()).available;
    await asCustomer();
    final id = await backend.create(_draft);
    await asPro();
    await agreeAsPro(backend, id);
    final q = await backend.commissionForAmount(id, 100);
    expect(q.openCommissions, 15, reason: 'el trabajo acordado de Bs 150 todavía no se cobró');
    // Una contraoferta (nuevo total) enorme no cabe: se rechaza, sin reservar nada y sin cambiar el precio.
    final big = (available * 10).roundToDouble() + 150;
    await backend.updateProgress(id, BookingStatus.onTheWay);
    final pin = await backend.markArrived(id);
    await asCustomer();
    await backend.verifyArrivalPin(id, pin.pin);
    await asPro();
    await backend.updateProgress(id, BookingStatus.inProgress);
    await expectLater(backend.proposePrice(id, big, kind: PriceKind.total), _code('HMY_INSUFFICIENT_BALANCE'));
    // Si la propone el cliente, el profesional tampoco puede aceptarla sin saldo.
    await asCustomer();
    final offer = await backend.proposePrice(id, big, kind: PriceKind.total);
    await asPro();
    await expectLater(backend.acceptPriceOffer(offer), _code('HMY_INSUFFICIENT_BALANCE'));
    final d = await backend.detail(id);
    expect(d.price.total, 150, reason: 'el precio no cambia mientras no se acepta');
    expect((await backend.wallet()).available, available);
  });

  test('"No recibí el pago": una vez, solo el profesional, y el propietario devuelve la comisión', () async {
    final id = await _finished(backend);
    await asPro();
    final start = (await backend.wallet()).available;
    await expectLater(backend.reportPaymentNotReceived(id, 'No me pagó'), _code('HMY_INVALID_TRANSITION'));
    await asCustomer();
    await backend.acknowledgePayment(id, PaymentMethod.cash);
    await expectLater(backend.reportPaymentNotReceived(id, 'No me pagó'), _code('HMY_FORBIDDEN'));
    await asPro();
    expect((await backend.wallet()).available, start - 15);
    await backend.reportPaymentNotReceived(id, 'El cliente se fue sin pagar');
    await expectLater(backend.reportPaymentNotReceived(id, 'Otra vez'), _code('HMY_ALREADY_REPORTED'));
    expect((await backend.detail(id)).paymentReviewStatus, 'open');

    await backend.signInAs(DemoBackend.adminPhone);
    final report = await backend.ownerPaymentReviews();
    expect(report.open, 1);
    final r = report.items.single;
    expect(r.commissionAmount, 15);
    await backend.resolvePaymentReview(r.id, refund: true, note: 'El cliente no pagó', authMethod: 'otp');
    await expectLater(
      backend.resolvePaymentReview(r.id, refund: true, note: 'otra vez', authMethod: 'otp'),
      _code('HMY_ALREADY_REVIEWED'),
    );
    await asPro();
    final w = await backend.wallet();
    expect(w.available, start, reason: 'la comisión volvió una vez');
    expect(w.commissionsCollected, 0);
    expect((await backend.detail(id)).commissionCharged, 0);
  });

  test('una disputa cancelada después de "Ya pagué" devuelve la comisión', () async {
    final id = await _finished(backend);
    await asPro();
    final start = (await backend.wallet()).available;
    await asCustomer();
    await backend.acknowledgePayment(id, PaymentMethod.cash);
    await backend.openDispute(id, 'Quedó una fuga');
    await backend.signInAs(DemoBackend.adminPhone);
    await backend.resolveDispute(id, DisputeOutcome.cancelled, 'Trabajo incompleto');
    await asPro();
    expect((await backend.wallet()).available, start);
  });

  testWidgets('el texto de la comisión no muestra reservas ni comisiones pendientes', (tester) async {
    const pending = CommissionQuote(
      hasRule: true,
      ratePercent: 10,
      amount: 200,
      commission: 20,
      net: 180,
      available: 50,
      pendingDebt: 7,
      canCover: false,
      missing: 0,
    );
    const short = CommissionQuote(
      hasRule: true,
      ratePercent: 10,
      amount: 200,
      commission: 20,
      net: 180,
      available: 25,
      pendingDebt: 0,
      canCover: false,
      missing: 10,
      openCommissions: 15,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CommissionText(quote: pending),
              CommissionText(quote: short),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('pendiente'), findsNothing);
    expect(find.textContaining('eserv'), findsNothing);
    expect(find.textContaining('Escribe a soporte'), findsOneWidget);
    expect(find.textContaining('Te faltan ${Fmt.bs(10)}'), findsOneWidget);
    expect(find.textContaining('otros trabajos'), findsOneWidget);
  });

  group('pantallas', () {
    Future<void> pump(WidgetTester tester, DemoAppBackend app, Widget home) async {
      await initializeDateFormatting('es');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(390, 844) * 3;
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
            home: home,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('el profesional ve la comisión cobrada y pide revisión con "No recibí el pago"', (tester) async {
      _logins.clear();
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = await tester.runAsync(() async {
        final id = await _finished(app);
        await _customer(app);
        await app.acknowledgePayment(id, PaymentMethod.cash);
        await _pro(app);
        return id;
      });
      await pump(tester, app, BookingDetailPage(id: id!));
      // La comisión no está a la vista: va dentro de "Detalle financiero".
      expect(find.byKey(const Key('payment-commission')), findsNothing);
      await Scrollable.ensureVisible(tester.element(find.byKey(const Key('payment-finance'))), alignment: 0.3);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Detalle financiero'));
      await tester.pumpAndSettle();
      expect(find.text('Monto de la comisión: ${Fmt.bs(15)}'), findsOneWidget);
      final notPaid = find.byKey(const Key('pro-not-paid'));
      await tester.ensureVisible(notPaid);
      await tester.tap(notPaid);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'El cliente se fue sin pagar');
      await tester.tap(find.text('Pedir revisión'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pro-not-paid')), findsNothing);
      expect(find.byKey(const Key('payment-review')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el propietario ve la revisión y devuelve la comisión', (tester) async {
      _logins.clear();
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      await tester.runAsync(() async {
        final id = await _finished(app);
        await _customer(app);
        await app.acknowledgePayment(id, PaymentMethod.cash);
        await _pro(app);
        await app.reportPaymentNotReceived(id, 'El cliente se fue sin pagar');
        await app.signInAs(DemoBackend.adminPhone);
      });
      await pump(tester, app, const OwnerPaymentReviewsPage());
      expect(find.textContaining('El cliente se fue sin pagar'), findsOneWidget);
      expect(find.textContaining('Comisión cobrada: ${Fmt.bs(15)}'), findsOneWidget);
      expect(find.text('Devolver comisión'), findsOneWidget);
      expect(find.text('En revisión (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
