import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/ai_control.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import '../security/confirm_identity.dart';

final aiOverviewProvider = FutureProvider<AiOverview>((ref) => ref.watch(backendProvider).aiOverview());
final aiAgentsProvider = FutureProvider<List<AiAgent>>((ref) => ref.watch(backendProvider).aiAgents());
final aiItemsProvider = FutureProvider.family<List<AiItem>, String>(
  (ref, filter) => ref.watch(backendProvider).aiItems(statuses: _filters[filter] ?? const []),
);
final dailyReportsProvider = FutureProvider<List<DailyReport>>((ref) => ref.watch(backendProvider).dailyReports());
final aiItemDetailProvider = FutureProvider.family<AiItemDetail, int>(
  (ref, id) => ref.watch(backendProvider).aiItemDetail(id),
);

const _filters = {
  'pendientes': ['pending_approval', 'open', 'more_info'],
  'completadas': ['completed', 'approved'],
  'fallidas': ['failed'],
  'cerradas': ['rejected', 'dismissed'],
};

/// Centro de Control IA: lo que vigilan los agentes y lo que espera la
/// decisión del dueño. Pensado para usarse desde el iPhone o el iPad.
class AiControlCenterPage extends ConsumerWidget {
  const AiControlCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 4,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Centro de Control IA'),
        // Con 320 px no caben las cuatro: se desplazan desde el borde
        // izquierdo y la pestaña elegida se trae a la vista.
        bottom: const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'Estado general'),
            Tab(text: 'Decisiones'),
            Tab(text: 'Agentes IA'),
            Tab(text: 'Reporte diario'),
          ],
        ),
      ),
      body: const TabBarView(children: [_OverviewTab(), _DecisionsTab(), _AgentsTab(), _ReportTab()]),
    ),
  );
}

void _refreshAll(WidgetRef ref) => ref
  ..invalidate(aiOverviewProvider)
  ..invalidate(aiItemsProvider)
  ..invalidate(aiAgentsProvider)
  ..invalidate(aiItemDetailProvider)
  ..invalidate(dailyReportsProvider);

/// Nombre del agente para mostrar el origen de un aviso.
String _agentLabel(WidgetRef ref, String key) {
  final agents = ref.watch(aiAgentsProvider).value ?? const <AiAgent>[];
  final a = agents.where((a) => a.key == key).firstOrNull;
  return a == null ? key : '${a.number}. ${a.name}';
}

/// Columnas de una grilla compacta: 1 en un teléfono, 2 en uno grande o
/// tableta vertical, 3 en tableta horizontal.
int _columns(double width, {double min = 300}) => (width / min).floor().clamp(1, 3);

class _Grid extends StatelessWidget {
  const _Grid({required this.children, this.minItemWidth = 300});

