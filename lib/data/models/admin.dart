import 'dart:typed_data';

import 'booking.dart';
import 'user.dart';
import 'wallet.dart';

double _d(Object? v) => v == null ? 0 : (v as num).toDouble();
double? _dn(Object? v) => v == null ? null : (v as num).toDouble();
DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

/// Números del inicio del panel.
class AdminDashboard {
  const AdminDashboard(this._m);

  final Map<String, dynamic> _m;

  int _i(String k) => (_m[k] as num?)?.toInt() ?? 0;

  int get pendingApplications => _i('pending_applications');
  int get pendingTopups => _i('pending_topups');
  int get openDisputes => _i('open_disputes');
  int get openReports => _i('open_reports');
  int get openTickets => _i('open_tickets');
  int get bookingsToday => _i('bookings_today');
  int get activeBookings => _i('active_bookings');
  int get approvedProfessionals => _i('approved_professionals');
  int get availableProfessionals => _i('available_professionals');
  int get users => _i('users');
  int get activeCommissionRules => _i('active_commission_rules');
}

class AdminApplication {
  const AdminApplication({
    required this.userId,
    required this.displayName,
    required this.fullName,
    this.phone,
    this.email,
    this.cityName,
    this.categoryName,
    required this.status,
    this.submittedAt,
    this.documents = 0,
  });

  final String userId;
  final String displayName;
  final String fullName;
  final String? phone;
  final String? email;
  final String? cityName;
  final String? categoryName;
  final VerificationStatus status;
  final DateTime? submittedAt;
  final int documents;

  factory AdminApplication.fromMap(Map<String, dynamic> m) => AdminApplication(
    userId: m['user_id'] as String,
    displayName: m['display_name'] as String? ?? '',
    fullName: m['full_name'] as String? ?? '',
    phone: m['phone'] as String?,
    email: m['email'] as String?,
    cityName: m['city_name'] as String?,
    categoryName: m['category_name'] as String?,
    status: VerificationStatus.parse(m['status'] as String?),
    submittedAt: _date(m['submitted_at']),
    documents: (m['documents'] as num?)?.toInt() ?? 0,
  );
}

enum DocumentStatus {
  pending('pending', 'Por revisar'),
  accepted('accepted', 'Aceptado'),
  rejected('rejected', 'Rechazado');

  const DocumentStatus(this.key, this.label);
  final String key;
  final String label;

  static DocumentStatus parse(String? v) => values.firstWhere((s) => s.key == v, orElse: () => pending);
}

class AdminDocument {
  const AdminDocument({
    required this.id,
    required this.docType,
    required this.status,
    this.url,
    this.bytes,
    this.reviewNote,
  });

  final int id;
  final String docType;
  final DocumentStatus status;
  final String? url;
  final Uint8List? bytes;
  final String? reviewNote;

  String get label => switch (docType) {
    'ci_anverso' => 'Carnet de identidad (frente)',
    'ci_reverso' => 'Carnet de identidad (reverso)',
    'certificado' => 'Certificado o título',
    'antecedentes' => 'Certificado de antecedentes',
    _ => 'Otro documento',
  };
}

class AdminApplicationDetail {
  const AdminApplicationDetail({
    required this.summary,
    this.bio,
    this.yearsExperience,
    this.reviewNote,
    this.zones = const [],
    this.categories = const [],
    this.documents = const [],
    this.history = const [],
  });

  final AdminApplication summary;
  final String? bio;
  final int? yearsExperience;
  final String? reviewNote;
  final List<String> zones;
  final List<String> categories;
  final List<AdminDocument> documents;
  final List<({VerificationStatus status, String? note, DateTime at})> history;
}

class AdminTopup {
  const AdminTopup({
    required this.id,
    required this.professionalId,
    required this.displayName,
    required this.amount,
    this.methodName,
    this.reference,
    this.proofUrl,
    this.proofBytes,
    required this.status,
    this.reviewNote,
    required this.createdAt,
  });

