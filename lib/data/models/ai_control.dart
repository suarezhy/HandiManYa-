/// Centro de Control IA: agentes, avisos, decisiones y reporte diario.
library;

/// Categoría de un agente según lo que de verdad está construido. Ninguna
/// etiqueta dice "Activo": eso solo lo dice [AgentExecution.active], que sale
/// del historial de ejecuciones.
enum AgentStatus {
  rules('Reglas en funcionamiento', 'Funcionan con reglas sobre datos reales'),
  ai('IA en funcionamiento', 'Integraciones de IA en funcionamiento'),
  needsSetup('Espera configuración', 'Esperan configuración'),
  planned('Planificado, sin construir', 'Planificados o sin construir'),
  off('Apagado', 'Apagados');

  const AgentStatus(this.label, this.groupTitle);
  final String label;
  final String groupTitle;

  static AgentStatus parse(String s) => switch (s) {
    'rules' => rules,
    'ai' => ai,
    'needs_setup' => needsSetup,
    'off' => off,
    _ => planned,
  };
}

/// Lo que muestra el historial de ejecuciones (ai_agent_runs) de un agente.
enum AgentExecution {
  active('active', 'Activo'),
  stale('stale', 'Sin ejecución reciente'),
  failed('failed', 'Última ejecución falló'),
  never('never', 'Sin ejecuciones registradas'),
  event('event', 'Corre por evento'),
  needsSetup('needs_setup', 'No corre: falta configurar'),
  notBuilt('not_built', 'No corre: sin construir'),
  off('off', 'Apagado');

  const AgentExecution(this.key, this.label);
  final String key;
  final String label;

  static AgentExecution parse(String? s) => values.firstWhere((v) => v.key == s, orElse: () => notBuilt);
}

class AiAgent {
  const AiAgent({
    required this.key,
    required this.number,
    required this.name,
    required this.purpose,
    required this.phase,
    required this.status,
    this.needs,
    this.addedByClaude = false,
    this.schedule,
    this.maxGapMinutes,
    this.lastRunAt,
    this.lastRunStatus,
    this.lastOkRunAt,
    this.lastSummary,
    this.lastError,
    this.runsOk24h = 0,
    this.runsFailed24h = 0,
    this.openItems = 0,
    this.execution,
  });

  final String key;
  final int number;
  final String name;
  final String purpose;
  final String phase;
  final AgentStatus status;
  final String? needs;
  final bool addedByClaude;

  /// Cuándo corre (texto para el panel); null si no tiene horario.
  final String? schedule;

  /// Más de esto sin una ejecución correcta = "sin ejecución reciente".
  final int? maxGapMinutes;

  /// Última ejecución registrada (correcta o fallida) y su resultado.
  final DateTime? lastRunAt;
  final String? lastRunStatus;

  /// Última ejecución correcta, tomada solo del historial.
  final DateTime? lastOkRunAt;
  final String? lastSummary;

  /// Código del error (nunca el texto) si la última falló.
  final String? lastError;
  final int runsOk24h;
  final int runsFailed24h;
  final int openItems;
  final AgentExecution? execution;

  /// Si la base no lo mandó (datos viejos), se calcula igual que en la base.
  AgentExecution executionAt(DateTime now) {
    if (execution != null) return execution!;
    return switch (status) {
      AgentStatus.off => AgentExecution.off,
      AgentStatus.planned => AgentExecution.notBuilt,
      AgentStatus.needsSetup => AgentExecution.needsSetup,
      _ when lastRunStatus == 'failed' => AgentExecution.failed,
      _ when lastOkRunAt == null => maxGapMinutes == null ? AgentExecution.event : AgentExecution.never,
      _ when maxGapMinutes != null && now.difference(lastOkRunAt!).inMinutes > maxGapMinutes! => AgentExecution.stale,
      _ => AgentExecution.active,
    };
  }

