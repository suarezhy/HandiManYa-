import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/core/utils/formatters.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/wallet.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/admin/finance_pages.dart';
import 'package:handimanya/features/booking/booking_detail_page.dart';
import 'package:handimanya/features/pro_mode/wallet_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';
import 'support/price_helpers.dart';

// Build 42 (0067): la contraoferta es el NUEVO TOTAL (nunca se suma), solo el
// profesional que ya aceptó paga Bs 3 al cancelar, "No puedo" se puede
// deshacer mientras el pedido siga abierto, y la billetera muestra cada
// movimiento con su monto, su solicitud y el saldo que quedó.

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

// La demostración limita a 5 códigos por hora; pasado eso se entra con el correo.
final _logins = <String, int>{};
Future<void> _pro(DemoBackend b) => _login(b, DemoBackend.professionalPhone, DemoBackend.professionalEmail);
Future<void> _customer(DemoBackend b) => _login(b, DemoBackend.customerPhone, DemoBackend.customerEmail);
Future<void> _login(DemoBackend b, String phone, String email) async {
  final n = _logins[phone] = (_logins[phone] ?? 0) + 1;
  if (n <= 5) return b.signInAs(phone);
  await b.sendEmailLoginCode(email);
  await b.verifyEmailLoginCode(email: email, code: DemoBackend.demoCode);
}

/// Pedido ¡Ya! de Bs 150 acordado; la sesión queda en el profesional.
Future<String> _agreed(DemoBackend b) async {
  await _pro(b);
  await b.setAvailability(true);
  await _customer(b);
  final id = await b.create(_draft);
  await _pro(b);
  await agreeAsPro(b, id);
  return id;
}

