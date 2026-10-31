import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/formatters.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/booking/booking_card.dart';
import 'package:handimanya/features/pro_mode/pro_jobs_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

BookingSummary _b({
  String id = 'b1',
  BookingStatus status = BookingStatus.confirmed,
  BookingMode mode = BookingMode.now,
  double? agreed = 120,
  double extras = 0,
  double? finalAmount,
  bool isOffer = false,
}) => BookingSummary(
  id: id,
  code: 'F9A50778',
  status: status,
  mode: mode,
  categoryId: 1,
  category: 'Plomería',
  city: 'Santa Cruz de la Sierra',
  zone: 'Equipetrol',
  description: 'Gotea la ducha',
  problems: const ['Fuga de agua'],
  scheduledStart: mode == BookingMode.scheduled ? DateTime(2026, 11, 2, 9) : null,
  createdAt: DateTime(2026, 10, 29, 23, 31),
  otherUserId: 'c1',
  otherName: 'Rosa',
  agreedAmount: agreed,
  extrasAmount: extras,
  finalAmount: finalAmount,
  isOffer: isOffer,
);

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

String _price(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(Key('booking-price-$id'))).textSpan?.toPlainText() ??
    tester.widget<Text>(find.byKey(Key('booking-price-$id'))).data!;

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  testWidgets('trabajo acordado: número, servicio, precio, cliente, "Ahora" y zona', (tester) async {
    await tester.pumpWidget(_app(BookingCard(booking: _b(), asProfessional: true)));
    expect(find.text('Solicitud #F9A50778'), findsOneWidget);
    expect(find.text('Plomería'), findsOneWidget);
    expect(find.text('Fuga de agua'), findsOneWidget);
    expect(_price(tester, 'b1'), 'Precio acordado ${Fmt.bs(120)}');
    expect(find.text('Rosa'), findsOneWidget);
    expect(find.text('Ahora'), findsOneWidget);
    expect(find.text('Equipetrol'), findsOneWidget);
  });

  testWidgets('sin precio acordado dice "Precio pendiente"', (tester) async {
    await tester.pumpWidget(
      _app(BookingCard(booking: _b(agreed: null, status: BookingStatus.requested), asProfessional: false)),
    );
    expect(_price(tester, 'b1'), 'Precio pendiente');
  });

  testWidgets('programado muestra fecha y hora; lo aparte se suma', (tester) async {
    await tester.pumpWidget(
      _app(BookingCard(booking: _b(mode: BookingMode.scheduled, extras: 30), asProfessional: false)),
    );
    expect(find.text(Fmt.dateTime(DateTime(2026, 11, 2, 9))), findsOneWidget);
    expect(_price(tester, 'b1'), 'Precio acordado ${Fmt.bs(150)}');
  });

  testWidgets('cancelado y completado conservan número y precio', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            BookingCard(
              booking: _b(id: 'x', status: BookingStatus.cancelled),
              asProfessional: true,
            ),
            BookingCard(
              booking: _b(id: 'y', status: BookingStatus.completed, finalAmount: 150),
              asProfessional: true,
            ),
          ],
        ),
      ),
    );
    expect(find.text('Solicitud #F9A50778'), findsNWidgets(2));
    expect(_price(tester, 'x'), 'Precio acordado ${Fmt.bs(120)}');
    expect(_price(tester, 'y'), 'Precio del trabajo ${Fmt.bs(150)}');
  });

  for (final (size, scale) in [(const Size(320, 568), 2.0), (const Size(360, 640), 1.3), (const Size(412, 915), 1.0)]) {
    testWidgets('cabe sin desbordes en ${size.width.toInt()}x${size.height.toInt()} con letra x$scale', (tester) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: BookingCard(booking: _b(mode: BookingMode.scheduled, extras: 1250.5), asProfessional: true),
          ),
          textScale: scale,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Activos del profesional muestra el trabajo confirmado; Historial el cancelado', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          backendProvider.overrideWithValue(backend),
          myBookingsProvider(true).overrideWith(
            (ref) async => [
              _b(id: 'activo'),
              _b(id: 'oferta', isOffer: true, agreed: null, status: BookingStatus.awaitingResponse),
              _b(id: 'viejo', status: BookingStatus.cancelled),
            ],
          ),
        ],
        child: _app(const ProJobsPage(incoming: false)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('booking-card-activo')), findsOneWidget);
    expect(find.byKey(const Key('booking-card-oferta')), findsNothing);
    expect(find.byKey(const Key('booking-card-viejo')), findsNothing);
    await tester.tap(find.text('Historial'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('booking-card-viejo')), findsOneWidget);
  });

  testWidgets('al volver a la app las listas se recargan', (tester) async {
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    final container = ProviderContainer(overrides: [backendProvider.overrideWithValue(backend)]);
    addTearDown(container.dispose);
    final ticks = <int>[];
    container.listen(bookingChangesProvider, (_, next) => next.whenData(ticks.add), fireImmediately: true);
    await tester.pump();
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    expect(ticks, isEmpty);
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    expect(ticks, [1]);
  });
}