  AiAgent copyWith({
    DateTime? lastRunAt,
    String? lastRunStatus,
    DateTime? lastOkRunAt,
    String? lastSummary,
    String? lastError,
    int? runsOk24h,
    int? runsFailed24h,
    int? openItems,
    AgentExecution? execution,
  }) => AiAgent(
    key: key,
    number: number,
    name: name,
    purpose: purpose,
    phase: phase,
    status: status,
    needs: needs,
    addedByClaude: addedByClaude,
    schedule: schedule,
    maxGapMinutes: maxGapMinutes,
    lastRunAt: lastRunAt ?? this.lastRunAt,
    lastRunStatus: lastRunStatus ?? this.lastRunStatus,
    lastOkRunAt: lastOkRunAt ?? this.lastOkRunAt,
    lastSummary: lastSummary ?? this.lastSummary,
    lastError: lastError ?? this.lastError,
    runsOk24h: runsOk24h ?? this.runsOk24h,
    runsFailed24h: runsFailed24h ?? this.runsFailed24h,
    openItems: openItems ?? this.openItems,
    execution: execution ?? this.execution,
  );

  /// Una ejecución nueva registrada (como una fila de ai_agent_runs).
  AiAgent withRun({required DateTime at, required String status, String? summary, String? error}) => copyWith(
    lastRunAt: at,
    lastRunStatus: status,
    lastOkRunAt: status == 'ok' ? at : null,
    lastSummary: summary,
    lastError: error,
    runsOk24h: runsOk24h + (status == 'ok' ? 1 : 0),
    runsFailed24h: runsFailed24h + (status == 'failed' ? 1 : 0),
  );

  static DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

  factory AiAgent.fromMap(Map<String, dynamic> m) => AiAgent(
    key: m['key'] as String,
    number: (m['number'] as num).toInt(),
    name: m['name'] as String,
    purpose: m['purpose'] as String,
    phase: m['phase'] as String,
    status: AgentStatus.parse(m['status'] as String),
    needs: m['needs'] as String?,
    addedByClaude: m['added_by_claude'] as bool? ?? false,
    schedule: m['schedule'] as String?,
    maxGapMinutes: (m['max_gap_minutes'] as num?)?.toInt(),
    lastRunAt: _date(m['last_run_at']),
    lastRunStatus: m['last_run_status'] as String?,
    lastOkRunAt: _date(m['last_ok_run_at']),
    lastSummary: m['last_summary'] as String?,
    lastError: m['last_error'] as String?,
    runsOk24h: (m['runs_ok_24h'] as num?)?.toInt() ?? 0,
    runsFailed24h: (m['runs_failed_24h'] as num?)?.toInt() ?? 0,
    openItems: (m['open_items'] as num?)?.toInt() ?? 0,
    execution: m['execution'] == null ? null : AgentExecution.parse(m['execution'] as String),
  );
}

/// Qué regla creó un aviso: el prefijo de su dedupe_key (ver
/// docs/ai-agents-audit.md). Si no se conoce, se muestra el prefijo tal cual.
String aiRuleLabel(String? rule) => switch (rule) {
  null || '' => 'Sin regla registrada',
  'wallet-mismatch' => 'Saldo distinto del libro mayor',
  'topup-late' => 'Recarga pendiente más de 24 horas',
  'topup-dup' => 'Mismo comprobante en varias recargas',
  'ya-unaccepted' => 'Pedido ¡Ya! sin aceptar más de 15 minutos',
  'application-late' => 'Postulación sin revisar más de 48 horas',
  'low-reviews' => 'Dos o más calificaciones de 1–2 estrellas en 30 días',
  'report-serious' => 'Reporte de acoso o fraude sin revisar',
  'many-reports' => 'Cuenta reportada por 3 o más personas en 30 días',
  'dispute-late' => 'Disputa abierta más de 48 horas',
  'ticket-late' => 'Ticket de soporte sin respuesta más de 24 horas',
  'deletion-late' => 'Eliminación de cuenta pendiente más de 7 días',
  'report-content' => 'Contenido inapropiado reportado',
  'agent-failed' => 'Un agente falló en 24 horas',
  'agent-stale' => 'Un agente dejó de ejecutarse',
  'ai-over-budget' => 'Gasto de IA por encima del presupuesto',
  'trip-stuck' => '"En camino" más de 3 horas sin llegada verificada',
  'arrival-admin' => 'Llegada verificada por el equipo, sin código',
  'late' => 'Tres o más atrasos de más de 15 minutos en 30 días',
  'no-ci' => 'Profesional aprobado sin carnet aceptado',
  'doc-expiry' => 'Documento vencido o por vencer',
  'pro-missing' => 'Postulación en borrador sin documentos',
  'cost' => 'Costos: plan gratis, tope o gasto frenado',
  'identity' => 'Resultado de la verificación de identidad',
  _ => 'Regla "$rule"',
};

