import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/staff.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../admin/admin_common.dart';
import '../security/confirm_identity.dart';
import 'management_common.dart';

/// Equipo. El propietario agrega, suspende, reactiva o quita acceso; el
/// gerente solo ve la carga de trabajo y los tiempos de respuesta. Los roles
/// los da solo el propietario y el servidor lo vuelve a revisar
/// (owner_grant_staff, owner_set_staff_status).
class TeamPage extends ConsumerWidget {
  const TeamPage({super.key, required this.role});

  final StaffRole role;

  bool get _isOwner => role == StaffRole.owner;

  Future<void> _setStatus(BuildContext context, WidgetRef ref, StaffMember m, String status) async {
    String? reason;
    if (status != 'active') {
      reason = await promptText(
        context,
        title: status == 'suspended' ? 'Suspender a ${m.fullName}' : 'Quitar el acceso a ${m.fullName}',
        label: 'Motivo',
        confirm: status == 'suspended' ? 'Suspender' : 'Quitar acceso',
        hint: 'Queda en la auditoría',
        minLength: 5,
      );
      if (reason == null) return;
    } else if (!await confirmDialog(
      context,
      title: '¿Reactivar a ${m.fullName}?',
      message: 'Vuelve a tener su rol de ${m.role.label} con los mismos permisos. Te pediremos un código.',
      confirm: 'Reactivar',
    )) {
      return;
    }
    if (!context.mounted) return;
    // Reactivar devuelve el acceso: pide un código nuevo, como dar un rol.
    String? method;
    if (status == 'active') {
      method = (await confirmIdentity(
        context,
        operation: 'Reactivar a ${m.fullName}',
        details: [('Rol', m.role.label), if (m.phoneMasked != null) ('Celular', m.phoneMasked!)],
        submitLabel: 'Confirmar y reactivar',
        codeOnly: true,
      ))?.serverMethod;
      if (method == null || !context.mounted) return;
    }
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).setStaffStatus(m.userId, status, reason: reason, authMethod: method),
      success: switch (status) {
        'suspended' => 'Suspendido. Sus casos abiertos volvieron a la bandeja.',
        'revoked' => 'Acceso quitado. Sus casos abiertos volvieron a la bandeja.',
        _ => 'Reactivado',
      },
    );
    if (ok) refreshOps(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = ref.watch(staffOverviewProvider);
    return Scaffold(
      appBar: PanelAppBar(role: role, title: 'Equipo'),
      floatingActionButton: _isOwner
          ? FloatingActionButton.extended(
              key: const Key('team-add'),
              backgroundColor: HyColors.primary,
              foregroundColor: Colors.white,
              onPressed: () => context.push(Routes.ownerTeamAdd),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Agregar al equipo'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => refreshOps(ref),
        child: ListView(
          padding: bottomSafePadding(context, bottom: 104),
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: HySpacing.md),
                  InfoBanner(
                    text: _isOwner
                        ? 'Solo tú das o quitas roles. Cada persona entra con su propia cuenta y su celular.'
                        : 'Puedes asignar casos al equipo. Solo el propietario agrega personas o cambia roles.',
                  ),
                  const SizedBox(height: HySpacing.sm),
                  switch (team) {
                    AsyncData(:final value) when value.isEmpty => const EmptyState(
                      key: Key('team-empty'),
                      icon: Icons.groups_outlined,
                      title: 'Todavía no hay equipo',
                      message: 'Nadie tiene rol de Gerente o Empleado.',
                    ),
                    AsyncData(:final value) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final r in [StaffRole.manager, StaffRole.employee])
                          if (value.any((m) => m.role == r)) ...[
                            SectionHeader(title: r == StaffRole.manager ? 'Gerencia' : 'Empleados'),
                            for (final m in value.where((m) => m.role == r))
                              _MemberCard(member: m, onStatus: _isOwner ? (s) => _setStatus(context, ref, m, s) : null),
                          ],
                      ],
                    ),
                    AsyncError(:final error) => ErrorView(
                      error: error,
                      onRetry: () => ref.invalidate(staffOverviewProvider),
                    ),
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

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member, this.onStatus});

  final StaffMember member;
  final ValueChanged<String>? onStatus;

  @override
  Widget build(BuildContext context) {
    final m = member;
    final tone = m.isActive ? StatusTone.success : (m.status == 'suspended' ? StatusTone.warning : StatusTone.neutral);
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.xs),
      child: AppCard(
        key: Key('member-${m.userId}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: panelAccent(m.role).withValues(alpha: 0.15),
                  child: Icon(
                    m.role == StaffRole.manager ? Icons.manage_accounts_outlined : Icons.support_agent_outlined,
                    color: HyColors.navy,
                  ),
                ),
                const SizedBox(width: HySpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.fullName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                      Text(
                        [m.role.label, ?m.phoneMasked].join(' · '),
                        style: const TextStyle(color: HyColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                ToneChip(m.statusLabel, tone),
              ],
            ),
            const SizedBox(height: HySpacing.xs),
            Wrap(
              spacing: HySpacing.md,
              runSpacing: 4,
              children: [
                _Metric(Icons.inbox_outlined, '${m.openCases} abiertos'),
                _Metric(Icons.task_alt, '${m.resolved7d} resueltos en 7 días'),
                _Metric(
                  Icons.timer_outlined,
                  m.avgFirstResponseMin == null
                      ? 'Sin respuestas todavía'
                      : 'Responde en ${m.avgFirstResponseMin} min (promedio)',
                ),
              ],
            ),
            if (m.statusReason != null && !m.isActive) InfoLine(Icons.notes_outlined, 'Motivo: ${m.statusReason}'),
            if (onStatus != null) ...[
              const SizedBox(height: HySpacing.xs),
              Wrap(
                spacing: HySpacing.xs,
                children: [
                  if (m.isActive)
                    OutlinedButton(
                      key: Key('member-suspend-${m.userId}'),
                      onPressed: () => onStatus!('suspended'),
                      child: const Text('Suspender'),
                    )
                  else
                    OutlinedButton(
                      key: Key('member-activate-${m.userId}'),
                      onPressed: () => onStatus!('active'),
                      child: const Text('Reactivar'),
                    ),
                  if (m.status != 'revoked')
                    TextButton(
                      key: Key('member-revoke-${m.userId}'),
                      onPressed: () => onStatus!('revoked'),
                      child: const Text('Quitar acceso', style: TextStyle(color: HyColors.danger)),
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

class _Metric extends StatelessWidget {
  const _Metric(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: HyColors.textMuted),
      const SizedBox(width: 4),
      Flexible(
        child: Text(text, style: const TextStyle(color: HyColors.textSecondary)),
      ),
    ],
  );
}

/// Agregar a alguien al equipo, en una pantalla completa (la lista no queda
/// tapada por el teclado). Se busca la cuenta por nombre o celular; el rol se
/// da por el id de la cuenta, con confirmación y un código nuevo.
class AddStaffPage extends ConsumerStatefulWidget {
  const AddStaffPage({super.key});

  @override
  ConsumerState<AddStaffPage> createState() => _AddStaffPageState();
}

class _AddStaffPageState extends ConsumerState<AddStaffPage> {
  final _query = TextEditingController();
  Timer? _debounce;
  Future<List<StaffCandidate>>? _results;
  String _searched = '';
  StaffRole _role = StaffRole.employee;
  bool _busy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _search(String q, {bool now = false}) {
    _debounce?.cancel();
    void run() {
      if (!mounted) return;
      final t = q.trim();
      setState(() {
        _searched = t;
        _results = t.length < 2 ? null : ref.read(backendProvider).staffCandidates(t);
      });
    }

    now ? run() : _debounce = Timer(const Duration(milliseconds: 350), run);
  }

  static bool _looksLikePhone(String q) => RegExp(r'^[+\d\s-]{6,}$').hasMatch(q);

  Future<void> _pick(StaffCandidate u) async {
    if (_busy) return;
    if (!await confirmDialog(
      context,
      title: '¿Dar el rol de ${_role.label}?',
      message:
          '${u.fullName}\n'
          'Celular: ${u.phoneMasked ?? 'sin celular'}\n'
          '${u.cityName == null ? '' : 'Ciudad: ${u.cityName}\n'}'
          'ID de la cuenta: ${u.id}\n\n'
          '${_role == StaffRole.manager ? 'Podrá ver y asignar todos los casos del equipo y revisar postulaciones. No verá dinero.' : 'Solo verá los casos que le asignen. No verá dinero ni a otros empleados.'}\n\n'
          'Revisa que sea la persona correcta. Después te pediremos un código.',
      confirm: 'Sí, continuar',
    )) {
      return;
    }
    if (!mounted) return;
    final c = await confirmIdentity(
      context,
      operation: 'Dar el rol de ${_role.label}',
      details: [('Persona', u.fullName), if (u.phoneMasked != null) ('Celular', u.phoneMasked!)],
      submitLabel: 'Confirmar y dar el rol',
      codeOnly: true,
    );
    if (c == null || !mounted) return;
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).grantStaff(u.id, _role, authMethod: c.serverMethod),
      success: '${u.fullName} ya es ${_role.label}. Entra al ${_role.panelTitle} con su celular.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return _search(_query.text, now: true);
    refreshOps(ref);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Agregar al equipo')),
    body: ListView(
      padding: bottomSafePadding(context, top: HySpacing.md),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Rol', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: HySpacing.xs),
              SegmentedButton<StaffRole>(
                key: const Key('team-role'),
                segments: const [
                  ButtonSegment(value: StaffRole.employee, label: Text('Empleado')),
                  ButtonSegment(value: StaffRole.manager, label: Text('Gerente')),
                ],
                selected: {_role},
                onSelectionChanged: (s) => setState(() => _role = s.first),
              ),
              const SizedBox(height: HySpacing.xs),
              Text(
                _role == StaffRole.manager
                    ? 'Gerente de Operaciones: ve y asigna todos los casos, revisa postulaciones. Sin dinero.'
                    : 'Empleado: solo los casos que le asignen. Sin dinero.',
                style: const TextStyle(color: HyColors.textSecondary),
              ),
              const SizedBox(height: HySpacing.md),
              TextField(
                key: const Key('team-search'),
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  labelText: 'Nombre o celular',
                  hintText: 'Ej.: Rosa Quispe o 71234567',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: _search,
                onSubmitted: (q) => _search(q, now: true),
              ),
              const SizedBox(height: HySpacing.xs),
              const Text(
                'La persona tiene que haber creado su cuenta con su celular. El rol se da a esa cuenta, no a un número.',
                style: TextStyle(color: HyColors.textSecondary),
              ),
              const SizedBox(height: HySpacing.sm),
              FutureBuilder<List<StaffCandidate>>(
                future: _results,
                builder: (context, snap) {
                  if (_results == null) return const SizedBox.shrink();
                  if (snap.connectionState != ConnectionState.done) return const LoadingView();
                  if (snap.hasError) {
                    return ErrorView(error: snap.error!, onRetry: () => _search(_query.text, now: true));
                  }
                  final list = snap.data!;
                  if (list.isEmpty) {
                    return EmptyState(
                      key: const Key('team-search-empty'),
                      icon: Icons.person_search_outlined,
                      title: _looksLikePhone(_searched)
                          ? 'No hay ninguna cuenta con ese celular'
                          : 'No encontramos cuentas con ese nombre',
                      message: _looksLikePhone(_searched)
                          ? 'Pídele a la persona que descargue HandiMan ¡Ya! y entre con su celular. '
                                'Cuando haya entrado, búscala de nuevo aquí.'
                          : 'Revisa el nombre o busca por su celular. La persona tiene que haber entrado a la app al menos una vez.',
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        list.length == 1 ? '1 cuenta encontrada' : '${list.length} cuentas encontradas',
                        style: const TextStyle(color: HyColors.textSecondary),
                      ),
                      const SizedBox(height: HySpacing.xs),
                      for (final u in list) _CandidateCard(candidate: u, busy: _busy, onPick: () => _pick(u)),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.candidate, required this.busy, required this.onPick});

  final StaffCandidate candidate;
  final bool busy;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final u = candidate;
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.xs),
      child: AppCard(
        key: Key('team-pick-${u.id}'),
        onTap: u.eligible && !busy ? onPick : null,
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: HyColors.primarySoft,
              child: Text(Fmt.initials(u.fullName), style: const TextStyle(color: HyColors.navy)),
            ),
            const SizedBox(width: HySpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(u.fullName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  Text(
                    [u.phoneMasked ?? 'Sin celular', ?u.cityName].join(' · '),
                    style: const TextStyle(color: HyColors.textSecondary),
                  ),
                  if (u.reasonLabel != null)
                    Padding(padding: const EdgeInsets.only(top: 4), child: ToneChip(u.reasonLabel!, StatusTone.neutral))
                  else if (u.wasStaff)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Antes estuvo en el equipo: se le dará el rol de nuevo.',
                        style: TextStyle(color: HyColors.textMuted, fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),
            if (u.eligible) const Icon(Icons.chevron_right, color: HyColors.textMuted),
          ],
        ),
      ),
    );
  }
}
