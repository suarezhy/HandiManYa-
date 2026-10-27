// Auditoría de toda la app: cada pantalla de los cinco roles (cliente,
// profesional, propietario, gerente y empleado) y cada categoría, en anchos
// de Android chicos, con letra normal, negrita del sistema y letra grande.
// Recorre cada pantalla de arriba abajo y anota:
// - palabras partidas ("Profesiona / les") y textos cortados;
// - desbordes (las franjas amarillas y negras);
// - botones con más de 3 palabras (se ven recargados).
// Con HMY_AUDIT=<archivo> escribe el informe completo.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:handimanya/core/services/location_service.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/demo/demo_data.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tool/screenshots/shots.dart';
import 'support/demo_login.dart';
import 'support/layout_checks.dart';

/// Huella del teléfono: en las pruebas no hay teléfono que responda.
class _FakeDeviceAuth implements DeviceAuth {
  const _FakeDeviceAuth();

  @override
  Future<Set<DeviceBiometric>> available() async => const {DeviceBiometric.fingerprint};

  @override
  Future<DeviceAuthResult> authenticate(String reason) async => DeviceAuthResult.success;
}

class _FakeLocation implements LocationService {
  const _FakeLocation();

  @override
  Future<GeoPoint> current() async => const GeoPoint(-17.7800, -63.1800);
}

/// Combinaciones de pantalla y letra (ancho x alto, letra, negrita).
const _variants = [
  (Size(320, 640), 1.0, false),
  (Size(360, 800), 1.3, true),
  (Size(384, 832), 1.0, false),
  (Size(360, 800), 2.0, false),
];

String _label((Size, double, bool) v) => '${v.$1.width.toInt()}px x${v.$2}${v.$3 ? ' negrita' : ''}';

final _report = <String, Set<String>>{};
final _buttons = <String>{};
var _shotFonts = false;

void _add(String where, String issue) => _report.putIfAbsent(where, () => <String>{}).add(issue);

Future<DemoAppBackend> _pump(WidgetTester tester, String phone, (Size, double, bool) v) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  await backend.signInAs(phone);
  tester.view.physicalSize = v.$1 * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 24 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 24 * 3, bottom: 24 * 3);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = v.$2;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(boldText: v.$3);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        backendProvider.overrideWithValue(backend),
        locationServiceProvider.overrideWithValue(const _FakeLocation()),
        mapTileUrlProvider.overrideWithValue(null),
        deviceAuthProvider.overrideWithValue(const _FakeDeviceAuth()),
      ],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

/// Las palabras de los botones a la vista.
void _checkButtons(WidgetTester tester, String route, String where) {
  final buttons = find.byWidgetPredicate(
    (w) => w is ButtonStyleButton || w is FloatingActionButton || w is SegmentedButton,
  );
  for (final b in buttons.evaluate()) {
    for (final t in find.descendant(of: find.byWidget(b.widget), matching: find.byType(RichText)).evaluate()) {
      final text = (t.widget as RichText).text.toPlainText().trim();
      if (text.isEmpty || text.runes.length == 1) continue;
      final words = text.split(RegExp(r'\s+')).where((w) => RegExp(r'[A-Za-zÁÉÍÓÚÑáéíóúñ]').hasMatch(w)).length;
      if (words > 3) _buttons.add('$route: "$text"');
      // Un botón con su texto en dos líneas se ve apretado ("Ver / todos").
      final p = t.renderObject! as RenderParagraph;
      final one = TextPainter(text: p.text, textDirection: TextDirection.ltr, textScaler: p.textScaler)..layout();
      if (p.size.height > one.height * 1.5) _add(where, 'botón en dos líneas: "$text"');
      one.dispose();
    }
  }
}

