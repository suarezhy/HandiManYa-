import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';
import 'support/layout_checks.dart';

/// Issue #12: en cada panel (Propietario, Gerente, Empleado, Cliente y
/// Profesional), en teléfonos chicos y con letra grande, ninguna palabra se
/// parte, nada se corta con "…", no hay desbordes y lo último de cada pantalla
/// queda por encima de la barra de abajo.

const _top = 24.0; // barra de estado de Android
const _bottom = 24.0; // barra de gestos de Android

Future<DemoAppBackend> _pump(
  WidgetTester tester,
  String phone,
  Size size,
  double scale, {
  double dpr = 3,
  bool bold = false,
}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  await backend.signInAs(phone);
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  tester.view.padding = FakeViewPadding(top: _top * dpr, bottom: _bottom * dpr);
  tester.view.viewPadding = FakeViewPadding(top: _top * dpr, bottom: _bottom * dpr);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  // Samsung: Ajustes > Pantalla > Tamaño y estilo de fuente > Fuente en negrita.
  tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(boldText: bold);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

/// Recorre la pantalla de arriba abajo y junta los problemas de texto.
Future<List<String>> _scan(WidgetTester tester, Size size, String where) async {
  final problems = <String>[];
  void collect() {
    for (final p in textProblems(tester, size)) {
      problems.add('$where: $p');
    }
    final e = tester.takeException();
    if (e != null) problems.add('$where: $e');
  }

  collect();
  final scrollable = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  if (scrollable.evaluate().isEmpty) return problems;
  final main = scrollable.first;
  for (var i = 0; i < 40; i++) {
    final state = tester.state<ScrollableState>(main);
    final pos = state.position;
    if (pos.pixels >= pos.maxScrollExtent - 1) break;
    pos.jumpTo((pos.pixels + size.height * 0.6).clamp(0, pos.maxScrollExtent));
    await tester.pumpAndSettle();
    collect();
  }
  return problems;
}

/// Lo último de la pantalla, al final del desplazamiento, no queda tapado por la barra de abajo.
String? _hiddenBehindNav(WidgetTester tester, String where) {
  final nav = find.byType(NavigationBar);
  final scrollable = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  if (nav.evaluate().isEmpty || scrollable.evaluate().isEmpty) return null;
  final navTop = tester.getTopLeft(nav.first).dy;
  final viewport = tester.getRect(scrollable.first);
  if (viewport.bottom > navTop + 0.5) return '$where: la lista sigue debajo de la barra de abajo';
  return null;
}

const _configs = [
  (Size(360, 780), 1.0, 3.0, false),
  (Size(360, 780), 1.15, 3.0, false),
  (Size(320, 640), 1.3, 2.0, false),
  (Size(412, 915), 1.6, 4.0, false),
  (Size(320, 640), 1.6, 3.0, false),
  // Issue #12 en el Samsung (Dev-17): con "Fuente en negrita" las palabras se partían.
  (Size(384, 832), 1.0, 3.0, true),
  (Size(360, 780), 1.15, 3.0, true),
  (Size(412, 915), 1.3, 3.0, true),
];

Future<List<String>> _checkTabs(WidgetTester tester, String phone, String navPrefix, List<String> tabs) async {
  final all = <String>[];
  for (final (size, scale, dpr, bold) in _configs) {
    await _pump(tester, phone, size, scale, dpr: dpr, bold: bold);
    for (final tab in tabs) {
      final key = find.byKey(Key('$navPrefix$tab'));
      if (key.evaluate().isEmpty) {
        all.add('falta la pestaña $tab');
        continue;
      }
      await tester.tap(key);
      await tester.pumpAndSettle();
      final where = '$tab ${size.width.toInt()}px x$scale dpr$dpr${bold ? ' negrita' : ''}';
      all.addAll(await _scan(tester, size, where));
      final hidden = _hiddenBehindNav(tester, where);
      if (hidden != null) all.add(hidden);
    }
  }
  for (final p in all.toSet()) {
    debugPrint(p);
  }
  return all;
}

void main() {
  testWidgets('propietario: todas las pestañas', (tester) async {
    await loadAppFonts(tester);
    final all = await _checkTabs(tester, DemoBackend.adminPhone, 'panel-nav-', [
      'Resumen',
      'Gestión',
      'Centro IA',
      'Equipo',
      'Perfil',
    ]);
    expect(all, isEmpty);
  });

  testWidgets('gerente: todas las pestañas', (tester) async {
    await loadAppFonts(tester);
    final all = await _checkTabs(tester, DemoBackend.managerPhone, 'panel-nav-', [
      'Resumen',
      'Casos',
      'Postulaciones',
      'Equipo',
      'Perfil',
    ]);
    expect(all, isEmpty);
  });

  testWidgets('empleado: todas las pestañas', (tester) async {
    await loadAppFonts(tester);
    final all = await _checkTabs(tester, DemoBackend.employeePhones.first, 'panel-nav-', [
      'Mis casos',
      'Actividad',
      'Perfil',
    ]);
    expect(all, isEmpty);
  });

  testWidgets('cliente: todas las pestañas', (tester) async {
    await loadAppFonts(tester);
    final all = await _checkTabs(tester, DemoBackend.customerPhone, 'nav-', [
      'Inicio',
      'Buscar',
      'Solicitudes',
      'Mensajes',
      'Perfil',
    ]);
    expect(all, isEmpty);
  });

  testWidgets('profesional: todas las pestañas', (tester) async {
    await loadAppFonts(tester);
    final all = await _checkTabs(tester, DemoBackend.professionalPhone, 'nav-', [
      'Inicio',
      'Solicitudes',
      'Trabajos',
      'Mensajes',
      'Perfil',
    ]);
    expect(all, isEmpty);
  });
}
