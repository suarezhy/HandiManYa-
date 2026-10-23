import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/ai_control.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/drilldown.dart';
import 'package:handimanya/data/models/staff.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/management/cases_pages.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Cada número del panel abre la lista que lo explica, con el mismo total, y
/// cada rol ve solo lo suyo. El servidor lo vuelve a revisar (99j).

Future<(DemoAppBackend, ProviderContainer)> _pump(WidgetTester tester, String phone) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.physicalSize = const Size(390, 844) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const HandiManYaApp()));
  await tester.pumpAndSettle();
  await loginWithPhone(tester, phone);
  return (backend, container);
}

String _location(ProviderContainer c) => c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

const _ya = BookingDraft(
  categoryId: 2,
  cityId: 1,
  zoneId: 12,
  mode: BookingMode.now,
  description: 'Se cortó la luz en la cocina',
  address: 'Calle Los Pinos 123',
  paymentMethod: PaymentMethod.cash,
);

/// Un pedido nuevo de la clienta de la demostración; vuelve a entrar como [phone].
Future<String> _newBooking(DemoBackend b, String phone) async {
  await b.signInAs(DemoBackend.professionalPhone);
  await b.setAvailability(true);
  await b.signInAs(DemoBackend.customerPhone);
  final id = await b.create(_ya);
  await b.signInAs(phone);
  return id;
}

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