/// Recorre la pantalla de arriba abajo anotando lo que esté mal.
Future<void> _sweep(WidgetTester tester, String where, Size screen, String route) async {
  void collect() {
    for (final p in textProblems(tester, screen)) {
      _add(where, p);
    }
    final e = tester.takeException();
    if (e != null) _add(where, 'error: ${e.toString().split('\n').first}');
    _checkButtons(tester, route, where);
  }

  collect();
  final scrollables = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  ScrollableState? main;
  var biggest = 0.0;
  for (final e in scrollables.evaluate()) {
    final s = (e as StatefulElement).state as ScrollableState;
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) continue;
    final area = box.size.width * box.size.height;
    if (area > biggest && s.position.hasContentDimensions) {
      biggest = area;
      main = s;
    }
  }
  if (main == null) return;
  final pos = main.position;
  var offset = 0.0;
  var steps = 0;
  while (offset < pos.maxScrollExtent && steps < 30) {
    offset = (offset + pos.viewportDimension * 0.7).clamp(0, pos.maxScrollExtent);
    pos.jumpTo(offset);
    await _settle(tester, where);
    collect();
    steps++;
  }
}

/// Espera a que la pantalla quede quieta. Si algo se mueve sin parar (una
/// rueda de carga que no termina), se anota y se sigue.
Future<void> _settle(WidgetTester tester, String where) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  } catch (_) {
    tester.takeException();
    _add(where, 'animación sin fin (¿carga que no termina?)');
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> _visit(WidgetTester tester, String route, (Size, double, bool) v, {bool push = false}) async {
  final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
  if (push) {
    router.push(route);
  } else {
    router.go(route);
  }
  await _settle(tester, '$route (${_label(v)})');
  await _capture(tester, route, v);
  await _sweep(tester, '$route (${_label(v)})', v.$1, route);
}

/// Con `HMY_SHOTS=<carpeta>`, guarda cada pantalla para revisarla a ojo.
Future<void> _capture(WidgetTester tester, String what, (Size, double, bool) v) async {
  if (shotsDir.isEmpty) return;
  if (!_shotFonts) {
    _shotFonts = true;
    await tester.runAsync(loadShotFonts);
  }
  final name = '${_label(v)} ${what.replaceAll('/', ' ')}'.trim().replaceAll(RegExp(r'[^\w\-áéíóúñ.]+'), '_');
  await shot(tester, name);
}

/// Elige la primera opción y recorre "Cuéntanos más" y "¿Dónde es?".
Future<void> _requestSteps(WidgetTester tester, (Size, double, bool) v, int categoryId) async {
  final route = Routes.service(categoryId);
  final first = DemoData.problems.firstWhere((p) => p.categoryId == categoryId && p.opensCategoryId == null);
  final option = find.byKey(ValueKey('problem-${first.id}'));
  if (option.evaluate().isEmpty) return;
  await tester.ensureVisible(option);
  await tester.pumpAndSettle();
  await tester.tap(option);
  await tester.pumpAndSettle();
  if (find.byKey(const ValueKey('tow-destination')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('vehicle-Auto')));
    await tester.enterText(find.byKey(const ValueKey('tow-destination')), 'Taller Central');
    await tester.pumpAndSettle();
  }
  for (final step in ['detalles', 'dirección']) {
    final next = find.text('Continuar');
    if (next.evaluate().isEmpty) return;
    await tester.tap(next.last);
    await _settle(tester, '$route $step (${_label(v)})');
    await _capture(tester, '$route $step', v);
    await _sweep(tester, '$route $step (${_label(v)})', v.$1, route);
  }
}

