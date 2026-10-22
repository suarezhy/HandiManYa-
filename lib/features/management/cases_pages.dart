import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/staff.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../admin/admin_common.dart';
import 'management_common.dart';

final _when = DateFormat("d MMM, HH:mm", 'es');

const _docLabels = {
  'ci_anverso': 'Carnet (frente)',
  'ci_reverso': 'Carnet (reverso)',
  'antecedentes': 'Antecedentes',
  'certificado': 'Certificado o matrícula',
  'nombramiento_notarial': 'Nombramiento notarial',
};

/// Lista de casos. El gerente y el propietario eligen qué bandeja ver; el
/// empleado ve solo los suyos (el servidor no le manda otros).
class CasesPage extends ConsumerStatefulWidget {
  const CasesPage({super.key, required this.role, this.initialScope = 'mine', this.inShell = true});

  final StaffRole role;
  final String initialScope;

  /// En una pestaña del panel lleva el encabezado del panel; abierta desde
  /// otra pantalla, una flecha de volver.
  final bool inShell;

  @override
  ConsumerState<CasesPage> createState() => _CasesPageState();
}

class _CasesPageState extends ConsumerState<CasesPage> {
  late String _scope = widget.role == StaffRole.employee ? 'mine' : widget.initialScope;
  bool _resolved = false;

  static const _scopes = [
    ('mine', 'Míos'),
    ('unassigned', 'Sin asignar'),
    ('escalated', 'Escalados'),
    ('all', 'Todos'),
  ];