void main() {
  group('demostración: el total de cada lista es el número del panel', () {
    late DemoBackend b;
    setUp(() async {
      b = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
      await b.signInAs(DemoBackend.adminPhone);
    });
    tearDown(() => b.dispose());

    test('pedidos, personas, casos, riesgos, billeteras y Centro IA', () async {
      final d = await b.adminDashboard();
      expect((await b.opsBookings(BookingFilter.today)).total, d.bookingsToday);
      expect((await b.opsBookings(BookingFilter.active)).total, d.activeBookings);
      expect((await b.opsBookings(BookingFilter.completedToday)).total, d.completedToday);
      expect((await b.opsBookings(BookingFilter.cancelledToday)).total, d.cancelledToday);
      final month = await b.opsBookings(BookingFilter.completedMonth);
      expect(month.items.fold<double>(0, (t, x) => t + (x.finalAmount ?? 0)), d.revenueMonth);
      expect((await b.adminPeople(PeopleFilter.customers)).total, d.customers);
      expect((await b.adminPeople(PeopleFilter.professionals)).total, d.approvedProfessionals);
      expect((await b.adminPeople(PeopleFilter.available)).total, d.availableProfessionals);
      expect((await b.opsCases(scope: 'urgent')).length, d.urgentCases);
      expect((await b.opsCases(scope: 'escalated_owner')).length, d.escalatedToOwner);
      expect((await b.opsCases(scope: 'unassigned')).length, d.unassignedCases);
      expect((await b.riskItems(RiskKind.safety)).total, d.safetyIncidents);
      expect((await b.riskItems(RiskKind.fraud)).total, d.fraudAlerts);
      final w = await b.ownerWallets();
      expect(w.available, d.walletAvailable);
      expect(w.reserved, d.walletReserved);
      final pending = await b.aiItems(statuses: const ['pending_approval', 'open', 'more_info']);
      expect(pending.length, d.aiPending);
      expect(
        pending.where((i) => i.severity == AiSeverity.high || i.severity == AiSeverity.critical).length,
        d.aiCritical,
      );
    });

    test('un caso desde un pedido: motivo, una sola vez, urgente si es fraude y auditado', () async {
      final bookingId = await _newBooking(b, DemoBackend.adminPhone);
      final booking = (await b.opsBookingDetail(bookingId)).booking;
      expect(booking.openCaseId, isNull);
      expect((await b.opsBookingDetail(bookingId)).toString().contains('Los Pinos'), isFalse);
      await expectLater(b.openBookingCase(booking.id, 'no'), _code('HMY_REASON_REQUIRED'));
      final id = await b.openBookingCase(booking.id, 'El cliente dice que cobró de más', category: 'fraud');
      expect(await b.openBookingCase(booking.id, 'Otra vez el mismo pedido'), id, reason: 'no duplica');
      final c = (await b.opsCases(scope: 'urgent')).firstWhere((c) => c.id == id);
      expect(c.kind, OpsCaseKind.booking);
      expect(c.category, 'fraud');
      final detail = await b.opsCaseDetail(id);
      expect(detail.s('code'), booking.code);
      expect(detail.source.containsKey('final_amount'), isFalse, reason: 'el caso no lleva montos');
      expect((await b.opsBookingDetail(booking.id)).booking.openCaseId, id);
      expect((await b.auditLog()).any((e) => e.action == 'case.open_booking'), isTrue);
    });

    test('el gerente ve pedidos sin montos y riesgos sin Centro IA; no ve billeteras', () async {
      await b.signInAs(DemoBackend.managerPhone);
      final list = await b.opsBookings(BookingFilter.recent);
      expect(list.items, isNotEmpty);
      expect(
        list.items.every(
          (x) =>
              x.finalAmount == null &&
              x.quoteAmount == null &&
              x.commissionReserved == null &&
              x.commissionCaptured == null,
        ),
        isTrue,
      );
      expect((await b.riskItems(RiskKind.fraud)).items.where((i) => i.source == 'ai'), isEmpty);
      await expectLater(b.ownerWallets(), _code('HMY_FORBIDDEN'));
      await expectLater(b.financeTransactions(professionalId: 'demo-pro-1'), _code('HMY_FORBIDDEN'));
    });

    test('el empleado, el profesional y el cliente no llegan a ninguna lista', () async {
      for (final phone in [DemoBackend.employeePhones.first, DemoBackend.customerPhone]) {
        await b.signInAs(phone);
        for (final call in <Future<Object?> Function()>[
          () => b.opsBookings(BookingFilter.today),
          () => b.opsBookingDetail('x'),
          () => b.openBookingCase('x', 'Revisar esto'),
          () => b.adminPeople(PeopleFilter.all),
          () => b.riskItems(RiskKind.safety),
          b.ownerWallets,
        ]) {
          await expectLater(call(), _code('HMY_FORBIDDEN'), reason: phone);
        }
      }
    });
  });

  testWidgets('el propietario: cada número abre su lista y vuelve al panel', (tester) async {
    final (backend, c) = await _pump(tester, DemoBackend.adminPhone);
    final d = (await tester.runAsync(backend.adminDashboard))!;
    final checks = <(String, String, String)>[
      ('owner-stat-bookings-today', Routes.opsBookings, 'Pedidos de hoy'),
      ('owner-stat-urgent', Routes.staffCases, 'Casos'),
      ('owner-stat-safety', Routes.adminRisk, 'Incidentes de seguridad'),
      ('owner-stat-customers', Routes.adminUsers, 'Clientes'),
      ('owner-stat-revenue', Routes.opsBookings, 'Completados este mes'),
      ('owner-stat-commission', Routes.adminFinanceMovements, 'Movimientos'),
      ('owner-stat-wallets', Routes.adminFinanceWallets, 'Billeteras de profesionales'),
      ('owner-stat-ai-high', Routes.adminAiDecisions, 'Alertas IA altas o críticas'),
    ];
    for (final (key, route, title) in checks) {
      await _tap(tester, find.byKey(Key(key)));
      expect(find.widgetWithText(AppBar, title), findsOneWidget, reason: key);
      expect(tester.takeException(), isNull, reason: key);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_location(c), Routes.admin, reason: 'atrás vuelve al panel desde $route');
    }
    // El total de la lista es el número de la tarjeta.
    await _tap(tester, find.byKey(const Key('owner-stat-customers')));
    expect(find.text(d.customers == 1 ? '1 persona' : '${d.customers} personas'), findsOneWidget);
    expect(find.byKey(const Key('people-filter-clientes')), findsOneWidget);
  });

  testWidgets('pedido: detalle sin dirección, montos para el propietario y abrir un caso', (tester) async {
    final (backend, c) = await _pump(tester, DemoBackend.adminPhone);
    final booking = (await tester.runAsync(() async {
      final id = await _newBooking(backend, DemoBackend.adminPhone);
      return (await backend.opsBookingDetail(id)).booking;
    }))!;
    await tester.pumpAndSettle();
    c.read(routerProvider).push(Routes.opsBookingsFiltered(BookingFilter.recent));
    await tester.pumpAndSettle();
    // Buscar por código.
    await tester.enterText(find.byKey(const Key('bookings-search')), booking.code);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('1 pedido'), findsOneWidget);
    await _tap(tester, find.byKey(Key('ops-booking-${booking.code}')));
    expect(find.byKey(const Key('booking-privacy')), findsOneWidget);
    expect(find.text('Dinero (solo propietario)'), findsOneWidget);
    expect(find.text('Historial del pedido'), findsOneWidget);
    // Abrir un caso: elegir el tipo, escribir el motivo, confirmar.
    await _tap(tester, find.byKey(const Key('booking-open-case')));
    await _tap(tester, find.byKey(const Key('open-case-continue')));
    expect(find.text('Escribe qué hay que revisar'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('open-case-safety')));
    await tester.enterText(find.byKey(const Key('open-case-reason')), 'La clienta reportó una mala experiencia');
    await _tap(tester, find.byKey(const Key('open-case-continue')));
    expect(find.text('¿Abrir un caso para el pedido ${booking.code}?'), findsOneWidget);
    await tester.tap(find.text('Abrir caso'));
    await tester.pumpAndSettle();
    expect(find.byType(CaseDetailPage), findsOneWidget);
    expect(find.text('Revisar el pedido ${booking.code}'), findsOneWidget);
    expect(find.byKey(const Key('case-open-booking')), findsOneWidget);
    final cases = (await tester.runAsync(() => backend.opsCases(scope: 'urgent')))!;
    expect(cases.where((x) => x.kind == OpsCaseKind.booking && x.category == 'safety'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('billeteras: totales, orden y movimientos de una sola persona', (tester) async {
    final (backend, c) = await _pump(tester, DemoBackend.adminPhone);
    c.read(routerProvider).push(Routes.adminFinanceWallets);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wallets-totals')), findsOneWidget);
    expect(find.textContaining('no un ingreso de la plataforma'), findsOneWidget);
    final w = (await tester.runAsync(backend.ownerWallets))!.items.first;
    await _tap(tester, find.byKey(Key('wallet-${w.professionalId}')));
    expect(find.widgetWithText(AppBar, 'Movimientos de ${w.name}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el gerente abre los pedidos sin montos; las billeteras no', (tester) async {
    final (_, c) = await _pump(tester, DemoBackend.managerPhone);
    await _tap(tester, find.byKey(const Key('manager-stat-bookings-today')));
    expect(find.widgetWithText(AppBar, 'Pedidos de hoy'), findsOneWidget);
    expect(find.textContaining('Pagado al profesional'), findsNothing);
    expect(find.textContaining('comisión'), findsNothing);
    for (final r in [Routes.adminFinanceWallets, '${Routes.adminFinanceMovements}?tipo=commission_capture']) {
      c.read(routerProvider).go(r);
      await tester.pumpAndSettle();
      expect(_location(c), Routes.manager, reason: r);
    }
  });

  testWidgets('el empleado no abre pedidos, riesgos ni personas', (tester) async {
    final (_, c) = await _pump(tester, DemoBackend.employeePhones.first);
    for (final r in [Routes.opsBookings, Routes.opsBooking('x'), Routes.adminRisk, Routes.adminUsers]) {
      c.read(routerProvider).go(r);
      await tester.pumpAndSettle();
      expect(_location(c), Routes.employee, reason: r);
    }
  });
}
