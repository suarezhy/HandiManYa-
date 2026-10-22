import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import 'admin_common.dart';
import 'admin_users_page.dart';

StatusTone _caseTone(CaseStatus s) => switch (s) {
  CaseStatus.open => StatusTone.danger,
  CaseStatus.reviewing => StatusTone.warning,
  CaseStatus.resolved => StatusTone.success,
  CaseStatus.dismissed => StatusTone.neutral,
};

class _Tabs extends StatelessWidget {
  const _Tabs({required this.title, required this.builder});

  final String title;
  final Widget Function(String status) builder;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Abiertos'),
            Tab(text: 'Todos'),
          ],
        ),
      ),
      body: TabBarView(children: [builder('open'), builder('all')]),
    ),
  );
}

// ======================================================================= Reportes
class AdminReportsPage extends StatelessWidget {
  const AdminReportsPage({super.key});

  @override
  Widget build(BuildContext context) => _Tabs(
    title: 'Reportes',
    builder: (s) => _ReportList(status: s),
  );
}

class _ReportList extends ConsumerWidget {
  const _ReportList({required this.status});

  final String status;

  Future<void> _act(BuildContext context, WidgetRef ref, AdminReport r, CaseStatus to) async {
    String? resolution;
    if (to != CaseStatus.reviewing) {
      resolution = await promptText(
        context,
        title: to == CaseStatus.resolved ? 'Resolver reporte' : 'Descartar reporte',
        label: 'Qué se hizo o por qué se descarta',
        confirm: 'Guardar',
      );
      if (resolution == null) return;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).reviewReport(r.id, to, resolution: resolution),
      success: 'Reporte actualizado',
    );
    if (ok) {
      ref
        ..invalidate(adminReportsProvider)
        ..invalidate(adminDashboardProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminList<AdminReport>(
      value: ref.watch(adminReportsProvider(status)),
      onRefresh: () => ref.refresh(adminReportsProvider(status).future),
      emptyTitle: 'No hay reportes abiertos',
      itemBuilder: (context, r) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(r.reason.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ),
                ToneChip(r.status.label, _caseTone(r.status)),
              ],
            ),
            InfoLine(Icons.person_off_outlined, 'Reportado: ${r.reportedName}'),
            if (r.reportsAgainst > 1)
              InfoLine(Icons.warning_amber_rounded, 'Tiene ${r.reportsAgainst} reportes en total'),
            InfoLine(Icons.person_outline, 'Lo reportó: ${r.reporterName} · ${Fmt.relative(r.createdAt)}'),
            if (r.details != null) ...[
              const SizedBox(height: HySpacing.xs),
              Text('"${r.details}"', style: const TextStyle(fontSize: 16, fontStyle: FontStyle.italic)),
            ],
            if (r.resolution != null) InfoLine(Icons.check, 'Resolución: ${r.resolution}'),
            if (r.status.isOpen) ...[
              const SizedBox(height: HySpacing.sm),
              Wrap(
                spacing: HySpacing.xs,
                runSpacing: HySpacing.xs,
                children: [
                  if (r.status == CaseStatus.open)
                    OutlinedButton(
                      onPressed: () => _act(context, ref, r, CaseStatus.reviewing),
                      child: const Text('Tomar caso'),
                    ),
                  OutlinedButton(
                    onPressed: () => _act(context, ref, r, CaseStatus.dismissed),
                    child: const Text('Descartar'),
                  ),
                  FilledButton(
                    onPressed: () => _act(context, ref, r, CaseStatus.resolved),
                    child: const Text('Resolver'),
                  ),
                  TextButton.icon(
                    onPressed: () => showSuspendSheet(context, ref, userId: r.reportedId, name: r.reportedName),
                    icon: const Icon(Icons.block, color: HyColors.danger),
                    label: const Text('Suspender cuenta', style: TextStyle(color: HyColors.danger)),
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

// ======================================================================= Disputas
class AdminDisputesPage extends StatelessWidget {
  const AdminDisputesPage({super.key});

  @override
  Widget build(BuildContext context) => _Tabs(
    title: 'Disputas',
    builder: (s) => _DisputeList(status: s),
  );
}

class _DisputeList extends ConsumerWidget {
  const _DisputeList({required this.status});

  final String status;

  Future<void> _resolve(BuildContext context, WidgetRef ref, AdminDispute d) async {
    final result = await showModalBottomSheet<(DisputeOutcome, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ResolveSheet(),
    );
    if (result == null || !context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).resolveDispute(d.bookingId, result.$1, result.$2),
      success: 'Disputa resuelta',
    );
    if (ok) {
      ref
        ..invalidate(adminDisputesProvider)
        ..invalidate(adminDashboardProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminList<AdminDispute>(
      value: ref.watch(adminDisputesProvider(status)),
      onRefresh: () => ref.refresh(adminDisputesProvider(status).future),
      emptyTitle: 'No hay disputas abiertas',
      itemBuilder: (context, d) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    d.categoryName ?? 'Trabajo',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
                ToneChip(d.isOpen ? 'Abierta' : 'Resuelta', d.isOpen ? StatusTone.danger : StatusTone.success),
              ],
            ),
            InfoLine(Icons.person_outline, 'Cliente: ${d.customerName}'),
            InfoLine(Icons.handyman_outlined, 'Profesional: ${d.professionalName ?? '—'}'),
            InfoLine(Icons.schedule, 'Abierta por ${d.openedByName} · ${Fmt.relative(d.createdAt)}'),
            const SizedBox(height: HySpacing.xs),
            Text('"${d.reason}"', style: const TextStyle(fontSize: 16, fontStyle: FontStyle.italic)),
            if (d.resolution != null) InfoLine(Icons.check, 'Resolución: ${d.resolution}'),
            if (d.isOpen) ...[
              const SizedBox(height: HySpacing.sm),
              const Text(
                'Antes de decidir, habla con las dos partes. La decisión se avisa a ambos y queda en la auditoría.',
                style: TextStyle(color: HyColors.textSecondary),
              ),
              const SizedBox(height: HySpacing.xs),
              PrimaryButton(label: 'Resolver disputa', onPressed: () => _resolve(context, ref, d)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResolveSheet extends StatefulWidget {
  const _ResolveSheet();

  @override
  State<_ResolveSheet> createState() => _ResolveSheetState();
}

class _ResolveSheetState extends State<_ResolveSheet> {
  DisputeOutcome? _outcome;
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Resolver disputa', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: HySpacing.sm),
        RadioGroup<DisputeOutcome>(
          groupValue: _outcome,
          onChanged: (v) => setState(() => _outcome = v),
          child: Column(
            children: [
              for (final o in DisputeOutcome.values)
                RadioListTile<DisputeOutcome>(contentPadding: EdgeInsets.zero, value: o, title: Text(o.label)),
            ],
          ),
        ),
        const Text(
          'Si se cancela, se libera la comisión reservada al profesional. Si se completa, se cobra.',
          style: TextStyle(color: HyColors.textSecondary),
        ),
        const SizedBox(height: HySpacing.sm),
        TextField(
          controller: _text,
          maxLines: 3,
          minLines: 2,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Explicación para las dos partes'),
        ),
        const SizedBox(height: HySpacing.md),
        PrimaryButton(
          label: 'Guardar decisión',
          onPressed: _outcome == null || _text.text.trim().length < 5
              ? null
              : () => Navigator.pop(context, (_outcome!, _text.text.trim())),
        ),
      ],
    ),
  );
}

// ======================================================================= Soporte
class AdminTicketsPage extends StatelessWidget {
  const AdminTicketsPage({super.key});

  @override
  Widget build(BuildContext context) => _Tabs(
    title: 'Soporte',
    builder: (s) => _TicketList(status: s),
  );
}

class _TicketList extends ConsumerWidget {
  const _TicketList({required this.status});

  final String status;

  Future<void> _act(BuildContext context, WidgetRef ref, AdminTicket t, TicketStatus to) async {
    final note = await promptOptional(
      context,
      title: to == TicketStatus.closed ? 'Cerrar ticket' : 'Atender ticket',
      label: 'Respuesta al usuario (opcional, le llega como aviso)',
      confirm: 'Guardar',
    );
    if (note == null || !context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).updateTicket(t.id, to, note: note),
      success: 'Ticket actualizado',
    );
    if (ok) {
      ref
        ..invalidate(adminTicketsProvider)
        ..invalidate(adminDashboardProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminList<AdminTicket>(
      value: ref.watch(adminTicketsProvider(status)),
      onRefresh: () => ref.refresh(adminTicketsProvider(status).future),
      emptyTitle: 'No hay mensajes pendientes',
      itemBuilder: (context, t) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(t.subject, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ),
                ToneChip(t.status.label, switch (t.status) {
                  TicketStatus.open => StatusTone.danger,
                  TicketStatus.inProgress => StatusTone.warning,
                  TicketStatus.closed => StatusTone.neutral,
                }),
              ],
            ),
            InfoLine(Icons.person_outline, '${t.userName} · ${Fmt.relative(t.createdAt)}'),
            const SizedBox(height: HySpacing.xs),
            Text(t.body, style: const TextStyle(fontSize: 16)),
            if (t.adminNote != null) InfoLine(Icons.reply, 'Respuesta: ${t.adminNote}'),
            if (t.status != TicketStatus.closed) ...[
              const SizedBox(height: HySpacing.sm),
              Row(
                children: [
                  if (t.status == TicketStatus.open) ...[
                    Expanded(
                      child: SecondaryButton(
                        label: 'Atender',
                        onPressed: () => _act(context, ref, t, TicketStatus.inProgress),
                      ),
                    ),
                    const SizedBox(width: HySpacing.xs),
                  ],
                  Expanded(
                    child: PrimaryButton(label: 'Cerrar', onPressed: () => _act(context, ref, t, TicketStatus.closed)),
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
