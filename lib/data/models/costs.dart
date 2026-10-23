/// Costos operativos (planes gratis, cargos y alertas) y verificación de identidad.
library;

double _d(Object? v) => v == null ? 0 : (v as num).toDouble();

/// Estado de un proveedor. Solo `paid` puede cobrar, y solo hasta su tope.
enum VendorStatus {
  off('Apagado'),
  sandbox('Solo pruebas'),
  free('Plan gratis'),
  paid('Pagado (autorizado)');

  const VendorStatus(this.label);
  final String label;

  String get key => name;

  static VendorStatus parse(String? s) => switch (s) {
    'sandbox' => sandbox,
    'free' => free,
    'paid' => paid,
    _ => off,
  };
}

/// Nivel de alerta de un proveedor este mes.
enum CostLevel {
  ok,
  willRunOut,
  nearFreeLimit,
  nearCap,
  blocked;

  static CostLevel parse(String? s) => switch (s) {
    'will_run_out' => willRunOut,
    'near_free_limit' => nearFreeLimit,
    'near_cap' => nearCap,
    'blocked' => blocked,
    _ => ok,
  };
}

class CostVendor {
  const CostVendor({
    required this.key,
    required this.name,
    required this.category,
    required this.unit,
    required this.billing,
    required this.status,
    this.freeUnits = 0,
    this.usedUnits = 0,
    this.sandboxUnits = 0,
    this.freeUsedPercent,
    this.unitPriceUsd = 0,
    this.fixedUsd = 0,
    this.costSoFarUsd = 0,
    this.projectedUnits = 0,
    this.projectedUsd = 0,
    this.monthlyCapUsd = 0,
    this.blocked = 0,
    this.level = CostLevel.ok,
    this.runsOutOn,
    this.priceSource,
    this.priceCheckedOn,
    this.notes,
  });

  final String key;
  final String name;
  final String category;
  final String unit;

  /// uso, mensual, anual o unico.
  final String billing;
  final VendorStatus status;
  final int freeUnits;
  final double usedUnits;
  final double sandboxUnits;
  final int? freeUsedPercent;
  final double unitPriceUsd;
  final double fixedUsd;
  final double costSoFarUsd;
  final double projectedUnits;
  final double projectedUsd;
  final double monthlyCapUsd;
  final int blocked;
  final CostLevel level;
  final DateTime? runsOutOn;
  final String? priceSource;
  final DateTime? priceCheckedOn;
  final String? notes;

  bool get metered => billing == 'uso';
  bool get hasSandbox => key == 'didit_kyc';

  factory CostVendor.fromMap(Map<String, dynamic> m) => CostVendor(
    key: m['key'] as String,
    name: m['name'] as String,
    category: m['category'] as String? ?? '',
    unit: m['unit'] as String? ?? '',
    billing: m['billing'] as String? ?? 'uso',
    status: VendorStatus.parse(m['status'] as String?),
    freeUnits: (m['free_units'] as num?)?.toInt() ?? 0,
    usedUnits: _d(m['used_units']),
    sandboxUnits: _d(m['sandbox_units']),
    freeUsedPercent: (m['free_used_percent'] as num?)?.toInt(),
    unitPriceUsd: _d(m['unit_price_usd']),
    fixedUsd: _d(m['fixed_usd']),
    costSoFarUsd: _d(m['cost_so_far_usd']),
    projectedUnits: _d(m['projected_units']),
    projectedUsd: _d(m['projected_usd']),
    monthlyCapUsd: _d(m['monthly_cap_usd']),
    blocked: (m['blocked'] as num?)?.toInt() ?? 0,
    level: CostLevel.parse(m['level'] as String?),
    runsOutOn: m['runs_out_on'] == null ? null : DateTime.parse(m['runs_out_on'] as String),
    priceSource: m['price_source'] as String?,
    priceCheckedOn: m['price_checked_on'] == null ? null : DateTime.parse(m['price_checked_on'] as String),
    notes: m['notes'] as String?,
  );
}

