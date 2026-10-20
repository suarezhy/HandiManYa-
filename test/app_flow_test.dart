import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/location_service.dart';
import 'package:handimanya/core/widgets/buttons.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/features/booking/request_flow_page.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<DemoAppBackend> _pumpApp(WidgetTester tester, {double textScale = 1}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false);
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

Future<void> _login(WidgetTester tester, {required bool professional}) async {
  await tester.tap(find.text('Omitir'));
  await tester.pumpAndSettle();
  final door = find.text(professional ? 'Soy profesional' : 'Necesito un servicio');
  await tester.ensureVisible(door);
  await tester.pumpAndSettle();
  await tester.tap(door);
  await tester.pumpAndSettle();
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), professional ? DemoBackend.professionalEmail : DemoBackend.customerEmail);
  await tester.enterText(fields.at(1), DemoBackend.demoPassword);
  final submit = find.widgetWithText(FilledButton, 'Ingresar');
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle();
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

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
    expect(find.text('Programar para después'), findsOneWidget);
    expect(find.text('Inicio'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el profesional entra a su panel', (tester) async {
    await _pumpApp(tester);
    await _login(tester, professional: true);

    expect(find.text('No disponible'), findsOneWidget);
    expect(find.text('Saldo de tu billetera'), findsOneWidget);
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
    await tester.tap(find.byType(YaButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(RequestFlowPage), findsOneWidget);
  });

  testWidgets('el profesional marca su zona de trabajo con el GPS', (tester) async {
    final backend = await _pumpApp(tester);
    await _login(tester, professional: true);
    await _tapText(tester, 'Perfil');
    await _tapText(tester, 'Mi zona de trabajo');
    await _tapText(tester, 'Actualizar con mi ubicación actual');
    expect(find.text('Usar tu ubicación'), findsOneWidget); // explicación antes del permiso
    await _tapText(tester, 'Continuar');
    await _tapText(tester, 'Guardar');
    expect(tester.takeException(), isNull);
    final loc = await backend.serviceLocation();
    expect(loc?.latitude, -17.78);
    expect(loc?.longitude, -63.18);
  });
}
