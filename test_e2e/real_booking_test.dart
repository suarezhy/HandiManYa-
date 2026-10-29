// Prueba de punta a punta contra el proyecto Supabase de DESARROLLO real:
// la misma capa de datos que usa la app (SupabaseBackend) habla por la API
// con Auth, PostgREST, RLS y las funciones del servidor. No usa el modo demo.
//
// Solo corre en el flujo .github/workflows/e2e-dev.yml, que antes crea las
// cuentas temporales (supabase/e2e/setup.sql) y después borra todo
// (supabase/e2e/cleanup.sql). Sin E2E_URL, E2E_ANON_KEY y E2E_PASSWORD se salta.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/models/admin.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/drilldown.dart';
import 'package:handimanya/data/models/finance.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/data/models/staff.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/models/wallet.dart';
import 'package:handimanya/data/supabase/supabase_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment('E2E_URL');
const _key = String.fromEnvironment('E2E_ANON_KEY');
const _pw = String.fromEnvironment('E2E_PASSWORD');

const _proId = 'e2e00000-0000-4000-8000-0000000000b1';
const _managerId = 'e2e00000-0000-4000-8000-0000000000e0';
const _emp1Id = 'e2e00000-0000-4000-8000-0000000000e1';
const _emp2Id = 'e2e00000-0000-4000-8000-0000000000e2';

const _ruleName = 'Prueba E2E (temporal) 10 %';

Future<SupabaseBackend> _signIn(String email) async => (await _signInWithClient(email)).$1;

/// La capa de datos de la app y el cliente de Supabase de esa sesión, para
/// leer tablas directo como lo intentaría alguien sin pasar por la app.
Future<(SupabaseBackend, SupabaseClient)> _signInWithClient(String email) async {
  final client = SupabaseClient(_url, _key, authOptions: const AuthClientOptions(autoRefreshToken: false));
  await client.auth.signInWithPassword(email: email, password: _pw);
  return (SupabaseBackend(client), client);
}

/// Vuelve a entrar con la contraseña: es la confirmación "recién" (menos de 5
/// minutos, una sola operación) que el servidor pide para dar roles o tocar
/// datos bancarios.
/// El servidor guarda la hora del inicio de sesión en segundos: se espera un
/// segundo para que cada confirmación sea un inicio nuevo.
Future<String> _reauth(SupabaseClient c, String email) async {
  await Future<void>.delayed(const Duration(milliseconds: 1100));
  await c.auth.signInWithPassword(email: email, password: _pw);
  return 'password';
}

/// Lo que esta sesión puede leer directo de una tabla (RLS decide).
Future<int> _visibleRows(SupabaseClient c, String table) async => (await c.from(table).select().limit(50)).length;

