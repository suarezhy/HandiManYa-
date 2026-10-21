// Prueba de punta a punta contra el proyecto Supabase de DESARROLLO real:
// la misma capa de datos que usa la app (SupabaseBackend) habla por la API
// con Auth, PostgREST, RLS y las funciones del servidor. No usa el modo demo.
//
// Solo corre en el flujo .github/workflows/e2e-dev.yml, que antes crea las
// cuentas temporales (supabase/e2e/setup.sql) y después borra todo
// (supabase/e2e/cleanup.sql). Sin E2E_URL, E2E_ANON_KEY y E2E_PASSWORD se salta.
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/models/admin.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/supabase/supabase_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment('E2E_URL');
const _key = String.fromEnvironment('E2E_ANON_KEY');
const _pw = String.fromEnvironment('E2E_PASSWORD');

const _proId = 'e2e00000-0000-4000-8000-0000000000b1';

Future<SupabaseBackend> _signIn(String email) async {
  final client = SupabaseClient(_url, _key, authOptions: const AuthClientOptions(autoRefreshToken: false));
  await client.auth.signInWithPassword(email: email, password: _pw);
  return SupabaseBackend(client);
}

// El servidor rechaza con un código HMY_*; la app lo traduce con AppError.from
// (igual que al mostrar el error en pantalla).
Matcher _code(String code) => throwsA(predicate((e) => AppError.from(e!).code == code, 'error con código $code'));

Future<T> _step<T>(String name, Future<T> Function() run) async {
  try {
    final r = await run();
    // ignore: avoid_print
    print('ok - $name');
    return r;
  } catch (e) {
    // ignore: avoid_print
    print('FALLÓ - $name: $e');
    rethrow;
  }
}

