import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/models/booking.dart';
import '../../router.dart';
import 'admin_common.dart';

/// Inicio del panel de administración. Solo lo ven administradores; además,
/// el servidor rechaza cualquier acción de quien no lo sea.
class AdminHomePage extends ConsumerWidget {
  const AdminHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(adminDashboardProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel de administración'),
        actions: [
          IconButton(
            tooltip: 'Ir a la app',
            icon: const Icon(Icons.home_outlined),
            onPressed: () => context.go(Routes.home),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(adminDashboardProvider.future),
        child: ListView(
          padding: const EdgeInsets.only(bottom: HySpacing.xxl),
          children: [
            PageBody(
              child: switch (dash) {
                AsyncData(:final value) => _Body(d: value),
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

class _Body extends StatelessWidget {
  const _Body({required this.d});

  final AdminDashboard d;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Tile(Icons.hub_outlined, 'Centro de Control IA', 'Agentes, decisiones y reporte diario', null, Routes.adminAi),
      _Tile(
        Icons.badge_outlined,
        'Postulaciones',
        'Verificar profesionales',
        d.pendingApplications,
        Routes.adminApplications,
      ),
      _Tile(
        Icons.account_balance_wallet_outlined,
        'Recargas',
        'Revisar comprobantes',
        d.pendingTopups,
        Routes.adminTopups,
      ),
      _Tile(Icons.flag_outlined, 'Reportes', 'Quejas entre usuarios', d.openReports, Routes.adminReports),
      _Tile(Icons.gavel_outlined, 'Disputas', 'Trabajos en conflicto', d.openDisputes, Routes.adminDisputes),
      _Tile(Icons.support_agent_outlined, 'Soporte', 'Mensajes de usuarios', d.openTickets, Routes.adminTickets),
      _Tile(Icons.people_outline, 'Usuarios', 'Buscar y suspender', null, Routes.adminUsers),
      _Tile(Icons.percent, 'Comisiones', 'Reglas y saldo mínimo', null, Routes.adminCommissions),
      _Tile(Icons.category_outlined, 'Catálogo', 'Categorías, ciudades y banners', null, Routes.adminCatalog),
      _Tile(Icons.history, 'Auditoría', 'Quién cambió qué', null, Routes.adminAudit),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: HySpacing.md),
        if (d.activeCommissionRules == 0) ...[
          const InfoBanner(
            icon: Icons.warning_amber_rounded,
            tone: StatusTone.warning,
            text: 'No hay reglas de comisión activas: no se cobra comisión a los profesionales hasta que crees una.',
          ),
          const SizedBox(height: HySpacing.md),
        ],
        Wrap(
          spacing: HySpacing.sm,
          runSpacing: HySpacing.sm,
          children: [
            _Stat('Pedidos de hoy', d.bookingsToday),
            _Stat('Pedidos activos', d.activeBookings),
            _Stat('Profesionales aprobados', d.approvedProfessionals),
            _Stat('Disponibles ahora', d.availableProfessionals),
            _Stat('Usuarios', d.users),
          ],
        ),
        const SectionHeader(title: 'Tareas'),
        for (final t in tiles)
          Padding(
            padding: const EdgeInsets.only(bottom: HySpacing.xs),
            child: AppCard(
              onTap: () => context.push(t.route),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: HyColors.primarySoft,
                      borderRadius: BorderRadius.circular(HyRadii.md),
                    ),
                    child: Icon(t.icon, color: HyColors.primaryDark),
                  ),
                  const SizedBox(width: HySpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        Text(t.subtitle, style: const TextStyle(color: HyColors.textSecondary)),
                      ],
                    ),
                  ),
                  if (t.count != null && t.count! > 0)
                    Semantics(
                      label: '${t.count} pendientes',
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: HyColors.primary,
                          borderRadius: BorderRadius.circular(HyRadii.pill),
                        ),
                        child: Text(
                          '${t.count}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                      ),
                    ),
                  const Icon(Icons.chevron_right, color: HyColors.textMuted),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Tile {
  const _Tile(this.icon, this.title, this.subtitle, this.count, this.route);

  final IconData icon;
  final String title;
  final String subtitle;
  final int? count;
  final String route;
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 140),
    child: AppCard(
      padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: HyColors.navy),
          ),
          Text(label, style: const TextStyle(color: HyColors.textSecondary)),
        ],
      ),
    ),
  );
}
