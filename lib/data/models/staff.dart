/// Roles de gestión: Propietario, Gerente de Operaciones y Empleado. Los
/// permisos los decide el servidor (hmy_can); la app solo elige qué panel
/// mostrar.
library;

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();

enum StaffRole {
  owner('owner', 'Propietario', 'Panel del Propietario'),
  manager('manager', 'Gerente de Operaciones', 'Panel del Gerente'),
  employee('employee', 'Empleado', 'Panel del Empleado');

  const StaffRole(this.key, this.label, this.panelTitle);
  final String key;
  final String label;
  final String panelTitle;

  static StaffRole? parse(String? v) => values.where((r) => r.key == v).firstOrNull;
}

/// Lo que el servidor permite a cada rol (supabase/migrations/…_management_roles.sql,
/// hmy_role_permissions). Sirve para explicar los permisos en el perfil; las
/// acciones las vuelve a revisar el servidor.
const staffPermissionLabels = <String, String>{
  'ops.dashboard': 'Ver el resumen de operaciones',
  'cases.view_all': 'Ver todos los casos',
  'cases.view_own': 'Ver los casos asignados a ti',
  'cases.assign': 'Asignar y reasignar casos',
  'cases.update': 'Cambiar el estado de cualquier caso',
  'cases.update_own': 'Cambiar el estado de tus casos (dentro de los límites)',
  'cases.note': 'Escribir notas internas',
  'cases.reply': 'Responder mensajes de soporte',
  'cases.escalate': 'Escalar casos',
  'applications.list': 'Revisar postulaciones completas',
  'applications.decide': 'Aprobar o rechazar profesionales (con todos los controles en regla)',
  'documents.view': 'Abrir documentos de identidad para revisarlos',
  'documents.review': 'Aceptar o rechazar documentos',
  'documents.flag': 'Marcar documentos faltantes o dudosos',
  'reports.view': 'Ver reportes',
  'reports.decide': 'Resolver reportes',
  'disputes.view': 'Ver disputas',
  'tickets.view': 'Ver todos los mensajes de soporte',
  'tickets.reply': 'Responder cualquier mensaje de soporte',
  'users.view': 'Buscar usuarios',
  'users.suspend': 'Suspender clientes o profesionales',
  'staff.view': 'Ver al equipo y sus tiempos de respuesta',
  'bookings.monitor': 'Seguir los trabajos activos',
};

/// Lo que cada rol no puede hacer, para mostrarlo claro en su perfil.
const staffRestrictions = <StaffRole, List<String>>{
  StaffRole.manager: [
    'Presupuestos, banco, ingresos, comisiones, billeteras o recargas',
    'Reembolsos, ajustes de dinero o resolver disputas con efecto en dinero',
    'Comisiones, ajustes de la plataforma o gastos de IA',
    'Crear miembros del equipo o cambiar permisos',
    'Pasar por alto una verificación de identidad rechazada',
    'Borrar la auditoría',
  ],
  StaffRole.employee: [
    'Aprobar o rechazar profesionales',
    'Abrir documentos de identidad',
    'Suspender cuentas',
    'Ver casos de otros miembros del equipo',
    'Dinero, reportes financieros, comisiones o recargas',
    'Gastos de IA o ajustes de la plataforma',
    'Crear miembros del equipo o cambiar roles',
    'Borrar la auditoría',
  ],
};

class StaffAccess {
  const StaffAccess({this.role, this.status, this.permissions = const {}});

  /// null: la cuenta no tiene rol de gestión activo.
  final StaffRole? role;

  /// 'active', 'suspended' o 'revoked' (Gerente y Empleado); null si nunca tuvo.
  final String? status;
  final Set<String> permissions;

  bool can(String permission) => role == StaffRole.owner || permissions.contains(permission);

  factory StaffAccess.fromMap(Map<String, dynamic> m) => StaffAccess(
    role: StaffRole.parse(m['role'] as String?),
    status: m['status'] as String?,
    permissions: {for (final p in (m['permissions'] as List? ?? const [])) p as String},
  );