  final List<Widget> children;
  final double minItemWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final cols = _columns(c.maxWidth, min: minItemWidth);
      const gap = HySpacing.xs;
      final w = ((c.maxWidth - gap * (cols - 1)) / cols).floorToDouble();
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final child in children) SizedBox(width: w, child: child)],
      );
    },
  );
}

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab();

  Future<void> _runChecks(BuildContext context, WidgetRef ref) async {
    final ok = await runGuarded(context, () async {
      final r = await ref.read(backendProvider).runAllChecks();
      if (!context.mounted) return;
      final news = r.total == 0 ? 'sin avisos nuevos' : '${r.total} aviso(s) nuevo(s)';
      showMessage(
        context,
        r.failed == 0
            ? 'Revisión completa: $news.'
            : 'Revisión hecha con fallas: $news; ${r.failed} revisión(es) fallaron. Mira "Agentes IA".',
      );
    });
    if (ok) _refreshAll(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = ref.watch(aiOverviewProvider);
    final urgent = ref.watch(aiItemsProvider('pendientes'));
    return RefreshIndicator(
      onRefresh: () async => _refreshAll(ref),
      child: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: switch (o) {
              AsyncData(:final value) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: HySpacing.md),
                  _Grid(
                    minItemWidth: 140,
                    children: [
                      _Stat('Esperan tu aprobación', value.pendingApproval, HyColors.primary),
                      _Stat('Abiertos (alertas y recomendaciones)', value.open, HyColors.navy),
                      _Stat('Críticas', value.critical, HyColors.danger),
                      _Stat('Altas', value.high, HyColors.warning),
                      _Stat('Recomendaciones de IA', value.aiRecommendationsOpen, HyColors.info),
                      _Stat('Completadas (7 días)', value.completed7d, HyColors.green),
                      _Stat('Fallidas (7 días)', value.failed7d, HyColors.danger),
                      _Stat('Ejecuciones correctas (24 h)', value.runsOk24h, HyColors.green),
                      _Stat('Ejecuciones fallidas (24 h)', value.runsFailed24h, HyColors.danger),
                    ],
                  ),
                  const SizedBox(height: HySpacing.xs),
                  const Text(
                    'Críticas y Altas cuentan alertas abiertas y pedidos que esperan tu aprobación. '
                    'Toca una alerta para ver qué agente y qué regla la crearon.',
                    style: TextStyle(color: HyColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: HySpacing.md),
                  InfoBanner(
                    icon: Icons.savings_outlined,
                    text: value.aiBudgetMonthUsd <= 0
                        ? 'Presupuesto de IA: sin aprobar. Ningún agente usa un modelo de IA pagado; los que funcionan lo hacen con reglas sobre datos reales.'
                        : 'Gasto de IA este mes: US\$ ${value.aiCostMonthUsd.toStringAsFixed(2)} de US\$ ${value.aiBudgetMonthUsd.toStringAsFixed(2)}.',
                  ),
                  const SizedBox(height: HySpacing.sm),
                  Text(
                    value.lastMonitorRun == null
                        ? 'Todavía no hay revisiones registradas en el historial.'
                        : 'Última revisión completa registrada: ${Fmt.dateTime(value.lastMonitorRun!.toLocal())}',
                    style: const TextStyle(color: HyColors.textSecondary),
                  ),
                  const SizedBox(height: HySpacing.md),
                  SecondaryButton(
                    label: 'Revisar ahora',
                    icon: Icons.manage_search,
                    onPressed: () => _runChecks(context, ref),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Corre en el servidor los monitores, los agentes con reglas y el monitor de costos. No aprueba, '
                      'no suspende, no cambia saldos ni gasta dinero.',
                      style: TextStyle(color: HyColors.textMuted, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: HySpacing.lg),
                  Text('Alertas críticas y altas', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: HySpacing.xs),
                  ...switch (urgent) {
                    AsyncData(:final value) => () {
                      final list = [
                        for (final i in value)
                          if (i.severity == AiSeverity.critical || i.severity == AiSeverity.high) i,
                      ];
                      return list.isEmpty
                          ? [
                              const InfoBanner(
                                icon: Icons.check_circle_outline,
                                text: 'No hay alertas críticas ni altas abiertas.',
                              ),
                            ]
                          : [for (final i in list) _ItemTile(item: i)];
                    }(),
                    AsyncError(:final error) => [
                      ErrorView(error: error, onRetry: () => ref.invalidate(aiItemsProvider('pendientes'))),
                    ],
                    _ => [const LoadingView()],
                  },
                ],
              ),
              AsyncError(:final error) => ErrorView(error: error, onRetry: () => ref.invalidate(aiOverviewProvider)),
              _ => const LoadingView(),
            },
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: HySpacing.xs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: color),
        ),
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
        ),
      ],
    ),
  );
}

void _openItem(BuildContext context, int id) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AiItemDetailPage(itemId: id)));

/// Una alerta en una línea: qué es, quién la creó y cuándo.
class _ItemTile extends ConsumerWidget {
  const _ItemTile({required this.item});