/// Nombre del registro al que apunta un aviso.
String aiTargetLabel(String? table) => switch (table) {
  null => 'Sin registro',
  'wallets' => 'Billetera',
  'topup_requests' => 'Recarga',
  'bookings' => 'Pedido',
  'professional_profiles' => 'Profesional',
  'professional_documents' => 'Documento',
  'profiles' => 'Cuenta',
  'user_reports' => 'Reporte',
  'disputes' => 'Disputa',
  'support_tickets' => 'Ticket de soporte',
  'cost_vendors' => 'Proveedor',
  'ai_agents' => 'Agente',
  'app_settings' => 'Ajuste',
  _ => table,
};

enum AiItemStatus {
  open('Abierto'),
  pendingApproval('Espera tu aprobación'),
  moreInfo('Pediste más información'),
  approved('Aprobado'),
  rejected('Rechazado'),
  completed('Completado'),
  failed('Falló'),
  dismissed('Descartado');

  const AiItemStatus(this.label);
  final String label;

  String get key => switch (this) {
    pendingApproval => 'pending_approval',
    moreInfo => 'more_info',
    _ => name,
  };

  bool get isPending => this == open || this == pendingApproval || this == moreInfo;

  static AiItemStatus parse(String s) => values.firstWhere((v) => v.key == s, orElse: () => open);
}

enum AiSeverity {
  info('Info'),
  low('Baja'),
  medium('Media'),
  high('Alta'),
  critical('Crítica');

  const AiSeverity(this.label);
  final String label;

  static AiSeverity parse(String s) => values.firstWhere((v) => v.name == s, orElse: () => info);
}

/// Un aviso, recomendación o pedido de aprobación de un agente.
class AiItem {
  const AiItem({
    required this.id,
    required this.agentKey,
    required this.kind,
    required this.severity,
    required this.status,
    required this.fromAi,
    required this.title,
    this.body,
    this.evidence = const {},
    this.proposedAction,
    this.decisionNote,
    required this.createdAt,
    this.dedupeKey,
    this.targetTable,
    this.targetId,
    this.decidedAt,
    this.completedAt,
  });

  final int id;
  final String agentKey;

  /// alert, recommendation o approval_request.
  final String kind;
  final AiSeverity severity;
  final AiItemStatus status;

  /// true: lo propuso un modelo de IA (recomendación). false: regla sobre datos reales.
  final bool fromAi;
  final String title;
  final String? body;
  final Map<String, dynamic> evidence;
  final Map<String, dynamic>? proposedAction;
  final String? decisionNote;
  final DateTime createdAt;
  final String? dedupeKey;

  /// El registro que originó el aviso (tabla e identificador).
  final String? targetTable;
  final String? targetId;
  final DateTime? decidedAt;
  final DateTime? completedAt;

  /// Prefijo de dedupe_key: identifica la regla que creó el aviso.
  String? get rule => dedupeKey?.split(':').first;

  bool get needsApproval => kind == 'approval_request';

