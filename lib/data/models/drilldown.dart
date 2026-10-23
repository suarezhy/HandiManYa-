/// Lo que hay detrás de cada número del panel (0041): pedidos, personas,
/// seguridad y fraude, y billeteras. Mismas definiciones que el panel, para
/// que la tarjeta y la lista digan lo mismo.
library;

import 'admin.dart';
import 'booking.dart';
import 'costs.dart';
import 'staff.dart';

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
double? _num(Object? v) => (v as num?)?.toDouble();

/// Una lista con su total real (la lista puede traer solo los primeros).
class Listed<T> {
  const Listed(this.items, this.total);

  final List<T> items;
  final int total;

  bool get isPartial => items.length < total;
}

enum BookingFilter {
  today('hoy', 'Hoy', 'Pedidos de hoy'),
  active('activos', 'Activos', 'Pedidos activos'),
  completedToday('completados_hoy', 'Completados hoy', 'Completados hoy'),
  cancelledToday('cancelados_hoy', 'Cancelados hoy', 'Cancelados hoy'),
  completedMonth('completados_mes', 'Completados del mes', 'Completados este mes'),
  cancelledMonth('cancelados_mes', 'Cancelados del mes', 'Cancelados este mes'),
  recent('recientes', 'Últimos 30 días', 'Últimos 30 días');

  const BookingFilter(this.key, this.label, this.title);
  final String key;
  final String label;
  final String title;

  static BookingFilter parse(String? v) => values.firstWhere((f) => f.key == v, orElse: () => today);
}

/// Un pedido visto por el equipo: sin dirección ni GPS. Los montos llegan
/// solo al propietario (null para el gerente).
class OpsBooking {
  const OpsBooking({
    required this.id,
    required this.code,
    required this.status,
    required this.mode,
    this.categoryName,
    this.cityName,
    this.zoneName,
    required this.customerName,
    this.professionalName,
    this.scheduledStart,
    this.acceptedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancelReason,
    this.paymentMethod,
    required this.createdAt,
    this.hasDispute = false,
    this.openCaseId,
    this.finalAmount,
    this.quoteAmount,
    this.commissionReserved,
    this.commissionCaptured,
  });

  final String id;
  final String code;
  final BookingStatus status;
  final BookingMode mode;
  final String? categoryName;
  final String? cityName;
  final String? zoneName;
  final String customerName;
  final String? professionalName;
  final DateTime? scheduledStart;
  final DateTime? acceptedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final PaymentMethod? paymentMethod;
  final DateTime createdAt;
  final bool hasDispute;
  final int? openCaseId;
  final double? finalAmount;
  final double? quoteAmount;
  final double? commissionReserved;
  final double? commissionCaptured;

  factory OpsBooking.fromMap(Map<String, dynamic> m) => OpsBooking(
    id: m['id'] as String,
    code: m['code'] as String? ?? '',
    status: BookingStatus.parse(m['status'] as String?),
    mode: BookingMode.parse(m['mode'] as String?),
    categoryName: m['category_name'] as String?,
    cityName: m['city_name'] as String?,
    zoneName: m['zone_name'] as String?,
    customerName: m['customer_name'] as String? ?? '',
    professionalName: m['professional_name'] as String?,
    scheduledStart: _date(m['scheduled_start']),
    acceptedAt: _date(m['accepted_at']),
    completedAt: _date(m['completed_at']),
    cancelledAt: _date(m['cancelled_at']),
    cancelReason: m['cancel_reason'] as String?,
    paymentMethod: m['payment_method'] == null ? null : PaymentMethod.parse(m['payment_method'] as String),
    createdAt: _date(m['created_at']) ?? DateTime.now(),
    hasDispute: m['has_dispute'] as bool? ?? false,
    openCaseId: (m['open_case_id'] as num?)?.toInt(),
    finalAmount: _num(m['final_amount']),
    quoteAmount: _num(m['quote_amount']),
    commissionReserved: _num(m['commission_reserved']),
    commissionCaptured: _num(m['commission_captured']),
  );
}

/// Un cambio de estado del pedido. Quién: cliente, profesional, equipo o
/// sistema (sin nombres).
class OpsBookingEvent {
  const OpsBookingEvent({this.from, required this.to, this.note, this.actor, required this.at});

  final BookingStatus? from;
  final BookingStatus to;
  final String? note;
  final String? actor;
  final DateTime at;

  String? get actorLabel => switch (actor) {
    'cliente' => 'Cliente',
    'profesional' => 'Profesional',
    'equipo' => 'Equipo de HandiMan ¡Ya!',
    'sistema' => 'Automático',
    _ => null,
  };

  factory OpsBookingEvent.fromMap(Map<String, dynamic> m) => OpsBookingEvent(
    from: m['from_status'] == null ? null : BookingStatus.parse(m['from_status'] as String),
    to: BookingStatus.parse(m['to_status'] as String?),
    note: m['note'] as String?,
    actor: m['actor'] as String?,
    at: _date(m['created_at']) ?? DateTime.now(),
  );
}

class OpsBookingDetail {
  const OpsBookingDetail({
    required this.booking,
    this.description,
    this.events = const [],
    this.cases = const [],
    this.disputeStatus,
    this.disputeReason,
    this.disputeResolution,
  });

  final OpsBooking booking;
  final String? description;
  final List<OpsBookingEvent> events;
  final List<OpsCase> cases;
  final String? disputeStatus;
  final String? disputeReason;
  final String? disputeResolution;