class CostDashboard {
  const CostDashboard({
    required this.month,
    required this.daysElapsed,
    required this.daysInMonth,
    required this.costSoFarUsd,
    required this.projectedUsd,
    this.oneTimeUsd = 0,
    this.vendors = const [],
    this.alerts = const [],
    this.history = const [],
  });

  /// AAAA-MM (mes calendario en UTC, como facturan los proveedores).
  final String month;
  final double daysElapsed;
  final double daysInMonth;
  final double costSoFarUsd;
  final double projectedUsd;
  final double oneTimeUsd;
  final List<CostVendor> vendors;
  final List<({String vendor, CostLevel level, String message})> alerts;
  final List<({String month, double costUsd})> history;

  factory CostDashboard.fromMap(Map<String, dynamic> m) => CostDashboard(
    month: m['month'] as String,
    daysElapsed: _d(m['days_elapsed']),
    daysInMonth: _d(m['days_in_month']),
    costSoFarUsd: _d(m['cost_so_far_usd']),
    projectedUsd: _d(m['projected_usd']),
    oneTimeUsd: _d(m['one_time_usd']),
    vendors: [
      for (final v in (m['vendors'] as List? ?? const [])) CostVendor.fromMap(Map<String, dynamic>.from(v as Map)),
    ],
    alerts: [
      for (final a in (m['alerts'] as List? ?? const []))
        (
          vendor: (a as Map)['vendor'] as String,
          level: CostLevel.parse(a['level'] as String?),
          message: a['message'] as String,
        ),
    ],
    history: [
      for (final h in (m['history'] as List? ?? const []))
        (month: (h as Map)['month'] as String, costUsd: _d(h['cost_usd'])),
    ],
  );
}

/// Estado de una verificación de identidad (Didit).
enum IdentityStatus {
  none('Sin verificar'),
  created('Sin empezar'),
  inProgress('En curso'),
  approved('Aprobada'),
  declined('Rechazada'),
  inReview('Para revisar'),
  resubmitted('Reenviada'),
  expired('Vencida'),
  abandoned('Abandonada'),
  failed('No se pudo iniciar');

  const IdentityStatus(this.label);
  final String label;

  static IdentityStatus parse(String? s) => switch (s) {
    'created' => created,
    'in_progress' => inProgress,
    'approved' => approved,
    'declined' => declined,
    'in_review' => inReview,
    'resubmitted' => resubmitted,
    'expired' => expired,
    'abandoned' => abandoned,
    'failed' => failed,
    _ => none,
  };
}

class IdentityCheck {
  const IdentityCheck({
    required this.status,
    this.id,
    this.sandbox = true,
    this.documentType,
    this.idDocumentStatus,
    this.livenessScore,
    this.faceMatchScore,
    this.warnings = const [],
    this.createdAt,
    this.decidedAt,
    this.vendorDeleted = false,
  });

  final int? id;
  final IdentityStatus status;

  /// Del sandbox de Didit: resultado simulado, nunca cuenta como verificación real.
  final bool sandbox;
  final String? documentType;
  final String? idDocumentStatus;
  final double? livenessScore;
  final double? faceMatchScore;
  final List<String> warnings;
  final DateTime? createdAt;
  final DateTime? decidedAt;

  /// Didit ya borró la sesión (y la plantilla facial).
  final bool vendorDeleted;

  static const none = IdentityCheck(status: IdentityStatus.none);

  factory IdentityCheck.fromMap(Map<String, dynamic> m) => IdentityCheck(
    id: (m['id'] as num?)?.toInt(),
    status: IdentityStatus.parse(m['status'] as String?),
    sandbox: m['sandbox'] as bool? ?? true,
    documentType: m['document_type'] as String?,
    idDocumentStatus: m['id_document_status'] as String?,
    livenessScore: (m['liveness_score'] as num?)?.toDouble(),
    faceMatchScore: (m['face_match_score'] as num?)?.toDouble(),
    warnings: [for (final w in (m['warnings'] as List? ?? const [])) w as String],
    createdAt: m['created_at'] == null ? null : DateTime.parse(m['created_at'] as String),
    decidedAt: m['decided_at'] == null ? null : DateTime.parse(m['decided_at'] as String),
    vendorDeleted: m['vendor_deleted'] as bool? ?? false,
  );
}