  static const none = StaffAccess();
}

enum OpsCaseKind {
  support('support', 'Soporte'),
  application('application', 'Postulación'),
  dispute('dispute', 'Disputa'),
  report('report', 'Reporte');

  const OpsCaseKind(this.key, this.label);
  final String key;
  final String label;

  static OpsCaseKind parse(String? v) => values.firstWhere((k) => k.key == v, orElse: () => support);
}

enum OpsCaseStatus {
  open('open', 'Nuevo'),
  inProgress('in_progress', 'En curso'),
  waiting('waiting', 'Esperando respuesta'),
  escalated('escalated', 'Escalado'),
  resolved('resolved', 'Resuelto');

  const OpsCaseStatus(this.key, this.label);
  final String key;
  final String label;

  static OpsCaseStatus parse(String? v) => values.firstWhere((s) => s.key == v, orElse: () => open);
}

class OpsCase {
  const OpsCase({
    required this.id,
    required this.kind,
    required this.refId,
    required this.title,
    this.category = 'routine',
    required this.status,
    this.priority = 'normal',
    this.assignedTo,
    this.assignedName,
    this.escalatedTo,
    this.firstResponseAt,
    this.resolvedAt,
    required this.createdAt,
  });

  final int id;
  final OpsCaseKind kind;
  final String refId;
  final String title;

  /// 'routine', 'safety', 'fraud' o 'dispute'. Los no rutinarios el empleado
  /// solo los escala.
  final String category;
  final OpsCaseStatus status;

  /// 'normal', 'high' o 'urgent'.
  final String priority;
  final String? assignedTo;
  final String? assignedName;
  final String? escalatedTo;
  final DateTime? firstResponseAt;
  final DateTime? resolvedAt;
  final DateTime createdAt;

  bool get isRoutine => category == 'routine';

  String get categoryLabel => switch (category) {
    'safety' => 'Seguridad',
    'fraud' => 'Posible fraude',
    'dispute' => 'Disputa',
    _ => 'Rutina',
  };

  String get priorityLabel => switch (priority) {
    'urgent' => 'Urgente',
    'high' => 'Alta',
    _ => 'Normal',
  };

  factory OpsCase.fromMap(Map<String, dynamic> m) => OpsCase(
    id: (m['id'] as num).toInt(),
    kind: OpsCaseKind.parse(m['kind'] as String?),
    refId: m['ref_id'] as String? ?? '',
    title: m['title'] as String? ?? '',
    category: m['category'] as String? ?? 'routine',
    status: OpsCaseStatus.parse(m['status'] as String?),
    priority: m['priority'] as String? ?? 'normal',
    assignedTo: m['assigned_to'] as String?,
    assignedName: m['assigned_name'] as String?,
    escalatedTo: m['escalated_to'] as String?,
    firstResponseAt: _date(m['first_response_at']),
    resolvedAt: _date(m['resolved_at']),
    createdAt: _date(m['created_at']) ?? DateTime.now(),
  );
}

class OpsCaseNote {
  const OpsCaseNote({required this.kind, required this.body, required this.authorName, required this.createdAt});

  /// 'note', 'reply', 'flag', 'status', 'assign' o 'escalate'.
  final String kind;
  final String body;
  final String authorName;
  final DateTime createdAt;

  String get kindLabel => switch (kind) {
    'reply' => 'Respuesta enviada',
    'flag' => 'Documento marcado',
    'status' => 'Estado',
    'assign' => 'Asignación',
    'escalate' => 'Escalado',
    _ => 'Nota interna',
  };

  factory OpsCaseNote.fromMap(Map<String, dynamic> m) => OpsCaseNote(
    kind: m['kind'] as String? ?? 'note',
    body: m['body'] as String? ?? '',
    authorName: m['author_name'] as String? ?? '',
    createdAt: _date(m['created_at']) ?? DateTime.now(),
  );
}