  final AiItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.xs),
    child: AppCard(
      key: Key('ai-item-${item.id}'),
      padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: HySpacing.xs),
      onTap: () => _openItem(context, item.id),
      child: Row(
        children: [
          _Chip(item.severity.label, _tone(item.severity)),
          const SizedBox(width: HySpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                  '${_agentLabel(ref, item.agentKey)} · ${aiRuleLabel(item.rule)} · '
                  '${Fmt.dateTime(item.createdAt.toLocal())}',
                  style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: HyColors.textMuted),
        ],
      ),
    ),
  );
}

StatusTone _tone(AiSeverity s) => switch (s) {
  AiSeverity.critical || AiSeverity.high => StatusTone.danger,
  AiSeverity.medium => StatusTone.warning,
  _ => StatusTone.info,
};

class _DecisionsTab extends ConsumerStatefulWidget {
  const _DecisionsTab();

  @override
  ConsumerState<_DecisionsTab> createState() => _DecisionsTabState();
}

class _DecisionsTabState extends ConsumerState<_DecisionsTab> {
  String _filter = 'pendientes';

  static const _empty = {
    'pendientes': 'No hay alertas ni pedidos pendientes.',
    'completadas': 'Todavía no marcaste nada como completado.',
    'fallidas': 'Nada marcado como fallido.',
    'cerradas': 'Nada rechazado ni descartado.',
  };

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(aiItemsProvider(_filter));
    return RefreshIndicator(
      onRefresh: () async => _refreshAll(ref),
      child: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.sm),
                Wrap(
                  spacing: HySpacing.xs,
                  children: [
                    for (final (k, label) in const [
                      ('pendientes', 'Pendientes'),
                      ('completadas', 'Completadas'),
                      ('fallidas', 'Fallidas'),
                      ('cerradas', 'Rechazadas o descartadas'),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: _filter == k,
                        onSelected: (_) => setState(() => _filter = k),
                      ),
                  ],
                ),
                const SizedBox(height: HySpacing.sm),
                ...switch (items) {
                  AsyncData(:final value) when value.isEmpty => [
                    EmptyState(icon: Icons.check_circle_outline, title: _empty[_filter] ?? 'Nada por aquí'),
                  ],
                  AsyncData(:final value) => [for (final i in value) _ItemCard(item: i)],
                  AsyncError(:final error) => [
                    ErrorView(error: error, onRetry: () => ref.invalidate(aiItemsProvider(_filter))),
                  ],
                  _ => [const LoadingView()],
                },
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Decide sobre un aviso. Aprobar pide confirmar identidad; rechazar,
/// descartar o marcar el resultado pide una nota. Todo queda auditado.
Future<bool> _decide(BuildContext context, WidgetRef ref, AiItem item, AiDecision d) async {
  String? method;
  String? note;
  if (d == AiDecision.approve) {
    final c = await confirmIdentity(context, operation: 'Aprobar: ${item.title}', submitLabel: 'Confirmar y aprobar');
    if (c == null) return false;
    method = c.serverMethod;
  } else if (d.needsNote) {
    note = await promptText(
      context,
      title: switch (d) {
        AiDecision.completed => 'Marcar como resuelto',
        AiDecision.failed => 'Marcar como fallido',
        AiDecision.reject => 'Rechazar',
        _ => 'Descartar',
      },
      label: 'Nota (queda en la auditoría)',
      hint: d == AiDecision.dismiss ? 'Por qué no hace falta hacer nada' : 'Qué hiciste',
      confirm: d == AiDecision.dismiss ? 'Descartar' : 'Guardar',
    );
    if (note == null) return false;
  }
  if (!context.mounted) return false;
  final ok = await runGuarded(
    context,
    () => ref.read(backendProvider).decideAiItem(item.id, d, note: note, authMethod: method),
    success: switch (d) {
      AiDecision.approve => 'Aprobado. Queda registrado en la auditoría. Aprobar no ejecuta nada por sí solo.',
      AiDecision.reject => 'Rechazado. Queda en la auditoría.',
      AiDecision.moreInfo => 'Marcado: pediste más información.',
      AiDecision.completed => 'Marcado como resuelto. Queda en la auditoría.',
      AiDecision.failed => 'Marcado como fallido. Queda en la auditoría.',
      AiDecision.dismiss => 'Descartado. Queda en la auditoría.',
    },
  );
  if (ok) _refreshAll(ref);
  return ok;
}

class _DecisionButtons extends ConsumerWidget {
  const _DecisionButtons({required this.item});

  final AiItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = item.status.isPending;
    if (!pending && item.status != AiItemStatus.approved) return const SizedBox.shrink();
    return Wrap(
      spacing: HySpacing.xs,
      children: [
        if (item.status == AiItemStatus.pendingApproval)
          FilledButton(onPressed: () => _decide(context, ref, item, AiDecision.approve), child: const Text('Aprobar')),
        if (pending && item.needsApproval)
          OutlinedButton(
            onPressed: () => _decide(context, ref, item, AiDecision.reject),
            child: const Text('Rechazar'),
          ),
        if (pending && item.status != AiItemStatus.moreInfo)
          TextButton(
            onPressed: () => _decide(context, ref, item, AiDecision.moreInfo),
            child: const Text('Pedir más información'),
          ),
        if (!item.needsApproval && pending)
          TextButton(
            onPressed: () => _decide(context, ref, item, AiDecision.completed),
            child: const Text('Ya lo resolví'),
          ),
        if (!item.needsApproval && pending)
          TextButton(onPressed: () => _decide(context, ref, item, AiDecision.dismiss), child: const Text('Descartar')),
        if (item.status == AiItemStatus.approved)
          TextButton(
            onPressed: () => _decide(context, ref, item, AiDecision.completed),
            child: const Text('Marcar como hecho'),
          ),
      ],
    );
  }
}

class _ItemCard extends ConsumerWidget {
  const _ItemCard({required this.item});