  factory OpsBookingDetail.fromMap(Map<String, dynamic> m) {
    final d = m['dispute'] as Map<String, dynamic>?;
    return OpsBookingDetail(
      booking: OpsBooking.fromMap(m),
      description: m['description'] as String?,
      events: [for (final e in (m['events'] as List? ?? const [])) OpsBookingEvent.fromMap(e as Map<String, dynamic>)],
      cases: [for (final c in (m['cases'] as List? ?? const [])) OpsCase.fromMap(c as Map<String, dynamic>)],
      disputeStatus: d?['status'] as String?,
      disputeReason: d?['reason'] as String?,
      disputeResolution: d?['resolution'] as String?,
    );
  }
}

enum PeopleFilter {
  all('todos', 'Todos', 'Usuarios'),
  customers('clientes', 'Clientes', 'Clientes'),
  professionals('profesionales', 'Profesionales aprobados', 'Profesionales aprobados'),
  available('disponibles', 'Disponibles ahora', 'Disponibles ahora'),
  identity('identidad', 'Identidad en revisión', 'Identidad en revisión'),
  suspended('suspendidos', 'Suspendidos', 'Cuentas suspendidas');

  const PeopleFilter(this.key, this.label, this.title);
  final String key;
  final String label;
  final String title;

  static PeopleFilter parse(String? v) => values.firstWhere((f) => f.key == v, orElse: () => all);
}

/// Una persona de la lista, con lo que el panel cuenta de ella.
class PersonRow {
  const PersonRow({required this.user, this.isAvailable, this.identityStatus});

  final AdminUser user;
  final bool? isAvailable;
  final IdentityStatus? identityStatus;

  factory PersonRow.fromMap(Map<String, dynamic> m) => PersonRow(
    user: AdminUser.fromMap(m),
    isAvailable: m['is_available'] as bool?,
    identityStatus: m['identity_status'] == null ? null : IdentityStatus.parse(m['identity_status'] as String),
  );
}

enum RiskKind {
  safety('safety', 'Incidentes de seguridad'),
  fraud('fraud', 'Alertas de fraude');

  const RiskKind(this.key, this.title);
  final String key;
  final String title;

  static RiskKind parse(String? v) => v == 'fraude' || v == 'fraud' ? fraud : safety;
}

/// Un incidente o alerta, de un reporte, un caso o el Centro IA.
class RiskItem {
  const RiskItem({
    required this.source,
    required this.id,
    required this.title,
    required this.status,
    required this.severity,
    this.reason,
    this.detail,
    this.person,
    this.personId,
    this.caseId,
    required this.createdAt,
  });

  /// 'report', 'case' o 'ai'.
  final String source;
  final String id;
  final String title;
  final String status;
  final String severity;
  final String? reason;
  final String? detail;
  final String? person;
  final String? personId;
  final int? caseId;
  final DateTime createdAt;

  String get sourceLabel => switch (source) {
    'report' => 'Reporte de un usuario',
    'case' => 'Caso del equipo',
    _ => 'Centro IA (reglas)',
  };

  String get statusLabel => switch (status) {
    'open' => 'Nuevo',
    'reviewing' => 'En revisión',
    'in_progress' => 'En curso',
    'waiting' => 'Esperando respuesta',
    'escalated' => 'Escalado',
    'pending_approval' => 'Espera aprobación',
    'more_info' => 'Pide más datos',
    _ => status,
  };

  String get severityLabel => switch (severity) {
    'critical' => 'Crítica',
    'high' => 'Alta',
    'medium' => 'Media',
    'low' => 'Baja',
    _ => 'Informativa',
  };

  factory RiskItem.fromMap(Map<String, dynamic> m) => RiskItem(
    source: m['source'] as String? ?? 'case',
    id: '${m['id']}',
    title: m['title'] as String? ?? '',
    status: m['status'] as String? ?? 'open',
    severity: m['severity'] as String? ?? 'medium',
    reason: m['reason'] as String?,
    detail: m['detail'] as String?,
    person: m['person'] as String?,
    personId: m['person_id'] as String?,
    caseId: (m['case_id'] as num?)?.toInt(),
    createdAt: _date(m['created_at']) ?? DateTime.now(),
  );
}

enum WalletSort {
  available('disponible', 'Más saldo disponible'),
  reserved('reservado', 'Más saldo reservado'),
  recent('reciente', 'Movimiento más reciente');

  const WalletSort(this.key, this.label);
  final String key;
  final String label;
}

/// La billetera de un profesional: su dinero, no un ingreso de la plataforma.
class OwnerWallet {
  const OwnerWallet({
    required this.professionalId,
    required this.name,
    this.cityName,
    required this.available,
    required this.reserved,
    this.lastMovementAt,
    this.pendingTopups = 0,
  });

  final String professionalId;
  final String name;
  final String? cityName;
  final double available;
  final double reserved;
  final DateTime? lastMovementAt;
  final int pendingTopups;

  factory OwnerWallet.fromMap(Map<String, dynamic> m) => OwnerWallet(
    professionalId: m['professional_id'] as String,
    name: m['name'] as String? ?? '',
    cityName: m['city_name'] as String?,
    available: _num(m['available']) ?? 0,
    reserved: _num(m['reserved']) ?? 0,
    lastMovementAt: _date(m['last_movement_at']),
    pendingTopups: (m['pending_topups'] as num?)?.toInt() ?? 0,
  );
}

class WalletList {
  const WalletList({required this.items, required this.total, required this.available, required this.reserved});

  final List<OwnerWallet> items;
  final int total;

  /// Sumas de todas las billeteras (no solo de las mostradas).
  final double available;
  final double reserved;

  factory WalletList.fromMap(Map<String, dynamic> m) => WalletList(
    items: [for (final w in (m['items'] as List? ?? const [])) OwnerWallet.fromMap(w as Map<String, dynamic>)],
    total: (m['total'] as num?)?.toInt() ?? 0,
    available: _num(m['available']) ?? 0,
    reserved: _num(m['reserved']) ?? 0,
  );
}
