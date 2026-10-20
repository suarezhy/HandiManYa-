import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/geo.dart';

BookingDraft _yaAt(double lat, double lng) => BookingDraft(
  categoryId: 2,
  cityId: 1,
  zoneId: 12,
  mode: BookingMode.now,
  description: 'Se cortó la luz en la cocina',
  address: 'Calle Los Pinos 123',
  paymentMethod: PaymentMethod.cash,
  latitude: lat,
  longitude: lng,
);

PhotoUpload _photo() => PhotoUpload(bytes: Uint8List.fromList([1, 2, 3]), fileName: 'foto.jpg');

void main() {
  late DemoBackend backend;

  setUp(() => backend = DemoBackend(simulateDelays: false));
  tearDown(() => backend.dispose());

  Future<void> asPro() => backend.signIn(email: DemoBackend.professionalEmail, password: DemoBackend.demoPassword);
  Future<void> asCustomer() => backend.signIn(email: DemoBackend.customerEmail, password: DemoBackend.demoPassword);

  test('distancia entre dos puntos de Santa Cruz', () {
    // Plaza 24 de Septiembre a Equipetrol: unos 3 km.
    final km = distanceKm(-17.7834, -63.1821, -17.7660, -63.1980);
    expect(km, inInclusiveRange(2, 4));
    expect(distanceKm(-17.78, -63.18, -17.78, -63.18), 0);
  });

  test('zona de trabajo: guarda base y radio, rechaza puntos fuera de Bolivia', () async {
    await asPro();
    await backend.setServiceLocation(latitude: -17.78, longitude: -63.18, radiusKm: 5);
    final loc = await backend.serviceLocation();
    expect(loc?.radiusKm, 5);
    await expectLater(
      backend.setServiceLocation(latitude: 40.4, longitude: -3.7, radiusKm: 5),
      throwsA(isA<AppError>().having((e) => e.code, 'code', 'HMY_INVALID_LOCATION')),
    );
  });

  test('¡Ya! con GPS: solo llega a quien está dentro de su radio, con distancia', () async {
    await asPro();
    await backend.setServiceLocation(latitude: -17.78, longitude: -63.18, radiusKm: 3);
    await backend.setAvailability(true);

    await asCustomer();
    final near = await backend.countYaAvailable(categoryId: 2, cityId: 1, latitude: -17.79, longitude: -63.18);
    final far = await backend.countYaAvailable(categoryId: 2, cityId: 1, latitude: -17.95, longitude: -63.18);
    expect(near, greaterThan(far));

    final id = await backend.create(_yaAt(-17.7912, -63.1801));
    await asPro();
    final offer = (await backend.myBookings(asProfessional: true)).firstWhere((b) => b.id == id);
    expect(offer.distanceKm, isNotNull);
    expect(offer.distanceKm!, lessThan(3));
    // Antes de aceptar sigue sin dirección exacta.
    expect((await backend.detail(id)).address, isNull);
  });

  test('fotos del problema: máximo 5 y solo el cliente las sube', () async {
    await asPro();
    await backend.setAvailability(true);
    await asCustomer();
    final id = await backend.create(_yaAt(-17.7621, -63.1848));
    await backend.addPhotos(id, [_photo(), _photo(), _photo()]);
    expect((await backend.detail(id)).photos, hasLength(3));
    await expectLater(
      backend.addPhotos(id, [_photo(), _photo(), _photo()]),
      throwsA(isA<AppError>().having((e) => e.code, 'code', 'HMY_TOO_MANY_PHOTOS')),
    );

    await asPro();
    // El profesional con la oferta ve las fotos, pero no puede subir.
    expect((await backend.detail(id)).photos, hasLength(3));
    await expectLater(backend.addPhotos(id, [_photo()]), throwsA(isA<AppError>()));
  });
}