void main() {
  late DemoBackend backend;

  setUp(() {
    _logins.clear();
    backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
  });
  tearDown(() => backend.dispose());

  group('"No puedo" y volver a tomar el pedido (69E3FD38)', () {
    test('después de "No puedo" el servidor dice por qué; volver a tomarlo deja aceptar el precio', () async {
      await _pro(backend);
      await backend.setAvailability(true);
      await _customer(backend);
      final id = await backend.create(_draft);
      await _pro(backend);
      await backend.decline(id, isOffer: true);
      await backend.decline(id, isOffer: true); // un segundo toque no rompe nada
      final d = await backend.detail(id);
      expect(d.declinedByMe, isTrue);
      final offer = d.price.customerOfferFor(backend.currentUser!.id);
      expect(offer, isNotNull);
      await expectLater(backend.acceptPriceOffer(offer!.id), _code('HMY_OFFER_DECLINED'));
      await backend.reopenOffer(id);
      expect((await backend.detail(id)).declinedByMe, isFalse);
      await backend.acceptPriceOffer(offer.id);
      final after = await backend.detail(id);
      expect(after.status, BookingStatus.confirmed);
      expect(after.price.total, 150);
    });
  });

  group('Contraoferta = nuevo total', () {
    test('130 sobre 100 deja el total en 130, no en 230; el precio no cambia mientras está pendiente', () async {
      await _pro(backend);
      await backend.setAvailability(true);
      await _customer(backend);
      final id = await backend.create(_draft);
      await _pro(backend);
      await agreeAsPro(backend, id);
      // Baja a 100 y luego sube a 130: cada número es el total.
      final down = await backend.proposePrice(id, 100, kind: PriceKind.total);
      expect((await backend.detail(id)).price.total, 150, reason: 'pendiente: el precio no cambia');
      await _customer(backend);
      await backend.acceptPriceOffer(down);
      expect((await backend.detail(id)).price.total, 100);
      await _pro(backend);
      final up = await backend.proposePrice(id, 130, kind: PriceKind.total);
      await _customer(backend);
      await backend.acceptPriceOffer(up);
      final c = await backend.detail(id);
      await _pro(backend);
      final p = await backend.detail(id);
      expect(c.price.total, 130, reason: 'cliente');
      expect(p.price.total, 130, reason: 'profesional: los dos ven lo mismo');
      expect(p.commissionAmount, 13, reason: '10 % del total final');
      // El historial guarda cada propuesta.
      expect(p.price.offers.where((o) => o.kind == PriceKind.total), hasLength(2));
    });

    test('el cliente también contraoferta; el otro puede rechazar y el precio se queda', () async {
      final id = await _agreed(backend);
      await _customer(backend);
      final offer = await backend.proposePrice(id, 120, kind: PriceKind.total);
      await _pro(backend);
      await backend.rejectPriceOffer(offer);
      expect((await backend.detail(id)).price.total, 150);
      await _customer(backend);
      final again = await backend.proposePrice(id, 140, kind: PriceKind.total);
      await _pro(backend);
      await backend.acceptPriceOffer(again);
      expect((await backend.detail(id)).price.total, 140);
    });

    test('el mismo precio y el viejo "monto aparte" se rechazan', () async {
      final id = await _agreed(backend);
      await expectLater(backend.proposePrice(id, 150, kind: PriceKind.total), _code('HMY_SAME_PRICE'));
      await expectLater(backend.proposePrice(id, 50, kind: PriceKind.extra), _code('HMY_INVALID_PRICE_KIND'));
    });

    test('una contraoferta nueva reemplaza a la pendiente: nunca quedan dos abiertas', () async {
      final id = await _agreed(backend);
      final first = await backend.proposePrice(id, 160, kind: PriceKind.total);
      await _customer(backend);
      await backend.proposePrice(id, 155, kind: PriceKind.total);
      await _pro(backend);
      await expectLater(backend.acceptPriceOffer(first), throwsA(isA<AppError>()));
      final d = await backend.detail(id);
      expect(d.price.offers.where((o) => o.kind == PriceKind.total && o.status == OfferStatus.open), hasLength(1));
      expect(d.price.total, 150, reason: 'el precio acordado no cambia mientras hay una contraoferta pendiente');
    });
  });

  group('Penalización por cancelar (Bs 3)', () {
    test('el profesional que ya aceptó paga Bs 3 una sola vez; queda en la billetera', () async {
      final id = await _agreed(backend);
      final start = (await backend.wallet()).available;
      await backend.cancel(id, '');
      await backend.cancel(id, ''); // un segundo toque no cobra otra vez
      expect((await backend.wallet()).available, start - 3);
      final d = await backend.detail(id);
      expect(d.cancelPenalty, 3);
      final rows = (await backend.ledger()).where((e) => e.type == LedgerType.penalty).toList();
      expect(rows, hasLength(1));
      expect(rows.single.amount, -3);
      expect(rows.single.bookingCode, d.code);
      expect(rows.single.balanceAfter, start - 3);
    });

    test('"No puedo" antes de aceptar y la cancelación del cliente no cuestan nada', () async {
      await _pro(backend);
      await backend.setAvailability(true);
      final start = (await backend.wallet()).available;
      await _customer(backend);
      final a = await backend.create(_draft);
      await _pro(backend);
      await backend.decline(a, isOffer: true);
      expect((await backend.wallet()).available, start);
      await _customer(backend);
      await backend.cancel(a, '');
      final b = await _agreed(backend);
      await _customer(backend);
      await backend.cancel(b, '');
      await _pro(backend);
      expect((await backend.wallet()).available, start);
      expect((await backend.ledger()).where((e) => e.type == LedgerType.penalty), isEmpty);
    });

    test('el propietario puede devolver la penalización una vez', () async {
      final id = await _agreed(backend);
      final start = (await backend.wallet()).available;
      await backend.cancel(id, '');
      await backend.signInAs(DemoBackend.adminPhone);
      final report = await backend.ownerPaymentReviews(status: 'all');
      expect(report.penalties.where((p) => p.bookingId == id), hasLength(1));
      await backend.waiveCancelPenalty(id, note: 'Emergencia familiar comprobada', authMethod: 'otp');
      await expectLater(backend.waiveCancelPenalty(id, note: 'otra vez', authMethod: 'otp'), throwsA(isA<AppError>()));
      await _pro(backend);
      expect((await backend.wallet()).available, start);
      expect((await backend.detail(id)).cancelPenaltyWaived, isTrue);
    });
  });

  group('pantallas', () {
    late SharedPreferences prefs;
    setUpAll(() async {
      await initializeDateFormatting('es');
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Future<void> pump(WidgetTester tester, DemoAppBackend app, Widget home) async {
      tester.view.physicalSize = const Size(390, 844) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
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

    testWidgets('Contraoferta: el profesional escribe el nuevo total y ve la diferencia y la comisión', (tester) async {
      _logins.clear();
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = await tester.runAsync(() => _agreed(app));
      await pump(tester, app, BookingDetailPage(id: id!));
      expect(find.text('Pedir monto aparte'), findsNothing);
      final button = find.byKey(const Key('price-counteroffer'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Contraoferta'), findsWidgets);
      await tester.enterText(find.byKey(const Key('counter-amount')), '130');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('counter-diff')),
          matching: find.textContaining('−${Fmt.bs(20)}', findRichText: true),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('counter-total')),
          matching: find.textContaining(Fmt.bs(130), findRichText: true),
        ),
        findsOneWidget,
      );
      expect(find.textContaining(Fmt.bs(13)), findsOneWidget, reason: '10 % del nuevo total');
      await tester.tap(find.byKey(const Key('counter-send')));
      await tester.pumpAndSettle();
      final d = await tester.runAsync(() => app.detail(id));
      expect(d!.price.total, 150, reason: 'cambia solo cuando el cliente acepte');
      expect(d.price.offers.last.kind, PriceKind.total);
      expect(d.price.offers.last.amount, 130);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el profesional confirma "¿Cancelar este trabajo?" con la penalización y sin motivo', (tester) async {
      _logins.clear();
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = await tester.runAsync(() => _agreed(app));
      await pump(tester, app, BookingDetailPage(id: id!));
      final cancel = find.text('Cancelar');
      await tester.ensureVisible(cancel.last);
      await tester.tap(cancel.last);
      await tester.pumpAndSettle();
      expect(find.text('¿Cancelar este trabajo?'), findsOneWidget);
      expect(find.textContaining('Penalización por cancelación: ${Fmt.bs(3)}'), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'sin campo de motivo');
      expect(find.text('Volver'), findsOneWidget);
      await tester.tap(find.text('Confirmar cancelación'));
      await tester.pumpAndSettle();
      final d = await tester.runAsync(() => app.detail(id));
      expect(d!.status, BookingStatus.cancelled);
      expect(d.cancelPenalty, 3);
      expect(find.byKey(const Key('cancel-penalty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Billetera: saldo total, recargar e historial con monto, solicitud y saldo (sin "—")', (tester) async {
      _logins.clear();
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final code = await tester.runAsync(() async {
        final id = await _agreed(app);
        await app.cancel(id, '');
        return (await app.detail(id)).code;
      });
      await pump(tester, app, const WalletPage());
      expect(find.byKey(const Key('wallet-total')), findsOneWidget);
      expect(find.byKey(const Key('wallet-recharge')), findsOneWidget);
      expect(find.textContaining('Comisiones cobradas'), findsNothing);
      expect(find.text('Solicitud #$code'), findsOneWidget);
      expect(find.text('−${Fmt.bs(3)}'), findsOneWidget);
      expect(find.text('—'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el propietario ve las penalizaciones y puede devolverlas', (tester) async {
      _logins.clear();
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = await tester.runAsync(() async {
        final id = await _agreed(app);
        await app.cancel(id, '');
        await app.signInAs(DemoBackend.adminPhone);
        return id;
      });
      await pump(tester, app, const OwnerPaymentReviewsPage());
      final row = find.byKey(Key('owner-penalty-$id'));
      await tester.ensureVisible(row);
      expect(row, findsOneWidget);
      expect(find.byKey(Key('owner-penalty-waive-$id')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
