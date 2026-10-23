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
import 'package:handimanya/data/models/finance.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/data/models/staff.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/supabase/supabase_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment('E2E_URL');
const _key = String.fromEnvironment('E2E_ANON_KEY');
const _pw = String.fromEnvironment('E2E_PASSWORD');

const _proId = 'e2e00000-0000-4000-8000-0000000000b1';
const _managerId = 'e2e00000-0000-4000-8000-0000000000e0';
const _emp1Id = 'e2e00000-0000-4000-8000-0000000000e1';
const _emp2Id = 'e2e00000-0000-4000-8000-0000000000e2';

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
}
