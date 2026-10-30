import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/location_service.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/features/booking/request_flow_page.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

Future<DemoAppBackend> _pumpApp(WidgetTester tester, {double textScale = 1}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        backendProvider.overrideWithValue(backend),
        locationServiceProvider.overrideWithValue(const _FakeLocation()),
        mapTileUrlProvider.overrideWithValue(null),
      ],
      child: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: const HandiManYaApp(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

Future<void> _login(WidgetTester tester, {required bool professional, String? phone}) =>
    loginWithPhone(tester, phone ?? (professional ? DemoBackend.professionalPhone : DemoBackend.customerPhone));

class _FakeLocation implements LocationService {
  const _FakeLocation();

  @override
  Future<GeoPoint> current() async => const GeoPoint(-17.7800, -63.1800);
}

Future<void> _tapText(WidgetTester tester, String label) async {
  final f = find.text(label).last;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('el cliente entra y ve el inicio con ¡Ya!', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Omitir'), findsOneWidget);
    await _login(tester, professional: false);

    expect(find.text('¡Hola, Carla!'), findsOneWidget);
    expect(find.byKey(const Key('home-ya-fab')), findsOneWidget);
    expect(find.text('Buscar profesionales'), findsOneWidget);
    expect(find.text('Inicio'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el profesional entra a su panel', (tester) async {
    await _pumpApp(tester);
    await _login(tester, professional: true);

    expect(find.text('No disponible'), findsOneWidget);
    expect(find.text('Saldo total'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.6]) {
    testWidgets('todas las pestañas abren sin errores (letra x$scale)', (tester) async {
      await _pumpApp(tester, textScale: scale);
      await _login(tester, professional: false);
      for (final tab in ['Buscar', 'Solicitudes', 'Mensajes', 'Perfil', 'Inicio']) {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'cliente: $tab');
      }
    });

    testWidgets('pestañas del profesional abren sin errores (letra x$scale)', (tester) async {
      await _pumpApp(tester, textScale: scale);
      await _login(tester, professional: true);
      for (final tab in ['Solicitudes', 'Trabajos', 'Mensajes', 'Perfil', 'Inicio']) {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'profesional: $tab');
      }
    });
  }

  testWidgets('el pedido ¡Ya! se abre desde el inicio', (tester) async {
    await _pumpApp(tester);
    await _login(tester, professional: false);
    await tester.tap(find.byKey(const Key('home-ya-fab')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(RequestFlowPage), findsOneWidget);
  });

  testWidgets('el profesional marca su zona de trabajo con el GPS', (tester) async {
    final backend = await _pumpApp(tester);
    await _login(tester, professional: true);
    await _tapText(tester, 'Perfil');
    await _tapText(tester, 'Mi zona de trabajo');
    await _tapText(tester, 'Actualizar');
    expect(find.text('Usar tu ubicación'), findsOneWidget); // explicación antes del permiso
    await _tapText(tester, 'Continuar');
    await _tapText(tester, 'Guardar');
    expect(tester.takeException(), isNull);
    final loc = await backend.serviceLocation();
    expect(loc?.latitude, -17.78);
    expect(loc?.longitude, -63.18);
  });

  for (final scale in [1.0, 1.6]) {
    testWidgets('el administrador entra a su panel y abre cada sección (letra x$scale)', (tester) async {
      await _pumpApp(tester, textScale: scale);
      await _login(tester, professional: false, phone: DemoBackend.adminPhone);
      expect(find.byKey(const Key('panel-title-owner')), findsOneWidget);
      expect(find.byKey(const Key('owner-summary')), findsOneWidget);
      await tester.tap(find.byKey(const Key('panel-nav-Gestión')));
      await tester.pumpAndSettle();
      for (final section in [
        'Postulaciones',
        'Recargas',
        'Reportes',
        'Disputas',
        'Soporte',
        'Usuarios',
        'Comisiones',
        'Catálogo',
        'Auditoría',
      ]) {
        await _tapText(tester, section);
        expect(tester.takeException(), isNull, reason: section);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
      // Revisar una postulación hasta aprobarla.
      await _tapText(tester, 'Postulaciones');
      await _tapText(tester, 'Rubén Gutiérrez');
      expect(find.byKey(const Key('approve-needs-id')), findsOneWidget);
      // Aceptar el carnet (frente y reverso) habilita la aprobación.
      for (final pick in [find.text('Aceptar').first, find.text('Aceptar').last]) {
        await tester.ensureVisible(pick);
        await tester.pumpAndSettle();
        await tester.tap(pick);
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const Key('approve-needs-id')), findsNothing);
      await _tapText(tester, 'Aprobar profesional');
      await _tapText(tester, 'Aprobar');
      expect(find.text('Este profesional ya está aprobado.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('el cliente reporta a un profesional desde su perfil', (tester) async {
    final backend = await _pumpApp(tester);
    await _login(tester, professional: false);
    await tester.tap(find.text('Buscar').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Juan Carlos Mamani').first);
    await tester.pumpAndSettle();
    expect(find.text('Profesional'), findsOneWidget);
    // La barra de abajo no debe tapar el contenido (antes ocupaba toda la pantalla).
    final body = find.descendant(of: find.byType(Scaffold).last, matching: find.byType(Scrollable)).first;
    expect(tester.getSize(body).height, greaterThan(400));
    await tester.tap(find.byTooltip('Más opciones'));
    await tester.pumpAndSettle();
    await _tapText(tester, 'Reportar');
    await _tapText(tester, 'Trabajo mal hecho');
    await _tapText(tester, 'Enviar reporte');
    expect(tester.takeException(), isNull);
    await backend.signInAs(DemoBackend.adminPhone);
    expect((await backend.adminReports()).any((r) => r.reportedName == 'Juan Carlos Mamani'), isTrue);
  });

  testWidgets('el detalle de una solicitud muestra su contenido y la barra de acciones', (tester) async {
    await _pumpApp(tester);
    await _login(tester, professional: false);
    await tester.tap(find.byKey(const Key('home-ya-fab')));
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(RequestFlowPage)));
    final backend = ProviderScope.containerOf(tester.element(find.byType(RequestFlowPage))).read(backendProvider);
    final id = await backend.create(
      const BookingDraft(
        categoryId: 1, // Plomería: Juan Carlos está disponible
        cityId: 1,
        mode: BookingMode.now,
        description: 'Gotea el caño de la cocina',
        address: 'Calle Los Pinos 123',
      ),
    );
    router.push(Routes.booking(id));
    // "Buscando profesional" tiene una animación continua: se avanza el reloj a mano.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Cancelar solicitud'), findsOneWidget);
    final body = find.descendant(of: find.byType(Scaffold).last, matching: find.byType(Scrollable)).first;
    expect(tester.getSize(body).height, greaterThan(400));
    expect(tester.takeException(), isNull);
  });
}
