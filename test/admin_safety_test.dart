import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/admin.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/models/wallet.dart';

import 'support/demo_login.dart';

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

void main() {
  late DemoBackend backend;

  setUp(() => backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero));
  tearDown(() => backend.dispose());

  Future<void> as(String phone) => backend.signInAs(phone);

  test('solo el administrador usa el panel', () async {
    await as(DemoBackend.customerPhone);
    await expectLater(backend.adminDashboard(), _code('HMY_FORBIDDEN'));
    await expectLater(backend.adminUsers(''), _code('HMY_FORBIDDEN'));

    await as(DemoBackend.adminPhone);
    final d = await backend.adminDashboard();
    expect(d.pendingApplications, 2);
    expect(d.pendingTopups, 2);
    expect(d.openReports, 1);
    expect(d.openDisputes, 1);
    expect(d.activeCommissionRules, 1);
  });

  test('aprobar una postulación da el rol profesional y queda en la auditoría', () async {
    await as(DemoBackend.adminPhone);
    final pending = await backend.adminApplications();
    final id = pending.first.userId;
    final detail = await backend.adminApplicationDetail(id);
    expect(detail.documents, isNotEmpty);

    await expectLater(backend.reviewApplication(id, VerificationStatus.rejected), _code('HMY_REASON_REQUIRED'));
    await backend.reviewDocument(detail.documents.first.id, DocumentStatus.accepted);
    await backend.reviewApplication(id, VerificationStatus.approved);

    expect((await backend.adminApplications()).map((a) => a.userId), isNot(contains(id)));
    final log = await backend.auditLog();
    expect(log.map((e) => e.action), containsAll(['professional.approved', 'document.accepted']));
    expect(log.first.label, 'Aprobó a un profesional');
  });

  test('recargas: acreditar suma saldo una sola vez', () async {
    await as(DemoBackend.adminPhone);
    final t = (await backend.adminTopups()).first;
    await backend.reviewTopup(t.id, approve: true);
    await expectLater(backend.reviewTopup(t.id, approve: true), _code('HMY_ALREADY_REVIEWED'));
    expect((await backend.adminTopups()).map((x) => x.id), isNot(contains(t.id)));
  });

  test('comprobante de recarga llega al panel', () async {
    await as(DemoBackend.professionalPhone);
    await backend.confirmWithCode();
    await backend.requestTopup(
      amount: 40,
      methodId: 1,
      reference: 'ABC',
      proof: PhotoUpload(bytes: Uint8List.fromList([1, 2, 3]), fileName: 'r.jpg'),
      authMethod: 'otp',
      clientKey: 'k-proof',
    );
    await as(DemoBackend.adminPhone);
    final mine = (await backend.adminTopups()).where((t) => t.professionalId == 'demo-pro');
    expect(mine.single.hasProof, isTrue);
    expect(mine.single.status, TopupStatus.pending);
  });

  test('comisiones: no se guarda una regla sin monto', () async {
    await as(DemoBackend.adminPhone);
    await expectLater(
      backend.saveCommissionRule(const CommissionRule(name: 'Vacía')),
      _code('HMY_COMMISSION_REQUIRED'),
    );
    await backend.saveCommissionRule(
      const CommissionRule(name: 'Plomería Santa Cruz', categoryId: 1, cityId: 1, ratePercent: 8),
    );
    expect((await backend.commissionRules()).map((r) => r.name), contains('Plomería Santa Cruz'));
    expect((await backend.auditLog()).first.action, 'commission_rules.insert');
  });

  test('suspender: la persona ve el motivo y no puede pedir; reactivar lo devuelve', () async {
    await as(DemoBackend.adminPhone);
    final carla = (await backend.adminUsers('carla')).single;
    await expectLater(backend.setSuspension(carla.id, suspend: true), _code('HMY_REASON_REQUIRED'));
    await backend.setSuspension(carla.id, suspend: true, reason: 'Pedidos falsos');
    final admin = (await backend.adminUsers('equipo')).single;
    await expectLater(backend.setSuspension(admin.id, suspend: true, reason: 'x'), _code('HMY_FORBIDDEN'));

    await as(DemoBackend.customerPhone);
    final me = await backend.myAccount();
    expect(me.isSuspended, isTrue);
    expect(me.suspensionReason, 'Pedidos falsos');
    await expectLater(
      backend.create(
        const BookingDraft(
          categoryId: 2,
          cityId: 1,
          mode: BookingMode.now,
          description: 'Se cortó la luz',
          address: 'Calle 1',
        ),
      ),
      _code('HMY_ACCOUNT_SUSPENDED'),
    );

    await as(DemoBackend.adminPhone);
    await backend.setSuspension(carla.id, suspend: false);
    await as(DemoBackend.customerPhone);
    expect((await backend.myAccount()).isSuspended, isFalse);
  });

  test('suspender a un profesional lo saca de los pedidos ¡Ya!', () async {
    await as(DemoBackend.professionalPhone);
    await backend.setAvailability(true);
    await as(DemoBackend.customerPhone);
    final before = await backend.countYaAvailable(categoryId: 2, cityId: 1);

    await as(DemoBackend.adminPhone);
    await backend.setSuspension('demo-pro', suspend: true, reason: 'Cobros indebidos');
    await as(DemoBackend.customerPhone);
    expect(await backend.countYaAvailable(categoryId: 2, cityId: 1), before - 1);
  });

  test('bloquear corta el chat y las ofertas; reportar llega al panel', () async {
    await as(DemoBackend.professionalPhone);
    await backend.setAvailability(true);
    await as(DemoBackend.customerPhone);
    final before = await backend.countYaAvailable(categoryId: 2, cityId: 1);
    await backend.blockUser('demo-pro');
    expect((await backend.myAccount()).blockedIds, contains('demo-pro'));
    expect(await backend.countYaAvailable(categoryId: 2, cityId: 1), before - 1);

    await backend.reportUser(userId: 'demo-pro', reason: ReportReason.harassment, details: 'Me insultó');
    await backend.unblockUser('demo-pro');
    expect(await backend.countYaAvailable(categoryId: 2, cityId: 1), before);

    await as(DemoBackend.adminPhone);
    final reports = await backend.adminReports();
    final r = reports.firstWhere((x) => x.reportedId == 'demo-pro');
    expect(r.reason, ReportReason.harassment);
    await expectLater(backend.reviewReport(r.id, CaseStatus.resolved), _code('HMY_REASON_REQUIRED'));
    await backend.reviewReport(r.id, CaseStatus.resolved, resolution: 'Se advirtió al profesional');
    expect((await backend.adminReports()).map((x) => x.id), isNot(contains(r.id)));
  });

  test('disputa: el admin la resuelve y se cierra', () async {
    await as(DemoBackend.adminPhone);
    final d = (await backend.adminDisputes()).single;
    await backend.resolveDispute(d.bookingId, DisputeOutcome.cancelled, 'El trabajo no se terminó');
    expect(await backend.adminDisputes(), isEmpty);
    expect((await backend.adminDisputes(status: 'all')).single.resolution, 'El trabajo no se terminó');
  });

  test('soporte: el mensaje del usuario llega y el admin lo cierra', () async {
    await as(DemoBackend.customerPhone);
    await backend.contactSupport(subject: 'Ayuda', body: 'No encuentro mi recibo');
    await as(DemoBackend.adminPhone);
    final t = (await backend.adminTickets()).firstWhere((x) => x.subject == 'Ayuda');
    await backend.updateTicket(t.id, TicketStatus.closed, note: 'Te enviamos el detalle por correo.');
    expect((await backend.adminTickets()).map((x) => x.id), isNot(contains(t.id)));
  });

  test('catálogo: apagar una categoría la quita de la app', () async {
    await as(DemoBackend.adminPhone);
    final before = (await backend.categories()).length;
    await backend.setCategoryActive(1, false);
    expect((await backend.categories()).length, before - 1);
    await backend.setCategoryActive(1, true);
    expect((await backend.categories()).length, before);
  });

  test('consentimientos quedan registrados por versión', () async {
    await as(DemoBackend.customerPhone);
    await backend.recordConsent('terminos', '2026-10-borrador');
    expect(backend.hasConsent('demo-cliente', 'terminos', '2026-10-borrador'), isTrue);
    expect(backend.hasConsent('demo-cliente', 'privacidad', '2026-10-borrador'), isFalse);
  });
}