// El servidor rechaza con un código HMY_*; la app lo traduce con AppError.from
// (igual que al mostrar el error en pantalla).
Matcher _code(String code) => throwsA(predicate((e) => AppError.from(e!).code == code, 'error con código $code'));
Matcher _codeIn(Set<String> codes) =>
    throwsA(predicate((e) => codes.contains(AppError.from(e!).code), 'error con código ${codes.join(' o ')}'));

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
      await _step('catálogo: Banda y Mariachis en Eventos; Grúa es un solo servicio, fuera de Mecánica', () async {
        int idOf(String slug) => categories.firstWhere((c) => c.slug == slug).id;
        final eventos = (await customer.problems(idOf('eventos'))).map((p) => p.name);
        expect(eventos, containsAll(['Banda', 'Mariachis']));
        final mecanica = await customer.problems(idOf('mecanica'));
        expect(mecanica.map((p) => p.name), isNot(contains('Grúa')));
        expect(mecanica.where((p) => p.opensCategoryId != null), isEmpty);
        expect(categories.where((c) => c.name == 'Grúa'), hasLength(1));
        final tow = (await customer.problems(idOf('grua'))).map((p) => p.name);
        expect(tow, contains('Remolque de vehículo'));
        expect(
          categories.firstWhere((c) => c.slug == 'grua').requiredDoc,
          isNotNull,
          reason: 'la grúa exige documentos',
        );
        expect(
          categories.firstWhere((c) => c.slug == 'mecanica').safetyNote,
          'Si tu vehículo se averió, espera en un lugar seguro y enciende las luces de emergencia. '
          'Nunca entregues tu vehículo sin acordarlo previamente con el profesional.',
        );
      });
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
          // Mecánica y Grúa se habilitan al final, cuando el equipo acepta sus documentos.
          categoryIds: {
            category,
            ?sensitive?.id,
            for (final c in categories)
              if (c.slug == 'mecanica' || c.slug == 'grua') c.id,
          },
          zoneIds: const {},
        );
        await pro.submitApplication();
      });
      await _step('un cliente no puede aprobar', () async {
        await expectLater(customer.reviewApplication(_proId, VerificationStatus.approved), _code('HMY_FORBIDDEN'));
      });
      await _step('el profesional no puede aprobarse ni aceptar sus propios documentos', () async {
        await expectLater(pro.reviewApplication(_proId, VerificationStatus.approved), _code('HMY_FORBIDDEN'));
        final ids = (await admin.adminApplicationDetail(_proId)).documents.where((d) => d.docType.startsWith('ci_'));
        for (final d in ids) {
          await expectLater(pro.reviewDocument(d.id, DocumentStatus.accepted), _code('HMY_FORBIDDEN'));
        }
        // Tampoco escribiendo directo en las tablas: la base lo impide.
        final (_, db) = await _signInWithClient('e2e-pro@test.bo');
        final changed = await db
            .from('professional_documents')
            .update({'status': 'accepted'})
            .eq('professional_id', _proId)
            .select('id');
        expect(changed, isEmpty);
        try {
          await db.from('professional_profiles').update({'status': 'approved'}).eq('user_id', _proId);
        } on PostgrestException {
          // Sin permiso de escritura: es lo esperado.
        }
        final after = await admin.adminApplicationDetail(_proId);
        expect(after.documents.where((d) => d.docType.startsWith('ci_')).map((d) => d.status).toSet(), {
          DocumentStatus.pending,
        });
        expect((await admin.adminApplications()).map((a) => a.userId), contains(_proId), reason: 'sigue pendiente');
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
            clientKey: newOperationKey(),
          );
          expect((await pro.wallet()).available, 0, reason: 'pedir recarga no acredita saldo');
          await admin.reviewTopup(id, approve: true);
          expect((await pro.wallet()).available, 100);
        });
      } else {
        // ignore: avoid_print
        print('aviso - no hay métodos de recarga configurados en dev; se prueba sin saldo');
      }

      // Comisión temporal de prueba (10 %, mínimo Bs 5), solo para este servicio y ciudad.
      // No es la política real; se desactiva al final y cleanup.sql la borra.
      if (methods.isNotEmpty) {
        await _step('el equipo crea la comisión temporal de prueba', () async {
          await expectLater(
            pro.saveCommissionRule(
              CommissionRule(name: _ruleName, categoryId: category, cityId: city, ratePercent: 10),
            ),
            _code('HMY_FORBIDDEN'),
          );
          await admin.saveCommissionRule(
            CommissionRule(
              name: _ruleName,
              categoryId: category,
              cityId: city,
              ratePercent: 10,
              reserveAmount: 5,
              minBalance: 5,
            ),
          );
          expect((await admin.commissionRules()).where((r) => r.name == _ruleName && r.isActive), hasLength(1));
        });
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
      await _step('aviso dentro de la app: al profesional le llega el pedido nuevo', () async {
        final mine = await pro.list();
        expect(mine.where((n) => n.kind == 'booking_new' && n.bookingId == bookingId), isNotEmpty);
      });
      await _step('antes de aceptar, el profesional no ve la dirección exacta', () async {
        final d = await pro.detail(bookingId);
        expect(d.status, BookingStatus.requested);
        expect(d.address, isNull);
      });
      await _step('otra cuenta no ve el pedido', () async {
        await expectLater(admin.myBookings(asProfessional: false), completion(isEmpty));
      });
      final walletBefore = await _step('saldo del profesional antes de aceptar', pro.wallet);
      await _step('el profesional acepta y ve la dirección', () async {
        await pro.accept(bookingId, isOffer: false);
        final d = await pro.detail(bookingId);
        expect(d.status, BookingStatus.confirmed);
        expect(d.address?.line, 'Calle Prueba 123, casa verde');
      });
      if (methods.isNotEmpty) {
        await _step('al aceptar se reserva el mínimo de Bs 5 (todavía no hay precio)', () async {
          final w = await pro.wallet();
          expect(w.reserved, closeTo(5, 0.005));
          expect(w.available, closeTo(walletBefore.available - 5, 0.005));
        });
      }
      await _step('aviso dentro de la app: al cliente le llega que lo aceptaron', () async {
        final mine = await customer.list();
        expect(mine.where((n) => n.kind == 'booking_status' && n.bookingId == bookingId), isNotEmpty);
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
      await _step('aviso dentro de la app: cada uno recibe el mensaje del otro', () async {
        final conv = (await customer.conversations()).firstWhere((c) => c.bookingId == bookingId);
        expect((await pro.list()).where((n) => n.kind == 'message' && n.conversationId == conv.id), isNotEmpty);
        expect((await customer.list()).where((n) => n.kind == 'message' && n.conversationId == conv.id), isNotEmpty);
      });
      await _step('los avisos de una persona no los ve nadie más', () async {
        expect((await admin.list()).where((n) => n.bookingId == bookingId), isEmpty);
      });
      await _step('nadie puede crear avisos a mano ni llamar a la función que los crea', () async {
        final (_, db) = await _signInWithClient('e2e-cliente@test.bo');
        await expectLater(
          db.from('notifications').insert({
            'user_id': _proId,
            'kind': 'message',
            'title': 'Falso',
            'body': 'Aviso falso',
          }),
          throwsA(isA<PostgrestException>()),
        );
        await expectLater(
          db.rpc(
            'notify',
            params: {'p_user': _proId, 'p_kind': 'message', 'p_title': 'Falso', 'p_body': 'Aviso falso'},
          ),
          throwsA(isA<PostgrestException>()),
        );
        expect((await pro.list()).where((n) => n.title == 'Falso'), isEmpty);
      });
      await _step('marcar como leídos deja todos los avisos del cliente leídos', () async {
        await customer.markAllRead();
        expect((await customer.list()).where((n) => n.readAt == null), isEmpty);
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
      // Código de llegada: el trabajo empieza solo cuando el cliente confirma con su código.
      final pin = await _step('el profesional marca que llegó y se genera el código', () => pro.markArrived(bookingId));
      await _step('sin llegada verificada no se empieza el trabajo', () async {
        await expectLater(pro.updateProgress(bookingId, BookingStatus.inProgress), throwsA(anything));
      });
      await _step('el profesional no puede verificarse solo', () async {
        await expectLater(pro.verifyArrivalPin(bookingId, pin.pin), throwsA(anything));
      });
      await _step('un código equivocado no verifica la llegada', () async {
        final last = pin.pin[pin.pin.length - 1];
        final wrong = pin.pin.substring(0, pin.pin.length - 1) + (last == '0' ? '1' : '0');
        expect((await customer.verifyArrivalPin(bookingId, wrong)).result, isNot(ArrivalCheckResult.verified));
        expect((await pro.arrival(bookingId)).verified, isFalse);
      });
      await _step('el cliente verifica la llegada con el código', () async {
        expect((await customer.verifyArrivalPin(bookingId, pin.pin)).result, ArrivalCheckResult.verified);
        expect((await pro.arrival(bookingId)).verified, isTrue);
      });
      await _step('al verificar la llegada se deja de compartir la posición', () async {
        expect((await customer.tripLocation(bookingId)).live, isFalse);
      });
      await _step('en progreso y trabajo terminado', () async {
        await pro.updateProgress(bookingId, BookingStatus.inProgress);
        await pro.updateProgress(bookingId, BookingStatus.workFinished, finalAmount: 150);
      });
      final preview = await _step('comisión esperada sobre el precio final', () => pro.commissionPreview(bookingId));
      await _step('el cliente confirma, paga con QR y califica', () async {
        await customer.confirmCompletion(bookingId);
        await customer.acknowledgePayment(bookingId, PaymentMethod.qr);
        await customer.submitReview(bookingId, 5, 'Prueba E2E: puntual y prolijo');
        final d = await customer.detail(bookingId);
        expect(d.status, BookingStatus.completed);
        expect(d.hasReview, isTrue);
        expect(d.paymentMethod, PaymentMethod.qr);
      });
      await _step('el profesional no cambia el método de pago que eligió el cliente', () async {
        await pro.acknowledgePayment(bookingId, PaymentMethod.cash);
        expect((await customer.detail(bookingId)).paymentMethod, PaymentMethod.qr);
      });
      await _step('la comisión cobrada es la esperada y no queda reserva colgada', () async {
        final w = await pro.wallet();
        expect(w.reserved, 0);
        expect(w.available, greaterThanOrEqualTo(0));
        if (methods.isNotEmpty) {
          // Con la comisión temporal: 10 % de Bs 150 = Bs 15.
          expect(preview?.hasRule, isTrue);
          expect(preview!.expected, closeTo(15, 0.005));
        }
        if (preview == null || !preview.hasRule) {
          // ignore: avoid_print
          print('aviso - dev no tiene regla de comisión para este servicio; el saldo no debe cambiar');
          expect(w.available, walletBefore.available);
          return;
        }
        // ignore: avoid_print
        print('comisión: esperada Bs ${preview.expected}, saldo antes Bs ${walletBefore.available}');
        final charged = walletBefore.available - w.available;
        expect(charged, closeTo(math.min(preview.expected, walletBefore.available), 0.005));
        if (preview.expected > 0 && walletBefore.available > 0) {
          final ledger = await pro.ledger();
          expect(ledger.where((e) => e.type == LedgerType.commissionCapture), isNotEmpty);
        }
      });

      // Cancelación: un segundo pedido que el cliente cancela antes de que lo acepten.
      if (methods.isNotEmpty) {
        await _step('el equipo desactiva la comisión temporal', () async {
          final rule = (await admin.commissionRules()).firstWhere((r) => r.name == _ruleName);
          await admin.saveCommissionRule(
            CommissionRule(
              id: rule.id,
              name: rule.name,
              categoryId: rule.categoryId,
              cityId: rule.cityId,
              ratePercent: rule.ratePercent,
              reserveAmount: rule.reserveAmount,
              minBalance: rule.minBalance,
              isActive: false,
            ),
          );
          expect((await admin.commissionRules()).where((r) => r.name == _ruleName && r.isActive), isEmpty);
        });
      }
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

  // Corre después de la reserva (las pruebas de un archivo van en orden).
  test(
    'equipo: el propietario da roles; gerente y empleados sin dinero; cada empleado solo sus casos; suspensión y auditoría',
    () async {
      final customer = await _step('el cliente entra', () => _signIn('e2e-cliente@test.bo'));
      final (owner, ownerDb) = await _step('el propietario entra', () => _signInWithClient('e2e-admin@test.bo'));
      final (manager, managerDb) = await _step('el gerente entra', () => _signInWithClient('e2e-gerente@test.bo'));
      final (emp1, emp1Db) = await _step('el empleado 1 entra', () => _signInWithClient('e2e-empleado1@test.bo'));
      final (emp2, _) = await _step('el empleado 2 entra', () => _signInWithClient('e2e-empleado2@test.bo'));
      final city = (await customer.cities()).first.id;
      for (final (name, api) in [
        ('Gerente Prueba E2E', manager),
        ('Empleado Uno E2E', emp1),
        ('Empleado Dos E2E', emp2),
      ]) {
        await _step(
          'perfil completo: $name',
          () => api.completeSignup(fullName: name, cityId: city, acceptTerms: true),
        );
      }

      await _step('sin rol, el gerente y los empleados no entran a ningún panel', () async {
        for (final api in [manager, emp1, emp2]) {
          expect((await api.myAccount()).managementRole, isNull);
          await expectLater(api.opsDashboard(), _code('HMY_FORBIDDEN'));
        }
      });
      await _step('un cliente no puede darse un rol', () async {
        await expectLater(
          customer.grantStaff(_managerId, StaffRole.manager, authMethod: 'password'),
          _code('HMY_FORBIDDEN'),
        );
      });
      await _step('el propietario busca por celular: enmascarado y sin cuentas inventadas', () async {
        final found = await owner.staffCandidates('6000 0904');
        expect(found.map((c) => c.id), contains(_managerId));
        final g = found.firstWhere((c) => c.id == _managerId);
        expect(g.phoneMasked, '+591 6••• ••04');
        expect(g.eligible, isTrue);
        expect(await owner.staffCandidates('+591 6999 0999'), isEmpty, reason: 'un número sin cuenta no da resultados');
        await expectLater(manager.staffCandidates('6000'), _code('HMY_FORBIDDEN'));
        await expectLater(customer.staffCandidates('6000'), _code('HMY_FORBIDDEN'));
      });
      await _step('dar un rol sin confirmar se rechaza', () async {
        await expectLater(
          owner.grantStaff(_managerId, StaffRole.manager, authMethod: 'biometric'),
          _code('HMY_CONFIRMATION_REQUIRED'),
        );
      });
      await _step('el propietario da los roles por id de cuenta, con confirmación', () async {
        await owner.grantStaff(_managerId, StaffRole.manager, authMethod: await _reauth(ownerDb, 'e2e-admin@test.bo'));
        await owner.grantStaff(_emp1Id, StaffRole.employee, authMethod: await _reauth(ownerDb, 'e2e-admin@test.bo'));
        await owner.grantStaff(_emp2Id, StaffRole.employee, authMethod: await _reauth(ownerDb, 'e2e-admin@test.bo'));
        // La misma confirmación no sirve dos veces.
        await expectLater(
          owner.grantStaff(_emp2Id, StaffRole.manager, authMethod: 'password'),
          _code('HMY_CONFIRMATION_USED'),
        );
        expect((await manager.myAccount()).managementRole, StaffRole.manager);
        expect((await emp1.myAccount()).managementRole, StaffRole.employee);
        final team = await owner.staffOverview();
        expect(team.map((m) => m.userId), containsAll([_managerId, _emp1Id, _emp2Id]));
      });
      await _step('el gerente no puede dar ni subir roles', () async {
        await expectLater(
          manager.grantStaff(_emp1Id, StaffRole.manager, authMethod: await _reauth(managerDb, 'e2e-gerente@test.bo')),
          _code('HMY_FORBIDDEN'),
        );
        await expectLater(manager.setStaffStatus(_emp1Id, 'suspended', reason: 'Prueba E2E'), _code('HMY_FORBIDDEN'));
      });
      await _step('un empleado no puede dar roles', () async {
        await expectLater(
          emp1.grantStaff(_emp2Id, StaffRole.manager, authMethod: await _reauth(emp1Db, 'e2e-empleado1@test.bo')),
          _code('HMY_FORBIDDEN'),
        );
      });

      // Dinero: solo el propietario.
      await _step('el propietario conserva el acceso completo', () async {
        final d = await owner.adminDashboard();
        expect(d.isOwnerView, isTrue, reason: 'owner_dashboard aplicado en dev');
        await owner.adminTopups();
        await owner.costDashboard();
        await owner.aiOverview();
        await owner.auditLog();
      });
      await _step('Finanzas y Bancos: el propietario separa comisiones de billeteras', () async {
        final f = await owner.financeSummary();
        expect(f.bankIntegration, 'pendiente_configuracion', reason: 'sin banco conectado, se dice');
        expect(f.months, hasLength(6));
        // La recarga de Bs 100 de esta prueba se acreditó, pero nadie la vio en el banco.
        final unverified = await owner.topupsForReconciliation('sin_verificar');
        final mine = unverified.where((t) => t.professionalId == _proId).toList();
        expect(mine, isNotEmpty);
        expect(mine.first.bankStatus, BankStatus.unverified);
        await owner.financeTransactions(limit: 5);
        await owner.receivingAccounts();
        await owner.financeAudit(limit: 5);
      });
      await _step('Finanzas y Bancos: cambios con confirmación y en el historial', () async {
        await expectLater(
          owner.saveReceivingAccount(
            const ReceivingAccountDraft(
              label: 'Cuenta E2E',
              type: ReceivingAccountType.savings,
              bankName: 'Banco de prueba E2E',
              holderName: 'Titular E2E',
              accountNumber: '9000000001',
            ),
            authMethod: 'biometric',
          ),
          _code('HMY_CONFIRMATION_REQUIRED'),
        );
        final id = await owner.saveReceivingAccount(
          const ReceivingAccountDraft(
            label: 'Cuenta E2E',
            type: ReceivingAccountType.savings,
            bankName: 'Banco de prueba E2E',
            holderName: 'Titular E2E',
            accountNumber: '9000000001',
          ),
          authMethod: await _reauth(ownerDb, 'e2e-admin@test.bo'),
        );
        final acc = (await owner.receivingAccounts()).firstWhere((a) => a.id == id);
        expect(acc.accountMasked, '•••• 0001');
        expect(acc.verified, isFalse);
        final topup = (await owner.topupsForReconciliation('sin_verificar'))
            .firstWhere((t) => t.professionalId == _proId);
        await expectLater(
          owner.reconcileTopup(
            topup.id,
            BankStatus.reconciled,
            authMethod: await _reauth(ownerDb, 'e2e-admin@test.bo'),
          ),
          _code('HMY_BANK_REFERENCE_REQUIRED'),
        );
        await owner.reconcileTopup(
          topup.id,
          BankStatus.reconciled,
          bankReference: 'E2E-REF-1',
          accountId: id,
          authMethod: await _reauth(ownerDb, 'e2e-admin@test.bo'),
        );
        final done = (await owner.topupsForReconciliation('conciliada')).firstWhere((t) => t.id == topup.id);
        expect(done.bankReference, 'E2E-REF-1');
        final audit = await owner.financeAudit(limit: 20);
        expect(audit.map((e) => e.action), containsAll(['finance.account_created', 'finance.reconcile']));
        expect(audit.every((e) => !'${e.details}'.contains('9000000001')), isTrue, reason: 'sin el número completo');
      });
      for (final (who, api, db) in [('el gerente', manager, managerDb), ('el empleado', emp1, emp1Db)]) {
        await _step('$who no ve dinero ni ajustes', () async {
          await expectLater(api.adminDashboard(), _code('HMY_FORBIDDEN'));
          await expectLater(api.adminTopups(), _code('HMY_FORBIDDEN'));
          await expectLater(api.reviewTopup(1, approve: true), _code('HMY_FORBIDDEN'));
          await expectLater(api.adjustWallet(_proId, 10, 'Prueba E2E'), _code('HMY_FORBIDDEN'));
          await expectLater(api.costDashboard(), _code('HMY_FORBIDDEN'));
          await expectLater(api.aiOverview(), _code('HMY_FORBIDDEN'));
          await expectLater(api.auditLog(), _code('HMY_FORBIDDEN'));
          await expectLater(api.financeSummary(), _code('HMY_FORBIDDEN'));
          await expectLater(api.financeTransactions(), _code('HMY_FORBIDDEN'));
          await expectLater(api.topupsForReconciliation('todas'), _code('HMY_FORBIDDEN'));
          await expectLater(api.receivingAccounts(), _code('HMY_FORBIDDEN'));
          await expectLater(api.financeAudit(), _code('HMY_FORBIDDEN'));
          await expectLater(
            api.reconcileTopup(1, BankStatus.reconciled, bankReference: 'X', authMethod: 'password'),
            _code('HMY_FORBIDDEN'),
          );
          await expectLater(api.staffCandidates('E2E'), _code('HMY_FORBIDDEN'));
          for (final table in ['wallets', 'wallet_ledger', 'topup_requests', 'cost_usage', 'admin_audit_log']) {
            expect(await _visibleRows(db, table), 0, reason: '$who no lee $table');
          }
          // Las cuentas de cobro no tienen ningún permiso directo: ni leer.
          await expectLater(
            db.from('receiving_accounts').select().limit(1),
            throwsA(predicate((e) => e is PostgrestException && e.code == '42501', 'permiso denegado')),
          );
          final ops = await api.opsDashboard();
          for (final k in ops.keys) {
            expect(k, isNot(anyOf(contains('revenue'), contains('commission'), contains('wallet'), contains('topup'))));
          }
        });
      }
      // Cada número del panel abre su lista (0041): mismo total que la tarjeta,
      // sin dirección ni GPS, y los montos solo para el propietario.
      await _step('panel del propietario: cada lista da el mismo total que su tarjeta', () async {
        final d = await owner.adminDashboard();
        expect((await owner.opsBookings(BookingFilter.today)).total, d.bookingsToday);
        expect((await owner.opsBookings(BookingFilter.active)).total, d.activeBookings);
        expect((await owner.opsBookings(BookingFilter.completedToday)).total, d.completedToday);
        expect((await owner.opsBookings(BookingFilter.cancelledToday)).total, d.cancelledToday);
        expect((await owner.adminPeople(PeopleFilter.customers)).total, d.customers);
        expect((await owner.adminPeople(PeopleFilter.professionals)).total, d.approvedProfessionals);
        expect((await owner.adminPeople(PeopleFilter.available)).total, d.availableProfessionals);
        expect((await owner.riskItems(RiskKind.safety)).total, d.safetyIncidents);
        expect((await owner.riskItems(RiskKind.fraud)).total, d.fraudAlerts);
        final w = await owner.ownerWallets();
        expect(w.available, d.walletAvailable);
        expect(w.reserved, d.walletReserved);
        final recent = await owner.opsBookings(BookingFilter.recent);
        if (recent.items.isNotEmpty) {
          final raw = await ownerDb.rpc('ops_booking_detail', params: {'p_booking': recent.items.first.id});
          for (final k in ['address', 'address_line', 'lat', 'lng', 'latitude', 'longitude', 'location']) {
            expect((raw as Map).containsKey(k), isFalse, reason: 'el detalle no lleva $k');
          }
        }
      });
      await _step('el gerente ve pedidos sin montos y no ve billeteras', () async {
        final list = await manager.opsBookings(BookingFilter.recent);
        expect(
          list.items.every((x) => x.finalAmount == null && x.quoteAmount == null && x.commissionCaptured == null),
          isTrue,
        );
        await expectLater(manager.ownerWallets(), _code('HMY_FORBIDDEN'));
        expect((await manager.riskItems(RiskKind.fraud)).items.every((i) => i.source != 'ai'), isTrue);
      });
      await _step('el empleado no abre las listas del panel', () async {
        await expectLater(emp1.opsBookings(BookingFilter.today), _code('HMY_FORBIDDEN'));
        await expectLater(emp1.adminPeople(PeopleFilter.all), _code('HMY_FORBIDDEN'));
        await expectLater(emp1.ownerWallets(), _code('HMY_FORBIDDEN'));
        await expectLater(customer.opsBookings(BookingFilter.today), _code('HMY_FORBIDDEN'));
      });
      await _step('el gerente no resuelve disputas (cambian la comisión)', () async {
        await expectLater(
          manager.resolveDispute('00000000-0000-0000-0000-000000000000', DisputeOutcome.completed, 'Prueba E2E'),
          _code('HMY_FORBIDDEN'),
        );
      });

      // Casos: el cliente escribe a soporte dos veces; cada mensaje abre un caso.
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await _step('el cliente escribe a soporte', () async {
        await customer.contactSupport(subject: 'E2E caso A $stamp', body: 'Prueba E2E: no puedo ver mi pedido');
        await customer.contactSupport(subject: 'E2E caso B $stamp', body: 'Prueba E2E: duda con el pago');
      });
      final (caseA, caseB) = await _step('el gerente ve los casos nuevos sin asignar', () async {
        final open = await manager.opsCases(scope: 'unassigned');
        final a = open.firstWhere((c) => c.title == 'E2E caso A $stamp');
        final b = open.firstWhere((c) => c.title == 'E2E caso B $stamp');
        return (a.id, b.id);
      });
      await _step('el gerente asigna un caso a cada empleado', () async {
        await manager.assignCase(caseA, _emp1Id);
        await manager.assignCase(caseB, _emp2Id);
      });
      await _step('un empleado no puede asignar casos', () async {
        await expectLater(emp1.assignCase(caseB, _emp1Id), _code('HMY_FORBIDDEN'));
      });
      await _step('cada empleado ve solo sus casos', () async {
        final mine1 = await emp1.opsCases(scope: 'all', includeResolved: true);
        expect(mine1.map((c) => c.id), contains(caseA));
        expect(mine1.map((c) => c.id), isNot(contains(caseB)));
        expect(mine1.every((c) => c.assignedTo == _emp1Id), isTrue);
        await expectLater(emp1.opsCaseDetail(caseB), _code('HMY_FORBIDDEN'));
        await expectLater(emp1.replyCase(caseB, 'Prueba E2E'), _code('HMY_FORBIDDEN'));
        expect(await _visibleRows(emp1Db, 'ops_cases'), lessThanOrEqualTo(mine1.length));
        final mine2 = await emp2.opsCases(scope: 'all');
        expect(mine2.map((c) => c.id), contains(caseB));
        expect(mine2.map((c) => c.id), isNot(contains(caseA)));
      });
      await _step('el empleado responde, anota y resuelve su caso de rutina', () async {
        await emp1.replyCase(caseA, 'Hola, ya revisamos tu pedido. Prueba E2E.');
        await emp1.addCaseNote(caseA, 'Nota interna de prueba E2E');
        await expectLater(emp1.setCaseStatus(caseA, OpsCaseStatus.resolved), throwsA(anything));
        await emp1.setCaseStatus(caseA, OpsCaseStatus.resolved, note: 'Resuelto en la prueba E2E');
        final d = await manager.opsCaseDetail(caseA);
        expect(d.item.status, OpsCaseStatus.resolved);
        expect(d.notes.length, greaterThanOrEqualTo(2));
      });

      // Seguridad: el empleado no la resuelve; la escala.
      await _step('un reporte de acoso abre un caso de seguridad', () async {
        await customer.reportUser(userId: _proId, reason: ReportReason.harassment, details: 'Prueba E2E: seguridad');
      });
      final safetyCase = await _step('el gerente asigna el caso de seguridad', () async {
        final c = (await manager.opsCases(scope: 'unassigned')).firstWhere(
          (c) =>
              c.kind == OpsCaseKind.report &&
              c.category == 'safety' &&
              c.createdAt.isAfter(DateTime.now().subtract(const Duration(minutes: 10))),
        );
        await manager.assignCase(c.id, _emp1Id);
        return c.id;
      });
      await _step('el empleado no puede cerrar un caso de seguridad: lo escala', () async {
        await expectLater(
          emp1.setCaseStatus(safetyCase, OpsCaseStatus.resolved, note: 'Prueba E2E'),
          _code('HMY_ESCALATE_REQUIRED'),
        );
        await emp1.escalateCase(safetyCase, 'Prueba E2E: posible acoso', category: 'safety');
        final esc = await manager.opsCases(scope: 'escalated');
        expect(esc.map((c) => c.id), contains(safetyCase));
      });

      // Lo que el empleado nunca hace.
      await _step('el empleado no aprueba, no abre documentos y no suspende', () async {
        await expectLater(emp1.reviewApplication(_proId, VerificationStatus.rejected), _code('HMY_FORBIDDEN'));
        await expectLater(emp1.adminApplicationDetail(_proId), _code('HMY_FORBIDDEN'));
        await expectLater(emp1.setSuspension(_proId, suspend: true, reason: 'Prueba E2E'), _code('HMY_FORBIDDEN'));
        expect(await _visibleRows(emp1Db, 'professional_documents'), 0);
        expect((await emp1Db.storage.from('professional-documents').list(path: _proId)).length, 0);
      });
      await _step('el gerente no suspende al equipo ni al propietario', () async {
        await expectLater(manager.setSuspension(_emp1Id, suspend: true, reason: 'Prueba E2E'), _code('HMY_FORBIDDEN'));
      });

      // Suspensión: pierde el acceso en la siguiente llamada y su caso vuelve a la bandeja.
      await _step('el propietario suspende al empleado 2', () async {
        await owner.setStaffStatus(_emp2Id, 'suspended', reason: 'Prueba E2E de suspensión');
        await expectLater(emp2.opsCases(scope: 'all'), _code('HMY_FORBIDDEN'));
        expect((await emp2.myAccount()).managementRole, isNull);
        final unassigned = await manager.opsCases(scope: 'unassigned');
        expect(unassigned.map((c) => c.id), contains(caseB));
      });

      // Auditoría: queda quién hizo qué; nadie del equipo la puede borrar.
      await _step('la auditoría registra roles y acciones del equipo', () async {
        final log = await owner.auditLog();
        final actions = log.map((e) => e.action).toSet();
        expect(actions, containsAll(['staff.grant', 'staff.suspended']));
        expect(log.where((e) => e.targetId == _emp2Id), isNotEmpty);
        final activity = await emp1.myStaffActivity();
        expect(activity.map((a) => a.action), containsAll(['case.reply', 'case.resolved', 'case.escalate']));
        // Sin permiso de borrar: la base lo rechaza (42501) o no borra nada.
        for (final db in [emp1Db, managerDb, ownerDb]) {
          try {
            await db.from('admin_audit_log').delete().neq('id', 0);
          } on PostgrestException catch (e) {
            expect(e.code, '42501');
          }
        }
        expect((await owner.auditLog()).length, greaterThanOrEqualTo(log.length), reason: 'nadie borra la auditoría');
      });
    },
    skip: configured ? false : 'Falta E2E_URL, E2E_ANON_KEY o E2E_PASSWORD',
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // Corre al final: suspender cuentas y comprobar que dejan de poder pedir o atender.
  test(
    'seguridad: un profesional suspendido sale del ¡Ya!, pierde sus pedidos y no ve direcciones; un cliente suspendido no pide',
    () async {
      final customer = await _step('el cliente entra', () => _signIn('e2e-cliente@test.bo'));
      final pro = await _step('el profesional entra', () => _signIn('e2e-pro@test.bo'));
      final owner = await _step('el propietario entra', () => _signIn('e2e-admin@test.bo'));
      final city = (await customer.cities()).first.id;
      final category = (await customer.categories()).firstWhere((c) => c.requiredDoc == null && c.allowsYa).id;
      Future<int> nearby() =>
          customer.countYaAvailable(categoryId: category, cityId: city, latitude: -17.79, longitude: -63.18);
      BookingDraft direct(String what) => BookingDraft(
        categoryId: category,
        cityId: city,
        mode: BookingMode.now,
        professionalId: _proId,
        description: 'Prueba E2E: $what',
        address: 'Calle Suspensión 9',
      );

      await _step('el profesional vuelve a estar disponible', () => pro.setAvailability(true));
      final before = await _step('¡Ya! lo cuenta cerca', nearby);
      expect(before, greaterThanOrEqualTo(1));
      final pending = await _step(
        'el cliente le pide directo',
        () => customer.create(direct('pedido antes de suspender')),
      );

      await _step('el propietario no suspende sin motivo', () async {
        await expectLater(owner.setSuspension(_proId, suspend: true, reason: ' '), _code('HMY_REASON_REQUIRED'));
      });
      await _step('el propietario suspende al profesional', () async {
        await owner.setSuspension(_proId, suspend: true, reason: 'Prueba E2E de suspensión');
      });
      await _step('su pedido sin empezar se cancela y nunca ve la dirección', () async {
        expect((await customer.detail(pending)).status, BookingStatus.cancelled);
        await expectLater(pro.accept(pending, isOffer: false), throwsA(anything));
        final d = await pro.detail(pending).then<BookingDetail?>((d) => d, onError: (_) => null);
        expect(d?.address, isNull);
      });
      await _step('sale del ¡Ya! y no puede ponerse disponible', () async {
        expect(await nearby(), before - 1);
        await expectLater(
          pro.setAvailability(true),
          _codeIn({'HMY_ACCOUNT_SUSPENDED', 'HMY_PROFESSIONAL_NOT_APPROVED'}),
        );
      });
      await _step('nadie le puede pedir directo', () async {
        await expectLater(
          customer.create(direct('pedido a un suspendido')),
          _codeIn({'HMY_PROFESSIONAL_NOT_AVAILABLE', 'HMY_PRO_NOT_CLEARED'}),
        );
      });
      await _step('el profesional recibe el aviso de la suspensión', () async {
        expect((await pro.list()).where((n) => n.kind == 'account'), isNotEmpty);
      });
      await _step('al levantar la suspensión vuelve a estar aprobado', () async {
        await owner.setSuspension(_proId, suspend: false);
        await pro.setAvailability(true);
        expect(await nearby(), before);
      });

      final open = await _step(
        'el cliente pide otra vez',
        () => customer.create(direct('pedido antes de suspender al cliente')),
      );
      await _step('el propietario suspende al cliente', () async {
        await owner.setSuspension('e2e00000-0000-4000-8000-0000000000c1', suspend: true, reason: 'Prueba E2E');
      });
      await _step('su pedido se cancela y el profesional no va a esa casa', () async {
        expect((await pro.detail(open)).status, BookingStatus.cancelled);
        expect((await pro.detail(open)).address, isNull);
        await expectLater(pro.accept(open, isOffer: false), throwsA(anything));
      });
      await _step('un cliente suspendido no puede pedir', () async {
        await expectLater(customer.create(direct('pedido de un suspendido')), _code('HMY_ACCOUNT_SUSPENDED'));
      });
      await _step('el profesional no puede suspender a nadie', () async {
        await expectLater(pro.setSuspension(_managerId, suspend: true, reason: 'Prueba E2E'), _code('HMY_FORBIDDEN'));
      });
      await _step('se levanta la suspensión del cliente', () async {
        await owner.setSuspension('e2e00000-0000-4000-8000-0000000000c1', suspend: false);
        await pro.setAvailability(false);
      });
    },
    skip: configured ? false : 'Falta E2E_URL, E2E_ANON_KEY o E2E_PASSWORD',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Corre al final: Mecánica y Grúa de punta a punta, con sus documentos aceptados.
  test(
    'mecánica y grúa: ¡Ya! con opciones, destino privado, cancelación y un remolque completo con código de llegada',
    () async {
      final customer = await _step('el cliente entra', () => _signIn('e2e-cliente@test.bo'));
      final pro = await _step('el profesional entra', () => _signIn('e2e-pro@test.bo'));
      final admin = await _step('el equipo entra', () => _signIn('e2e-admin@test.bo'));
      final city = (await customer.cities()).first.id;
      final categories = await customer.categories();
      final mecanica = categories.firstWhere((c) => c.slug == 'mecanica').id;
      final grua = categories.firstWhere((c) => c.slug == 'grua').id;
      final noArranca = (await customer.problems(mecanica)).firstWhere((p) => p.name == 'El auto no arranca').id;
      final remolque = (await customer.problems(grua)).firstWhere((p) => p.name == 'Remolque de vehículo').id;
      BookingDraft ya(int category, List<int> problems, String what, {String? destination}) => BookingDraft(
        categoryId: category,
        cityId: city,
        mode: BookingMode.now,
        description: what,
        address: 'Av. Prueba km 9',
        paymentMethod: PaymentMethod.cash,
        latitude: -17.7905,
        longitude: -63.1802,
        problemIds: problems,
        destination: destination,
      );

      await _step('el profesional se pone disponible', () => pro.setAvailability(true));
      await _step('el equipo acepta los antecedentes y los documentos de la grúa', () async {
        final docs = (await admin.adminApplicationDetail(_proId)).documents;
        final needed = docs.where((d) => d.docType == 'antecedentes' || d.docType == 'documentos_grua').toList();
        expect(needed.map((d) => d.docType).toSet(), {'antecedentes', 'documentos_grua'});
        for (final d in needed) {
          await admin.reviewDocument(d.id, DocumentStatus.accepted);
        }
      });

      // Mecánica.
      final mecId = await _step('el cliente pide mecánica ¡Ya! con una opción', () {
        return customer.create(ya(mecanica, [noArranca], 'Prueba E2E: el auto no arranca'));
      });
      await _step('mecánica no acepta destino', () async {
        await expectLater(
          customer.create(ya(mecanica, [noArranca], 'Prueba E2E', destination: 'Taller Central')),
          _code('HMY_INVALID_PROBLEM'),
        );
      });
      await _step('al mecánico le llega la oferta sin dirección; al aceptar la ve', () async {
        final offer = (await pro.myBookings(asProfessional: true)).firstWhere((b) => b.id == mecId);
        expect(offer.isOffer, isTrue);
        expect((await pro.detail(mecId)).address, isNull);
        await pro.accept(mecId, isOffer: true);
        final d = await pro.detail(mecId);
        expect(d.status, BookingStatus.confirmed);
        expect(d.address?.line, 'Av. Prueba km 9');
        expect(d.address?.destination, isNull);
      });
      await _step('el cliente cancela el pedido de mecánica', () => customer.cancel(mecId, 'Prueba E2E terminada'));

      // Grúa.
      await _step('la grúa sin destino se rechaza', () async {
        await expectLater(
          customer.create(ya(grua, [remolque], 'Vehículo: Camioneta. Prueba E2E')),
          _code('HMY_DESTINATION_REQUIRED'),
        );
      });
      final towId = await _step('el cliente pide grúa ¡Ya! con vehículo, recogida y destino', () {
        return customer.create(
          ya(
            grua,
            [remolque],
            'Vehículo: Camioneta. Prueba E2E: no enciende',
            destination: 'Taller Central, 3er anillo',
          ),
        );
      });
      await _step('a la grúa le llega la oferta sin dirección ni destino', () async {
        final offer = (await pro.myBookings(asProfessional: true)).firstWhere((b) => b.id == towId);
        expect(offer.isOffer, isTrue);
        expect(offer.distanceKm, isNotNull);
        expect((await pro.detail(towId)).address, isNull);
      });
      await _step('al aceptar, la grúa ve la recogida, el destino y el vehículo', () async {
        await pro.accept(towId, isOffer: true);
        final d = await pro.detail(towId);
        expect(d.status, BookingStatus.confirmed);
        expect(d.address?.line, 'Av. Prueba km 9');
        expect(d.address?.destination, 'Taller Central, 3er anillo');
        expect(d.description, contains('Camioneta'));
      });
      await _step('el cliente ve su destino y su vehículo', () async {
        final d = await customer.detail(towId);
        expect(d.address?.destination, 'Taller Central, 3er anillo');
        expect(d.description, contains('Camioneta'));
      });
      await _step('el cliente cancela la grúa ya aceptada', () async {
        await customer.cancel(towId, 'Prueba E2E: ya no la necesito');
        expect((await customer.detail(towId)).status, BookingStatus.cancelled);
        expect((await pro.detail(towId)).status, BookingStatus.cancelled);
      });

      // Un trabajo de grúa completo, pedido directo a la cuenta de prueba: no llega a nadie más.
      final jobId = await _step('el cliente pide la grúa de prueba directo, con destino y vehículo', () {
        return customer.create(
          BookingDraft(
            categoryId: grua,
            cityId: city,
            mode: BookingMode.now,
            professionalId: _proId,
            description: 'Vehículo: Auto. Prueba E2E: remolque completo',
            address: 'Av. Prueba km 9',
            paymentMethod: PaymentMethod.cash,
            problemIds: [remolque],
            destination: 'Taller Central, 3er anillo',
          ),
        );
      });
      await _step('la grúa acepta y sale en camino', () async {
        expect((await pro.detail(jobId)).address, isNull, reason: 'antes de aceptar no ve la recogida');
        await pro.accept(jobId, isOffer: false);
        expect((await pro.detail(jobId)).address?.destination, 'Taller Central, 3er anillo');
        await pro.updateProgress(jobId, BookingStatus.onTheWay);
        expect(await pro.shareTripLocation(jobId, const GeoPoint(-17.789, -63.181), accuracyM: 20), isTrue);
      });
      final towPin = await _step('la grúa llega y se genera el código', () => pro.markArrived(jobId));
      await _step('sin el código del cliente no se carga el vehículo', () async {
        await expectLater(pro.updateProgress(jobId, BookingStatus.inProgress), throwsA(anything));
        await expectLater(pro.verifyArrivalPin(jobId, towPin.pin), throwsA(anything));
      });
      await _step('el cliente confirma la llegada con su código', () async {
        expect((await customer.verifyArrivalPin(jobId, towPin.pin)).result, ArrivalCheckResult.verified);
        expect((await customer.tripLocation(jobId)).live, isFalse);
      });
      await _step('remolque en curso y terminado', () async {
        await pro.updateProgress(jobId, BookingStatus.inProgress);
        await pro.updateProgress(jobId, BookingStatus.workFinished, finalAmount: 180);
      });
      await _step('el cliente confirma, paga en efectivo y califica a la grúa', () async {
        await customer.confirmCompletion(jobId);
        await customer.acknowledgePayment(jobId, PaymentMethod.cash);
        await customer.submitReview(jobId, 5, 'Prueba E2E: grúa puntual');
        final d = await customer.detail(jobId);
        expect(d.status, BookingStatus.completed);
        expect(d.hasReview, isTrue);
      });
      await _step('la billetera de la grúa no queda con reserva colgada', () async {
        expect((await pro.wallet()).reserved, 0);
        await pro.setAvailability(false);
      });
    },
    skip: configured ? false : 'Falta E2E_URL, E2E_ANON_KEY o E2E_PASSWORD',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Corre al final: rechazar un ¡Ya!, una solicitud programada publicada, una
  // cotización aceptada y otra rechazada, y las reseñas en el perfil.
  test(
    'rechazo, programada, cotización y reseñas: cada paso con su aviso y sin pedidos repetidos',
    () async {
      // Otro cliente: el primero ya hizo los pedidos que el límite por hora permite.
      final customer = await _step('el cliente 2 entra', () => _signIn('e2e-cliente2@test.bo'));
      final reviewer = await _step('el cliente 1 entra', () => _signIn('e2e-cliente@test.bo'));
      final pro = await _step('el profesional entra', () => _signIn('e2e-pro@test.bo'));
      final city = (await customer.cities()).first.id;
      final category = (await customer.categories()).firstWhere((c) => c.requiredDoc == null && c.allowsYa).id;
      await _step(
        'perfil completo: Cliente Dos E2E',
        () => customer.completeSignup(fullName: 'Cliente Dos E2E', cityId: city, acceptTerms: true),
      );
      BookingDraft near(String what, {BookingMode mode = BookingMode.now, String? professionalId, DateTime? start}) =>
          BookingDraft(
            categoryId: category,
            cityId: city,
            mode: mode,
            professionalId: professionalId,
            scheduledStart: start,
            description: what,
            address: 'Calle Prueba 789',
            paymentMethod: PaymentMethod.cash,
            latitude: -17.7912,
            longitude: -63.1801,
          );
      await _step('el profesional se pone disponible', () => pro.setAvailability(true));

      // Rechazar un ¡Ya!: la oferta se va y no se puede aceptar después.
      final yaId = await _step('el cliente pide ¡Ya!', () => customer.create(near('Prueba E2E: ¡Ya! que se rechaza')));
      await _step('el profesional rechaza la oferta', () async {
        expect((await pro.myBookings(asProfessional: true)).firstWhere((b) => b.id == yaId).isOffer, isTrue);
        await pro.decline(yaId, isOffer: true);
        expect((await pro.myBookings(asProfessional: true)).where((b) => b.id == yaId && b.isOffer), isEmpty);
      });
      await _step('después de rechazar no puede aceptarlo ni rechazarlo otra vez', () async {
        await expectLater(pro.accept(yaId, isOffer: true), _code('HMY_FORBIDDEN'));
        await expectLater(pro.decline(yaId, isOffer: true), _code('HMY_NOT_FOUND'));
      });
      await _step('el pedido del cliente sigue buscando profesional y lo cancela', () async {
        expect((await customer.detail(yaId)).status, BookingStatus.awaitingResponse);
        await customer.cancel(yaId, 'Prueba E2E: ya no hace falta');
        expect((await customer.detail(yaId)).status, BookingStatus.cancelled);
      });

      // Programada sin elegir profesional: le llega al profesional de la zona.
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final start = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 10);
      final schedId = await _step('el cliente publica una solicitud programada', () {
        return customer.create(near('Prueba E2E: programada', mode: BookingMode.scheduled, start: start));
      });
      await _step('la misma solicitud otra vez se rechaza', () async {
        await expectLater(
          customer.create(near('Prueba E2E: programada', mode: BookingMode.scheduled, start: start)),
          _code('HMY_DUPLICATE_REQUEST'),
        );
      });
      await _step('al profesional le llega, sin dirección, con aviso', () async {
        final offer = (await pro.myBookings(asProfessional: true)).firstWhere((b) => b.id == schedId);
        expect(offer.isOffer, isTrue);
        expect((await pro.detail(schedId)).address, isNull);
        expect((await pro.list()).where((n) => n.kind == 'booking_new' && n.bookingId == schedId), isNotEmpty);
      });
      await _step('el profesional la acepta y el cliente recibe el aviso', () async {
        await pro.accept(schedId, isOffer: true);
        final d = await pro.detail(schedId);
        expect(d.status, BookingStatus.confirmed);
        expect(d.address?.line, 'Calle Prueba 789');
        final notes = (await customer.list()).where((n) => n.kind == 'booking_status' && n.bookingId == schedId);
        expect(notes, isNotEmpty);
      });
      await _step('aceptarla otra vez dice que ya está tomada', () async {
        await expectLater(pro.accept(schedId, isOffer: true), _code('HMY_ALREADY_TAKEN'));
      });
      await _step('el cliente cancela la programada y no queda reserva', () async {
        await customer.cancel(schedId, 'Prueba E2E: cambio de planes');
        expect((await pro.detail(schedId)).status, BookingStatus.cancelled);
        expect((await pro.wallet()).reserved, 0);
      });

      // Cotización: el profesional cotiza; el cliente acepta una y rechaza otra.
      final quotedId = await _step('el cliente pide directo y el profesional cotiza', () async {
        final id = await customer.create(near('Prueba E2E: cotización aceptada', professionalId: _proId));
        await expectLater(customer.sendQuote(id, 1, null), _code('HMY_INVALID_TRANSITION'));
        await expectLater(pro.sendQuote(id, 0, null), _code('HMY_INVALID_AMOUNT'));
        await pro.sendQuote(id, 150, 'Prueba E2E');
        final d = await customer.detail(id);
        expect(d.status, BookingStatus.quoteSent);
        expect(d.quoteAmount, closeTo(150, 0.005));
        return id;
      });
      await _step('el profesional no puede responder su propia cotización', () async {
        await expectLater(pro.respondQuote(quotedId, accept: true), throwsA(anything));
        expect((await customer.detail(quotedId)).status, BookingStatus.quoteSent);
      });
      await _step('el cliente acepta la cotización: queda confirmado', () async {
        await customer.respondQuote(quotedId, accept: true);
        expect((await pro.detail(quotedId)).status, BookingStatus.confirmed);
      });
      // Tiempo real (Supabase Realtime): lo que ve la app sin recargar.
      await _step('tiempo real: el mensaje del profesional le llega al cliente al momento', () async {
        final conv = (await customer.conversations()).firstWhere((c) => c.bookingId == quotedId);
        final arrived = customer
            .watchMessages(conv.id)
            .firstWhere((list) => list.any((m) => m.body == 'Prueba E2E: tiempo real'))
            .timeout(const Duration(seconds: 20));
        await Future<void>.delayed(const Duration(seconds: 2));
        await pro.send(conv.id, 'Prueba E2E: tiempo real');
        await arrived;
      });
      await _step('tiempo real: el aviso sin leer y el cambio de estado llegan solos', () async {
        final conv = (await pro.conversations()).firstWhere((c) => c.bookingId == quotedId);
        await pro.markAllRead();
        final unread = pro.unreadCount().firstWhere((n) => n > 0).timeout(const Duration(seconds: 20));
        final changed = pro.changes().first.timeout(const Duration(seconds: 20));
        await Future<void>.delayed(const Duration(seconds: 2));
        await customer.send(conv.id, 'Prueba E2E: ¿viene hoy?');
        await unread;
        await customer.cancel(quotedId, 'Prueba E2E: fin de la prueba');
        await changed;
      });
      await _step('otra cotización rechazada cancela el pedido', () async {
        final id = await customer.create(near('Prueba E2E: cotización rechazada', professionalId: _proId));
        await pro.sendQuote(id, 300, null);
        await customer.respondQuote(id, accept: false);
        expect((await pro.detail(id)).status, BookingStatus.cancelled);
        expect((await pro.wallet()).reserved, 0);
      });

      // Reseñas: la de la grúa aparece en el perfil y no se puede repetir.
      await _step('la reseña aparece en el perfil del profesional', () async {
        final reviews = await reviewer.reviews(_proId);
        expect(reviews.map((r) => r.comment), contains('Prueba E2E: grúa puntual'));
        expect((await reviewer.professionalDetail(_proId))?.summary.ratingCount, greaterThanOrEqualTo(1));
      });
      await _step('el mismo trabajo no se califica dos veces', () async {
        final done = (await reviewer.myBookings(asProfessional: false))
            .where((b) => b.status == BookingStatus.completed);
        expect(done, isNotEmpty);
        await expectLater(reviewer.submitReview(done.first.id, 1, 'Otra vez'), _code('HMY_ALREADY_RATED'));
      });
      await _step('el profesional deja de estar disponible', () => pro.setAvailability(false));
    },
    skip: configured ? false : 'Falta E2E_URL, E2E_ANON_KEY o E2E_PASSWORD',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
