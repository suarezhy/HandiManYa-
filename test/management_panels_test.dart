import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/staff.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Los tres paneles de gestión: cada rol entra directo al suyo, con su barra,
/// y la app no muestra lo que el rol no puede ver. El servidor lo vuelve a
/// revisar (supabase/tests/99d y 99f); aquí se prueba la app.

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
  return (backend, container);
}

String _location(ProviderContainer c) => c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

Future<void> _go(WidgetTester tester, ProviderContainer c, String route) async {
  c.read(routerProvider).go(route);
  await tester.pumpAndSettle();
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(Key('panel-nav-$label')));
  await tester.pumpAndSettle();
}

const _money = ['Bs', 'Recargas', 'Comisiones', 'Saldo', 'billetera', 'Ingresos', 'Costos'];

void _expectNoMoney(WidgetTester tester, String where) {
  for (final w in _money) {
    expect(find.textContaining(w), findsNothing, reason: '$where no muestra "$w"');
  }
}

void main() {
  for (final size in const [Size(320, 568), Size(390, 844), Size(820, 1180)]) {
    testWidgets('el propietario entra directo a su panel (${size.width.toInt()} px)', (tester) async {
      final (_, c) = await _pump(tester, size: size);
      await loginWithPhone(tester, DemoBackend.adminPhone);
      expect(_location(c), Routes.admin);
      expect(find.byKey(const Key('panel-title-owner')), findsOneWidget);
      expect(find.byKey(const Key('panel-nav-owner')), findsOneWidget);
      expect(find.byKey(const Key('owner-summary')), findsOneWidget);
      // Sin "Modo cliente", "Quiero ser profesional" ni promociones.
      expect(find.text('Modo cliente'), findsNothing);
      expect(find.text('Quiero ser profesional'), findsNothing);
      // Números reales del panel, con el dinero solo aquí.
      expect(find.text('Dinero (solo propietario)'), findsOneWidget);
      expect(find.byKey(const Key('owner-identity-sandbox')), findsOneWidget);
      for (final tab in ['Gestión', 'Centro IA', 'Equipo', 'Perfil', 'Resumen']) {
        await _tab(tester, tab);
        expect(tester.takeException(), isNull, reason: tab);
      }
    });
  }

  testWidgets('el propietario ve el equipo y su perfil con permisos', (tester) async {
    final (_, c) = await _pump(tester);
    await loginWithPhone(tester, DemoBackend.adminPhone);
    await _tab(tester, 'Equipo');
    expect(find.text('Lucía Fernández'), findsOneWidget);
    expect(find.byKey(const Key('team-add')), findsOneWidget);
    for (final name in ['Diego Rojas', 'Paola Quiroga', 'Marco Antezana', 'Elena Vargas', 'Tomás Céspedes']) {
      await tester.scrollUntilVisible(find.text(name), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text(name), findsOneWidget);
    }
    await _tab(tester, 'Perfil');
    expect(find.byKey(const Key('staff-profile-owner')), findsOneWidget);
    expect(find.byKey(const Key('owner-permissions')), findsOneWidget);
    expect(_location(c), Routes.ownerProfile);
  });

  testWidgets('modo cliente del propietario y vuelta al panel', (tester) async {
    final (_, c) = await _pump(tester);
    await loginWithPhone(tester, DemoBackend.adminPhone);
    // Sin elegir modo cliente, las pestañas del cliente vuelven al panel.
    await _go(tester, c, Routes.home);
    expect(_location(c), Routes.admin);
    await _tab(tester, 'Perfil');
    final toCustomer = find.byKey(const Key('switch-to-customer'));
    await tester.ensureVisible(toCustomer);
    await tester.pumpAndSettle();
    await tester.tap(toCustomer);
    await tester.pumpAndSettle();
    expect(_location(c), Routes.home);
    await _go(tester, c, Routes.profile);
    expect(find.text('Quiero ser profesional'), findsNothing);
    final back = find.byKey(const Key('back-to-panel'));
    expect(back, findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(_location(c), Routes.admin);
  });

  testWidgets('el gerente entra a su panel, sin dinero ni pantallas del propietario', (tester) async {
    final (_, c) = await _pump(tester);
    await loginWithPhone(tester, DemoBackend.managerPhone);
    expect(_location(c), Routes.manager);
    expect(find.byKey(const Key('panel-title-manager')), findsOneWidget);
    expect(find.byKey(const Key('manager-summary')), findsOneWidget);
    _expectNoMoney(tester, 'el resumen del gerente');
    for (final tab in ['Casos', 'Postulaciones', 'Equipo', 'Perfil']) {
      await _tab(tester, tab);
      expect(tester.takeException(), isNull, reason: tab);
    }
    expect(find.byKey(const Key('team-add')), findsNothing);
    // Pantallas del propietario: la app las cierra.
    for (final route in [
      Routes.admin,
      Routes.adminTopups,
      Routes.adminCommissions,
      Routes.adminCosts,
      Routes.adminAi,
      Routes.adminAudit,
      Routes.ownerTeam,
      Routes.ownerTeamAdd,
      Routes.adminFinance,
      Routes.adminFinanceAccounts,
      Routes.adminFinanceReconcile,
      Routes.adminFinanceMovements,
      Routes.adminFinanceAudit,
      Routes.employee,
      Routes.home,
    ]) {
      await _go(tester, c, route);
      expect(_location(c), Routes.manager, reason: route);
    }
    // Lo operativo de /admin sí lo abre.
    await _go(tester, c, Routes.adminReports);
    expect(_location(c), Routes.adminReports);
  });

  testWidgets('el gerente ve disputas pero no puede resolverlas', (tester) async {
    final (_, c) = await _pump(tester);
    await loginWithPhone(tester, DemoBackend.managerPhone);
    await _go(tester, c, Routes.adminDisputes);
    expect(find.text('Resolver disputa'), findsNothing);
    expect(find.byKey(const Key('dispute-owner-only')), findsWidgets);
  });

  testWidgets('el empleado ve su panel, solo sus casos y sin dinero', (tester) async {
    final (backend, c) = await _pump(tester, size: const Size(320, 568));
    await loginWithPhone(tester, DemoBackend.employeePhones.first);
    expect(_location(c), Routes.employee);
    expect(find.byKey(const Key('panel-title-employee')), findsOneWidget);
    expect(find.byKey(const Key('panel-nav-employee')), findsOneWidget);
    // Sin las bandejas del equipo.
    expect(find.byKey(const Key('cases-scope-all')), findsNothing);
    expect(find.byKey(const Key('cases-scope-unassigned')), findsNothing);
    _expectNoMoney(tester, 'los casos del empleado');
    for (final tab in ['Actividad', 'Perfil']) {
      await _tab(tester, tab);
      expect(tester.takeException(), isNull, reason: tab);
    }
    final restrictions = find.byKey(const Key('staff-restrictions'));
    await tester.ensureVisible(restrictions);
    expect(find.text('Aprobar o rechazar profesionales'), findsOneWidget);
    for (final route in [
      Routes.admin,
      Routes.adminApplications,
      Routes.adminUsers,
      Routes.adminTopups,
      Routes.manager,
      Routes.ownerTeam,
      Routes.ownerTeamAdd,
      Routes.adminFinance,
      Routes.adminFinanceAccounts,
      Routes.adminFinanceReconcile,
      Routes.wallet,
    ]) {
      await _go(tester, c, route);
      expect(_location(c), anyOf(Routes.employee, Routes.home), reason: route);
      expect(_location(c), isNot(route), reason: route);
    }
    // El servidor (demo) tampoco le da lo que no le toca.
    for (final call in <Future<Object?> Function()>[
      backend.adminDashboard,
      backend.adminApplications,
      () => backend.adminUsers(''),
      backend.staffOverview,
      () => backend.grantStaff('demo-empleado-2', StaffRole.manager, authMethod: 'otp'),
      () => backend.staffCandidates('demo'),
      backend.financeSummary,
      backend.receivingAccounts,
      () => backend.topupsForReconciliation('todas'),
      backend.financeAudit,
    ]) {
      final code = await tester.runAsync(() async {
        try {
          await call();
          return 'sin error';
        } on AppError catch (e) {
          return e.code;
        }
      });
      expect(code, 'HMY_FORBIDDEN');
    }
    final mine = (await tester.runAsync(() => backend.opsCases(scope: 'all')))!;
    expect(mine.every((x) => x.assignedTo == 'demo-empleado-1'), isTrue);
  });

  testWidgets('un empleado suspendido pierde el panel', (tester) async {
    final (backend, c) = await _pump(tester);
    await tester.runAsync(() async {
      await backend.signInAs(DemoBackend.adminPhone);
      await backend.setStaffStatus('demo-empleado-3', 'suspended', reason: 'Prueba de suspensión');
      await backend.signOut();
    });
    await tester.pumpAndSettle();
    await loginWithPhone(tester, DemoBackend.employeePhones[2]);
    expect(_location(c), isNot(Routes.employee));
    expect(find.byKey(const Key('panel-title-employee')), findsNothing);
  });

  testWidgets('el cliente no llega a ningún panel', (tester) async {
    final (_, c) = await _pump(tester);
    await loginWithPhone(tester, DemoBackend.customerPhone);
    for (final route in [Routes.admin, Routes.manager, Routes.employee, Routes.staffCases, Routes.staffCase(1)]) {
      await _go(tester, c, route);
      expect(_location(c), Routes.home, reason: route);
    }
  });

  test('las rutas de cada panel son distintas', () {
    expect({
      Routes.panelHome(StaffRole.owner),
      Routes.panelHome(StaffRole.manager),
      Routes.panelHome(StaffRole.employee),
    }, hasLength(3));
  });
}
