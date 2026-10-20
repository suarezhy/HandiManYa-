/// Centro de Control IA: agentes, avisos, decisiones y reporte diario.
library;

enum AgentStatus {
  rules('Activo (reglas)'),
  ai('Activo con IA'),
  needsSetup('Falta configurar'),
  planned('Planificado'),
  off('Apagado');

  const AgentStatus(this.label);
  final String label;

  static AgentStatus parse(String s) => switch (s) {
    'rules' => rules,
    'ai' => ai,
    'needs_setup' => needsSetup,
    'off' => off,
    _ => planned,
  };
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
    this.lastRunAt,
    this.lastRunStatus,
  });

  final String key;
  final int number;
  final String name;
  final String purpose;
  final String phase;
  final AgentStatus status;
  final String? needs;
  final bool addedByClaude;
  final DateTime? lastRunAt;
  final String? lastRunStatus;

  factory AiAgent.fromMap(Map<String, dynamic> m) => AiAgent(
    key: m['key'] as String,
    number: (m['number'] as num).toInt(),
    name: m['name'] as String,
    purpose: m['purpose'] as String,
    phase: m['phase'] as String,
    status: AgentStatus.parse(m['status'] as String),
    needs: m['needs'] as String?,
    addedByClaude: m['added_by_claude'] as bool? ?? false,
    lastRunAt: m['last_run_at'] == null ? null : DateTime.parse(m['last_run_at'] as String),
    lastRunStatus: m['last_run_status'] as String?,
  );
}

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
  );
}

enum AiDecision { approve, reject, moreInfo, dismiss, completed, failed }

extension AiDecisionKey on AiDecision {
  String get key => this == AiDecision.moreInfo ? 'more_info' : name;
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
  final DateTime? lastMonitorRun;

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
