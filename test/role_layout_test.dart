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

Future<DemoAppBackend> _pump(WidgetTester tester, String phone, Size size, double scale, {double dpr = 3}) async {
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

void main() {
  testWidgets('propietario: Resumen sin palabras partidas', (tester) async {
    await loadAppFonts(tester);
    final all = <String>[];
    for (final (size, scale) in [
      (const Size(360, 780), 1.0),
      (const Size(360, 780), 1.15),
      (const Size(360, 780), 1.3),
      (const Size(320, 640), 1.6),
    ]) {
      await _pump(tester, DemoBackend.adminPhone, size, scale);
      all.addAll(await _scan(tester, size, '${size.width.toInt()} x$scale'));
    }
    for (final p in all.toSet()) {
      debugPrint(p);
    }
    expect(all, isEmpty);
  });
}
