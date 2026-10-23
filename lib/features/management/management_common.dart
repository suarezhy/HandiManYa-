import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/staff.dart';
import '../../data/providers.dart';

final myStaffAccessProvider = FutureProvider<StaffAccess>((ref) {
  ref.watch(accountProvider.select((a) => (a.value?.id, a.value?.managementRole)));
  return ref.watch(backendProvider).myStaffAccess();
});

final opsDashboardProvider = FutureProvider<OpsDashboard>((ref) => ref.watch(backendProvider).opsDashboard());

final opsCasesProvider = FutureProvider.family<List<OpsCase>, (String, bool)>(
  (ref, a) => ref.watch(backendProvider).opsCases(scope: a.$1, includeResolved: a.$2),
);

final opsCaseDetailProvider = FutureProvider.family<OpsCaseDetail, int>(
  (ref, id) => ref.watch(backendProvider).opsCaseDetail(id),
);

final staffOverviewProvider = FutureProvider<List<StaffMember>>((ref) => ref.watch(backendProvider).staffOverview());

final myStaffActivityProvider = FutureProvider<List<StaffActivity>>(
  (ref) => ref.watch(backendProvider).myStaffActivity(),
);

/// Probar la app como cliente sin dejar de ser del equipo. Dura la sesión.
final managementCustomerModeProvider = NotifierProvider<_CustomerMode, bool>(_CustomerMode.new);

class _CustomerMode extends Notifier<bool> {
  @override
  bool build() {
    // Al cambiar de cuenta se vuelve al panel.
    ref.watch(authUserProvider.select((u) => u.value?.id));
    return false;
  }

  void set(bool value) => state = value;
}

/// Color de acento de cada panel, dentro de la marca (azul marino, blanco y
/// naranja): el propietario en naranja, el gerente en verde y el empleado en
/// azul, para que nunca se confundan.
Color panelAccent(StaffRole role) => switch (role) {
  StaffRole.owner => HyColors.primary,
  StaffRole.manager => HyColors.green,
  StaffRole.employee => const Color(0xFF4F8FE0),
};

/// Encabezado de los paneles: azul marino con el nombre del panel.
class PanelAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PanelAppBar({super.key, required this.role, required this.title, this.actions = const []});

  final StaffRole role;
  final String title;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 22);

  @override
  Widget build(BuildContext context) => AppBar(
    backgroundColor: HyColors.navy,
    foregroundColor: Colors.white,
    toolbarHeight: kToolbarHeight + 22,
    titleSpacing: HySpacing.page,
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: panelAccent(role), shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                role.panelTitle.toUpperCase(),
                key: Key('panel-title-${role.key}'),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w800,
                  color: panelAccent(role),
                ),
              ),
            ),
          ],
        ),
        Text(
          title,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white),
        ),
      ],
    ),
    actions: actions,
  );
}

/// Un número del panel, con su etiqueta. Sin datos, lo dice.
class PanelStat extends StatelessWidget {
  const PanelStat(this.label, this.value, {super.key, this.tone, this.onTap, this.display, this.detail});

  final String label;
  final int? value;
  final StatusTone? tone;
  final VoidCallback? onTap;

  /// Texto en lugar del número (por ejemplo un monto en Bs). Null y sin
  /// [value]: "—", sin datos.
  final String? display;

  /// Una línea chica debajo del nombre (por ejemplo "3 billeteras"), para que
  /// el nombre no se corte.
  final String? detail;

  @override
  Widget build(BuildContext context) => AppCard(
    onTap: onTap,
    padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Un monto nunca se corta: se achica para entrar entero.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  display ?? (value == null ? '—' : '$value'),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: display != null ? 21 : 26,
                    fontWeight: FontWeight.w900,
                    color: tone != null && (value ?? 0) > 0 ? tone!.foreground : HyColors.navy,
                  ),
                ),
              ),
              Text(
                label,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: HyColors.textSecondary),
              ),
              if (detail != null)
                Text(
                  detail!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
                ),
            ],
          ),
        ),
        // Se ve que se puede tocar (en Build 13 las tarjetas parecían fijas).
        if (onTap != null) const Icon(Icons.chevron_right, size: 20, color: HyColors.textMuted),
      ],
    ),
  );
}

/// Cuadrícula que se adapta al ancho: 2 columnas en el teléfono, más en la
/// tableta.
class PanelGrid extends StatelessWidget {
  const PanelGrid({super.key, required this.children, this.minTileWidth = 150});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      // En un teléfono de 320 px va una por fila, para que ningún texto se corte.
      final columns = (box.maxWidth / minTileWidth).floor().clamp(1, 5);
      final width = (box.maxWidth - HySpacing.sm * (columns - 1)) / columns;
      return Wrap(
        spacing: HySpacing.sm,
        runSpacing: HySpacing.sm,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}

/// Una tarea del panel: ícono, título, explicación y pendientes.
class PanelTile extends StatelessWidget {
  const PanelTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.count,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.xs),
    child: AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: HyColors.primarySoft, borderRadius: BorderRadius.circular(HyRadii.md)),
            child: Icon(icon, color: HyColors.primaryDark),
          ),
          const SizedBox(width: HySpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                Text(subtitle, style: const TextStyle(color: HyColors.textSecondary)),
              ],
            ),
          ),
          if (count != null && count! > 0)
            Semantics(
              label: '$count pendientes',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: HyColors.primary, borderRadius: BorderRadius.circular(HyRadii.pill)),
                child: Text(
                  '$count',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ),
          const Icon(Icons.chevron_right, color: HyColors.textMuted),
        ],
      ),
    ),
  );
}

StatusTone caseStatusTone(OpsCaseStatus s) => switch (s) {
  OpsCaseStatus.open => StatusTone.brand,
  OpsCaseStatus.inProgress => StatusTone.info,
  OpsCaseStatus.waiting => StatusTone.neutral,
  OpsCaseStatus.escalated => StatusTone.danger,
  OpsCaseStatus.resolved => StatusTone.success,
};

IconData caseKindIcon(OpsCaseKind k) => switch (k) {
  OpsCaseKind.support => Icons.support_agent_outlined,
  OpsCaseKind.application => Icons.badge_outlined,
  OpsCaseKind.dispute => Icons.gavel_outlined,
  OpsCaseKind.report => Icons.flag_outlined,
  OpsCaseKind.booking => Icons.receipt_long_outlined,
};

/// Recarga todo lo del equipo después de una acción.
void refreshOps(WidgetRef ref) {
  ref
    ..invalidate(opsDashboardProvider)
    ..invalidate(opsCasesProvider)
    ..invalidate(opsCaseDetailProvider)
    ..invalidate(staffOverviewProvider)
    ..invalidate(myStaffActivityProvider);
}
