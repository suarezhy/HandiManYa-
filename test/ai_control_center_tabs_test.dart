import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/admin/ai_control_center_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

const _tabs = ['Estado general', 'Decisiones', 'Agentes IA', 'Reporte diario'];

bool _inside(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;

void main() {
  testWidgets('Centro de Control IA a 320 px: todas las pestañas se alcanzan y se ven enteras', (tester) async {
    await initializeDateFormatting('es');
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    await backend.signInAs(DemoBackend.adminPhone);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(320, 568) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('es', 'BO'),
          supportedLocales: const [Locale('es', 'BO')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const AiControlCenterPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    const screen = Rect.fromLTWH(0, 0, 320, 568);
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.isScrollable, isTrue);
    expect(bar.tabAlignment, TabAlignment.start);
    // La primera pestaña empieza en el borde, sin hueco que empuje a las demás.
    expect(tester.getRect(find.text(_tabs.first)).left, lessThan(32));
    expect(_inside(screen, tester.getRect(find.text(_tabs.first))), isTrue);

    for (final (i, name) in _tabs.indexed) {
      // Cada pestaña tiene su nombre para el lector de pantalla.
      expect(find.bySemanticsLabel(RegExp('^${RegExp.escape(name)}')), findsOneWidget, reason: name);
      await tester.dragUntilVisible(find.text(name), find.byType(TabBar), const Offset(-80, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
      expect(DefaultTabController.of(tester.element(find.byType(TabBar))).index, i);
      // La pestaña elegida queda entera en la pantalla.
      expect(
        _inside(screen, tester.getRect(find.text(name))),
        isTrue,
        reason: '$name: ${tester.getRect(find.text(name))}',
      );
      expect(tester.takeException(), isNull);
    }

    // Volver a la primera la trae de vuelta a la vista.
    await tester.dragUntilVisible(find.text(_tabs.first), find.byType(TabBar), const Offset(80, 0));
    await tester.tap(find.text(_tabs.first));
    await tester.pumpAndSettle();
    expect(_inside(screen, tester.getRect(find.text(_tabs.first))), isTrue);
    semantics.dispose();
  });
}