  @override
  Widget build(BuildContext context) {
    final cases = ref.watch(opsCasesProvider((_scope, _resolved)));
    final title = widget.role == StaffRole.employee ? 'Mis casos' : 'Casos';
    return Scaffold(
      appBar: widget.inShell ? PanelAppBar(role: widget.role, title: title) : AppBar(title: Text(title)),
      body: RefreshIndicator(
        onRefresh: () async => refreshOps(ref),
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
                    runSpacing: HySpacing.xs,
                    children: [
                      if (widget.role != StaffRole.employee)
                        for (final (key, label) in _scopes)
                          ChoiceChip(
                            key: Key('cases-scope-$key'),
                            label: Text(label),
                            selected: _scope == key,
                            onSelected: (_) => setState(() => _scope = key),
                          ),
                      FilterChip(
                        key: const Key('cases-resolved'),
                        label: const Text('Incluir resueltos'),
                        selected: _resolved,
                        onSelected: (v) => setState(() => _resolved = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: HySpacing.sm),
                  switch (cases) {
                    AsyncData(:final value) when value.isEmpty => EmptyState(
                      icon: Icons.inbox_outlined,
                      title: widget.role == StaffRole.employee ? 'No tienes casos asignados' : 'No hay casos aquí',
                      message: widget.role == StaffRole.employee
                          ? 'Cuando el gerente te asigne un caso, aparece aquí.'
                          : 'Los mensajes de soporte, reportes, disputas y postulaciones abren casos solos.',
                    ),
                    AsyncData(:final value) => Column(children: [for (final c in value) CaseCard(item: c)]),
                    AsyncError(:final error) => ErrorView(error: error, onRetry: () => refreshOps(ref)),
                    _ => const LoadingView(),
                  },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CaseCard extends StatelessWidget {
  const CaseCard({super.key, required this.item});

  final OpsCase item;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.xs),
    child: AppCard(
      key: Key('case-${item.id}'),
      onTap: () => context.push(Routes.staffCase(item.id)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(caseKindIcon(item.kind), color: HyColors.navy, size: 28),
          const SizedBox(width: HySpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(
                  '${item.kind.label} · ${_when.format(item.createdAt)}'
                  '${item.assignedName == null ? ' · Sin asignar' : ' · ${item.assignedName}'}',
                  style: const TextStyle(color: HyColors.textSecondary),
                ),
                const SizedBox(height: HySpacing.xxs),
                Wrap(
                  spacing: HySpacing.xxs,
                  runSpacing: HySpacing.xxs,
                  children: [
                    ToneChip(item.status.label, caseStatusTone(item.status)),
                    if (!item.isRoutine) ToneChip(item.categoryLabel, StatusTone.danger),
                    if (item.priority != 'normal')
                      ToneChip(
                        'Prioridad ${item.priorityLabel.toLowerCase()}',
                        item.priority == 'urgent' ? StatusTone.danger : StatusTone.warning,
                      ),
                  ],
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

/// Un caso: de dónde viene, su historial y lo que puede hacer quien lo mira.
/// Cada botón lo vuelve a autorizar el servidor.
class CaseDetailPage extends ConsumerWidget {
  const CaseDetailPage({super.key, required this.caseId});

  final int caseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(opsCaseDetailProvider(caseId));
    final account = ref.watch(accountProvider).value;
    final role = account?.managementRole ?? StaffRole.employee;
    return Scaffold(
      appBar: AppBar(title: const Text('Caso')),
      body: switch (detail) {
        AsyncData(:final value) => _CaseBody(d: value, role: role, myId: account?.id),
        AsyncError(:final error) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(opsCaseDetailProvider(caseId)),
        ),
        _ => const LoadingView(),
      },
    );
  }
}

class _CaseBody extends ConsumerWidget {
  const _CaseBody({required this.d, required this.role, required this.myId});

  final OpsCaseDetail d;
  final StaffRole role;
  final String? myId;

  bool get _isManager => role != StaffRole.employee;
  bool get _mine => d.item.assignedTo == myId;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action, String done) async {
    final ok = await runGuarded(context, action, success: done);
    if (ok) refreshOps(ref);
  }

  Future<void> _reply(BuildContext context, WidgetRef ref) async {
    final text = await promptText(
      context,
      title: 'Responder',
      label: 'Mensaje para la persona',
      confirm: 'Enviar respuesta',
      minLength: 2,
    );
    if (text == null || !context.mounted) return;
    await _run(context, ref, () => ref.read(backendProvider).replyCase(d.item.id, text), 'Respuesta enviada.');
  }

  Future<void> _note(BuildContext context, WidgetRef ref) async {
    final text = await promptText(
      context,
      title: 'Nota interna',
      label: 'Solo la ve el equipo',
      confirm: 'Guardar nota',
      minLength: 2,
    );
    if (text == null || !context.mounted) return;
    await _run(context, ref, () => ref.read(backendProvider).addCaseNote(d.item.id, text), 'Nota guardada.');
  }

  Future<void> _status(BuildContext context, WidgetRef ref, OpsCaseStatus status) async {
    String? note;
    if (status == OpsCaseStatus.resolved) {
      note = await promptText(
        context,
        title: 'Resolver el caso',
        label: 'Cómo se resolvió',
        confirm: 'Marcar resuelto',
        minLength: 3,
      );
      if (note == null || !context.mounted) return;
    }
    await _run(
      context,
      ref,
      () => ref.read(backendProvider).setCaseStatus(d.item.id, status, note: note),
      'Caso: ${status.label.toLowerCase()}.',
    );
  }

  Future<void> _escalate(BuildContext context, WidgetRef ref) async {
    final category = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
              child: Text(
                role == StaffRole.employee ? 'Escalar al gerente' : 'Escalar al propietario',
                style: Theme.of(c).textTheme.titleLarge,
              ),
            ),
            for (final (key, label, icon) in [
              ('safety', 'Incidente de seguridad', Icons.health_and_safety_outlined),
              ('fraud', 'Posible fraude', Icons.report_gmailerrorred_outlined),
              ('dispute', 'Disputa', Icons.gavel_outlined),
              ('', 'Otro motivo', Icons.more_horiz),
            ])
              ListTile(
                key: Key('escalate-${key.isEmpty ? 'other' : key}'),
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(c, key),
              ),
          ],
        ),
      ),
    );
    if (category == null || !context.mounted) return;
    final reason = await promptText(
      context,
      title: 'Motivo',
      label: 'Qué pasó y qué hace falta',
      confirm: 'Escalar',
      minLength: 5,
    );
    if (reason == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(backendProvider).escalateCase(d.item.id, reason, category: category.isEmpty ? null : category),
      'Caso escalado.',
    );
  }

  Future<void> _assign(BuildContext context, WidgetRef ref) async {
    final team = await ref.read(staffOverviewProvider.future);
    if (!context.mounted) return;
    final active = team.where((m) => m.isActive).toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
                child: Text('Asignar a', style: Theme.of(c).textTheme.titleLarge),
              ),
              if (active.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(HySpacing.page),
                  child: Text('Todavía no hay miembros activos en el equipo.'),
                ),
              for (final m in active)
                ListTile(
                  key: Key('assign-${m.userId}'),
                  leading: const Icon(Icons.person_outline),
                  title: Text(m.fullName),
                  subtitle: Text('${m.role.label} · ${m.openCases} casos abiertos'),
                  onTap: () => Navigator.pop(c, m.userId),
                ),
              if (d.item.assignedTo != null)
                ListTile(
                  key: const Key('assign-none'),
                  leading: const Icon(Icons.person_off_outlined),
                  title: const Text('Dejar sin asignar'),
                  onTap: () => Navigator.pop(c, ''),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(backendProvider).assignCase(d.item.id, picked.isEmpty ? null : picked),
      'Caso asignado.',
    );
  }

  Future<void> _flag(BuildContext context, WidgetRef ref, OpsDocument doc) async {
    final note = await promptText(
      context,
      title: 'Marcar documento',
      label: 'Qué falta o qué es dudoso',
      confirm: 'Marcar',
      minLength: 3,
    );
    if (note == null || !context.mounted) return;
    await _run(context, ref, () => ref.read(backendProvider).flagDocument(doc.id, note), 'Documento marcado.');
    ref.invalidate(adminApplicationDetailProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = d.item;
    final canAct = _isManager || _mine;
    final employeeLimited = role == StaffRole.employee && (!c.isRoutine || c.kind == OpsCaseKind.dispute);
    return ListView(
      padding: bottomSafePadding(context),
      children: [
        PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: HySpacing.md),
              Text(c.title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: HySpacing.xs),
              Wrap(
                spacing: HySpacing.xxs,
                runSpacing: HySpacing.xxs,
                children: [
                  ToneChip(c.kind.label, StatusTone.neutral),
                  ToneChip(c.status.label, caseStatusTone(c.status)),
                  if (!c.isRoutine) ToneChip(c.categoryLabel, StatusTone.danger),
                  if (c.priority != 'normal')
                    ToneChip('Prioridad ${c.priorityLabel.toLowerCase()}', StatusTone.warning),
                ],
              ),
              const SizedBox(height: HySpacing.sm),
              _Field('Abierto', _when.format(c.createdAt)),
              _Field('Asignado a', c.assignedName ?? 'Sin asignar'),
              if (c.escalatedTo != null) _Field('Escalado a', c.escalatedTo == 'owner' ? 'Propietario' : 'Gerente'),
              if (c.firstResponseAt != null) _Field('Primera respuesta', _when.format(c.firstResponseAt!)),
              const SectionHeader(title: 'Detalle'),
              ..._source(context, ref, canAct),
              if (employeeLimited)
                const Padding(
                  padding: EdgeInsets.only(top: HySpacing.sm),
                  child: InfoBanner(
                    icon: Icons.shield_outlined,
                    tone: StatusTone.warning,
                    text: 'Disputas, fraude y seguridad no los cierras tú: anota lo que sepas y escálalo al gerente.',
                  ),
                ),
              if (canAct && c.status != OpsCaseStatus.resolved) ...[
                const SectionHeader(title: 'Acciones'),
                Wrap(
                  spacing: HySpacing.xs,
                  runSpacing: HySpacing.xs,
                  children: [
                    if (c.kind == OpsCaseKind.support)
                      FilledButton.icon(
                        key: const Key('case-reply'),
                        onPressed: () => _reply(context, ref),
                        icon: const Icon(Icons.reply),
                        label: const Text('Responder'),
                      ),
                    OutlinedButton.icon(
                      key: const Key('case-note'),
                      onPressed: () => _note(context, ref),
                      icon: const Icon(Icons.sticky_note_2_outlined),
                      label: const Text('Nota interna'),
                    ),
                    if (c.status != OpsCaseStatus.escalated || _isManager) ...[
                      if (c.status != OpsCaseStatus.inProgress)
                        OutlinedButton(
                          key: const Key('case-in-progress'),
                          onPressed: () => _status(context, ref, OpsCaseStatus.inProgress),
                          child: const Text('Tomar el caso'),
                        ),
                      if (c.status != OpsCaseStatus.waiting)
                        OutlinedButton(
                          key: const Key('case-waiting'),
                          onPressed: () => _status(context, ref, OpsCaseStatus.waiting),
                          child: const Text('Esperando respuesta'),
                        ),
                      if (c.kind != OpsCaseKind.application && (!employeeLimited))
                        OutlinedButton(
                          key: const Key('case-resolve'),
                          onPressed: () => _status(context, ref, OpsCaseStatus.resolved),
                          child: const Text('Marcar resuelto'),
                        ),
                    ],
                    if (role != StaffRole.owner)
                      OutlinedButton.icon(
                        key: const Key('case-escalate'),
                        style: OutlinedButton.styleFrom(foregroundColor: HyColors.danger),
                        onPressed: () => _escalate(context, ref),
                        icon: const Icon(Icons.priority_high),
                        label: Text(role == StaffRole.employee ? 'Escalar al gerente' : 'Escalar al propietario'),
                      ),
                    if (_isManager)
                      OutlinedButton.icon(
                        key: const Key('case-assign'),
                        onPressed: () => _assign(context, ref),
                        icon: const Icon(Icons.person_add_alt),
                        label: Text(c.assignedTo == null ? 'Asignar' : 'Reasignar'),
                      ),
                  ],
                ),
              ],
              const SectionHeader(title: 'Historial'),
              if (d.notes.isEmpty)
                const Text('Todavía no hay notas ni respuestas.', style: TextStyle(color: HyColors.textSecondary)),
              for (final n in d.notes.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: HySpacing.xs),
                  child: AppCard(
                    padding: const EdgeInsets.all(HySpacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${n.kindLabel} · ${n.authorName} · ${_when.format(n.createdAt)}',
                          style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(n.body),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _source(BuildContext context, WidgetRef ref, bool canAct) {
    String? s(String k) => d.s(k);
    switch (d.item.kind) {
      case OpsCaseKind.support:
        return [
          _Field('De', s('user_name') ?? ''),
          _Field('Asunto', s('subject') ?? ''),
          const SizedBox(height: HySpacing.xs),
          Text(s('body') ?? '', style: const TextStyle(fontSize: 16)),
          if (s('last_reply') != null) ...[
            const SizedBox(height: HySpacing.xs),
            _Field('Última respuesta', s('last_reply')!),
          ],
        ];
      case OpsCaseKind.report:
        return [
          _Field('Reporta', s('reporter_name') ?? ''),
          _Field('Sobre', s('reported_name') ?? ''),
          _Field('Motivo', s('reason') ?? ''),
          if (s('details') != null) Text(s('details')!, style: const TextStyle(fontSize: 16)),
        ];
      case OpsCaseKind.dispute:
        return [
          _Field('Cliente', s('customer_name') ?? ''),
          _Field('Profesional', s('professional_name') ?? '—'),
          _Field('Motivo', s('reason') ?? ''),
          if (role != StaffRole.owner)
            const InfoBanner(text: 'Resolver una disputa cambia el cobro de la comisión: lo decide el propietario.'),
        ];
      case OpsCaseKind.application:
        return [
          _Field('Nombre', s('display_name') ?? ''),
          if (s('category_name') != null) _Field('Servicio', s('category_name')!),
          if (s('city_name') != null) _Field('Ciudad', s('city_name')!),
          const SizedBox(height: HySpacing.xs),
          for (final doc in d.documents)
            Padding(
              padding: const EdgeInsets.only(bottom: HySpacing.xxs),
              child: AppCard(
                padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: HySpacing.xs),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined),
                    const SizedBox(width: HySpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _docLabels[doc.docType] ?? doc.docType,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            doc.flagNote == null ? _docStatus(doc.status) : 'Marcado: ${doc.flagNote}',
                            style: TextStyle(color: doc.flagNote == null ? HyColors.textSecondary : HyColors.warning),
                          ),
                        ],
                      ),
                    ),
                    if (canAct && doc.status == 'pending')
                      TextButton(
                        key: Key('flag-doc-${doc.id}'),
                        onPressed: () => _flag(context, ref, doc),
                        child: const Text('Marcar'),
                      ),
                  ],
                ),
              ),
            ),
          if (role == StaffRole.employee)
            const InfoBanner(
              text: 'Puedes marcar documentos faltantes o dudosos. Aceptar documentos y aprobar lo hace el gerente.',
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: HySpacing.xs),
              child: FilledButton.icon(
                key: const Key('case-open-application'),
                onPressed: () => context.push(Routes.adminApplication(d.item.refId)),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Revisar la postulación completa'),
              ),
            ),
        ];
    }
  }

  static String _docStatus(String s) => switch (s) {
    'accepted' => 'Aceptado',
    'rejected' => 'Rechazado',
    _ => 'Por revisar',
  };
}

/// Una línea "Etiqueta: valor" del detalle del caso.
class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(color: HyColors.textSecondary),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
}
