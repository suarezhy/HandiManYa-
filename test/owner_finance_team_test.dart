import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/core/utils/formatters.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/drilldown.dart';
import 'package:handimanya/data/models/finance.dart';
import 'package:handimanya/data/models/staff.dart';
import 'package:handimanya/data/models/wallet.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/admin/admin_money_pages.dart';
import 'package:handimanya/features/admin/drilldown_pages.dart';
import 'package:handimanya/features/admin/finance_pages.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Finanzas y Bancos y Agregar al equipo (Build 13): solo el Propietario, con
/// código para cada cambio. El servidor lo vuelve a revisar (99g y 99h).

Future<(DemoAppBackend, ProviderContainer)> _pump(WidgetTester tester, {Size size = const Size(390, 844)}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const HandiManYaApp()));
  await tester.pumpAndSettle();
  await loginWithPhone(tester, DemoBackend.adminPhone);
  return (backend, container);
}

String _location(ProviderContainer c) => c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

Future<void> _go(WidgetTester tester, ProviderContainer c, String route) async {
  c.read(routerProvider).push(route);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// "Confirma que eres tú" con el código de la demostración.
Future<void> _confirmWithCode(WidgetTester tester) async {
  expect(find.text('Confirma que eres tú'), findsOneWidget);
  expect(find.byKey(const Key('confirm-fingerprint')), findsNothing, reason: 'solo código');
  await _tap(tester, find.byKey(const Key('confirm-submit')));
  await tester.enterText(find.byKey(const Key('confirm-code-field')), DemoBackend.demoCode);
  await tester.pumpAndSettle();
}

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

void main() {
  test('celular y cuenta enmascarados como en la base', () {
    expect(maskPhone('+59170000005'), '+591 7••• ••05');
    expect(maskPhone('59177099502'), '+591 7••• ••02');
    expect(maskPhone('123'), isNull);
    expect(maskAccount('1000-123-456'), '•••• 3456');
    expect(maskAccount('12'), '••••');
  });

  group('demostración: mismas reglas que la base', () {
    late DemoBackend b;
    setUp(() async {
      b = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
      await b.signInAs(DemoBackend.adminPhone);
    });
    tearDown(() => b.dispose());

    test('un comprobante no es dinero en el banco; conciliar pide referencia y código', () async {
      final pending = await b.topupsForReconciliation('pendiente');
      expect(pending, isNotEmpty);
      final t = pending.first;
      await expectLater(
        b.reconcileTopup(t.id, BankStatus.reconciled, bankReference: 'X', authMethod: 'otp'),
        _code('HMY_TOPUP_NOT_CREDITED'),
      );
      final before = await b.financeSummary();
      await b.reviewTopup(t.id, approve: true);
      final after = await b.financeSummary();
      expect(after.walletFundsReceivedBs - before.walletFundsReceivedBs, t.amount);
      expect(after.walletFundsUnverifiedBs - before.walletFundsUnverifiedBs, t.amount);
      expect(after.commissionEarnedBs, before.commissionEarnedBs, reason: 'una recarga no es un ingreso');
      expect(after.bankConnected, isFalse);
      await expectLater(
        b.reconcileTopup(t.id, BankStatus.reconciled, authMethod: 'otp'),
        _code('HMY_BANK_REFERENCE_REQUIRED'),
      );
      await expectLater(
        b.reconcileTopup(t.id, BankStatus.reconciled, bankReference: 'BNB-1', authMethod: 'biometric'),
        _code('HMY_CONFIRMATION_REQUIRED'),
      );
      // El código del inicio de sesión vale para una sola operación.
      await b.reconcileTopup(t.id, BankStatus.notFound, authMethod: 'otp');
      await expectLater(
        b.reconcileTopup(t.id, BankStatus.reconciled, bankReference: 'BNB-1', authMethod: 'otp'),
        _code('HMY_CONFIRMATION_EXPIRED'),
        reason: 'sin un código recién verificado',
      );
      await b.confirmWithCode();
      await b.reconcileTopup(t.id, BankStatus.reconciled, bankReference: 'BNB-1', authMethod: 'otp');
      final s = await b.financeSummary();
      expect(s.walletFundsReconciledBs - before.walletFundsReconciledBs, t.amount);
      expect((await b.financeAudit()).first.action, 'finance.reconcile');
    });

    test('cuentas de cobro: código para cada cambio y vuelve a sin verificar', () async {
      const draft = ReceivingAccountDraft(
        label: 'BNB principal',
        type: ReceivingAccountType.savings,
        bankName: 'Banco Nacional de Bolivia',
        holderName: 'HandiMan Ya SRL',
        accountNumber: '1000123456',
      );
      final id = await b.saveReceivingAccount(draft, authMethod: 'otp');
      await expectLater(
        b.setReceivingAccount(id, active: true, verified: true, authMethod: 'otp'),
        _code('HMY_CONFIRMATION_EXPIRED'),
        reason: 'el código del inicio de sesión ya se usó',
      );
      await b.confirmWithCode();
      await b.setReceivingAccount(id, active: true, verified: true, authMethod: 'otp');
      expect((await b.receivingAccounts()).single.verified, isTrue);
      await b.confirmWithCode();
      await b.saveReceivingAccount(
        ReceivingAccountDraft(
          id: id,
          label: draft.label,
          type: draft.type,
          bankName: draft.bankName,
          holderName: draft.holderName,
          accountNumber: '1000999888',
        ),
        authMethod: 'otp',
      );
      final a = (await b.receivingAccounts()).single;
      expect(a.verified, isFalse);
      expect(a.accountMasked, '•••• 9888');
      expect((await b.financeAudit()).every((e) => !'${e.details}'.contains('1000999888')), isTrue);
    });

    test('equipo: buscar por celular, enmascarado, y dar el rol con código', () async {
      expect(await b.staffCandidates('70000005'), isEmpty, reason: 'ese número no tiene cuenta');
      final c = (await b.staffCandidates('7123 4567')).single;
      expect(c.phoneMasked, '+591 7••• ••67');
      expect(c.eligible, isTrue);
      expect((await b.staffCandidates('73000011')).single.reason, 'already_staff');
      expect((await b.staffCandidates('70000000')).single.reason, 'self');
      await expectLater(
        b.grantStaff(c.id, StaffRole.employee, authMethod: 'biometric'),
        _code('HMY_CONFIRMATION_REQUIRED'),
      );
      await b.grantStaff(c.id, StaffRole.employee, authMethod: 'otp');
      await expectLater(b.grantStaff(c.id, StaffRole.employee, authMethod: 'otp'), _code('HMY_ALREADY_STAFF'));
      // Reactivar devuelve el acceso: código otra vez.
      await b.setStaffStatus(c.id, 'revoked', reason: 'Prueba de quitar acceso');
      await expectLater(b.setStaffStatus(c.id, 'active'), _code('HMY_CONFIRMATION_REQUIRED'));
      await expectLater(b.setStaffStatus(c.id, 'active', authMethod: 'otp'), _code('HMY_CONFIRMATION_EXPIRED'));
      await b.confirmWithCode();
      await b.setStaffStatus(c.id, 'active', authMethod: 'otp');
      final m = (await b.staffOverview()).firstWhere((m) => m.userId == c.id);
      expect(m.isActive, isTrue);
      expect(m.phoneMasked, '+591 7••• ••67');
    });

    test('el gerente y el empleado no llegan a Finanzas ni al buscador del equipo', () async {
      for (final phone in [DemoBackend.managerPhone, DemoBackend.employeePhones.first]) {
        await b.signInAs(phone);
        for (final call in <Future<Object?> Function()>[
          b.financeSummary,
          b.financeTransactions,
          b.receivingAccounts,
          b.financeAudit,
          () => b.topupsForReconciliation('todas'),
          () => b.reconcileTopup(1, BankStatus.reconciled, bankReference: 'X', authMethod: 'otp'),
          () => b.staffCandidates('7123'),
          () => b.grantStaff('demo-empleado-2', StaffRole.manager, authMethod: 'otp'),
        ]) {
          await expectLater(call(), _code('HMY_FORBIDDEN'), reason: phone);
        }
      }
    });
  });

  testWidgets('Finanzas y Bancos: desde Gestión, separa ingresos de billeteras y concilia con código', (tester) async {
    final (backend, c) = await _pump(tester);
    await tester.tap(find.byKey(const Key('panel-nav-Gestión')));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('owner-finance')));
    expect(find.text('Finanzas y Bancos'), findsWidgets);
    expect(find.byKey(const Key('finance-bank-pending')), findsOneWidget);
    expect(find.text('Ingresos de la plataforma'), findsOneWidget);
    expect(find.text('Fondos de billeteras (son de los profesionales)'), findsOneWidget);
    expect(find.textContaining('Un comprobante subido no prueba'), findsOneWidget);
    expect(find.text('Pendiente de configuración'), findsOneWidget, reason: 'sin cuentas de cobro');
    // El mes siguiente no existe todavía; el anterior sí.
    expect(tester.widget<IconButton>(find.byKey(const Key('finance-next-month'))).onPressed, isNull);
    await _tap(tester, find.byKey(const Key('finance-prev-month')));
    await _tap(tester, find.byKey(const Key('finance-next-month')));

    // Una recarga acreditada queda "sin verificar" hasta conciliarla.
    final t = (await backend.topupsForReconciliation('pendiente')).first;
    await tester.runAsync(() => backend.reviewTopup(t.id, approve: true));
    await _go(tester, c, Routes.adminFinanceReconcile);
    await tester.pumpAndSettle();
    expect(find.byKey(Key('reconcile-${t.id}')), findsOneWidget);
    expect(find.text('Sin verificar'), findsWidgets);
    await _tap(tester, find.byKey(Key('reconcile-ok-${t.id}')));
    await _tap(tester, find.byKey(const Key('reconcile-continue')));
    expect(find.text('Escribe la referencia del extracto'), findsOneWidget, reason: 'sin referencia no sigue');
    await tester.enterText(find.byKey(const Key('reconcile-reference')), 'BNB-778812');
    await _tap(tester, find.byKey(const Key('reconcile-continue')));
    await _confirmWithCode(tester);
    expect(
      (await tester.runAsync(() => backend.topupsForReconciliation('conciliada')))!.map((x) => x.id),
      contains(t.id),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('cada tarjeta de Finanzas abre su lista, con el mismo total y filtros', (tester) async {
    final (backend, c) = await _pump(tester);
    // Una recarga acreditada este mes, sin conciliar.
    final t = (await backend.topupsForReconciliation('pendiente')).first;
    await tester.runAsync(() => backend.reviewTopup(t.id, approve: true));
    await _go(tester, c, Routes.adminFinance);
    // La etiqueta ya no se corta ("Saldos disponibles (0").
    expect(find.text('Saldos disponibles'), findsOneWidget);
    expect(find.textContaining('Saldos disponibles ('), findsNothing);

    // Cada tarjeta abre la pantalla correcta, ya filtrada, y "atrás" vuelve.
    final month = '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}';
    bool movements(String kind) => tester
        .widgetList<FinanceMovementsPage>(find.byType(FinanceMovementsPage))
        .any((p) => p.initialKind == kind && p.month == month);
    bool topups(TopupFilter f, String? m) => tester
        .widgetList<FinanceReconcilePage>(find.byType(FinanceReconcilePage))
        .any((p) => p.initialFilter == f && p.month == m);
    bool wallets(WalletSort s) =>
        tester.widgetList<OwnerWalletsPage>(find.byType(OwnerWalletsPage)).any((p) => p.initialSort == s);
    final cases = <(String, bool Function())>[
      ('fin-card-commission', () => movements('commission_capture')),
      ('fin-card-commission-jobs', () => movements('commission_capture')),
      ('fin-card-credited', () => topups(TopupFilter.credited, month)),
      ('fin-card-reconciled', () => topups(TopupFilter.reconciled, month)),
      ('fin-card-unverified', () => topups(TopupFilter.unverified, month)),
      ('fin-card-not-found', () => topups(TopupFilter.notFound, month)),
      ('fin-card-available', () => wallets(WalletSort.available)),
      ('fin-card-reserved', () => wallets(WalletSort.reserved)),
      ('fin-card-pending', () => find.byType(AdminTopupsPage).evaluate().isNotEmpty),
      ('fin-card-unverified-all', () => topups(TopupFilter.unverified, null)),
    ];
    for (final (card, opened) in cases) {
      await _tap(tester, find.byKey(Key(card)));
      expect(opened(), isTrue, reason: card);
      await tester.binding.handlePopRoute(); // atrás del sistema
      await tester.pumpAndSettle();
      expect(find.byKey(Key(card)), findsOneWidget, reason: 'vuelve a Finanzas desde $card');
    }

    // La lista de "sin conciliar" de este mes trae la recarga y su total.
    await _tap(tester, find.byKey(const Key('fin-card-unverified')));
    expect(find.byKey(Key('reconcile-${t.id}')), findsOneWidget);
    final list = (await tester.runAsync(() => backend.financeTopups(TopupFilter.unverified, month: DateTime.now())))!;
    expect(
      find.text('${list.total} ${list.total == 1 ? 'recarga' : 'recargas'} · ${Fmt.bs(list.sumBs)}'),
      findsOneWidget,
    );
    // Buscar algo que no existe deja la lista vacía, con su mensaje.
    await tester.enterText(find.byKey(const Key('topups-search')), 'zzz-no-existe');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('reconcile-${t.id}')), findsNothing);
    expect(find.textContaining('No hay recargas acreditadas sin conciliar'), findsOneWidget);
    // Otro estado, con chips.
    await tester.enterText(find.byKey(const Key('topups-search')), '');
    await tester.pump(const Duration(seconds: 1));
    await _tap(tester, find.byKey(const Key('topups-filter-TopupFilter.reconciled')));
    expect(find.byKey(Key('reconcile-${t.id}')), findsNothing, reason: 'todavía no está conciliada');
    // Todos los meses.
    await _tap(tester, find.byKey(const Key('topups-filter-TopupFilter.credited')));
    await _tap(tester, find.byKey(const Key('month-all')));
    expect(find.text('Todos los meses'), findsOneWidget);
    expect(find.byKey(Key('reconcile-${t.id}')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Movimientos: recargas del mes, con referencia y estado del banco.
    await _go(tester, c, '${Routes.adminFinanceMovements}?tipo=topup');
    expect(find.text('Todos los meses'), findsOneWidget, reason: 'sin mes en el enlace');
    expect(find.textContaining('Banco: Sin verificar'), findsWidgets);
    expect(find.byKey(const Key('finance-count')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('panel: cada fila de demanda y de "Sin cobertura" abre sus pedidos, con el mismo número', (tester) async {
    final (backend, c) = await _pump(tester);
    final d = (await tester.runAsync(backend.adminDashboard))!;
    expect(d.demandMunicipality, isNotEmpty, reason: 'la demostración tiene pedidos recientes');
    final cases = [
      for (final r in d.demandMunicipality.take(2)) ('municipio', r),
      for (final r in d.demandDepartment.take(1)) ('departamento', r),
      for (final r in d.demandCategory.take(2)) ('categoria', r),
      for (final r in d.coverageGaps.take(1)) ('municipio-gap', r),
    ];
    for (final (kind, r) in cases) {
      final row = find.byKey(Key('demand-$kind-${r.name}'));
      await tester.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text(r.count == 1 ? '1 pedido' : '${r.count} pedidos'), findsOneWidget, reason: '$kind ${r.name}');
      if (kind.startsWith('municipio')) expect(find.byKey(const Key('demand-coverage')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('cuenta de cobro: atrás con cambios pregunta, guardar pide código y la muestra enmascarada', (
    tester,
  ) async {
    final (backend, c) = await _pump(tester);
    await _go(tester, c, Routes.adminFinanceAccounts);
    expect(find.textContaining('Pendiente de configuración'), findsOneWidget);
    expect(find.textContaining('Nunca escribas aquí contraseñas'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('receiving-add')));
    await tester.enterText(find.byKey(const Key('receiving-label')), 'BNB principal');
    await tester.pumpAndSettle();
    // Atrás con cambios: pregunta y no pierde lo escrito.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('¿Salir sin guardar?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('unsaved-keep-editing')));
    await tester.pumpAndSettle();
    expect(find.text('BNB principal'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('receiving-bank')), 'Banco Nacional de Bolivia');
    await tester.enterText(find.byKey(const Key('receiving-holder')), 'HandiMan Ya SRL');
    await tester.enterText(find.byKey(const Key('receiving-number')), 'abc');
    await _tap(tester, find.byKey(const Key('receiving-save')));
    expect(find.text('Solo números, espacios o guiones'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('receiving-number')), '1000123456');
    await _tap(tester, find.byKey(const Key('receiving-save')));
    expect(find.text('Número: •••• 3456'), findsOneWidget, reason: 'la confirmación no muestra el número completo');
    await _confirmWithCode(tester);
    expect(find.byKey(const Key('receiving-save')), findsNothing, reason: 'volvió a la lista');
    expect(find.text('Cuenta •••• 3456'), findsOneWidget);
    expect(find.text('Sin verificar'), findsOneWidget);
    expect(find.textContaining('1000123456'), findsNothing);
    expect((await tester.runAsync(backend.receivingAccounts))!.single.accountNumber, '1000123456');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Agregar al equipo: explica cuando no hay cuenta y da el rol con confirmación y código', (tester) async {
    final (backend, c) = await _pump(tester);
    await tester.tap(find.byKey(const Key('panel-nav-Equipo')));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('team-add')));
    expect(find.byKey(const Key('team-search')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('team-search')), '70000005');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('team-search-empty')), findsOneWidget);
    expect(find.text('No hay ninguna cuenta con ese celular'), findsOneWidget);
    expect(find.textContaining('descargue HandiMan ¡Ya! y entre con su celular'), findsOneWidget);

    // Alguien que ya es del equipo aparece, pero no se puede elegir.
    await tester.enterText(find.byKey(const Key('team-search')), '73000011');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ya es Empleado'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('team-search')), '71234567');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('1 cuenta encontrada'), findsOneWidget);
    expect(find.textContaining('+591 7••• ••67'), findsOneWidget);
    final customer = (await tester.runAsync(() => backend.staffCandidates('71234567')))!.single;
    expect(
      find.descendant(of: find.byKey(Key('team-pick-${customer.id}')), matching: find.textContaining('71234567')),
      findsNothing,
      reason: 'el resultado no muestra el número completo',
    );
    await _tap(tester, find.byKey(Key('team-pick-${customer.id}')));
    expect(find.text('¿Dar el rol de Empleado?'), findsOneWidget);
    expect(find.textContaining('ID de la cuenta: ${customer.id}'), findsOneWidget);
    await tester.tap(find.text('Sí, continuar'));
    await tester.pumpAndSettle();
    await _confirmWithCode(tester);
    expect(_location(c), Routes.ownerTeam);
    expect(find.byKey(Key('member-${customer.id}')), findsOneWidget);
    expect(find.textContaining('Empleado · +591 7••• ••67'), findsWidgets);
    final team = (await tester.runAsync(backend.staffOverview))!;
    expect(team.firstWhere((m) => m.userId == customer.id).role, StaffRole.employee);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el gerente no abre Finanzas ni Agregar al equipo', (tester) async {
    await initializeDateFormatting('es');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const HandiManYaApp()));
    await tester.pumpAndSettle();
    await loginWithPhone(tester, DemoBackend.managerPhone);
    for (final r in [
      Routes.adminFinance,
      Routes.adminFinanceAccounts,
      Routes.adminFinanceReconcile,
      Routes.adminFinanceMovements,
      Routes.ownerTeamAdd,
    ]) {
      c.read(routerProvider).go(r);
      await tester.pumpAndSettle();
      expect(_location(c), Routes.manager, reason: r);
    }
    expect(find.textContaining('Finanzas'), findsNothing);
  });

  test('LedgerType de comisión es el único ingreso', () {
    expect(
      FinanceTransaction(
        id: 1,
        professionalId: 'p',
        entryType: 'commission_capture',
        availableDelta: 3,
        reservedDelta: -15,
        createdAt: DateTime(2026),
      ).platformRevenue,
      12,
    );
    expect(
      FinanceTransaction(
        id: 2,
        professionalId: 'p',
        entryType: 'topup',
        availableDelta: 100,
        reservedDelta: 0,
        createdAt: DateTime(2026),
      ).platformRevenue,
      0,
    );
    expect(LedgerType.parse('commission_capture'), LedgerType.commissionCapture);
  });
}
