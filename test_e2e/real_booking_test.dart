// Prueba de punta a punta contra el proyecto Supabase de DESARROLLO real:
// la misma capa de datos que usa la app (SupabaseBackend) habla por la API
// con Auth, PostgREST, RLS y las funciones del servidor. No usa el modo demo.
//
// Solo corre en el flujo .github/workflows/e2e-dev.yml, que antes crea las
// cuentas temporales (supabase/e2e/setup.sql) y después borra todo
// (supabase/e2e/cleanup.sql). Sin E2E_URL, E2E_ANON_KEY y E2E_PASSWORD se salta.
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/models/booking.dart';
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
    'reserva real: postulación, aprobación, recarga, pedido, trabajo, pago, reseña y privacidad',
    () async {
      final customer = await _step('el cliente entra', () => _signIn('e2e-cliente@test.bo'));
      final pro = await _step('el profesional entra', () => _signIn('e2e-pro@test.bo'));
      final admin = await _step('el equipo entra', () => _signIn('e2e-admin@test.bo'));

      final cities = await _step('ciudades desde la base', customer.cities);
      expect(cities, isNotEmpty);
      final city = cities.first.id;
      final categories = await _step('categorías desde la base', customer.categories);
      expect(categories, isNotEmpty);
      final category = categories.first.id;

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
          categoryIds: {category},
          zoneIds: const {},
        );
        await pro.submitApplication();
      });
      await _step('un cliente no puede aprobar', () async {
        await expectLater(customer.reviewApplication(_proId, VerificationStatus.approved), _code('HMY_FORBIDDEN'));
      });
      await _step('el equipo ve la postulación y la aprueba', () async {
        final pending = await admin.adminApplications();
        expect(pending.map((a) => a.userId), contains(_proId));
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
        await expectLater(customer.updateProgress(bookingId, BookingStatus.onTheWay), throwsA(isA<AppError>()));
      });
      await _step('chat entre cliente y profesional', () async {
        final convs = await customer.conversations();
        final conv = convs.firstWhere((c) => c.bookingId == bookingId);
        await customer.send(conv.id, 'Hola, ¿a qué hora llega?');
        await pro.send(conv.id, 'En 20 minutos');
        expect((await pro.conversations()).map((c) => c.id), contains(conv.id));
      });
      await _step('en camino', () => pro.updateProgress(bookingId, BookingStatus.onTheWay));
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

      await _step('el profesional deja de estar disponible', () => pro.setAvailability(false));
    },
    skip: configured ? false : 'Falta E2E_URL, E2E_ANON_KEY o E2E_PASSWORD',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
