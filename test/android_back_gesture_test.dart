import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/widgets/edge_swipe_back.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Atrás en Android como llega en un teléfono de verdad:
///
/// - Android 13+ solo le pasa el atrás a la app si la app avisó que lo maneja
///   (`SystemNavigator.setFrameworkHandlesBack`). Si avisa mal, el gesto saca
///   de la app en vez de volver.
/// - Android 14+ manda el gesto predictivo por otro canal (inicio, avance,
///   confirmación), no como un atrás simple.
/// - Con la barra de tres botones no hay gesto del sistema: deslizar desde el
///   borde lo hace la app ([EdgeSwipeBack]).
class _Phone {
  _Phone(this.tester, this.backend, this.calls);

  final WidgetTester tester;
  final DemoAppBackend backend;
  final List<bool> calls;

  bool? get handlesBack => calls.isEmpty ? null : calls.last;

  String get location => GoRouter.of(tester.element(find.byType(Scaffold).first)).state.uri.path;

  Future<void> push(String route) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push(route);
    await tester.pumpAndSettle();
  }

  Future<void> _send(String method, [Object? args]) async {
    const codec = StandardMethodCodec();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.backGesture.name,
      codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  /// El gesto atrás predictivo de Android 14+, tal como lo manda el sistema.
  Future<void> predictiveBack() async {
    await _send('startBackGesture', {
      'touchOffset': [2.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _send('updateBackGestureProgress', {
      'touchOffset': [180.0, 300.0],
      'progress': 0.6,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _send('commitBackGesture');
    await tester.pumpAndSettle();
  }

  Future<void> edgeSwipe({double from = 4, double distance = 220}) async {
    await tester.dragFrom(Offset(from, 300), Offset(distance, 0));
    await tester.pumpAndSettle();
  }
}

Future<_Phone> _pump(WidgetTester tester, String phone) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(360, 780) * 3;
  addTearDown(tester.view.reset);
  final calls = <bool>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemNavigator.setFrameworkHandlesBack') calls.add(call.arguments as bool);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  // En el teléfono la app está "resumed"; sin esto Flutter no avisa nada.
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
  await loginWithPhone(tester, phone);
  await tester.pumpAndSettle();
  return _Phone(tester, backend, calls);
}

void main() {
  // Cada rol, en su inicio y en pantallas abiertas encima.
  for (final (who, phone, home, screens) in [
    ('cliente', DemoBackend.customerPhone, Routes.home, [Routes.support, Routes.editProfile, Routes.notifications]),
    (
      'propietario',
      DemoBackend.adminPhone,
      Routes.admin,
      [Routes.adminApplications, Routes.staffCases, Routes.adminAi, Routes.ownerTeam],
    ),
    (
      'gerente',
      DemoBackend.managerPhone,
      Routes.manager,
      [Routes.adminReports, Routes.staffCases, Routes.notifications],
    ),
    ('empleado', DemoBackend.employeePhones.first, Routes.employee, [Routes.staffCases, Routes.notifications]),
  ]) {
    testWidgets('$who: Android recibe el atrás en cada pantalla y el gesto predictivo vuelve', (tester) async {
      final p = await _pump(tester, phone);
      expect(p.location, home);
      expect(p.handlesBack, isFalse, reason: 'en el inicio, atrás es del sistema (sale de la app)');
      for (final s in screens) {
        await p.push(s);
        expect(p.location, s, reason: 'abre $s');
        expect(p.handlesBack, isTrue, reason: '$s: la app avisa que maneja el atrás');
        await p.predictiveBack();
        expect(p.location, home, reason: 'el gesto predictivo vuelve desde $s');
      }
      expect(p.handlesBack, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('otra pestaña: el gesto vuelve a la primera, sin salir de la app', (tester) async {
    final p = await _pump(tester, DemoBackend.adminPhone);
    await tester.tap(find.byKey(const Key('panel-nav-Equipo')));
    await tester.pumpAndSettle();
    expect(p.handlesBack, isTrue);
    await p.predictiveBack();
    expect(p.location, Routes.admin);
  });

  group('deslizar desde el borde (barra de tres botones)', () {
    testWidgets('vuelve a la pantalla anterior', (tester) async {
      final p = await _pump(tester, DemoBackend.customerPhone);
      await tester.tap(find.byKey(const Key('nav-Perfil')));
      await tester.pumpAndSettle();
      await p.push(Routes.support);
      expect(find.byKey(const Key('edge-swipe-back')), findsOneWidget);
      await p.edgeSwipe();
      expect(p.location, Routes.profile);
    });

    testWidgets('un arrastre corto o lejos del borde no hace nada', (tester) async {
      final p = await _pump(tester, DemoBackend.customerPhone);
      await p.push(Routes.support);
      await p.edgeSwipe(distance: 40);
      expect(p.location, Routes.support, reason: 'arrastre corto');
      await p.edgeSwipe(from: 60);
      expect(p.location, Routes.support, reason: 'empezó lejos del borde');
    });

    testWidgets('la primera pantalla de una pestaña no tiene borde para deslizar', (tester) async {
      await _pump(tester, DemoBackend.customerPhone);
      expect(find.byKey(const Key('edge-swipe-back')), findsNothing);
    });

    testWidgets('con cambios sin guardar pregunta y no pierde lo escrito', (tester) async {
      final p = await _pump(tester, DemoBackend.customerPhone);
      await p.push(Routes.editProfile);
      await tester.enterText(find.byType(TextFormField).first, 'Carla Nueva Prueba');
      await tester.pumpAndSettle();
      await p.edgeSwipe();
      expect(find.text('¿Salir sin guardar?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('unsaved-keep-editing')));
      await tester.pumpAndSettle();
      expect(p.location, Routes.editProfile);
      expect(find.text('Carla Nueva Prueba'), findsOneWidget);
      await p.edgeSwipe();
      await tester.tap(find.byKey(const Key('unsaved-leave')));
      await tester.pumpAndSettle();
      expect(p.location, isNot(Routes.editProfile));
    });

    testWidgets('el botón atrás de la barra sigue funcionando en el borde', (tester) async {
      final p = await _pump(tester, DemoBackend.customerPhone);
      await p.push(Routes.support);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(p.location, Routes.home);
    });
  });
}
