import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/location_service.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/booking/booking_detail_page.dart';
import 'package:handimanya/features/booking/live_trip.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

class _FakeLocation implements LocationService {
  _FakeLocation(this.point);

  final GeoPoint point;
  int calls = 0;

  @override
  Future<GeoPoint> current() async {
    calls++;
    return point;
  }
}

const _draft = BookingDraft(
  categoryId: 2,
  cityId: 1,
  zoneId: 12,
  mode: BookingMode.now,
  description: 'Se cortó la luz en la cocina',
  address: 'Calle Los Pinos 123',
  latitude: -17.7833,
  longitude: -63.1821,
);

const _near = GeoPoint(-17.80, -63.20);

Future<String> _onTheWay(DemoBackend backend) async {
  await backend.signInAs(DemoBackend.professionalPhone);
  await backend.setAvailability(true);
  await backend.signInAs(DemoBackend.customerPhone);
  final id = await backend.create(_draft);
  await backend.signInAs(DemoBackend.professionalPhone);
  await backend.accept(id, isOffer: true);
  return id;
}

void main() {
  late DemoBackend backend;

  setUp(() => backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero));
  tearDown(() => backend.dispose());

  Future<void> asPro() => backend.signInAs(DemoBackend.professionalPhone);
  Future<void> asCustomer() => backend.signInAs(DemoBackend.customerPhone);

  group('ubicación en vivo', () {
    test('solo en camino, solo el profesional asignado, y el cliente ve distancia y tiempo', () async {
      final id = await _onTheWay(backend);
      await expectLater(backend.shareTripLocation(id, _near), _code('HMY_TRIP_NOT_ACTIVE'));
      await backend.updateProgress(id, BookingStatus.onTheWay);
      await expectLater(backend.shareTripLocation(id, const GeoPoint(40.7, -74)), _code('HMY_INVALID_LOCATION'));
      expect(await backend.shareTripLocation(id, _near), isTrue);
      expect(await backend.shareTripLocation(id, _near), isFalse, reason: 'más de una vez cada 5 s se ignora');

      await asCustomer();
      await expectLater(backend.shareTripLocation(id, _near), _code('HMY_FORBIDDEN'));
      final t = await backend.tripLocation(id);
      expect(t.live, isTrue);
      expect(t.distanceKm, greaterThan(0));
      expect(t.etaMinutes, greaterThanOrEqualTo(1));

      await backend.signInAs('+59171112233');
      await expectLater(backend.tripLocation(id), _code('HMY_FORBIDDEN'));
    });

    test('se deja de compartir al verificar la llegada o al pausar', () async {
      final id = await _onTheWay(backend);
      await backend.updateProgress(id, BookingStatus.onTheWay);
      await backend.shareTripLocation(id, _near);
      await backend.stopTripLocation(id);
      await asCustomer();
      expect((await backend.tripLocation(id)).hasPoint, isFalse);

      await asPro();
      await backend.shareTripLocation(id, _near);
      final pin = await backend.markArrived(id);
      await asCustomer();
      await backend.verifyArrivalPin(id, pin.pin);
      expect((await backend.tripLocation(id)).live, isFalse);
      await asPro();
      await expectLater(backend.shareTripLocation(id, _near), _code('HMY_TRIP_NOT_ACTIVE'));
    });
  });

  group('viaje compartido', () {
    test('el contacto ve quién va y la ubicación; se anula y deja de servir al cancelar', () async {
      final id = await _onTheWay(backend);
      await backend.updateProgress(id, BookingStatus.onTheWay);
      await backend.shareTripLocation(id, _near);
      await expectLater(backend.createTripShare(id), _code('HMY_FORBIDDEN'));

      await asCustomer();
      final token = await backend.createTripShare(id, contactName: 'Mamá');
      final seen = await backend.sharedTrip(token);
      expect(seen.professionalName, isNotEmpty);
      expect(seen.professionalVerified, isTrue);
      expect(seen.trip?.hasPoint, isTrue);
      await expectLater(backend.sharedTrip('no-existe'), _code('HMY_SHARE_NOT_FOUND'));

      await backend.createTripShare(id);
      await backend.createTripShare(id);
      await expectLater(backend.createTripShare(id), _code('HMY_TOO_MANY_SHARES'));
      final shares = await backend.tripShares(id);
      expect(shares, hasLength(3));
      await backend.revokeTripShare(shares.last.id);
      await expectLater(backend.sharedTrip(token), _code('HMY_SHARE_NOT_FOUND'));

      final other = await backend.createTripShare(id);
      // En camino, solo el profesional puede cancelar.
      await asPro();
      await backend.cancel(id, 'Se me pinchó la llanta');
      await expectLater(backend.sharedTrip(other), _code('HMY_SHARE_NOT_FOUND'));
    });
  });

  group('pantallas', () {
    Future<void> pump(WidgetTester tester, DemoAppBackend app, Widget page, {_FakeLocation? location}) async {
      await initializeDateFormatting('es');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            backendProvider.overrideWithValue(app),
            locationServiceProvider.overrideWithValue(location ?? _FakeLocation(_near)),
            tripShareBaseUrlProvider.overrideWithValue('https://ejemplo.bo'),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('es', 'BO'),
            supportedLocales: const [Locale('es', 'BO')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('el profesional comparte en camino y puede pausar; el cliente ve la distancia', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = (await tester.runAsync(() async {
        final id = await _onTheWay(app);
        await app.updateProgress(id, BookingStatus.onTheWay);
        return id;
      }))!;

      final gps = _FakeLocation(_near);
      await pump(tester, app, BookingDetailPage(id: id), location: gps);
      expect(find.byKey(const Key('pro-trip-sharer')), findsOneWidget);
      expect(find.text('Compartiendo tu ubicación con el cliente'), findsOneWidget);
      expect(gps.calls, greaterThan(0));

      await tester.runAsync(() => app.signInAs(DemoBackend.customerPhone));
      await pump(tester, app, BookingDetailPage(id: id));
      expect(find.byKey(const Key('customer-trip')), findsOneWidget);
      expect(find.textContaining(' km'), findsWidgets);
      expect(find.text('Ver en el mapa'), findsOneWidget);
      expect(find.byKey(const Key('share-trip')), findsOneWidget);

      // Pausar: el profesional deja de compartir y el cliente ya no ve el punto.
      await tester.runAsync(() => app.signInAs(DemoBackend.professionalPhone));
      await pump(tester, app, BookingDetailPage(id: id), location: gps);
      await tester.tap(find.byKey(const Key('pro-trip-switch')));
      await tester.pumpAndSettle();
      expect(find.text('Ubicación en pausa'), findsOneWidget);
      await tester.runAsync(() => app.signInAs(DemoBackend.customerPhone));
      expect((await tester.runAsync(() => app.tripLocation(id)))!.hasPoint, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('la página del enlace muestra al profesional y el estado, sin la dirección', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final token = (await tester.runAsync(() async {
        final id = await _onTheWay(app);
        await app.updateProgress(id, BookingStatus.onTheWay);
        await app.shareTripLocation(id, _near);
        await app.signInAs(DemoBackend.customerPhone);
        return app.createTripShare(id, contactName: 'Mamá');
      }))!;
      await pump(tester, app, TripSharePage(token: token));
      expect(find.textContaining('compartió su servicio contigo'), findsOneWidget);
      expect(find.byKey(const Key('shared-status')), findsOneWidget);
      expect(find.textContaining('Los Pinos'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