/// Un documento de una postulación, sin el archivo (el empleado no lo abre).
class OpsDocument {
  const OpsDocument({required this.id, required this.docType, required this.status, this.flagNote});

  final int id;
  final String docType;
  final String status;
  final String? flagNote;

  factory OpsDocument.fromMap(Map<String, dynamic> m) => OpsDocument(
    id: (m['id'] as num).toInt(),
    docType: m['doc_type'] as String? ?? '',
    status: m['status'] as String? ?? 'pending',
    flagNote: m['flag_note'] as String?,
  );
}

class OpsCaseDetail {
  const OpsCaseDetail({required this.item, this.source = const {}, this.notes = const []});

  final OpsCase item;

  /// Resumen del origen (ticket, reporte, disputa o postulación), tal como lo
  /// manda el servidor: sin dinero, teléfonos ni archivos.
  final Map<String, dynamic> source;
  final List<OpsCaseNote> notes;

  String? s(String key) => source[key]?.toString();

  List<OpsDocument> get documents => [
    for (final d in (source['documents'] as List? ?? const []))
      OpsDocument.fromMap(Map<String, dynamic>.from(d as Map)),
  ];

  factory OpsCaseDetail.fromMap(Map<String, dynamic> m) => OpsCaseDetail(
    item: OpsCase.fromMap(m),
    source: Map<String, dynamic>.from(m['source'] as Map? ?? const {}),
    notes: [
      for (final n in (m['notes'] as List? ?? const [])) OpsCaseNote.fromMap(Map<String, dynamic>.from(n as Map)),
    ],
  );
}

/// Resumen de operaciones: solo conteos, nunca dinero.
class OpsDashboard {
  const OpsDashboard(this._m);

  final Map<String, dynamic> _m;

  int? _i(String k) => (_m[k] as num?)?.toInt();

  bool get hasTeamView => _m.containsKey('unassigned_cases');
  int get myOpenCases => _i('my_open_cases') ?? 0;
  int get myEscalated => _i('my_escalated') ?? 0;
  int get myResolved7d => _i('my_resolved_7d') ?? 0;
  int get unassignedCases => _i('unassigned_cases') ?? 0;
  int get escalatedCases => _i('escalated_cases') ?? 0;
  int get urgentCases => _i('urgent_cases') ?? 0;
  int get pendingApplications => _i('pending_applications') ?? 0;
  int get pendingDocuments => _i('pending_documents') ?? 0;
  int get flaggedDocuments => _i('flagged_documents') ?? 0;
  int get openTickets => _i('open_tickets') ?? 0;
  int get openReports => _i('open_reports') ?? 0;
  int get openDisputes => _i('open_disputes') ?? 0;
  int get activeBookings => _i('active_bookings') ?? 0;
  int get bookingsToday => _i('bookings_today') ?? 0;
  int get completedToday => _i('completed_today') ?? 0;
  int get cancelledToday => _i('cancelled_today') ?? 0;
  int get availableProfessionals => _i('available_professionals') ?? 0;
  int get approvedProfessionals => _i('approved_professionals') ?? 0;

  /// Claves que mandó el servidor (las pruebas revisan que no haya dinero).
  Set<String> get keys => _m.keys.toSet();
}

class StaffMember {
  const StaffMember({
    required this.userId,
    required this.fullName,
    required this.role,
    required this.status,
    this.statusReason,
    this.phoneMasked,
    this.openCases = 0,
    this.resolved7d = 0,
    this.avgFirstResponseMin,
  });

  final String userId;
  final String fullName;
  final StaffRole role;
  final String status;
  final String? statusReason;

  /// "+591 7••• ••05": nunca el número completo.
  final String? phoneMasked;
  final int openCases;
  final int resolved7d;
  final int? avgFirstResponseMin;

  bool get isActive => status == 'active';

  String get statusLabel => switch (status) {
    'active' => 'Activo',
    'suspended' => 'Suspendido',
    _ => 'Sin acceso',
  };

