import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoPageTransition, CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/booking/request_flow_page.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Atrás del sistema (gesto o botón de Android, `handlePopRoute`) y
/// deslizamiento desde el borde en iOS, en el teléfono más chico (320x568).
///
/// Devuelve la lista donde se anotan los "cerrar la app" (SystemNavigator.pop).
Future<List<String>> _pumpApp(WidgetTester tester, String phone) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(320, 568) * 3;
  addTearDown(tester.view.reset);
  final exits = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemNavigator.pop') exits.add(call.method);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
  await loginWithPhone(tester, phone);
  return exits;
}

Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _push(WidgetTester tester, String location) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).push(location);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

int _selectedTab(WidgetTester tester) => tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

const _leaveTitle = '¿Salir sin guardar?';

void main() {
  group('pestañas: atrás del sistema', () {
    for (final (who, phone, tabs) in [
      ('cliente', DemoBackend.customerPhone, ['Buscar', 'Solicitudes', 'Mensajes', 'Perfil']),
      ('profesional', DemoBackend.professionalPhone, ['Solicitudes', 'Trabajos', 'Mensajes', 'Perfil']),
    ]) {
      testWidgets('$who: en otra pestaña vuelve a Inicio; en Inicio cierra la app', (tester) async {
        final exits = await _pumpApp(tester, phone);
        if (phone == DemoBackend.professionalPhone && _selectedTab(tester) != 0) {
          await _tap(tester, find.byKey(const Key('nav-Inicio')));
        }
        expect(_selectedTab(tester), 0);
        for (final tab in tabs) {
          await _tap(tester, find.byKey(Key('nav-$tab')));
          expect(_selectedTab(tester), isNot(0), reason: tab);
          await _systemBack(tester);
          expect(_selectedTab(tester), 0, reason: 'atrás desde $tab');
          expect(exits, isEmpty, reason: 'atrás desde $tab no debe cerrar la app');
        }
        await _systemBack(tester);
        expect(exits, hasLength(1), reason: 'en Inicio, atrás sale de la app');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('una pantalla abierta encima de una pestaña se cierra primero', (tester) async {
      final exits = await _pumpApp(tester, DemoBackend.customerPhone);
      await _tap(tester, find.byKey(const Key('nav-Perfil')));
      await _push(tester, Routes.support);
      await _systemBack(tester);
      expect(_selectedTab(tester), 4, reason: 'vuelve a Perfil, no a Inicio');
      await _systemBack(tester);
      expect(_selectedTab(tester), 0);
      expect(exits, isEmpty);
    });
  });

  group('Información personal', () {
    testWidgets('sin cambios, atrás sale directo', (tester) async {
      await _pumpApp(tester, DemoBackend.customerPhone);
      await _push(tester, Routes.editProfile);
      expect(find.text('Información personal'), findsOneWidget);
      await _systemBack(tester);
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.text('Información personal'), findsNothing);
    });

    testWidgets('con el nombre cambiado, atrás pregunta; "Seguir editando" se queda y "Salir" sale', (tester) async {
      final exits = await _pumpApp(tester, DemoBackend.customerPhone);
      await _push(tester, Routes.editProfile);
      final name = find.byType(TextFormField).first;
      await tester.enterText(name, 'Carla Nueva Prueba');
      await tester.pumpAndSettle();

      await _systemBack(tester);
      expect(find.text(_leaveTitle), findsOneWidget);
      expect(find.text('Seguir editando'), findsOneWidget);
      expect(find.text('Salir'), findsOneWidget);
      await tester.tap(find.text('Seguir editando'));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.text('Información personal'), findsOneWidget);
      expect(find.text('Carla Nueva Prueba'), findsOneWidget, reason: 'lo escrito sigue ahí');

      // El botón de la barra hace lo mismo que el gesto.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsOneWidget);
      await tester.tap(find.text('Salir'));
      await tester.pumpAndSettle();
      expect(find.text('Información personal'), findsNothing);
      expect(exits, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('las hojas de celular y correo se cierran con atrás sin preguntar', (tester) async {
      await _pumpApp(tester, DemoBackend.customerPhone);
      await _push(tester, Routes.editProfile);
      await _tap(tester, find.byKey(const Key('profile-phone')));
      expect(find.byType(BottomSheet), findsOneWidget);
      await _systemBack(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.text('Información personal'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('profile-email')));
      expect(find.byType(BottomSheet), findsOneWidget);
      await _systemBack(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Información personal'), findsOneWidget);
    });

    testWidgets('iOS: deslizar desde el borde izquierdo vuelve atrás', (tester) async {
      await _pumpApp(tester, DemoBackend.customerPhone);
      await _tap(tester, find.byKey(const Key('nav-Perfil')));
      await _push(tester, Routes.editProfile);
      expect(find.text('Información personal'), findsOneWidget);
      // Cada pantalla es una página Material con la transición del tema (en
      // iOS, Cupertino con su deslizamiento desde el borde).
      final route = ModalRoute.of(tester.element(find.text('Información personal')));
      expect(route, isA<MaterialRouteTransitionMixin<dynamic>>());
      expect(find.byType(CupertinoPageTransition), findsWidgets);
      final gesture = await tester.startGesture(const Offset(4, 300));
      for (var x = 0; x < 6; x++) {
        await gesture.moveBy(const Offset(50, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Información personal'), findsNothing);
      expect(_selectedTab(tester), 4);

      // Con cambios sin guardar, deslizar no saca de la pantalla ni pierde lo
      // escrito (Flutter desactiva el deslizamiento); el botón atrás pregunta.
      await _push(tester, Routes.editProfile);
      await tester.enterText(find.byType(TextFormField).first, 'Carla Nueva Prueba');
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(4, 300), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('Carla Nueva Prueba'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('Pedir ¡Ya!', () {
    testWidgets('atrás vuelve al paso anterior y, con algo elegido, pregunta antes de salir', (tester) async {
      await _pumpApp(tester, DemoBackend.customerPhone);
      await _push(tester, Routes.ya);
      expect(find.text('¿Qué servicio necesitas?'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('category-search')), 'plomeria');
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Plomería'));
      expect(find.text('¿Qué necesitas solucionar?'), findsOneWidget);

      await _systemBack(tester);
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.text('¿Qué servicio necesitas?'), findsOneWidget, reason: 'vuelve al paso 1');

      await _systemBack(tester);
      expect(find.text(_leaveTitle), findsOneWidget);
      await tester.tap(find.text('Seguir editando'));
      await tester.pumpAndSettle();
      expect(find.text('¿Qué servicio necesitas?'), findsOneWidget);

      await _systemBack(tester);
      await tester.tap(find.text('Salir'));
      await tester.pumpAndSettle();
      expect(find.byType(RequestFlowPage), findsNothing);
      expect(_selectedTab(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sin elegir nada, atrás sale directo', (tester) async {
      await _pumpApp(tester, DemoBackend.customerPhone);
      await _push(tester, Routes.ya);
      await _systemBack(tester);
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.byType(RequestFlowPage), findsNothing);
    });
  });

  group('Quiero ser profesional', () {
    testWidgets('con cambios pregunta; después de "Guardar borrador" sale directo', (tester) async {
      await _pumpApp(tester, DemoBackend.customerPhone);
      await _push(tester, Routes.apply);
      expect(find.text('Quiero ser profesional'), findsOneWidget);
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(2), 'Limpieza de casas y oficinas, con productos propios.');
      await tester.pumpAndSettle();

      await _systemBack(tester);
      expect(find.text(_leaveTitle), findsOneWidget);
      await tester.tap(find.text('Seguir editando'));
      await tester.pumpAndSettle();
      expect(find.text('Quiero ser profesional'), findsOneWidget);

      // Guardar borrador sigue ahí; guardado, ya no hay nada que perder.
      await _tap(tester, find.byKey(const Key('application-primary')));
      await tester.tap(find.text('Limpieza').last);
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('application-save-draft')));
      if (find.text('Borrador guardado').evaluate().isNotEmpty) {
        await _systemBack(tester);
        expect(find.text(_leaveTitle), findsNothing);
        expect(find.text('Quiero ser profesional'), findsNothing);
      } else {
        // Sin municipio el borrador no se guarda: sigue preguntando.
        await _systemBack(tester);
        expect(find.text(_leaveTitle), findsOneWidget);
        await tester.tap(find.text('Salir'));
        await tester.pumpAndSettle();
        expect(find.text('Quiero ser profesional'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('el botón de la barra también pregunta', (tester) async {
      await _pumpApp(tester, DemoBackend.customerPhone);
      await _push(tester, Routes.apply);
      await tester.enterText(find.byType(TextFormField).at(3), '12');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsOneWidget);
      await tester.tap(find.text('Salir'));
      await tester.pumpAndSettle();
      expect(find.text('Quiero ser profesional'), findsNothing);
    });

    testWidgets('sin cambios, atrás sale directo', (tester) async {
      await _pumpApp(tester, DemoBackend.customerPhone);
      await _push(tester, Routes.apply);
      await _systemBack(tester);
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.text('Quiero ser profesional'), findsNothing);
    });
  });

  test('Android: el gesto atrás predictivo está activado', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:enableOnBackInvokedCallback="true"'));
  });

  testWidgets('tema: deslizar en iOS y atrás predictivo en Android', (tester) async {
    await _pumpApp(tester, DemoBackend.customerPhone);
    await _push(tester, Routes.support);
    // Página Material (no la página sin transición que go_router arma cuando
    // no reconoce el MaterialApp): usa el gesto predictivo del tema.
    expect(ModalRoute.of(tester.element(find.byType(Scaffold).last)), isA<MaterialRouteTransitionMixin<dynamic>>());
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(theme.pageTransitionsTheme.builders[TargetPlatform.iOS], isA<CupertinoPageTransitionsBuilder>());
    expect(theme.pageTransitionsTheme.builders[TargetPlatform.android], isA<PredictiveBackPageTransitionsBuilder>());
  });
}
