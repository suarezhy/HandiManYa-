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
        bottom: const TabBar(
          isScrollable: true,
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
  ..invalidate(dailyReportsProvider);

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = ref.watch(aiOverviewProvider);
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
                  Wrap(
                    spacing: HySpacing.sm,
                    runSpacing: HySpacing.sm,
                    children: [
                      _Stat('Esperan tu aprobación', value.pendingApproval, HyColors.primary),
                      _Stat('Alertas abiertas', value.open, HyColors.navy),
                      _Stat('Críticas', value.critical, HyColors.danger),
                      _Stat('Altas', value.high, HyColors.warning),
                      _Stat('Recomendaciones de IA', value.aiRecommendationsOpen, HyColors.info),
                      _Stat('Completadas (7 días)', value.completed7d, HyColors.green),
                      _Stat('Fallidas (7 días)', value.failed7d, HyColors.danger),
                    ],
                  ),
                  const SizedBox(height: HySpacing.md),
                  InfoBanner(
                    icon: Icons.savings_outlined,
                    text: value.aiBudgetMonthUsd <= 0
                        ? 'Presupuesto de IA: sin aprobar. Ningún agente usa un modelo de IA pagado; todo funciona con reglas sobre datos reales.'
                        : 'Gasto de IA este mes: US\$ ${value.aiCostMonthUsd.toStringAsFixed(2)} de US\$ ${value.aiBudgetMonthUsd.toStringAsFixed(2)}.',
                  ),
                  const SizedBox(height: HySpacing.sm),
                  Text(
                    value.lastMonitorRun == null
                        ? 'Los monitores todavía no corrieron.'
                        : 'Última revisión automática: ${Fmt.dateTime(value.lastMonitorRun!.toLocal())}',
                    style: const TextStyle(color: HyColors.textSecondary),
                  ),
                  const SizedBox(height: HySpacing.md),
                  SecondaryButton(
                    label: 'Revisar ahora',
                    icon: Icons.manage_search,
                    onPressed: () async {
                      final ok = await runGuarded(context, () async {
                        final n = await ref.read(backendProvider).runMonitors();
                        if (context.mounted) {
                          showMessage(context, n == 0 ? 'Sin avisos nuevos.' : '$n aviso(s) nuevo(s).');
                        }
                      });
                      if (ok) _refreshAll(ref);
                    },
                  ),
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
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 150),
    child: AppCard(
      padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: color),
          ),
          Text(label, style: const TextStyle(color: HyColors.textSecondary)),
        ],
      ),
    ),
  );
}

class _DecisionsTab extends ConsumerStatefulWidget {
  const _DecisionsTab();

  @override
  ConsumerState<_DecisionsTab> createState() => _DecisionsTabState();
}

class _DecisionsTabState extends ConsumerState<_DecisionsTab> {
  String _filter = 'pendientes';

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
                    const EmptyState(icon: Icons.check_circle_outline, title: 'Nada por aquí'),
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

class _ItemCard extends ConsumerWidget {
  const _ItemCard({required this.item});

  final AiItem item;

  Future<void> _decide(BuildContext context, WidgetRef ref, AiDecision d) async {
    String? method;
    if (d == AiDecision.approve) {
      final c = await confirmIdentity(context, operation: 'Aprobar: ${item.title}', submitLabel: 'Confirmar y aprobar');
      if (c == null) return;
      method = c.serverMethod;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).decideAiItem(item.id, d, authMethod: method),
      success: switch (d) {
        AiDecision.approve => 'Aprobado. Queda registrado en la auditoría.',
        AiDecision.reject => 'Rechazado.',
        AiDecision.moreInfo => 'Marcado: pediste más información.',
        AiDecision.completed => 'Marcado como completado.',
        AiDecision.failed => 'Marcado como fallido.',
        AiDecision.dismiss => 'Descartado.',
      },
    );
    if (ok) _refreshAll(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tone = switch (item.severity) {
      AiSeverity.critical || AiSeverity.high => StatusTone.danger,
      AiSeverity.medium => StatusTone.warning,
      _ => StatusTone.info,
    };
    final pending = item.status.isPending;
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: HySpacing.xs,
              runSpacing: 4,
              children: [
                _Chip(item.severity.label, tone),
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
            if (item.evidence.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Evidencia: ${item.evidence.entries.map((e) => '${e.key}: ${e.value}').join(' · ')}',
                  style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
                ),
              ),
            Text(
              Fmt.dateTime(item.createdAt.toLocal()),
              style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
            ),
            if (pending || item.status == AiItemStatus.approved) ...[
              const SizedBox(height: HySpacing.xs),
              Wrap(
                spacing: HySpacing.xs,
                children: [
                  if (item.status == AiItemStatus.pendingApproval)
                    FilledButton(
                      onPressed: () => _decide(context, ref, AiDecision.approve),
                      child: const Text('Aprobar'),
                    ),
                  if (pending && item.needsApproval)
                    OutlinedButton(
                      onPressed: () => _decide(context, ref, AiDecision.reject),
                      child: const Text('Rechazar'),
                    ),
                  if (pending && item.status != AiItemStatus.moreInfo)
                    TextButton(
                      onPressed: () => _decide(context, ref, AiDecision.moreInfo),
                      child: const Text('Pedir más información'),
                    ),
                  if (!item.needsApproval && pending)
                    TextButton(
                      onPressed: () => _decide(context, ref, AiDecision.completed),
                      child: const Text('Ya lo resolví'),
                    ),
                  if (!item.needsApproval && pending)
                    TextButton(
                      onPressed: () => _decide(context, ref, AiDecision.dismiss),
                      child: const Text('Descartar'),
                    ),
                  if (item.status == AiItemStatus.approved)
                    TextButton(
                      onPressed: () => _decide(context, ref, AiDecision.completed),
                      child: const Text('Marcar como hecho'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
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
    return ListView(
      padding: bottomSafePadding(context),
      children: [
        PageBody(
          child: switch (agents) {
            AsyncData(:final value) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.sm),
                const InfoBanner(
                  text: 'Los agentes vigilan y recomiendan. No cambian saldos, no aprueban documentos, no suspenden cuentas ni gastan dinero: eso lo decides tú.',
                ),
                const SizedBox(height: HySpacing.sm),
                for (final a in value)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HySpacing.xs),
                    child: AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${a.number}. ${a.name}',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                                ),
                              ),
                              _Chip(a.status.label, switch (a.status) {
                                AgentStatus.rules || AgentStatus.ai => StatusTone.success,
                                AgentStatus.needsSetup => StatusTone.warning,
                                _ => StatusTone.neutral,
                              }),
                            ],
                          ),
                          Text(a.purpose, style: const TextStyle(color: HyColors.textSecondary)),
                          Text(
                            'Fase ${a.phase}${a.addedByClaude ? ' · Agregado por Claude' : ''}'
                            '${a.lastRunAt == null ? '' : ' · Última vez: ${Fmt.dateTime(a.lastRunAt!.toLocal())}'}',
                            style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
                          ),
                          if (a.needs != null)
                            Text('Falta: ${a.needs}', style: const TextStyle(color: HyColors.warning, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            AsyncError(:final error) => ErrorView(error: error, onRetry: () => ref.invalidate(aiAgentsProvider)),
            _ => const LoadingView(),
          },
        ),
      ],
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
