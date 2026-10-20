import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../data/providers.dart';

/// AppBottomNav: la única barra de navegación de la app. Cambia sus pestañas
/// según el modo (cliente o profesional) y conserva la pestaña elegida.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell, required this.professional});

  final StatefulNavigationShell shell;
  final bool professional;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const _SuspendedBanner(),
          Expanded(child: shell),
        ],
      ),
      bottomNavigationBar: AppBottomNav(
        currentIndex: shell.currentIndex,
        professional: professional,
        onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}

/// Aviso fijo cuando la cuenta está suspendida, con el motivo.
class _SuspendedBanner extends ConsumerWidget {
  const _SuspendedBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).value;
    if (account == null || !account.isSuspended) return const SizedBox.shrink();
    return Material(
      color: HyColors.danger,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HySpacing.page, vertical: HySpacing.sm),
          child: Row(
            children: [
              const Icon(Icons.block, color: Colors.white),
              const SizedBox(width: HySpacing.xs),
              Expanded(
                child: Text(
                  'Tu cuenta está suspendida${account.suspensionReason == null ? '' : ': ${account.suspensionReason}'}. '
                  'Puedes escribirnos desde Perfil > Ayuda.',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NavItem {
  const NavItem(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const customerNavItems = [
  NavItem('Inicio', Icons.home_outlined, Icons.home_rounded),
  NavItem('Buscar', Icons.search, Icons.search),
  NavItem('Solicitudes', Icons.receipt_long_outlined, Icons.receipt_long),
  NavItem('Mensajes', Icons.chat_bubble_outline, Icons.chat_bubble),
  NavItem('Perfil', Icons.person_outline, Icons.person),
];

const professionalNavItems = [
  NavItem('Inicio', Icons.dashboard_outlined, Icons.dashboard),
  NavItem('Solicitudes', Icons.notifications_active_outlined, Icons.notifications_active),
  NavItem('Trabajos', Icons.work_outline, Icons.work),
  NavItem('Mensajes', Icons.chat_bubble_outline, Icons.chat_bubble),
  NavItem('Perfil', Icons.person_outline, Icons.person),
];

class AppBottomNav extends ConsumerWidget {
  const AppBottomNav({super.key, required this.currentIndex, required this.professional, required this.onTap});

  final int currentIndex;
  final bool professional;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = professional ? professionalNavItems : customerNavItems;
    final unread = ref.watch(unreadMessagesProvider);
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HyColors.border)),
      ),
      child: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: onTap,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          for (var i = 0; i < items.length; i++)
            NavigationDestination(
              tooltip: items[i].label,
              label: items[i].label,
              icon: _badge(items[i].icon, i == 3 ? unread : 0),
              selectedIcon: _badge(items[i].selectedIcon, i == 3 ? unread : 0),
            ),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, int count) => count == 0
      ? Icon(icon)
      : Badge(label: Text(count > 9 ? '9+' : '$count'), backgroundColor: HyColors.primary, child: Icon(icon));
}