  final AiItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = item.status.isPending;
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.sm),
      child: AppCard(
        key: Key('ai-item-${item.id}'),
        onTap: () => _openItem(context, item.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: HySpacing.xs,
              runSpacing: 4,
              children: [
                _Chip(item.severity.label, _tone(item.severity)),
                _Chip(item.kindLabel, StatusTone.neutral),
                _Chip(
                  item.fromAi ? 'Recomendación de IA' : 'Dato verificado',
                  item.fromAi ? StatusTone.info : StatusTone.success,
                ),
                _Chip(item.status.label, pending ? StatusTone.warning : StatusTone.neutral),
              ],
            ),
            const SizedBox(height: HySpacing.xs),
            Text(item.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            if ((item.body ?? '').isNotEmpty) Text(item.body!, style: const TextStyle(fontSize: 15)),
            Text(
              '${_agentLabel(ref, item.agentKey)} · ${aiRuleLabel(item.rule)} · '
              '${Fmt.dateTime(item.createdAt.toLocal())}',
              style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
            ),
            if ((item.decisionNote ?? '').isNotEmpty)
              Text('Nota: ${item.decisionNote}', style: const TextStyle(color: HyColors.textSecondary, fontSize: 13)),
            const Text(
              'Toca para ver el origen y el historial.',
              style: TextStyle(color: HyColors.textMuted, fontSize: 12),
            ),
            if (pending || item.status == AiItemStatus.approved) ...[
              const SizedBox(height: HySpacing.xs),
              _DecisionButtons(item: item),
            ],
          ],
        ),
      ),
    );
  }
}

/// Un aviso abierto: de dónde salió (agente, regla, registro, hora), la
/// evidencia, qué se decidió y el historial de la auditoría.
class AiItemDetailPage extends ConsumerWidget {
  const AiItemDetailPage({super.key, required this.itemId});

