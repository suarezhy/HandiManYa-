import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test/support/demo_login.dart';
import 'shots.dart';

Future<void> pumpCustomerHome(WidgetTester tester, Size size, {double scale = 1, int? city}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true, 'selected_city_v1': ?city});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false);
  addTearDown(backend.dispose);
  await backend.signInAs(DemoBackend.customerPhone);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 24 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 24 * 3, bottom: 24 * 3);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  // Las pruebas dibujan las sombras como un borde negro; aquí, como en el teléfono.
  debugDisableShadows = false;
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
}

void main() {
  setUpAll(loadShotFonts);
  final skip = shotsDir.isEmpty ? 'HMY_SHOTS no está definido' : null;
  for (final (name, size, scale, city) in [
    ('home-360x800', const Size(360, 800), 1.0, null),
    ('home-360x800-x1.3', const Size(360, 800), 1.3, null),
    ('home-320x568-x1.3', const Size(320, 568), 1.3, null),
    ('home-360x800-sin-profesionales', const Size(360, 800), 1.0, 239),
  ]) {
    testWidgets(name, skip: skip != null, (tester) async {
      await pumpCustomerHome(tester, size, scale: scale, city: city);
      await shot(tester, name);
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      list.position.jumpTo(list.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await shot(tester, '$name-final');
      debugDisableShadows = true;
    });
  }
}
