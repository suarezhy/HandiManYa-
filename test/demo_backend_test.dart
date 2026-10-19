import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/user.dart';

const _ya = BookingDraft(
  categoryId: 2, // Electricidad
  cityId: 1, // Santa Cruz
  zoneId: 12,
  mode: BookingMode.now,
  description: 'Se cortó la luz en la cocina',
  address: 'Calle Los Pinos 123',
  paymentMethod: PaymentMethod.cash,
);

void main() {
  late DemoBackend backend;

  setUp(() => backend = DemoBackend(simulateDelays: false));
  tearDown(() => backend.dispose());

  Future<void> asPro() => backend.signIn(email: DemoBackend.professionalEmail, password: DemoBackend.demoPassword);
  Future<void> asCustomer() => backend.signIn(email: DemoBackend.customerEmail, password: DemoBackend.demoPassword);

  test('¡Ya! completo: oferta, aceptación, trabajo y comisión', () async {
    await asPro();
    await backend.setAvailability(true);
    final startBalance = (await backend.wallet()).available;

    await asCustomer();
    final id = await backend.create(_ya);
    expect((await backend.detail(id)).status, BookingStatus.awaitingResponse);

    await asPro();
    final offers = await backend.myBookings(asProfessional: true);
    final offer = offers.firstWhere((b) => b.id == id);
    expect(offer.isOffer, isTrue);

    // Antes de aceptar, el profesional no ve la dirección exacta.
    expect((await backend.detail(id)).address, isNull);

    await backend.accept(id, isOffer: true);
    final confirmed = await backend.detail(id);
    expect(confirmed.status, BookingStatus.confirmed);
    expect(confirmed.address, isNotNull);
    final reserved = await backend.wallet();
    expect(reserved.reserved, greaterThan(0));
    expect(reserved.available, lessThan(startBalance));

    await backend.updateProgress(id, BookingStatus.onTheWay);
    await backend.updateProgress(id, BookingStatus.inProgress);
    await backend.updateProgress(id, BookingStatus.workFinished, finalAmount: 150);

    await asCustomer();
    await backend.confirmCompletion(id);
    expect((await backend.detail(id)).status, BookingStatus.completed);
    await backend.submitReview(id, 5, '¡Excelente!');

    await asPro();
    final after = await backend.wallet();
    expect(after.reserved, 0);
    expect(after.available, lessThan(startBalance));
  });

  test('¡Ya!: si nadie está disponible avisa con un mensaje claro', () async {
    await asCustomer();
    await expectLater(
      backend.create(
        const BookingDraft(
          categoryId: 999,
          cityId: 1,
          mode: BookingMode.now,
          description: 'Algo que nadie ofrece',
          address: 'Calle 1',
        ),
      ),
      throwsA(isA<AppError>().having((e) => e.code, 'code', 'HMY_NO_PROFESSIONALS_AVAILABLE')),
    );
  });

  test('cancelar un trabajo aceptado devuelve la comisión reservada', () async {
    await asPro();
    await backend.setAvailability(true);
    final start = await backend.wallet();

    await asCustomer();
    final id = await backend.create(_ya);
    await asPro();
    await backend.accept(id, isOffer: true);
    await asCustomer();
    await backend.cancel(id, 'Ya lo solucioné');

    await asPro();
    final w = await backend.wallet();
    expect(w.available, start.available);
    expect(w.reserved, 0);
  });

  test('el modo profesional exige un perfil aprobado', () async {
    await asCustomer();
    await expectLater(backend.setActiveRole(AppRole.professional), throwsA(isA<AppError>()));
    await asPro();
    await backend.setActiveRole(AppRole.customer);
    expect((await backend.myAccount()).isProfessionalMode, isFalse);
    await backend.setActiveRole(AppRole.professional);
    expect((await backend.myAccount()).isProfessionalMode, isTrue);
  });
}