  final int itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(aiItemDetailProvider(itemId));
    return Scaffold(
      appBar: AppBar(title: const Text('Origen del aviso')),
      body: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: switch (d) {
              AsyncData(:final value) => _ItemDetailView(detail: value),
              AsyncError(:final error) => ErrorView(
                error: error,
                onRetry: () => ref.invalidate(aiItemDetailProvider(itemId)),
              ),
              _ => const LoadingView(),
            },
          ),
        ],
      ),
    );
  }
}

class _ItemDetailView extends StatelessWidget {
  const _ItemDetailView({required this.detail});

  final AiItemDetail detail;

  @override
  Widget build(BuildContext context) {
    final i = detail.item;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: HySpacing.md),
        Wrap(
          spacing: HySpacing.xs,
          runSpacing: 4,
          children: [
            _Chip(i.severity.label, _tone(i.severity)),
            _Chip(i.kindLabel, StatusTone.neutral),
            _Chip(i.status.label, i.status.isPending ? StatusTone.warning : StatusTone.neutral),
          ],
        ),
        const SizedBox(height: HySpacing.xs),
        Text(i.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        if ((i.body ?? '').isNotEmpty) Text(i.body!),
        const SizedBox(height: HySpacing.sm),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Origen', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              row(
                'Agente',
                detail.agentNumber == null ? detail.agentName : '${detail.agentNumber}. ${detail.agentName}',
              ),
              row('Regla', aiRuleLabel(i.rule)),
              row(
                'Fuente',
                i.fromAi ? 'Recomendación de un modelo de IA (no es un hecho)' : 'Regla sobre datos reales (sin IA)',
              ),
              row(
                'Registro',
                i.targetTable == null ? 'Sin registro' : '${aiTargetLabel(i.targetTable)} ${i.targetId ?? ''}'.trim(),
              ),
              row('Creado', Fmt.dateTime(i.createdAt.toLocal())),
              if (i.evidence.isNotEmpty)
                row('Evidencia', i.evidence.entries.map((e) => '${e.key}: ${e.value}').join(' · ')),
            ],
          ),
        ),
        if (i.decidedAt != null || (i.decisionNote ?? '').isNotEmpty) ...[
          const SizedBox(height: HySpacing.sm),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Decisión', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                row('Estado', i.status.label),
                if (detail.decidedByName != null) row('Por', detail.decidedByName!),
                if (i.decidedAt != null) row('Cuándo', Fmt.dateTime(i.decidedAt!.toLocal())),
                if ((i.decisionNote ?? '').isNotEmpty) row('Nota', i.decisionNote!),
              ],
            ),
          ),
        ],
        const SizedBox(height: HySpacing.sm),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Historial (auditoría)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (detail.history.isEmpty) const Text('Sin decisiones todavía.'),
              for (final e in detail.history)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${Fmt.dateTime(e.createdAt.toLocal())} · ${e.actorName}: ${e.label}'
                    '${(e.note ?? '').isEmpty ? '' : ' — ${e.note}'}',
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: HySpacing.sm),
        _DecisionButtons(item: i),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.tone);

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: tone.background, borderRadius: BorderRadius.circular(HyRadii.pill)),
    child: Text(
      label,
      style: TextStyle(color: tone.foreground, fontWeight: FontWeight.w700, fontSize: 13),
    ),
  );
}

