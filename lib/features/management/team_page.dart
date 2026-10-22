import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/models/booking.dart';
import '../../data/models/user.dart';
import '../../data/models/staff.dart';
import '../../data/providers.dart';
import '../admin/admin_common.dart';
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
      message: 'Vuelve a tener su rol de ${m.role.label} con los mismos permisos.',
      confirm: 'Reactivar',
    )) {
      return;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).setStaffStatus(m.userId, status, reason: reason),
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
              onPressed: () => showAddStaffSheet(context, ref),
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
                      Text(m.role.label, style: const TextStyle(color: HyColors.textSecondary)),
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

/// Agregar a alguien al equipo: buscar su cuenta (ya tiene que haber entrado
/// con su celular), elegir el rol y confirmar viendo el id de la cuenta.
Future<void> showAddStaffSheet(BuildContext context, WidgetRef ref) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const _AddStaffSheet(),
);

class _AddStaffSheet extends ConsumerStatefulWidget {
  const _AddStaffSheet();

  @override
  ConsumerState<_AddStaffSheet> createState() => _AddStaffSheetState();
}

class _AddStaffSheetState extends ConsumerState<_AddStaffSheet> {
  final _query = TextEditingController();
  Timer? _debounce;
  Future<List<AdminUser>>? _results;
  StaffRole _role = StaffRole.employee;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _results = q.trim().length < 2 ? null : ref.read(backendProvider).adminUsers(q.trim()));
    });
  }

  Future<void> _pick(AdminUser u) async {
    if (!await confirmDialog(
      context,
      title: '¿Dar el rol de ${_role.label}?',
      message:
          '${u.fullName}\n'
          'Celular: ${u.phone ?? 'sin celular'}\n'
          'ID de la cuenta: ${u.id}\n\n'
          'Revisa que sea la persona correcta. Podrá entrar al ${_role.panelTitle} con su celular.',
      confirm: 'Dar el rol',
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).grantStaff(u.id, _role),
      success: '${u.fullName} ya es ${_role.label}.',
    );
    if (!ok || !mounted) return;
    refreshOps(ref);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      HySpacing.page,
      HySpacing.md,
      HySpacing.page,
      HySpacing.md + sheetBottomInset(context),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Agregar al equipo', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: HySpacing.sm),
        SegmentedButton<StaffRole>(
          segments: const [
            ButtonSegment(value: StaffRole.employee, label: Text('Empleado')),
            ButtonSegment(value: StaffRole.manager, label: Text('Gerente')),
          ],
          selected: {_role},
          onSelectionChanged: (s) => setState(() => _role = s.first),
        ),
        const SizedBox(height: HySpacing.sm),
        TextField(
          key: const Key('team-search'),
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(labelText: 'Nombre o celular', prefixIcon: Icon(Icons.search)),
          onChanged: _search,
        ),
        const SizedBox(height: HySpacing.xs),
        const Text(
          'La persona tiene que haber creado su cuenta con su celular. No se asigna un rol por número de teléfono.',
          style: TextStyle(color: HyColors.textSecondary),
        ),
        const SizedBox(height: HySpacing.xs),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
          child: FutureBuilder<List<AdminUser>>(
            future: _results,
            builder: (context, snap) {
              if (_results == null) return const SizedBox.shrink();
              if (snap.connectionState != ConnectionState.done) return const LoadingView();
              if (snap.hasError) return ErrorView(error: snap.error!, onRetry: () => _search(_query.text));
              final list = snap.data!
                  .where((u) => !u.isAdmin && u.roles.contains(AppRole.customer) && !u.isSuspended)
                  .toList();
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(HySpacing.sm),
                  child: Text('Ninguna cuenta disponible con ese nombre o celular.'),
                );
              }
              return ListView(
                shrinkWrap: true,
                children: [
                  for (final u in list)
                    ListTile(
                      key: Key('team-pick-${u.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(u.fullName),
                      subtitle: Text([?u.phone, ?u.cityName].join(' · ')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pick(u),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
