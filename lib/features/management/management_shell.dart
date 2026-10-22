import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/staff.dart';
import '../shell/app_shell.dart';
import 'management_common.dart';

const ownerNavItems = [
  NavItem('Resumen', Icons.space_dashboard_outlined, Icons.space_dashboard),
  NavItem('Gestión', Icons.business_center_outlined, Icons.business_center),
  NavItem('Centro IA', Icons.hub_outlined, Icons.hub),
  NavItem('Equipo', Icons.groups_outlined, Icons.groups),
  NavItem('Perfil', Icons.person_outline, Icons.person),
];

const managerNavItems = [
  NavItem('Resumen', Icons.space_dashboard_outlined, Icons.space_dashboard),
  NavItem('Casos', Icons.inbox_outlined, Icons.inbox),
  NavItem('Postulaciones', Icons.badge_outlined, Icons.badge),
  NavItem('Equipo', Icons.groups_outlined, Icons.groups),
  NavItem('Perfil', Icons.person_outline, Icons.person),
];

const employeeNavItems = [
  NavItem('Mis casos', Icons.inbox_outlined, Icons.inbox),
  NavItem('Actividad', Icons.history, Icons.history),
  NavItem('Perfil', Icons.person_outline, Icons.person),
];

List<NavItem> panelNavItems(StaffRole role) => switch (role) {
  StaffRole.owner => ownerNavItems,
  StaffRole.manager => managerNavItems,
  StaffRole.employee => employeeNavItems,
};

/// Panel de gestión: su propia barra de abajo, en azul marino, distinta de la
/// del cliente y la del profesional. Cada rol tiene sus pestañas.
class ManagementShell extends StatelessWidget {
  const ManagementShell({super.key, required this.role, required this.shell});

  final StaffRole role;
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => PopScope(
    // Igual que en la app del cliente: atrás en otra pestaña vuelve a la
    // primera; en la primera cierra la app.
    canPop: shell.currentIndex == 0,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) shell.goBranch(0);
    },
    child: Scaffold(
      body: shell,
      bottomNavigationBar: PanelBottomNav(
        role: role,
        currentIndex: shell.currentIndex,
        onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    ),
  );
}

class PanelBottomNav extends StatelessWidget {
  const PanelBottomNav({super.key, required this.role, required this.currentIndex, required this.onTap});

  final StaffRole role;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final items = panelNavItems(role);
    final media = MediaQuery.of(context);
    // Las etiquetas siempre en una línea: la letra sigue al sistema hasta 1,2x.
    final scale = media.textScaler.scale(1).clamp(1.0, 1.2);
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(scale)),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: HyColors.navy,
          surfaceTintColor: Colors.transparent,
          indicatorColor: panelAccent(role).withValues(alpha: 0.22),
          height: 68,
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
              color: states.contains(WidgetState.selected) ? Colors.white : const Color(0xFFB7C0D3),
            ),
          ),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 24,
              color: states.contains(WidgetState.selected) ? panelAccent(role) : const Color(0xFFB7C0D3),
            ),
          ),
        ),
        child: NavigationBar(
          key: Key('panel-nav-${role.key}'),
          selectedIndex: currentIndex,
          onDestinationSelected: onTap,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final i in items)
              NavigationDestination(
                key: Key('panel-nav-${i.label}'),
                tooltip: i.label,
                label: i.label,
                icon: Icon(i.icon),
                selectedIcon: Icon(i.selectedIcon),
              ),
          ],
        ),
      ),
    );
  }
}
