import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/core/widgets/common.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/professional.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/booking/request_flow_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  theme: AppTheme.light(),
  locale: const Locale('es', 'BO'),
  supportedLocales: const [Locale('es', 'BO')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (c, w) => MediaQuery(
    data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
    child: w!,
  ),
  home: Scaffold(body: child),
);

void main() {
  test('la categoría se lee del servidor; lo desconocido es "sin categoría"', () {
    expect(RankTier.parse('plata'), RankTier.plata);
    expect(RankTier.parse('oro'), RankTier.oro);
    expect(RankTier.parse('diamante'), RankTier.diamante);
    expect(RankTier.parse(null), RankTier.none);
    expect(RankTier.parse('platino'), RankTier.none);
    expect(
      ProfessionalSummary.fromMap({'id': 'x', 'display_name': 'X', 'rank_tier': 'oro', 'is_verified': false}).rankTier,
      RankTier.oro,
    );
  });

  test('fuera del horario del profesional se explica en español', () {
    expect(AppError.from(Exception('HMY_OUTSIDE_AVAILABILITY')).message, contains('no atiende'));
  });

  testWidgets('"Identidad verificada" con escudo, distinto de la categoría', (tester) async {
    await tester.pumpWidget(
      _app(
        const Column(
          children: [
            VerifiedBadge(),
            RankBadge(tier: RankTier.diamante),
          ],
        ),
      ),
    );
    expect(find.text('Identidad verificada'), findsOneWidget);
    expect(find.byIcon(Icons.verified_user), findsOneWidget);
    expect(find.text('Diamante'), findsOneWidget);
    expect(find.text('Verificado'), findsNothing);
  });

  testWidgets('sin categoría no se muestra nada y sin reseñas lo dice', (tester) async {
    await tester.pumpWidget(
      _app(
        const Column(
          children: [
            RankBadge(tier: RankTier.none),
            RatingLabel(rating: 0, count: 0),
          ],
        ),
      ),
    );
    expect(find.byType(InkWell), findsNothing);
    expect(find.text('Nuevo · Sin reseñas todavía'), findsOneWidget);
  });

  testWidgets('tocar la categoría explica qué significa y que no es identidad', (tester) async {
    await tester.pumpWidget(_app(const Center(child: RankBadge(tier: RankTier.oro))));
    await tester.tap(find.byKey(const Key('rank-badge-oro')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rank-info')), findsOneWidget);
    expect(find.text('Categoría Oro'), findsOneWidget);
    expect(find.textContaining('no se puede comprar'), findsOneWidget);
    expect(find.textContaining('no es una verificación de identidad'), findsOneWidget);
  });

  testWidgets('las insignias caben con letra grande en un teléfono chico', (tester) async {
    tester.view.physicalSize = const Size(320, 568) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        const Padding(
          padding: EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              Text('Juan Carlos Mamani Quispe'),
              VerifiedBadge(),
              RankBadge(tier: RankTier.diamante),
              RatingLabel(rating: 4.9, count: 210),
            ],
          ),
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Programar desde un perfil: dice para quién es y su categoría', (tester) async {
    await initializeDateFormatting('es');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    await backend.signInAs('+59171000001');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
        child: _app(
          const RequestFlowPage(professionalId: 'p1', initialMode: BookingMode.scheduled, initialCategoryId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Para: Juan Carlos Mamani'), findsOneWidget);
    expect(find.byKey(const Key('rank-badge-oro')), findsOneWidget);
    expect(find.text('Programar servicio'), findsOneWidget);
  });
}