/// Bienvenida y acceso, sin sesión.
Future<void> _loggedOut(WidgetTester tester, (Size, double, bool) v) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.physicalSize = v.$1 * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = v.$2;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(boldText: v.$3);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
  for (var i = 0; i < 4; i++) {
    await _sweep(tester, 'bienvenida ${i + 1} (${_label(v)})', v.$1, 'bienvenida');
    final next = find.text('Continuar');
    if (next.evaluate().isEmpty) break;
    await tester.tap(next.last);
    await tester.pumpAndSettle();
  }
  final skip = find.text('Omitir');
  if (skip.evaluate().isNotEmpty) {
    await tester.tap(skip);
    await tester.pumpAndSettle();
  }
  await _sweep(tester, 'acceso (${_label(v)})', v.$1, 'acceso');
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDownAll(() {
    final out = Platform.environment['HMY_AUDIT'];
    if (out == null) return;
    final b = StringBuffer('# Auditoría de pantallas\n\n');
    for (final e in _report.entries) {
      b.writeln('## ${e.key}');
      for (final i in e.value) {
        b.writeln('- $i');
      }
      b.writeln();
    }
    b.writeln('## Botones con más de 3 palabras');
    for (final x in _buttons) {
      b.writeln('- $x');
    }
    File(out).writeAsStringSync(b.toString());
  });

  final customerRoutes = [
    Routes.home,
    Routes.search,
    Routes.requests,
    Routes.messages,
    Routes.profile,
    Routes.categories,
    Routes.notifications,
    Routes.editProfile,
    Routes.security,
    Routes.emergencyGuide,
    Routes.support,
    Routes.ya,
  ];
  final proRoutes = [
    Routes.proHome,
    Routes.proRequests,
    Routes.proJobs,
    Routes.proMessages,
    Routes.proProfile,
    Routes.wallet,
    Routes.serviceArea,
  ];
  final ownerRoutes = [
    Routes.admin,
    Routes.adminApplications,
    Routes.adminTopups,
    Routes.adminReports,
    Routes.adminDisputes,
    Routes.adminTickets,
    Routes.adminUsers,
    Routes.adminCommissions,
    Routes.adminCatalog,
    Routes.adminAudit,
    Routes.adminAi,
    Routes.adminCosts,
    Routes.adminAds,
    Routes.adminFinance,
    Routes.opsBookings,
    Routes.adminRisk,
    Routes.ownerManage,
    Routes.ownerTeam,
    Routes.ownerProfile,
    Routes.staffCases,
  ];
  final managerRoutes = [
    Routes.manager,
    Routes.managerCases,
    Routes.managerApplications,
    Routes.managerTeam,
    Routes.managerProfile,
  ];
  final employeeRoutes = [Routes.employee, Routes.employeeActivity, Routes.employeeProfile];

  final roles = {
    'cliente': (DemoBackend.customerPhone, customerRoutes),
    'profesional': (DemoBackend.professionalPhone, proRoutes),
    'propietario': (DemoBackend.adminPhone, ownerRoutes),
    'gerente': (DemoBackend.managerPhone, managerRoutes),
    'empleado': (DemoBackend.employeePhones.first, employeeRoutes),
  };

  for (final v in _variants) {
    testWidgets('auditoría sin sesión ${_label(v)}', (tester) async {
      await loadAppFonts(tester);
      await _loggedOut(tester, v);
      final issues = [
        for (final e in _report.entries)
          if (e.key.endsWith('(${_label(v)})') && (e.key.startsWith('bienvenida') || e.key.startsWith('acceso')))
            ...e.value,
      ];
      expect(issues, isEmpty, reason: issues.take(15).join('\n'));
    });
  }

  for (final role in roles.entries) {
    for (final v in _variants) {
      testWidgets('auditoría ${role.key} ${_label(v)}', (tester) async {
        await loadAppFonts(tester);
        final (phone, routes) = role.value;
        await _pump(tester, phone, v);
        for (final r in routes) {
          await _visit(tester, r, v);
        }
        // Cada categoría: "¿Qué necesitas?" y los pasos siguientes del pedido.
        if (role.key == 'cliente') {
          for (final c in DemoData.categories) {
            await _visit(tester, Routes.service(c.id), v, push: true);
            await _requestSteps(tester, v, c.id);
            GoRouter.of(tester.element(find.byType(Scaffold).first)).go(Routes.home);
            await _settle(tester, 'inicio');
          }
        }
        // Las pantallas de cada pedido y su chat.
        if (role.key == 'cliente' || role.key == 'profesional') {
          final backend = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)).read(backendProvider);
          final bookings = await tester.runAsync(() => backend.myBookings(asProfessional: role.key == 'profesional'));
          for (final b in (bookings ?? const []).take(4)) {
            await _visit(tester, Routes.booking(b.id), v, push: true);
          }
        }
        if (role.key == 'cliente') {
          final pros = DemoData.professionals.take(2);
          for (final p in pros) {
            await _visit(tester, Routes.professional(p.$1), v, push: true);
          }
        }
        final issues = [
          for (final e in _report.entries)
            if (e.key.endsWith('(${_label(v)})') &&
                (routes.any((r) => e.key.startsWith(r)) ||
                    (role.key == 'cliente' && (e.key.startsWith('/servicio') || e.key.startsWith('/profesional'))) ||
                    e.key.startsWith('/solicitud')))
              ...e.value,
        ];
        expect(issues, isEmpty, reason: issues.take(15).join('\n'));
      });
    }
  }
}