  final int id;
  final String professionalId;
  final String displayName;
  final double amount;
  final String? methodName;
  final String? reference;
  final String? proofUrl;
  final Uint8List? proofBytes;
  final TopupStatus status;
  final String? reviewNote;
  final DateTime createdAt;

  bool get hasProof => proofUrl != null || proofBytes != null;

  factory AdminTopup.fromMap(Map<String, dynamic> m, {String? proofUrl}) => AdminTopup(
    id: (m['id'] as num).toInt(),
    professionalId: m['professional_id'] as String,
    displayName: m['display_name'] as String? ?? '',
    amount: _d(m['amount']),
    methodName: m['method_name'] as String?,
    reference: m['reference'] as String?,
    proofUrl: proofUrl,
    status: TopupStatus.parse(m['status'] as String),
    reviewNote: m['review_note'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

enum ReportReason {
  noShow('no_se_presento', 'No se presentó'),
  badWork('mal_trabajo', 'Trabajo mal hecho'),
  overcharge('cobro_indebido', 'Cobró de más o cobro indebido'),
  harassment('acoso', 'Acoso, insultos o amenazas'),
  fraud('fraude', 'Estafa o fraude'),
  inappropriate('contenido_inapropiado', 'Mensajes o fotos inapropiadas'),
  other('otro', 'Otro motivo');

  const ReportReason(this.key, this.label);
  final String key;
  final String label;

  static ReportReason parse(String? v) => values.firstWhere((r) => r.key == v, orElse: () => other);
}

enum CaseStatus {
  open('open', 'Nuevo'),
  reviewing('reviewing', 'En revisión'),
  resolved('resolved', 'Resuelto'),
  dismissed('dismissed', 'Descartado');

  const CaseStatus(this.key, this.label);
  final String key;
  final String label;

  bool get isOpen => this == open || this == reviewing;

  static CaseStatus parse(String? v) => values.firstWhere((s) => s.key == v, orElse: () => open);
}

class AdminReport {
  const AdminReport({
    required this.id,
    required this.reporterName,
    required this.reportedId,
    required this.reportedName,
    this.bookingId,
    required this.reason,
    this.details,
    required this.status,
    this.resolution,
    required this.createdAt,
    this.reportsAgainst = 1,
  });

  final int id;
  final String reporterName;
  final String reportedId;
  final String reportedName;
  final String? bookingId;
  final ReportReason reason;
  final String? details;
  final CaseStatus status;
  final String? resolution;
  final DateTime createdAt;
  final int reportsAgainst;

  factory AdminReport.fromMap(Map<String, dynamic> m) => AdminReport(
    id: (m['id'] as num).toInt(),
    reporterName: m['reporter_name'] as String? ?? '',
    reportedId: m['reported_id'] as String,
    reportedName: m['reported_name'] as String? ?? '',
    bookingId: m['booking_id'] as String?,
    reason: ReportReason.parse(m['reason'] as String?),
    details: m['details'] as String?,
    status: CaseStatus.parse(m['status'] as String?),
    resolution: m['resolution'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    reportsAgainst: (m['reports_against'] as num?)?.toInt() ?? 1,
  );
}

class AdminDispute {
  const AdminDispute({
    required this.bookingId,
    required this.reason,
    required this.isOpen,
    this.resolution,
    required this.createdAt,
    required this.openedByName,
    required this.customerName,
    this.professionalName,
    this.categoryName,
  });

  final String bookingId;
  final String reason;
  final bool isOpen;
  final String? resolution;
  final DateTime createdAt;
  final String openedByName;
  final String customerName;
  final String? professionalName;
  final String? categoryName;

  factory AdminDispute.fromMap(Map<String, dynamic> m) => AdminDispute(
    bookingId: m['booking_id'] as String,
    reason: m['reason'] as String? ?? '',
    isOpen: m['status'] == 'open',
    resolution: m['resolution'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    openedByName: m['opened_by_name'] as String? ?? '',
    customerName: m['customer_name'] as String? ?? '',
    professionalName: m['professional_name'] as String?,
    categoryName: m['category_name'] as String?,
  );
}

enum TicketStatus {
  open('open', 'Nuevo'),
  inProgress('in_progress', 'En curso'),
  closed('closed', 'Cerrado');

  const TicketStatus(this.key, this.label);
  final String key;
  final String label;

  static TicketStatus parse(String? v) => values.firstWhere((s) => s.key == v, orElse: () => open);
}

class AdminTicket {
  const AdminTicket({
    required this.id,
    required this.userName,
    this.bookingId,
    required this.subject,
    required this.body,
    required this.status,
    this.adminNote,
    required this.createdAt,
  });

  final int id;
  final String userName;
  final String? bookingId;
  final String subject;
  final String body;
  final TicketStatus status;
  final String? adminNote;
  final DateTime createdAt;

  factory AdminTicket.fromMap(Map<String, dynamic> m) => AdminTicket(
    id: (m['id'] as num).toInt(),
    userName: m['user_name'] as String? ?? '',
    bookingId: m['booking_id'] as String?,
    subject: m['subject'] as String? ?? '',
    body: m['body'] as String? ?? '',
    status: TicketStatus.parse(m['status'] as String?),
    adminNote: m['admin_note'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

class AdminUser {
  const AdminUser({
    required this.id,
    required this.fullName,
    this.email,
    this.phone,
    this.cityName,
    this.roles = const {AppRole.customer},
    this.professionalStatus,
    this.suspendedAt,
    this.suspensionReason,
    this.reportsAgainst = 0,
  });

  final String id;
  final String fullName;
  final String? email;
  final String? phone;
  final String? cityName;
  final Set<AppRole> roles;
  final VerificationStatus? professionalStatus;
  final DateTime? suspendedAt;
  final String? suspensionReason;
  final int reportsAgainst;

  bool get isSuspended => suspendedAt != null;
  bool get isAdmin => roles.contains(AppRole.admin);

  factory AdminUser.fromMap(Map<String, dynamic> m) => AdminUser(
    id: m['id'] as String,
    fullName: m['full_name'] as String? ?? '',
    email: m['email'] as String?,
    phone: m['phone'] as String?,
    cityName: m['city_name'] as String?,
    roles: {for (final r in (m['roles'] as List? ?? const [])) AppRole.parse(r as String)},
    professionalStatus: m['professional_status'] == null
        ? null
        : VerificationStatus.parse(m['professional_status'] as String),
    suspendedAt: _date(m['suspended_at']),
    suspensionReason: m['suspension_reason'] as String?,
    reportsAgainst: (m['reports_against'] as num?)?.toInt() ?? 0,
  );
}

enum CommissionMilestone {
  accepted('accepted', 'Al aceptar el trabajo'),
  completed('completed', 'Al completar el trabajo');

  const CommissionMilestone(this.key, this.label);
  final String key;
  final String label;

  static CommissionMilestone parse(String? v) => values.firstWhere((s) => s.key == v, orElse: () => completed);
}

class CommissionRule {
  const CommissionRule({
    this.id,
    required this.name,
    this.categoryId,
    this.cityId,
    this.ratePercent,
    this.fixedFee,
    this.reserveAmount = 0,
    this.minBalance = 0,
    this.captureAt = CommissionMilestone.completed,
    this.isActive = true,
  });

  final int? id;
  final String name;
  final int? categoryId;
  final int? cityId;
  final double? ratePercent;
  final double? fixedFee;
  final double reserveAmount;
  final double minBalance;
  final CommissionMilestone captureAt;
  final bool isActive;

  factory CommissionRule.fromMap(Map<String, dynamic> m) => CommissionRule(
    id: (m['id'] as num).toInt(),
    name: m['name'] as String,
    categoryId: (m['category_id'] as num?)?.toInt(),
    cityId: (m['city_id'] as num?)?.toInt(),
    ratePercent: _dn(m['rate_percent']),
    fixedFee: _dn(m['fixed_fee']),
    reserveAmount: _d(m['reserve_amount']),
    minBalance: _d(m['min_balance']),
    captureAt: CommissionMilestone.parse(m['capture_at'] as String?),
    isActive: m['is_active'] as bool? ?? true,
  );
}

/// Elemento del catálogo que el administrador activa o desactiva.
class CatalogItem {
  const CatalogItem({required this.id, required this.name, required this.isActive, this.subtitle});

  final int id;
  final String name;
  final String? subtitle;
  final bool isActive;
}

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.actorName,
    required this.action,
    this.targetTable,
    this.targetId,
    this.details = const {},
    required this.createdAt,
  });

  final int id;
  final String actorName;
  final String action;
  final String? targetTable;
  final String? targetId;
  final Map<String, dynamic> details;
  final DateTime createdAt;

  /// Descripción en español de la acción.
  String get label {
    const known = {
      'topup.request': 'Pidió una recarga (con confirmación)',
      'topup.approve': 'Aprobó una recarga',
      'security.biometric_on': 'Activó la confirmación con huella o rostro',
      'security.biometric_off': 'Desactivó la confirmación con huella o rostro',
      'topup.reject': 'Rechazó una recarga',
      'wallet.adjust': 'Ajustó un saldo',
      'dispute.resolve': 'Resolvió una disputa',
      'account.suspend': 'Suspendió una cuenta',
      'account.reactivate': 'Reactivó una cuenta',
      'professional.approved': 'Aprobó a un profesional',
      'professional.rejected': 'Rechazó una postulación',
      'professional.suspended': 'Suspendió a un profesional',
      'professional.under_review': 'Marcó una postulación en revisión',
      'professional.reverification_required': 'Pidió nueva verificación',
      'document.accepted': 'Aceptó un documento',
      'document.rejected': 'Rechazó un documento',
      'document.pending': 'Volvió un documento a revisión',
      'report.reviewing': 'Tomó un reporte',
      'report.resolved': 'Resolvió un reporte',
      'report.dismissed': 'Descartó un reporte',
      'ticket.in_progress': 'Atendió un ticket de soporte',
      'ticket.closed': 'Cerró un ticket de soporte',
      'ticket.open': 'Reabrió un ticket de soporte',
      'review.moderate': 'Moderó una reseña',
    };
    if (known[action] case final l?) return l;
    final parts = action.split('.');
    if (parts.length == 2) {
      final what = switch (parts[0]) {
        'commission_rules' => 'una regla de comisión',
        'topup_methods' => 'un método de recarga',
        'service_categories' => 'una categoría',
        'cities' => 'una ciudad',
        'service_zones' => 'una zona',
        'promotions' => 'un banner',
        _ => parts[0],
      };
      final verb = switch (parts[1]) {
        'insert' => 'Creó',
        'update' => 'Cambió',
        'delete' => 'Borró',
        _ => parts[1],
      };
      return '$verb $what';
    }
    return action;
  }

  factory AuditEntry.fromMap(Map<String, dynamic> m) => AuditEntry(
    id: (m['id'] as num).toInt(),
    actorName: m['actor_name'] as String? ?? 'Sistema',
    action: m['action'] as String,
    targetTable: m['target_table'] as String?,
    targetId: m['target_id'] as String?,
    details: Map<String, dynamic>.from(m['details'] as Map? ?? const {}),
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

/// Resultado posible al resolver una disputa.
enum DisputeOutcome {
  completed(BookingStatus.completed, 'Dar el trabajo por completado'),
  cancelled(BookingStatus.cancelled, 'Cancelar el trabajo');

  const DisputeOutcome(this.status, this.label);
  final BookingStatus status;
  final String label;
}
