import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/drilldown.dart';
import '../../data/models/staff.dart';
import '../../data/providers.dart';
import '../../router.dart';
import 'management_common.dart';

/// Resumen del Panel del Gerente: solo operación, sin dinero. Los números
/// vienen de ops_dashboard, que no manda montos.
class ManagerHomePage extends ConsumerWidget {
  const ManagerHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(opsDashboardProvider);
    return Scaffold(
      appBar: const PanelAppBar(role: StaffRole.manager, title: 'Resumen'),
      body: RefreshIndicator(
        onRefresh: () async => refreshOps(ref),
        // Con datos, los títulos de sección quedan fijos arriba al desplazarse.
        child: switch (dash) {
          AsyncData(:final value) => _ManagerSummary(d: value),
          _ => ListView(
            padding: bottomSafePadding(context),
            children: [
              PageBody(
                child: switch (dash) {
                  AsyncError(:final error) => ErrorView(error: error, onRetry: () => refreshOps(ref)),
                  _ => const LoadingView(),
                },
              ),
            ],
          ),
        },
      ),
    );
  }
}

class _ManagerSummary extends StatelessWidget {
  const _ManagerSummary({required this.d});

  final OpsDashboard d;

  @override
  Widget build(BuildContext context) {
    void go(String route) => context.push(route);
    return PanelSections(
      key: const Key('manager-summary'),
      children: [
        const SectionHeader(title: 'Casos del equipo'),
        PanelGrid(
          children: [
            PanelStat(
              'Urgentes',
              d.urgentCases,
              tone: StatusTone.danger,
              onTap: () => go(Routes.staffCasesScope('urgent')),
            ),
            PanelStat(
              'Escalados',
              d.escalatedCases,
              tone: StatusTone.danger,
              onTap: () => go(Routes.staffCasesScope('escalated')),
            ),
            PanelStat(
              'Sin asignar',
              d.unassignedCases,
              tone: StatusTone.brand,
              onTap: () => go(Routes.staffCasesScope('unassigned')),
            ),
            PanelStat('Míos abiertos', d.myOpenCases, onTap: () => go(Routes.staffCasesScope('mine'))),
          ],
        ),
        const SectionHeader(title: 'Verificación de profesionales'),
        PanelGrid(
          children: [
            PanelStat(
              'Solicitudes pendientes',
              d.pendingApplications,
              tone: StatusTone.brand,
              onTap: () => go(Routes.adminApplications),
            ),
            PanelStat(
              'Revisar documentos',
              d.pendingDocuments,
              tone: StatusTone.brand,
              onTap: () => go(Routes.adminApplications),
            ),
            PanelStat('Documentos marcados', d.flaggedDocuments, tone: StatusTone.warning),
          ],
        ),
        const SectionHeader(title: 'Quejas, disputas y seguridad'),
        PanelGrid(
          children: [
            PanelStat('Soporte abierto', d.openTickets, tone: StatusTone.brand, onTap: () => go(Routes.adminTickets)),
            PanelStat(
              'Reportes abiertos',
              d.openReports,
              tone: StatusTone.warning,
              onTap: () => go(Routes.adminReports),
            ),
            PanelStat(
              'Disputas abiertas',
              d.openDisputes,
              tone: StatusTone.warning,
              onTap: () => go(Routes.adminDisputes),
            ),
          ],
        ),
        const SectionHeader(title: 'Trabajos y disponibilidad'),
        PanelGrid(
          children: [
            PanelStat(
              'Pedidos de hoy',
              d.bookingsToday,
              key: const Key('manager-stat-bookings-today'),
              onTap: () => go(Routes.opsBookingsFiltered(BookingFilter.today)),
            ),
            PanelStat(
              'Activos ahora',
              d.activeBookings,
              onTap: () => go(Routes.opsBookingsFiltered(BookingFilter.active)),
            ),
            PanelStat(
              'Completados hoy',
              d.completedToday,
              onTap: () => go(Routes.opsBookingsFiltered(BookingFilter.completedToday)),
            ),
            PanelStat(
              'Cancelados hoy',
              d.cancelledToday,
              tone: StatusTone.warning,
              onTap: () => go(Routes.opsBookingsFiltered(BookingFilter.cancelledToday)),
            ),
            PanelStat(
              'Profesionales disponibles',
              d.availableProfessionals,
              onTap: () => go(Routes.adminUsersFiltered(PeopleFilter.available)),
            ),
            PanelStat(
              'Profesionales',
              d.approvedProfessionals,
              onTap: () => go(Routes.adminUsersFiltered(PeopleFilter.professionals)),
            ),
          ],
        ),
        const SectionHeader(title: 'Más tareas'),
        PanelTile(
          icon: Icons.people_outline,
          title: 'Usuarios',
          subtitle: 'Buscar y suspender clientes o profesionales',
          onTap: () => go(Routes.adminUsers),
        ),
        const SizedBox(height: HySpacing.xs),
        const InfoBanner(text: 'Este panel no muestra dinero. Lo que necesite al propietario, escálalo desde el caso.'),
      ],
    );
  }
}

