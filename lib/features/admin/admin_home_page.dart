import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/models/booking.dart';
import '../../data/models/staff.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../management/management_common.dart';
import 'admin_common.dart';

/// Resumen del Panel del Propietario. Solo lo ve el propietario; además, el
/// servidor (owner_dashboard) rechaza a cualquier otra cuenta. Cada número sale
/// de la base: sin el dato dice "—", nunca un número inventado.
class AdminHomePage extends ConsumerWidget {
  const AdminHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(adminDashboardProvider);
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;
    return Scaffold(
      appBar: PanelAppBar(
        role: StaffRole.owner,
        title: 'Resumen',
        actions: [
          IconButton(
            key: const Key('owner-notifications'),
            tooltip: unread > 0 ? 'Notificaciones ($unread sin leer)' : 'Notificaciones',
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_none),
            ),
            onPressed: () => context.push(Routes.notifications),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          refreshOps(ref);
          return ref.refresh(adminDashboardProvider.future);
        },
        child: ListView(
          padding: bottomSafePadding(context),
          children: [
            PageBody(
              child: switch (dash) {
                AsyncData(:final value) => _Summary(d: value),
                AsyncError(:final error) => ErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(adminDashboardProvider),
                ),
                _ => const LoadingView(),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.d});

  final AdminDashboard d;

  String? _bs(double? v) => v == null ? null : Fmt.bs(v);

  @override
  Widget build(BuildContext context) {
    void go(String route) => context.push(route);
    return Column(
      key: const Key('owner-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: HySpacing.md),
        if (!d.isOwnerView) ...[
          const InfoBanner(
            key: Key('owner-dashboard-partial'),
            icon: Icons.hourglass_empty,
            tone: StatusTone.warning,
            text:
                'El servidor todavía no tiene el panel completo (falta aplicar su actualización). '
                'Los números con "—" aparecerán cuando esté aplicada.',
          ),
          const SizedBox(height: HySpacing.sm),
        ],
        if (d.activeCommissionRules == 0) ...[
          const InfoBanner(
            icon: Icons.warning_amber_rounded,
            tone: StatusTone.warning,
            text: 'No hay reglas de comisión activas: no se cobra comisión a los profesionales hasta que crees una.',
          ),
          const SizedBox(height: HySpacing.sm),
        ],
        if (d.identitySandboxOnly ?? false) ...[
          InfoBanner(
            key: const Key('owner-identity-sandbox'),
            icon: Icons.verified_user_outlined,
            tone: StatusTone.warning,
            text:
                'La verificación de identidad está solo en pruebas (sandbox). '
                'Una prueba no cuenta como verificación real. '
                '${(d.identityRequired ?? false) ? 'Está exigida para aprobar.' : 'Hoy no se exige para aprobar.'}',
          ),
          const SizedBox(height: HySpacing.sm),
        ],
        if ((d.paidVendors ?? 0) > 0) ...[
          InfoBanner(
            icon: Icons.payments_outlined,
            tone: StatusTone.warning,
            text: '${d.paidVendors} servicio(s) con cobro autorizado. Revisa Costos del mes.',
          ),
          const SizedBox(height: HySpacing.sm),
        ],
        const SectionHeader(title: 'Pedidos de hoy'),
        PanelGrid(
          children: [
            PanelStat('Pedidos de hoy', d.bookingsToday),
            PanelStat('Activos ahora', d.activeBookings),
            PanelStat('Completados hoy', d.completedToday),
            PanelStat('Cancelados hoy', d.cancelledToday, tone: StatusTone.warning),
          ],
        ),
        const SectionHeader(title: 'Atención urgente'),
        PanelGrid(
          children: [
            PanelStat('Casos urgentes', d.urgentCases, tone: StatusTone.danger, onTap: () => go(Routes.staffCases)),
            PanelStat(
              'Escalados a ti',
              d.escalatedToOwner,
              tone: StatusTone.danger,
              onTap: () => go(Routes.staffCases),
            ),
            PanelStat(
              'Incidentes de seguridad',
              d.safetyIncidents,
              tone: StatusTone.danger,
              onTap: () => go(Routes.adminReports),
            ),
            PanelStat(
              'Alertas de fraude',
              d.fraudAlerts,
              tone: StatusTone.danger,
              onTap: () => go(Routes.adminReports),
            ),
            PanelStat(
              'Disputas abiertas',
              d.openDisputes,
              tone: StatusTone.warning,
              onTap: () => go(Routes.adminDisputes),
            ),
            PanelStat('Soporte abierto', d.openTickets, tone: StatusTone.brand, onTap: () => go(Routes.adminTickets)),
          ],
        ),
        const SectionHeader(title: 'Personas y verificación'),
        PanelGrid(
          children: [
            PanelStat('Clientes', d.customers),
            PanelStat('Profesionales aprobados', d.approvedProfessionals),
            PanelStat('Disponibles ahora', d.availableProfessionals),
            PanelStat(
              'Postulaciones pendientes',
              d.pendingApplications,
              tone: StatusTone.brand,
              onTap: () => go(Routes.adminApplications),
            ),
            PanelStat(
              'Documentos por revisar',
              d.pendingDocuments,
              tone: StatusTone.brand,
              onTap: () => go(Routes.adminApplications),
            ),
            PanelStat('Identidad en revisión', d.identityInReview, tone: StatusTone.brand),
          ],
        ),
        const SectionHeader(title: 'Dinero (solo propietario)'),
        PanelGrid(
          minTileWidth: 170,
          children: [
            PanelStat('Pagado por trabajos este mes', null, display: _bs(d.revenueMonth)),
            PanelStat('Comisión cobrada este mes', null, display: _bs(d.commissionMonth)),
            PanelStat('Saldos disponibles', null, display: _bs(d.walletAvailable)),
            PanelStat('Saldos reservados', null, display: _bs(d.walletReserved)),
            PanelStat(
              'Recargas pendientes${d.pendingTopupsAmount != null ? ' (${Fmt.bs(d.pendingTopupsAmount!)})' : ''}',
              d.pendingTopups,
              tone: StatusTone.brand,
              onTap: () => go(Routes.adminTopups),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: HySpacing.xs),
          child: Text(
            'Lo pagado por trabajos lo recibe el profesional; la plataforma cobra solo la comisión.',
            style: TextStyle(color: HyColors.textSecondary),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('owner-summary-finance'),
            onPressed: () => go(Routes.adminFinance),
            icon: const Icon(Icons.account_balance_outlined),
            label: const Text('Ver Finanzas y Bancos'),
          ),
        ),
        const SectionHeader(title: 'Demanda de los últimos 30 días'),
        _DemandCard(
          key: const Key('owner-demand-municipality'),
          title: 'Por municipio',
          rows: d.demandMunicipality,
          available: d.hasDemand,
          detail: (r) => [?r.department, if (r.professionals != null) '${r.professionals} profesionales'].join(' · '),
        ),
        _DemandCard(title: 'Por departamento', rows: d.demandDepartment, available: d.hasDemand),
        _DemandCard(title: 'Por categoría', rows: d.demandCategory, available: d.hasDemand),
        _DemandCard(
          key: const Key('owner-coverage-gaps'),
          title: 'Sin cobertura',
          subtitle: 'Municipios con pedidos y ningún profesional aprobado con base allí',
          rows: d.coverageGaps,
          available: d.hasDemand,
          empty: 'Ningún municipio con pedidos se quedó sin profesionales.',
          detail: (r) => r.department ?? '',
        ),
        const SectionHeader(title: 'Equipo, Centro IA y control'),
        PanelGrid(
          children: [
            PanelStat('Gerentes activos', d.activeManagers),
            PanelStat('Empleados activos', d.activeEmployees),
            PanelStat(
              'Casos sin asignar',
              d.unassignedCases,
              tone: StatusTone.brand,
              onTap: () => go(Routes.staffCases),
            ),
            PanelStat('Pendientes del Centro IA', d.aiPending, tone: StatusTone.brand, onTap: () => go(Routes.adminAi)),
            PanelStat(
              'Alertas IA altas o críticas',
              d.aiCritical,
              tone: StatusTone.danger,
              onTap: () => go(Routes.adminAi),
            ),
            PanelStat(
              'Costos del mes',
              null,
              display: d.costsMonthUsd == null ? null : 'US\$ ${d.costsMonthUsd!.toStringAsFixed(2)}',
              onTap: () => go(Routes.adminCosts),
            ),
            PanelStat('Avisos sin leer', d.unreadNotifications, onTap: () => go(Routes.notifications)),
            PanelStat('Cambios auditados (24 h)', d.audit24h, onTap: () => go(Routes.adminAudit)),
          ],
        ),
      ],
    );
  }
}

class _DemandCard extends StatelessWidget {
  const _DemandCard({
    super.key,
    required this.title,
    required this.rows,
    required this.available,
    this.subtitle,
    this.detail,
    this.empty = 'Sin pedidos en los últimos 30 días.',
  });

  final String title;
  final String? subtitle;
  final List<DemandRow> rows;
  final bool available;
  final String Function(DemandRow)? detail;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final max = rows.fold<int>(1, (m, r) => r.count > m ? r.count : m);
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.xs),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            if (subtitle != null) Text(subtitle!, style: const TextStyle(color: HyColors.textSecondary)),
            const SizedBox(height: HySpacing.xs),
            if (!available)
              const Text('Sin datos del servidor todavía.', style: TextStyle(color: HyColors.textSecondary))
            else if (rows.isEmpty)
              Text(empty, style: const TextStyle(color: HyColors.textSecondary))
            else
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          Text('${r.count}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        ],
                      ),
                      if (detail != null && detail!(r).isNotEmpty)
                        Text(detail!(r), style: const TextStyle(color: HyColors.textSecondary, fontSize: 13)),
                      const SizedBox(height: 2),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(HyRadii.pill),
                        child: LinearProgressIndicator(
                          value: r.count / max,
                          minHeight: 6,
                          backgroundColor: HyColors.primarySoft,
                          color: HyColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// Gestión del Panel del Propietario: todas las tareas de administración.
class OwnerManagePage extends ConsumerWidget {
  const OwnerManagePage({super.key});

  // Excepción: el cliente no puede escribir el código de llegada (sin batería,
  // sin la app) y llama a soporte. Queda en la auditoría con el motivo.
  Future<void> _verifyArrival(BuildContext context, WidgetRef ref) async {
    final code = await promptText(
      context,
      title: 'Verificar una llegada',
      label: 'Código del pedido',
      confirm: 'Siguiente',
      hint: 'Por ejemplo A1B2C3D4',
      minLength: 4,
    );
    if (code == null || !context.mounted) return;
    final reason = await promptText(
      context,
      title: 'Verificar una llegada',
      label: 'Motivo',
      confirm: 'Verificar llegada',
      hint: 'Cómo confirmaste que llegó la persona correcta',
      minLength: 5,
    );
    if (reason == null || !context.mounted) return;
    await runGuarded(
      context,
      () => ref.read(backendProvider).adminVerifyArrival(code, reason),
      success: 'Llegada verificada. Quedó en la auditoría.',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(adminDashboardProvider).value;
    void go(String route) => context.push(route);
    return Scaffold(
      appBar: const PanelAppBar(role: StaffRole.owner, title: 'Gestión'),
      body: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(title: 'Operación'),
                PanelTile(
                  icon: Icons.inbox_outlined,
                  title: 'Casos del equipo',
                  subtitle: 'Asignar, revisar y resolver',
                  count: d?.escalatedToOwner,
                  onTap: () => go(Routes.staffCases),
                ),
                PanelTile(
                  icon: Icons.badge_outlined,
                  title: 'Postulaciones',
                  subtitle: 'Verificar profesionales',
                  count: d?.pendingApplications,
                  onTap: () => go(Routes.adminApplications),
                ),
                PanelTile(
                  icon: Icons.flag_outlined,
                  title: 'Reportes',
                  subtitle: 'Quejas entre usuarios',
                  count: d?.openReports,
                  onTap: () => go(Routes.adminReports),
                ),
                PanelTile(
                  icon: Icons.gavel_outlined,
                  title: 'Disputas',
                  subtitle: 'Trabajos en conflicto',
                  count: d?.openDisputes,
                  onTap: () => go(Routes.adminDisputes),
                ),
                PanelTile(
                  icon: Icons.support_agent_outlined,
                  title: 'Soporte',
                  subtitle: 'Mensajes de usuarios',
                  count: d?.openTickets,
                  onTap: () => go(Routes.adminTickets),
                ),
                PanelTile(
                  icon: Icons.people_outline,
                  title: 'Usuarios',
                  subtitle: 'Buscar y suspender',
                  onTap: () => go(Routes.adminUsers),
                ),
                const SectionHeader(title: 'Dinero y costos'),
                PanelTile(
                  key: const Key('owner-finance'),
                  icon: Icons.account_balance_outlined,
                  title: 'Finanzas y Bancos',
                  subtitle: 'Comisiones, billeteras, cuentas de cobro y conciliación',
                  onTap: () => go(Routes.adminFinance),
                ),
                PanelTile(
                  icon: Icons.account_balance_wallet_outlined,
                  title: 'Recargas',
                  subtitle: 'Revisar comprobantes',
                  count: d?.pendingTopups,
                  onTap: () => go(Routes.adminTopups),
                ),
                PanelTile(
                  icon: Icons.percent,
                  title: 'Comisiones',
                  subtitle: 'Reglas y saldo mínimo',
                  onTap: () => go(Routes.adminCommissions),
                ),
                PanelTile(
                  icon: Icons.savings_outlined,
                  title: 'Costos del mes',
                  subtitle: 'Planes gratis, cargos y alertas',
                  onTap: () => go(Routes.adminCosts),
                ),
                const SectionHeader(title: 'Plataforma'),
                PanelTile(
                  icon: Icons.category_outlined,
                  title: 'Catálogo',
                  subtitle: 'Categorías, ciudades y banners',
                  onTap: () => go(Routes.adminCatalog),
                ),
                PanelTile(
                  icon: Icons.history,
                  title: 'Auditoría',
                  subtitle: 'Quién cambió qué',
                  onTap: () => go(Routes.adminAudit),
                ),
                AppCard(
                  key: const Key('admin-verify-arrival'),
                  onTap: () => _verifyArrival(context, ref),
                  child: const Row(
                    children: [
                      Icon(Icons.pin_outlined, color: HyColors.primaryDark, size: 32),
                      SizedBox(width: HySpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Verificar una llegada', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                            Text(
                              'Solo si el cliente no puede escribir el código',
                              style: TextStyle(color: HyColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