  String get kindLabel => switch (kind) {
    'approval_request' => 'Pide tu aprobación',
    'recommendation' => 'Recomendación',
    _ => 'Alerta',
  };

  factory AiItem.fromMap(Map<String, dynamic> m) => AiItem(
    id: (m['id'] as num).toInt(),
    agentKey: m['agent_key'] as String,
    kind: m['kind'] as String,
    severity: AiSeverity.parse(m['severity'] as String),
    status: AiItemStatus.parse(m['status'] as String),
    fromAi: m['source'] == 'ai',
    title: m['title'] as String,
    body: m['body'] as String?,
    evidence: Map<String, dynamic>.from((m['evidence'] as Map?) ?? const {}),
    proposedAction: m['proposed_action'] == null ? null : Map<String, dynamic>.from(m['proposed_action'] as Map),
    decisionNote: m['decision_note'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    dedupeKey: m['dedupe_key'] as String?,
    targetTable: m['target_table'] as String?,
    targetId: m['target_id'] as String?,
    decidedAt: m['decided_at'] == null ? null : DateTime.parse(m['decided_at'] as String),
    completedAt: m['completed_at'] == null ? null : DateTime.parse(m['completed_at'] as String),
  );

  AiItem copyWith({AiItemStatus? status, String? decisionNote, DateTime? decidedAt, DateTime? completedAt}) => AiItem(
    id: id,
    agentKey: agentKey,
    kind: kind,
    severity: severity,
    status: status ?? this.status,
    fromAi: fromAi,
    title: title,
    body: body,
    evidence: evidence,
    proposedAction: proposedAction,
    decisionNote: decisionNote ?? this.decisionNote,
    createdAt: createdAt,
    dedupeKey: dedupeKey,
    targetTable: targetTable,
    targetId: targetId,
    decidedAt: decidedAt ?? this.decidedAt,
    completedAt: completedAt ?? this.completedAt,
  );
}

/// Una entrada del historial de un aviso (de la auditoría).
class AiItemEvent {
  const AiItemEvent({required this.action, required this.actorName, this.note, required this.createdAt});

  final String action;
  final String actorName;
  final String? note;
  final DateTime createdAt;

  String get label => switch (action) {
    'ai_item.approve' => 'Aprobó',
    'ai_item.reject' => 'Rechazó',
    'ai_item.more_info' => 'Pidió más información',
    'ai_item.dismiss' => 'Descartó',
    'ai_item.completed' => 'Marcó como resuelto',
    'ai_item.failed' => 'Marcó como fallido',
    _ => action,
  };

