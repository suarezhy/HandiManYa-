// Publicidad propia del inicio: el espacio sale solo con un anuncio aprobado,
// siempre dice "Publicidad" o "Patrocinado", no deja hueco cuando no hay, y el
// Propietario lo administra.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/ads.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/home/home_ad.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';
import 'support/layout_checks.dart';

Future<DemoAppBackend> _pump(
  WidgetTester tester,
  String phone, {
  Size size = const Size(360, 800),
  double scale = 1,
}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  await backend.signInAs(phone);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 24 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 24 * 3, bottom: 24 * 3);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        backendProvider.overrideWithValue(backend),
        mapTileUrlProvider.overrideWithValue(null),
      ],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  for (final (size, scale) in [(const Size(320, 568), 1.3), (const Size(384, 832), 1.0), (const Size(360, 800), 2.0)]) {
    testWidgets('inicio: el anuncio sale entre "Buscar profesionales" y Servicios, con su etiqueta '
        '(${size.width.toInt()}px x$scale)', (tester) async {
      await loadAppFonts(tester);
      await _pump(tester, DemoBackend.customerPhone, size: size, scale: scale);
      final ad = find.byKey(const Key('home-ad'));
      await tester.ensureVisible(ad);
      await tester.pumpAndSettle();
      expect(ad, findsOneWidget);
      expect(find.descendant(of: ad, matching: find.text('Publicidad')), findsOneWidget);
      expect(find.descendant(of: ad, matching: find.text('Ferretería El Tornillo')), findsOneWidget);
      final top = tester.getRect(ad);
      expect(top.top, greaterThan(tester.getRect(find.byKey(const Key('home-search-pros'))).bottom));
      expect(top.bottom, lessThan(tester.getRect(find.text('Servicios')).top));
      expect(textProblems(tester, size), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('inicio: sin anuncios aprobados el espacio no aparece ni deja hueco', (tester) async {
    await loadAppFonts(tester);
    final backend = await _pump(tester, DemoBackend.adminPhone);
    await backend.setAdStatus(1, AdAction.pause);
    await backend.signInAs(DemoBackend.customerPhone);
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    container.invalidate(homeAdProvider);
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(Routes.home);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-ad')), findsNothing);
    expect(find.text('Publicidad'), findsNothing);
    expect(tester.getSize(find.byType(HomeAdSlot)).height, 0);
  });

  test('rotación justa, cuentas sin datos del cliente y solo el Propietario administra', () async {
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    await backend.signInAs(DemoBackend.adminPhone);
    final id = await backend.saveAd(
      const AdDraft(advertiser: 'Pinturas Andinas', title: 'Pintura lavable', label: 'Patrocinado'),
    );
    expect((await backend.ownerAds()).firstWhere((a) => a.id == id).status, AdStatus.draft);
    await expectLater(
      backend.saveAd(const AdDraft(advertiser: 'Tienda', title: 'Enlace', linkUrl: 'http://inseguro.bo')),
      throwsA(isA<AppError>()),
    );
    await backend.setAdStatus(id, AdAction.approve);

    await backend.signInAs(DemoBackend.customerPhone);
    final seen = [for (var i = 0; i < 6; i++) (await backend.homeAd(1))!.id];
    expect(seen.where((s) => s == id).length, 3, reason: 'dos anunciantes, tres vistas cada uno');
    expect(await backend.adClick(1), 'https://ferreteria.example.bo');
    await expectLater(backend.ownerAds(), throwsA(isA<AppError>()));

    await backend.signInAs(DemoBackend.adminPhone);
    final ads = await backend.ownerAds();
    final first = ads.firstWhere((a) => a.id == 1);
    expect((first.impressions, first.clicks), (3, 1));
    expect(ads.firstWhere((a) => a.id == id).label, 'Patrocinado');

    // Editar uno aprobado lo saca del inicio hasta aprobarlo otra vez.
    await backend.saveAd(AdDraft(id: id, advertiser: 'Pinturas Andinas', title: 'Pintura al 2x1'));
    expect((await backend.ownerAds()).firstWhere((a) => a.id == id).status, AdStatus.draft);
    await backend.setAdStatus(1, AdAction.remove);
    await backend.signInAs(DemoBackend.customerPhone);
    expect(await backend.homeAd(1), isNull);
  });

  testWidgets('Propietario: crea, aprueba y pausa un anuncio', (tester) async {
    await loadAppFonts(tester);
    await _pump(tester, DemoBackend.adminPhone, size: const Size(360, 800), scale: 1.3);
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push(Routes.adminAds);
    await tester.pumpAndSettle();
    expect(find.text('En el inicio'), findsOneWidget);
    expect(textProblems(tester, const Size(360, 800)), isEmpty);

    await tester.tap(find.byKey(const Key('ads-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ad-advertiser')), 'Pinturas Andinas');
    await tester.enterText(find.byKey(const Key('ad-title')), 'Pintura lavable');
    await tester.enterText(find.byKey(const Key('ad-link')), 'http://inseguro.bo');
    FocusManager.instance.primaryFocus?.unfocus(); // si no, el cursor vuelve a llevar la vista al campo
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('ad-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ad-save')));
    await tester.pumpAndSettle();
    expect(find.text('Debe empezar con https:// y tener un dominio'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ad-link')), 'https://pinturas.example.bo');
    FocusManager.instance.primaryFocus?.unfocus(); // si no, el cursor vuelve a llevar la vista al campo
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('ad-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ad-save')));
    await tester.pumpAndSettle();

    expect(find.text('Por aprobar'), findsOneWidget);
    // Que se vaya el aviso de abajo antes de tocar los botones.
    ScaffoldMessenger.of(tester.element(find.byKey(const Key('ad-2')))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('ad-approve-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ad-approve-2')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('ad-2')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('ad-2')), matching: find.text('En el inicio')), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byKey(const Key('ad-2')))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('ad-pause-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ad-pause-2')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('ad-2')), matching: find.text('Pausado')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