void main() {
  final configured = _url.isNotEmpty && _key.isNotEmpty && _pw.isNotEmpty;

  test(
    'reserva real: postulación, aprobación, recarga, pedido, viaje en vivo, trabajo, pago, reseña, ¡Ya! con GPS, reportes y privacidad',
    () async {
      final customer = await _step('el cliente entra', () => _signIn('e2e-cliente@test.bo'));
      final pro = await _step('el profesional entra', () => _signIn('e2e-pro@test.bo'));
      final admin = await _step('el equipo entra', () => _signIn('e2e-admin@test.bo'));

      final cities = await _step('ciudades desde la base', customer.cities);
      expect(cities, isNotEmpty);
      final city = cities.first.id;
      final categories = await _step('categorías desde la base', customer.categories);
      expect(categories, isNotEmpty);
      // Un servicio que no exige documento extra; la cerrajería y similares se prueban aparte.
      final category = categories.firstWhere((c) => c.requiredDoc == null && c.allowsYa).id;
      final sensitive = categories.where((c) => c.requiredDoc != null).firstOrNull;

      for (final (name, api) in [
        ('Cliente Prueba E2E', customer),
        ('Profesional Prueba E2E', pro),
        ('Equipo Prueba E2E', admin),
      ]) {
        await _step('perfil completo: $name', () async {
          await api.completeSignup(fullName: name, cityId: city, acceptTerms: true);
          final me = await api.myAccount();
          expect(me.profileComplete, isTrue);
          expect(me.phoneVerified, isTrue);
        });
      }

      // Verificación del profesional: postula, el equipo revisa y aprueba.
      await _step('el profesional completa su postulación', () async {
        await pro.saveApplication(
          displayName: 'Pro E2E',
          primaryCategoryId: category,
          cityId: city,
          bio: 'Profesional de prueba automática',
          categoryIds: {category, ?sensitive?.id},
          zoneIds: const {},
        );
        await pro.submitApplication();
      });
      await _step('un cliente no puede aprobar', () async {
        await expectLater(customer.reviewApplication(_proId, VerificationStatus.approved), _code('HMY_FORBIDDEN'));
      });
      await _step('el equipo ve la postulación, acepta el carnet y la aprueba', () async {
        final pending = await admin.adminApplications();
        expect(pending.map((a) => a.userId), contains(_proId));
        final detail = await admin.adminApplicationDetail(_proId);
        final ids = detail.documents.where((d) => d.docType.startsWith('ci_')).toList();
        expect(ids.map((d) => d.docType).toSet(), {'ci_anverso', 'ci_reverso'});
        for (final d in ids) {
          await admin.reviewDocument(d.id, DocumentStatus.accepted);
        }
        await admin.reviewApplication(_proId, VerificationStatus.approved, note: 'Prueba E2E');
      });

      // Billetera: la recarga queda pendiente hasta que el equipo la verifica.
      final methods = await _step('métodos de recarga', pro.topupMethods);
      if (methods.isNotEmpty) {
        await _step('recarga confirmada por el equipo', () async {
          final id = await pro.requestTopup(
            amount: 100,
            methodId: methods.first.id,
            reference: 'E2E',
            authMethod: 'password',
            clientKey: 'e2e-${DateTime.now().millisecondsSinceEpoch}',
          );
          expect((await pro.wallet()).available, 0, reason: 'pedir recarga no acredita saldo');
          await admin.reviewTopup(id, approve: true);
          expect((await pro.wallet()).available, 100);
        });
      } else {
        // ignore: avoid_print
        print('aviso - no hay métodos de recarga configurados en dev; se prueba sin saldo');
      }

      await _step('el profesional se pone disponible', () async {
        await pro.setActiveRole(AppRole.professional);
        await pro.setAvailability(true);
      });

      if (sensitive != null) {
        await _step('sin su documento aceptado, nadie le pide un servicio sensible (${sensitive.slug})', () async {
          await expectLater(
            customer.create(
              BookingDraft(
                categoryId: sensitive.id,
                cityId: city,
                mode: BookingMode.now,
                professionalId: _proId,
                description: 'Prueba E2E: servicio que exige documento',
                address: 'Calle Prueba 123',
              ),
            ),
            _code('HMY_PRO_NOT_CLEARED'),
          );
        });
      }

      // Pedido directo: la dirección exacta solo se ve después de aceptar.
      final bookingId = await _step('el cliente pide al profesional', () {
        return customer.create(
          BookingDraft(
            categoryId: category,
            cityId: city,
            mode: BookingMode.now,
            professionalId: _proId,
            description: 'Prueba E2E: gotea el grifo de la cocina',
            address: 'Calle Prueba 123, casa verde',
          ),
        );
      });
      await _step('antes de aceptar, el profesional no ve la dirección exacta', () async {
        final d = await pro.detail(bookingId);
        expect(d.status, BookingStatus.requested);
        expect(d.address, isNull);
      });
      await _step('otra cuenta no ve el pedido', () async {
        await expectLater(admin.myBookings(asProfessional: false), completion(isEmpty));
      });
      await _step('el profesional acepta y ve la dirección', () async {
        await pro.accept(bookingId, isOffer: false);
        final d = await pro.detail(bookingId);
        expect(d.status, BookingStatus.confirmed);
        expect(d.address?.line, 'Calle Prueba 123, casa verde');
      });
      await _step('el cliente no puede marcar el avance del profesional', () async {
        await expectLater(customer.updateProgress(bookingId, BookingStatus.onTheWay), _code('HMY_FORBIDDEN'));
      });
      await _step('chat entre cliente y profesional', () async {
        final convs = await customer.conversations();
        final conv = convs.firstWhere((c) => c.bookingId == bookingId);
        await customer.send(conv.id, 'Hola, ¿a qué hora llega?');
        await pro.send(conv.id, 'En 20 minutos');
        expect((await pro.conversations()).map((c) => c.id), contains(conv.id));
      });
      await _step('en camino', () => pro.updateProgress(bookingId, BookingStatus.onTheWay));

      // Viaje en vivo: solo el profesional manda su posición, y solo mientras va en camino.
      await _step('el cliente no puede mandar la posición del profesional', () async {
        await expectLater(
          customer.shareTripLocation(bookingId, const GeoPoint(-17.785, -63.182)),
          _code('HMY_FORBIDDEN'),
        );
      });
      await _step('una posición fuera de Bolivia se rechaza', () async {
        await expectLater(pro.shareTripLocation(bookingId, const GeoPoint(40.4, -3.7)), _code('HMY_INVALID_LOCATION'));
      });
      await _step('el profesional comparte su posición y el cliente la ve en vivo', () async {
        expect(await pro.shareTripLocation(bookingId, const GeoPoint(-17.785, -63.182), accuracyM: 15), isTrue);
        expect(
          await pro.shareTripLocation(bookingId, const GeoPoint(-17.786, -63.182)),
          isFalse,
          reason: 'una segunda posición en menos de 5 segundos se ignora',
        );
        final t = await customer.tripLocation(bookingId);
        expect(t.live, isTrue);
        expect(t.latitude, closeTo(-17.785, 0.001));
      });
      await _step('el profesional no ve el viaje como cliente', () async {
        await expectLater(pro.tripLocation(bookingId), _code('HMY_FORBIDDEN'));
      });
      await _step('un contacto de confianza sigue el viaje con el enlace, sin cuenta', () async {
        final token = await customer.createTripShare(bookingId, contactName: 'Contacto E2E');
        final anon = SupabaseBackend(
          SupabaseClient(_url, _key, authOptions: const AuthClientOptions(autoRefreshToken: false)),
        );
        final shared = await anon.sharedTrip(token);
        expect(shared.status, BookingStatus.onTheWay);
        expect(shared.trip?.live, isTrue);
        await expectLater(anon.sharedTrip('codigo-que-no-existe'), _code('HMY_SHARE_NOT_FOUND'));
      });
      // Código de llegada (migración 0014). Mientras no esté aplicada en dev, se avisa y se sigue.
      ArrivalPin? pin;
      try {
        pin = await pro.markArrived(bookingId);
      } on PostgrestException catch (e) {
        if (e.code != 'PGRST202') rethrow;
        // ignore: avoid_print
        print('aviso - el código de llegada (0014) todavía no está aplicado en dev');
      }
      if (pin != null) {
        await _step('sin llegada verificada no se empieza el trabajo', () async {
          await expectLater(pro.updateProgress(bookingId, BookingStatus.inProgress), throwsA(anything));
        });
        await _step('el profesional no puede verificarse solo', () async {
          await expectLater(pro.verifyArrivalPin(bookingId, pin!.pin), throwsA(anything));
        });
        await _step('el cliente verifica la llegada con el código', () async {
          expect((await customer.verifyArrivalPin(bookingId, pin!.pin)).result, ArrivalCheckResult.verified);
          expect((await pro.arrival(bookingId)).verified, isTrue);
        });
        await _step('al verificar la llegada se deja de compartir la posición', () async {
          expect((await customer.tripLocation(bookingId)).live, isFalse);
        });
      }
      await _step('en progreso y trabajo terminado', () async {
        await pro.updateProgress(bookingId, BookingStatus.inProgress);
        await pro.updateProgress(bookingId, BookingStatus.workFinished, finalAmount: 150);
      });
      await _step('el cliente confirma, paga en efectivo y califica', () async {
        await customer.confirmCompletion(bookingId);
        await customer.acknowledgePayment(bookingId, PaymentMethod.cash);
        await customer.submitReview(bookingId, 5, 'Prueba E2E: puntual y prolijo');
        final d = await customer.detail(bookingId);
        expect(d.status, BookingStatus.completed);
        expect(d.hasReview, isTrue);
      });
      await _step('la billetera nunca queda con reserva colgada', () async {
        final w = await pro.wallet();
        expect(w.reserved, 0);
        expect(w.available, greaterThanOrEqualTo(0));
      });

      // Cancelación: un segundo pedido que el cliente cancela antes de que lo acepten.
      await _step('cancelar un pedido', () async {
        final id = await customer.create(
          BookingDraft(
            categoryId: category,
            cityId: city,
            mode: BookingMode.now,
            professionalId: _proId,
            description: 'Prueba E2E: pedido que se cancela',
            address: 'Calle Prueba 123',
          ),
        );
        await customer.cancel(id, 'Ya no lo necesito');
        expect((await customer.detail(id)).status, BookingStatus.cancelled);
      });

      // ¡Ya! con GPS: el pedido llega solo a quien está dentro de su radio.
      await _step('el profesional fija su base y un radio de 3 km', () async {
        await expectLater(
          pro.setServiceLocation(latitude: 40.4, longitude: -3.7, radiusKm: 3),
          _code('HMY_INVALID_LOCATION'),
        );
        await pro.setServiceLocation(latitude: -17.78, longitude: -63.18, radiusKm: 3);
      });
      await _step('¡Ya! cuenta al profesional cerca y no lejos', () async {
        final near = await customer.countYaAvailable(
          categoryId: category,
          cityId: city,
          latitude: -17.79,
          longitude: -63.18,
        );
        final far = await customer.countYaAvailable(
          categoryId: category,
          cityId: city,
          latitude: -17.95,
          longitude: -63.18,
        );
        expect(near, greaterThanOrEqualTo(1));
        expect(near, greaterThan(far));
      });
      await _step('un pedido ¡Ya! lejos de todos se rechaza', () async {
        await expectLater(
          customer.create(
            BookingDraft(
              categoryId: category,
              cityId: city,
              mode: BookingMode.now,
              description: 'Prueba E2E: ¡Ya! fuera del radio',
              address: 'Calle Lejana 1',
              paymentMethod: PaymentMethod.cash,
              latitude: -21.5,
              longitude: -64.7,
            ),
          ),
          _code('HMY_NO_PROFESSIONALS_AVAILABLE'),
        );
      });
      final yaId = await _step('el cliente pide ¡Ya! cerca del profesional', () {
        return customer.create(
          BookingDraft(
            categoryId: category,
            cityId: city,
            mode: BookingMode.now,
            description: 'Prueba E2E: ¡Ya! se cortó la luz',
            address: 'Calle Prueba 456',
            paymentMethod: PaymentMethod.cash,
            latitude: -17.7912,
            longitude: -63.1801,
          ),
        );
      });
      await _step('al profesional le llega la oferta con distancia y sin dirección', () async {
        final offer = (await pro.myBookings(asProfessional: true)).firstWhere((b) => b.id == yaId);
        expect(offer.isOffer, isTrue);
        expect(offer.distanceKm, isNotNull);
        expect(offer.distanceKm!, lessThan(3));
        expect((await pro.detail(yaId)).address, isNull);
      });
      await _step('el profesional toma el ¡Ya! y recién ve la dirección', () async {
        await pro.accept(yaId, isOffer: true);
        final d = await pro.detail(yaId);
        expect(d.status, BookingStatus.confirmed);
        expect(d.address?.line, 'Calle Prueba 456');
      });
      await _step('el ¡Ya! tomado no se puede tomar otra vez', () async {
        await expectLater(pro.accept(yaId, isOffer: true), _code('HMY_ALREADY_TAKEN'));
      });

      // Reportes: el cliente reporta y solo el equipo los ve y resuelve.
      await _step('el cliente cancela el ¡Ya! y reporta al profesional', () async {
        await customer.cancel(yaId, 'Prueba E2E: no llegó');
        await customer.reportUser(userId: _proId, reason: ReportReason.noShow, details: 'Prueba E2E', bookingId: yaId);
      });
      await _step('un cliente no ve los reportes del equipo', () async {
        await expectLater(customer.adminReports(), _code('HMY_FORBIDDEN'));
      });
      await _step('el equipo ve el reporte y lo resuelve', () async {
        final report = (await admin.adminReports()).firstWhere((r) => r.bookingId == yaId);
        expect(report.reportedId, _proId);
        expect(report.reason, ReportReason.noShow);
        await admin.reviewReport(report.id, CaseStatus.resolved, resolution: 'Prueba E2E revisada');
        final resolved = await admin.adminReports(status: 'resolved');
        expect(resolved.firstWhere((r) => r.id == report.id).status, CaseStatus.resolved);
      });

      await _step('el profesional deja de estar disponible', () => pro.setAvailability(false));
    },
    skip: configured ? false : 'Falta E2E_URL, E2E_ANON_KEY o E2E_PASSWORD',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