  factory StaffMember.fromMap(Map<String, dynamic> m) => StaffMember(
    userId: m['user_id'] as String,
    fullName: m['full_name'] as String? ?? '',
    role: StaffRole.parse(m['role'] as String?) ?? StaffRole.employee,
    status: m['status'] as String? ?? 'active',
    statusReason: m['status_reason'] as String?,
    phoneMasked: m['phone_masked'] as String?,
    openCases: (m['open_cases'] as num?)?.toInt() ?? 0,
    resolved7d: (m['resolved_7d'] as num?)?.toInt() ?? 0,
    avgFirstResponseMin: (m['avg_first_response_min'] as num?)?.toInt(),
  );
}

/// Una cuenta encontrada al buscar a quién agregar al equipo. El servidor
/// (owner_staff_candidates) dice si puede recibir un rol y, si no, por qué.
class StaffCandidate {
  const StaffCandidate({
    required this.id,
    required this.fullName,
    this.phoneMasked,
    this.cityName,
    this.staffRole,
    this.staffStatus,
    required this.eligible,
    this.reason,
  });

  final String id;
  final String fullName;
  final String? phoneMasked;
  final String? cityName;

  /// Rol y estado en el equipo, si ya lo tuvo.
  final StaffRole? staffRole;
  final String? staffStatus;
  final bool eligible;

  /// self, owner, suspended, phone_unconfirmed o already_staff.
  final String? reason;

  String? get reasonLabel => switch (reason) {
    null => null,
    'self' => 'Es tu cuenta',
    'owner' => 'Es el Propietario',
    'suspended' => 'La cuenta está suspendida',
    'phone_unconfirmed' => 'No confirmó su celular',
    'already_staff' => 'Ya es ${staffRole?.label ?? 'del equipo'}',
    _ => 'No disponible',
  };

  /// Antes tuvo un rol (suspendido o sin acceso): dar el rol lo reactiva.
  bool get wasStaff => staffRole != null && staffStatus != 'active';

  factory StaffCandidate.fromMap(Map<String, dynamic> m) => StaffCandidate(
    id: m['id'] as String,
    fullName: m['full_name'] as String? ?? '',
    phoneMasked: m['phone_masked'] as String?,
    cityName: m['city_name'] as String?,
    staffRole: StaffRole.parse(m['staff_role'] as String?),
    staffStatus: m['staff_status'] as String?,
    eligible: m['eligible'] as bool? ?? false,
    reason: m['reason'] as String?,
  );
}

class StaffActivity {
  const StaffActivity({required this.action, this.targetTable, this.targetId, required this.createdAt});

  final String action;
  final String? targetTable;
  final String? targetId;
  final DateTime createdAt;

  String get label => switch (action) {
    'case.reply' => 'Respondió un mensaje de soporte',
    'case.note' => 'Escribió una nota interna',
    'case.escalate' => 'Escaló un caso',
    'case.assign' => 'Asignó un caso',
    'case.resolved' => 'Resolvió un caso',
    'case.in_progress' => 'Tomó un caso',
    'case.waiting' => 'Dejó un caso esperando respuesta',
    'case.open' => 'Reabrió un caso',
    'document.flag' => 'Marcó un documento',
    'document.accepted' => 'Aceptó un documento',
    'document.rejected' => 'Rechazó un documento',
    'application.approved' => 'Aprobó a un profesional',
    'application.rejected' => 'Rechazó una postulación',
    'account.suspend' => 'Suspendió una cuenta',
    'account.reactivate' => 'Reactivó una cuenta',
    _ => action,
  };

  factory StaffActivity.fromMap(Map<String, dynamic> m) => StaffActivity(
    action: m['action'] as String? ?? '',
    targetTable: m['target_table'] as String?,
    targetId: m['target_id'] as String?,
    createdAt: _date(m['created_at']) ?? DateTime.now(),
  );
}
