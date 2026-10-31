import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/pro_mode/application_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Barra del sistema: tres botones (48 dp) o gestos (24 dp), como en Android 15 de borde a borde.
Future<DemoAppBackend> _pump(
  WidgetTester tester, {
  required Size size,
  double navBar = 48,
  double textScale = 1,
  DemoAppBackend? backend,
}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final b = backend ?? DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  if (backend == null) await b.signInAs(DemoBackend.customerPhone);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: 24, bottom: navBar);
  tester.view.viewPadding = FakeViewPadding(top: 24, bottom: navBar);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(b)],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('es'),
        supportedLocales: const [Locale('es')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const ApplicationPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return b;
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  final scrollable = find.descendant(of: find.byKey(const Key('application-form')), matching: find.byType(Scrollable));
  final state = tester.state<ScrollableState>(scrollable.first);
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Etapa 1 completa: nombre, servicio principal y descripción.
Future<void> _fillServices(WidgetTester tester, {String primary = 'Limpieza'}) async {
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), 'Rosa Mamani');
  await tester.enterText(fields.at(2), 'Limpieza de casas y oficinas en Uyuni, con productos propios.');
  await _tapKey(tester, 'application-primary');
  await tester.tap(find.text(primary).last);
  await tester.pumpAndSettle();
}

/// Etapa 2: un municipio sin zonas, fuera de las tres ciudades.
Future<void> _chooseUyuni(WidgetTester tester) async {
  await _tapKey(tester, 'application-city');
  await tester.enterText(find.byKey(const Key('city-search')), 'uyuni');
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('city-uyuni-pt')));
  await tester.pumpAndSettle();
}

void _expectAboveSystemBar(WidgetTester tester, String key, Size size, double navBar) {
  final r = tester.getRect(find.byKey(Key(key)));
  expect(r.bottom, lessThanOrEqualTo(size.height - navBar), reason: '$key tapado por la barra del sistema');
  expect(r.left >= 0 && r.right <= size.width, isTrue, reason: '$key se sale de la pantalla');
}