class _AgentsTab extends ConsumerWidget {
  const _AgentsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(aiAgentsProvider);
    final now = DateTime.now();
    return RefreshIndicator(
      onRefresh: () async => _refreshAll(ref),
      child: ListView(
        padding: bottomSafePadding(context),
        children: [
          // Más ancho que PageBody para que la tableta muestre 2 o 3 columnas.
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: HySpacing.md),
                child: switch (agents) {
                  AsyncData(:final value) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: HySpacing.sm),
                      const InfoBanner(
                        text:
                            'Los agentes vigilan y avisan. No aprueban profesionales, no suspenden cuentas, no cambian '
                            'saldos ni gastan dinero: eso lo decides tú. "Activo" solo aparece si hay una ejecución '
                            'correcta registrada dentro de su horario.',
                      ),
                      Text(
                        '${value.where((a) => a.executionAt(now) == AgentExecution.active).length} activos ahora · '
                        '${value.where((a) => a.status == AgentStatus.rules).length} con reglas · '
                        '${value.where((a) => a.status == AgentStatus.ai).length} con IA · '
                        '${value.where((a) => a.status == AgentStatus.needsSetup).length} esperan configuración · '
                        '${value.where((a) => a.status == AgentStatus.planned).length} planificados',
                        style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
                      ),
                      for (final s in AgentStatus.values)
                        if (s != AgentStatus.off || value.any((a) => a.status == s)) ...[
                          const SizedBox(height: HySpacing.md),
                          Text(
                            '${s.groupTitle} (${value.where((a) => a.status == s).length})',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: HySpacing.xs),
                          if (!value.any((a) => a.status == s))
                            Text(
                              s == AgentStatus.ai
                                  ? 'Ninguna: no hay presupuesto de IA aprobado y ningún agente llama a un modelo de IA.'
                                  : 'Ninguno.',
                              style: const TextStyle(color: HyColors.textSecondary),
                            )
                          else
                            _Grid(
                              children: [
                                for (final a in value)
                                  if (a.status == s) _AgentCard(agent: a, execution: a.executionAt(now)),
                              ],
                            ),
                        ],
                    ],
                  ),
                  AsyncError(:final error) => ErrorView(error: error, onRetry: () => ref.invalidate(aiAgentsProvider)),
                  _ => const LoadingView(),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({required this.agent, required this.execution});

  final AiAgent agent;
  final AgentExecution execution;

  @override
  Widget build(BuildContext context) {
    final a = agent;
    const small = TextStyle(color: HyColors.textMuted, fontSize: 12.5);
    return AppCard(
      key: Key('agent-card-${a.key}'),
      padding: const EdgeInsets.all(HySpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: HySpacing.xs,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${a.number}. ${a.name}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              _Chip(execution.label, switch (execution) {
                AgentExecution.active => StatusTone.success,
                AgentExecution.failed => StatusTone.danger,
                AgentExecution.stale || AgentExecution.never => StatusTone.warning,
                _ => StatusTone.neutral,
              }),
            ],
          ),
          const SizedBox(height: 2),
          Text(a.purpose, style: const TextStyle(color: HyColors.textSecondary, fontSize: 13.5)),
          if (a.schedule != null) Text('Cuándo: ${a.schedule}', style: small),
          if (a.lastOkRunAt != null)
            Text('Última ejecución correcta: ${Fmt.dateTime(a.lastOkRunAt!.toLocal())}', style: small),
          if (a.lastRunStatus == 'failed' && a.lastRunAt != null)
            Text(
              'Última ejecución: falló el ${Fmt.dateTime(a.lastRunAt!.toLocal())}'
              '${a.lastError == null ? '' : ' (código ${a.lastError})'}',
              style: const TextStyle(color: HyColors.danger, fontSize: 12.5),
            ),
          if (a.lastSummary != null && a.lastRunStatus == 'ok') Text('Resultado: ${a.lastSummary}', style: small),
          if (a.status == AgentStatus.rules || a.status == AgentStatus.ai)
            Text(
              'Últimas 24 h: ${a.runsOk24h} correcta(s), ${a.runsFailed24h} fallida(s) · ${a.openItems} aviso(s) abierto(s)',
              style: small,
            ),
          if (a.needs != null)
            Text('Falta: ${a.needs}', style: const TextStyle(color: HyColors.warning, fontSize: 12.5)),
          Text('Fase ${a.phase}${a.addedByClaude ? ' · Agregado por Claude' : ''}', style: small),
        ],
      ),
    );
  }
}

/// El reporte diario es para el dueño y va en inglés (montos en bolivianos).
class _ReportTab extends ConsumerWidget {
  const _ReportTab();