  factory AiItemEvent.fromMap(Map<String, dynamic> m) => AiItemEvent(
    action: m['action'] as String,
    actorName: m['actor_name'] as String? ?? 'Sistema',
    note: m['note'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

/// Un aviso abierto con su origen: agente, regla, registro, hora e historial.
class AiItemDetail {
  const AiItemDetail({
    required this.item,
    required this.agentName,
    this.agentNumber,
    this.decidedByName,
    this.history = const [],
  });

  final AiItem item;
  final String agentName;
  final int? agentNumber;
  final String? decidedByName;
  final List<AiItemEvent> history;

  factory AiItemDetail.fromMap(Map<String, dynamic> m) => AiItemDetail(
    item: AiItem.fromMap(m),
    agentName: m['agent_name'] as String? ?? m['agent_key'] as String,
    agentNumber: (m['agent_number'] as num?)?.toInt(),
    decidedByName: m['decided_by_name'] as String?,
    history: [
      for (final e in (m['history'] as List?) ?? const []) AiItemEvent.fromMap(Map<String, dynamic>.from(e as Map)),
    ],
  );
}

/// Resultado de "Revisar ahora": avisos nuevos de cada revisión y fallas.
class AiCheckResult {
  const AiCheckResult({this.rules = 0, this.costs = 0, this.monitors = 0, this.failed = 0});

  final int rules;
  final int costs;
  final int monitors;
  final int failed;

  int get total => rules + costs + monitors;

  factory AiCheckResult.fromMap(Map<String, dynamic> m) {
    int i(String k) => (m[k] as num?)?.toInt() ?? 0;
    return AiCheckResult(rules: i('rules'), costs: i('costs'), monitors: i('monitors'), failed: i('failed'));
  }
}

enum AiDecision { approve, reject, moreInfo, dismiss, completed, failed }

extension AiDecisionKey on AiDecision {
  String get key => this == AiDecision.moreInfo ? 'more_info' : name;

  /// Rechazar, descartar y marcar el resultado exigen una nota (la base también).
  bool get needsNote => this != AiDecision.approve && this != AiDecision.moreInfo;
}

class AiOverview {
  const AiOverview({
    required this.pendingApproval,
    required this.open,
    required this.critical,
    required this.high,
    required this.completed7d,
    required this.failed7d,
    required this.aiRecommendationsOpen,
    required this.aiCostMonthUsd,
    required this.aiBudgetMonthUsd,
    this.lastReportDate,
    this.lastMonitorRun,
    this.runsOk24h = 0,
    this.runsFailed24h = 0,
  });

  final int pendingApproval;
  final int open;
  final int critical;
  final int high;
  final int completed7d;
  final int failed7d;
  final int aiRecommendationsOpen;
  final double aiCostMonthUsd;
  final double aiBudgetMonthUsd;
  final DateTime? lastReportDate;

  /// Última revisión completa registrada por el AI Boss (historial).
  final DateTime? lastMonitorRun;
  final int runsOk24h;
  final int runsFailed24h;

  factory AiOverview.fromMap(Map<String, dynamic> m) {
    int i(String k) => (m[k] as num?)?.toInt() ?? 0;
    double d(String k) => (m[k] as num?)?.toDouble() ?? 0;
    return AiOverview(
      pendingApproval: i('pending_approval'),
      open: i('open'),
      critical: i('critical'),
      high: i('high'),
      completed7d: i('completed_7d'),
      failed7d: i('failed_7d'),
      aiRecommendationsOpen: i('ai_recommendations_open'),
      aiCostMonthUsd: d('ai_cost_month_usd'),
      aiBudgetMonthUsd: d('ai_budget_month_usd'),
      lastReportDate: m['last_report_date'] == null ? null : DateTime.parse(m['last_report_date'] as String),
      lastMonitorRun: m['last_monitor_run'] == null ? null : DateTime.parse(m['last_monitor_run'] as String),
      runsOk24h: i('runs_ok_24h'),
      runsFailed24h: i('runs_failed_24h'),
    );
  }
}

/// Reporte diario (para el dueño, en inglés). Guarda el JSON tal como lo arma
/// la base: solo datos reales y una lista de lo que todavía no se mide.
class DailyReport {
  const DailyReport({required this.date, required this.timezone, required this.generatedAt, required this.data});

  final DateTime date;
  final String timezone;
  final DateTime generatedAt;
  final Map<String, dynamic> data;

  Map<String, dynamic> get today => Map<String, dynamic>.from((data['today'] as Map?) ?? const {});
  Map<String, dynamic> get previousDay => Map<String, dynamic>.from((data['previous_day'] as Map?) ?? const {});
  Map<String, dynamic> get current => Map<String, dynamic>.from((data['current'] as Map?) ?? const {});
  List<String> get priorities => [for (final p in (data['priorities'] as List?) ?? const []) '$p'];
  List<String> get unavailable => [for (final p in (data['unavailable'] as List?) ?? const []) '$p'];

  factory DailyReport.fromMap(Map<String, dynamic> m) => DailyReport(
    date: DateTime.parse(m['report_date'] as String),
    timezone: m['timezone'] as String,
    generatedAt: DateTime.parse(m['generated_at'] as String),
    data: Map<String, dynamic>.from(m['data'] as Map),
  );
}