void main() {
  for (final (size, navBar, scale) in [
    (const Size(320, 568), 48.0, 1.0),
    (const Size(360, 640), 48.0, 1.3),
    (const Size(360, 640), 24.0, 1.0),
    (const Size(393, 852), 34.0, 1.6), // iPhone con indicador de inicio
    (const Size(412, 915), 48.0, 1.0),
  ]) {
    testWidgets('en cada etapa los botones quedan por encima de la barra del sistema en '
        '${size.width.toInt()}x${size.height.toInt()}, barra $navBar, texto x$scale', (tester) async {
      await _pump(tester, size: size, navBar: navBar, textScale: scale);
      expect(tester.takeException(), isNull);
      await _scrollToEnd(tester);
      for (final key in ['application-next', 'application-save-draft']) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        _expectAboveSystemBar(tester, key, size, navBar);
      }
      await _fillServices(tester);
      await _tapKey(tester, 'application-next');
      expect(find.text('Dónde trabajo'), findsWidgets);
      await _chooseUyuni(tester);
      await _tapKey(tester, 'application-next');
      expect(find.text('Verificación'), findsWidgets);
      await _scrollToEnd(tester);
      for (final key in ['application-submit', 'application-save-draft', 'doc-ci-anverso', 'doc-ci-reverso']) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        _expectAboveSystemBar(tester, key, size, navBar);
      }
      await _scrollToEnd(tester);
      _expectAboveSystemBar(tester, 'application-save-draft', size, navBar);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tres etapas: no avanza sin lo obligatorio y se puede volver', (tester) async {
    await _pump(tester, size: const Size(360, 640));
    expect(find.byKey(const Key('application-city')), findsNothing, reason: 'el municipio va en la etapa 2');
    expect(find.byKey(const Key('doc-ci-anverso')), findsNothing, reason: 'los documentos van en la etapa 3');
    await _tapKey(tester, 'application-next');
    expect(find.text('Escribe al menos 20 caracteres'), findsOneWidget);
    expect(find.byKey(const Key('application-city')), findsNothing);
    await _fillServices(tester);
    await _tapKey(tester, 'application-next');
    expect(find.byKey(const Key('application-city')), findsOneWidget);
    expect(find.byKey(const Key('application-service-area')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing, reason: 'no pide el municipio antes de mostrar el campo');
    await _tapKey(tester, 'application-back');
    expect(find.text('Rosa Mamani'), findsOneWidget, reason: 'al volver se conserva lo escrito');
  });

  testWidgets('el borrador se guarda sin enviarse y vuelve al abrir otra vez', (tester) async {
    final backend = await _pump(tester, size: const Size(412, 915));
    await _fillServices(tester);
    await _tapKey(tester, 'application-next');
    await _chooseUyuni(tester);
    // Perfil ya leyó la cuenta (sin postulación) antes de guardar.
    final container = ProviderScope.containerOf(tester.element(find.byType(ApplicationPage)));
    final auth = container.listen(authUserProvider, (_, _) {});
    await container.read(authUserProvider.future);
    final account = container.listen(accountProvider, (_, _) {});
    expect((await container.read(accountProvider.future))!.professionalStatus, VerificationStatus.notStarted);
    await _tapKey(tester, 'application-save-draft');
    expect(find.text('Borrador guardado'), findsOneWidget);
    // Perfil pasa a "Postulación: Borrador" sin volver a abrir la app.
    expect((await container.read(accountProvider.future))!.professionalStatus, VerificationStatus.draft);
    account.close();
    auth.close();

    final app = await backend.application();
    expect(app.status.canEdit, isTrue, reason: 'guardar no envía la postulación');
    expect(app.displayName, 'Rosa Mamani');

    // Volver a abrir: los datos guardados aparecen.
    await _pump(tester, size: const Size(412, 915), backend: backend);
    expect(find.text('Rosa Mamani'), findsOneWidget);
    expect(find.text('Limpieza de casas y oficinas en Uyuni, con productos propios.'), findsOneWidget);
    await _tapKey(tester, 'application-next');
    expect(find.text('Uyuni'), findsOneWidget);
  });

  testWidgets('otros servicios: buscador con recomendados primero, chips que se quitan', (tester) async {
    await _pump(tester, size: const Size(320, 568), textScale: 1.3);
    // Ya no hay una lista larga de chips en el formulario.
    expect(find.byType(FilterChip), findsNothing);
    final primary = find.byKey(const Key('application-primary'));
    await tester.ensureVisible(primary);
    await tester.pumpAndSettle();
    await tester.tap(primary);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Electricidad').last);
    await tester.pumpAndSettle();

    final add = find.byKey(const Key('add-extra-services'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Recomendados para ti'), findsOneWidget);
    expect(find.byKey(const Key('service-electricidad')), findsNothing, reason: 'el principal no se repite');
    // Los relacionados (hogar) aparecen antes que el resto.
    final first = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).first).key! as ValueKey<String>;
    expect(
      ['service-plomeria', 'service-albanileria', 'service-pintura', 'service-reparaciones-hogar'],
      contains(first.value),
      reason: 'el primero recomendado es de hogar',
    );
    await tester.tap(find.byKey(const Key('service-plomeria')));
    await tester.enterText(find.byKey(const Key('service-search')), 'jardin');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('service-plomeria')), findsNothing);
    await tester.tap(find.byKey(const Key('service-jardineria')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-done')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byKey(const Key('extra-plomeria')), findsOneWidget);
    expect(find.byKey(const Key('extra-jardineria')), findsOneWidget);
    final chip = find.byKey(const Key('extra-jardineria'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Quitar Jardinería'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('extra-jardineria')), findsNothing);
    expect(find.byKey(const Key('extra-plomeria')), findsOneWidget);
  });
}