  static const _labels = {
    'commission_revenue_bs': 'Commission revenue (Bs)',
    'commissions_captured': 'Commissions collected',
    'recharges_requested': 'Recharges requested',
    'recharges_requested_bs': 'Recharges requested (Bs)',
    'recharges_approved': 'Recharges approved',
    'recharges_approved_bs': 'Recharges approved (Bs)',
    'bookings_created': 'Bookings created',
    'bookings_completed': 'Bookings completed',
    'bookings_cancelled': 'Bookings cancelled',
    'disputes_opened': 'Disputes opened',
    'new_customers': 'New users',
    'new_applications': 'New pro applications',
    'professionals_approved': 'Pros approved',
    'complaints': 'Complaints and tickets',
    'poor_reviews': 'Reviews of 1–2 stars',
    'bookings_pending': 'Bookings waiting',
    'bookings_in_progress': 'Bookings in progress',
    'disputes_open': 'Open disputes',
    'verifications_pending': 'Pending verifications',
    'recharges_pending': 'Pending recharges',
    'recharges_pending_bs': 'Pending recharges (Bs)',
    'complaints_open': 'Open complaints',
    'alerts_open': 'Open alerts',
    'alerts_critical': 'Critical alerts',
    'security_alerts_open': 'Security and fraud alerts',
    'quality_alerts_open': 'Quality alerts',
    'decisions_pending': 'Decisions waiting for you',
    'agent_runs_ok': 'Agent runs OK',
    'agent_runs_failed': 'Agent runs failed',
    'ai_cost_usd': 'AI cost (US\$)',
    'database_size_mb': 'Database size (MB)',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(dailyReportsProvider);
    return ListView(
      padding: bottomSafePadding(context),
      children: [
        PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: HySpacing.sm),
              const Text(
                'Sent every day at 6:00 AM Miami time. Real data only.',
                style: TextStyle(color: HyColors.textSecondary),
              ),
              const SizedBox(height: HySpacing.sm),
              SecondaryButton(
                label: 'Generate now',
                icon: Icons.summarize_outlined,
                onPressed: () async {
                  final ok = await runGuarded(context, () => ref.read(backendProvider).generateDailyReport());
                  if (ok) ref.invalidate(dailyReportsProvider);
                },
              ),
              const SizedBox(height: HySpacing.md),
              ...switch (reports) {
                AsyncData(:final value) when value.isEmpty => [
                  const EmptyState(icon: Icons.article_outlined, title: 'No reports yet'),
                ],
                AsyncData(:final value) => [_ReportView(report: value.first)],
                AsyncError(:final error) => [
                  ErrorView(error: error, onRetry: () => ref.invalidate(dailyReportsProvider)),
                ],
                _ => [const LoadingView()],
              },
            ],
          ),
        ),
      ],
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.report});

  final DailyReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    Widget section(String title, Map<String, dynamic> data, {Map<String, dynamic>? previous}) => AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          for (final e in data.entries)
            if (e.value is num)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(_ReportTab._labels[e.key] ?? e.key)),
                    Text('${e.value}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    if (previous != null && previous[e.key] is num)
                      Text(
                        '  (prev. ${previous[e.key]})',
                        style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Report for ${Fmt.date(r.date)} (${r.timezone})', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: HySpacing.sm),
        AppCard(
          color: HyColors.primarySoft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Top priorities today', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (r.priorities.isEmpty) const Text('Nothing urgent.'),
              for (var i = 0; i < r.priorities.length; i++) Text('${i + 1}. ${r.priorities[i]}'),
            ],
          ),
        ),
        const SizedBox(height: HySpacing.sm),
        section('Yesterday (compared with the day before)', r.today, previous: r.previousDay),
        const SizedBox(height: HySpacing.sm),
        section('Right now', r.current),
        const SizedBox(height: HySpacing.sm),
        if (r.unavailable.isNotEmpty)
          InfoBanner(icon: Icons.info_outline, text: 'Not available yet: ${r.unavailable.join('; ')}.'),
      ],
    );
  }
}