/// Actividad del empleado: lo que hizo, según la auditoría.
class EmployeeActivityPage extends ConsumerWidget {
  const EmployeeActivityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(opsDashboardProvider);
    final activity = ref.watch(myStaffActivityProvider);
    return Scaffold(
      appBar: const PanelAppBar(role: StaffRole.employee, title: 'Actividad'),
      body: RefreshIndicator(
        onRefresh: () async => refreshOps(ref),
        child: ListView(
          padding: bottomSafePadding(context),
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: HySpacing.md),
                  PanelGrid(
                    children: [
                      PanelStat('Casos abiertos', dash.value?.myOpenCases),
                      PanelStat('Escalados', dash.value?.myEscalated, tone: StatusTone.warning),
                      PanelStat('Resueltos en 7 días', dash.value?.myResolved7d),
                    ],
                  ),
                  const SectionHeader(title: 'Lo último que hiciste'),
                  switch (activity) {
                    AsyncData(:final value) when value.isEmpty => const EmptyState(
                      key: Key('activity-empty'),
                      icon: Icons.history,
                      title: 'Sin actividad todavía',
                      message: 'Aquí verás tus respuestas, notas y casos resueltos.',
                    ),
                    AsyncData(:final value) => Column(
                      children: [
                        for (final a in value)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.history, color: HyColors.navy),
                            title: Text(a.label),
                            subtitle: Text(Fmt.dateTime(a.createdAt)),
                          ),
                      ],
                    ),
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

/// Perfil del equipo: identidad, seguridad, permisos y salida. Cada rol ve sus
/// permisos y lo que no puede hacer; el servidor los vuelve a revisar.
class StaffProfilePage extends ConsumerWidget {
  const StaffProfilePage({super.key, required this.role});

  final StaffRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).value;
    final access = ref.watch(myStaffAccessProvider);
    if (account == null) return const Scaffold(body: LoadingView());
    final text = Theme.of(context).textTheme;
    final restrictions = staffRestrictions[role] ?? const [];
    return Scaffold(
      appBar: PanelAppBar(role: role, title: 'Perfil'),
      body: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.md),
                AppCard(
                  key: Key('staff-profile-${role.key}'),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: HyColors.navy,
                        child: Text(
                          Fmt.initials(account.fullName),
                          style: TextStyle(color: panelAccent(role), fontWeight: FontWeight.w900, fontSize: 20),
                        ),
                      ),
                      const SizedBox(width: HySpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(account.fullName, style: text.titleLarge),
                            if (account.phone != null)
                              Text(account.phone!, style: const TextStyle(color: HyColors.textSecondary)),
                            if (account.email.isNotEmpty)
                              Text(account.email, style: const TextStyle(color: HyColors.textSecondary)),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: panelAccent(role).withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(HyRadii.pill),
                              ),
                              child: Text(
                                role.label,
                                style: const TextStyle(color: HyColors.navy, fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionHeader(title: 'Cuenta y seguridad'),
                _Row(
                  icon: Icons.edit_outlined,
                  title: 'Información personal',
                  subtitle: 'Nombre, ciudad, celular y correo',
                  onTap: () => context.push(Routes.editProfile),
                ),
                _Row(
                  icon: Icons.shield_outlined,
                  title: 'Seguridad de la cuenta',
                  subtitle: 'Huella, rostro y confirmación de operaciones',
                  onTap: () => context.push(Routes.security),
                ),
                _Row(
                  icon: Icons.notifications_none_rounded,
                  title: 'Notificaciones',
                  onTap: () => context.push(Routes.notifications),
                ),
                if (role == StaffRole.owner) ...[
                  const SectionHeader(title: 'Ajustes de la plataforma'),
                  _Row(
                    icon: Icons.percent,
                    title: 'Comisiones',
                    subtitle: 'Reglas y saldo mínimo',
                    onTap: () => context.push(Routes.adminCommissions),
                  ),
                  _Row(
                    icon: Icons.savings_outlined,
                    title: 'Costos y servicios pagados',
                    onTap: () => context.push(Routes.adminCosts),
                  ),
                  _Row(
                    icon: Icons.category_outlined,
                    title: 'Catálogo y ciudades',
                    onTap: () => context.push(Routes.adminCatalog),
                  ),
                  _Row(
                    icon: Icons.history,
                    title: 'Auditoría',
                    subtitle: 'Quién cambió qué',
                    onTap: () => context.push(Routes.adminAudit),
                  ),
                ],
                const SectionHeader(title: 'Mis permisos'),
                if (role == StaffRole.owner)
                  const Text(
                    'Control total del negocio, el dinero, la seguridad y la plataforma. '
                    'Solo tú das o quitas roles al equipo.',
                    key: Key('owner-permissions'),
                  )
                else
                  switch (access) {
                    AsyncData(:final value) => Column(
                      key: const Key('staff-permissions'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final p in staffPermissionLabels.entries)
                          if (value.permissions.contains(p.key)) _Perm(p.value, allowed: true),
                      ],
                    ),
                    AsyncError(:final error) => ErrorView(
                      error: error,
                      onRetry: () => ref.invalidate(myStaffAccessProvider),
                    ),
                    _ => const LoadingView(),
                  },
                if (restrictions.isNotEmpty) ...[
                  const SectionHeader(title: 'No puedes'),
                  Column(
                    key: const Key('staff-restrictions'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final r in restrictions) _Perm(r, allowed: false)],
                  ),
                ],
                const SectionHeader(title: 'Ver la app'),
                AppCard(
                  key: const Key('switch-to-customer'),
                  onTap: () {
                    ref.read(managementCustomerModeProvider.notifier).set(true);
                    context.go(Routes.home);
                  },
                  child: const Row(
                    children: [
                      Icon(Icons.person_outline, color: HyColors.navy, size: 28),
                      SizedBox(width: HySpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Cambiar a modo cliente', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                            Text(
                              'Ves la app como un cliente. Vuelves con "Volver al panel" en tu perfil.',
                              style: TextStyle(color: HyColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right),
                    ],
                  ),
                ),
                const SizedBox(height: HySpacing.lg),
                OutlinedButton.icon(
                  key: const Key('staff-sign-out'),
                  onPressed: () async {
                    final ok = await confirmDialog(
                      context,
                      title: '¿Cerrar sesión?',
                      message: 'Podrás volver a entrar con tu número de celular y un código.',
                      confirm: 'Cerrar sesión',
                    );
                    if (ok && context.mounted) await runGuarded(context, () => ref.read(backendProvider).signOut());
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Cerrar sesión'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    minVerticalPadding: 12,
    leading: Icon(icon, color: HyColors.navy),
    title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _Perm extends StatelessWidget {
  const _Perm(this.text, {required this.allowed});

  final String text;
  final bool allowed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          allowed ? Icons.check_circle_outline : Icons.block,
          size: 20,
          color: allowed ? HyColors.green : HyColors.danger,
        ),
        const SizedBox(width: HySpacing.xs),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
