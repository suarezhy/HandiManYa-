import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/text_fit.dart';
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

/// La barra de abajo, igual en todas las pantallas del cliente (y del
/// profesional): cinco espacios del mismo ancho, ícono centrado sobre su
/// etiqueta, etiquetas siempre en una línea, pestaña elegida en naranja y
/// respetando la zona segura de abajo (gestos de Android, barra del iPhone).
class AppBottomNav extends ConsumerWidget {
  const AppBottomNav({super.key, required this.currentIndex, required this.professional, required this.onTap});

  final int currentIndex;
  final bool professional;
  final ValueChanged<int> onTap;

  /// Letra base de las etiquetas (≈ 11 sp) e ícono (24 dp).
  static const labelFontSize = 11.0;
  static const iconSize = 24.0;

  /// Máximo de agrandado de las etiquetas (el mismo tope que usa Material).
  static const maxLabelScale = 1.3;

  static const _labelStyle = TextStyle(fontSize: labelFontSize, fontWeight: FontWeight.w800, height: 1.2);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = professional ? professionalNavItems : customerNavItems;
    final unread = ref.watch(unreadMessagesProvider);
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth.isFinite ? box.maxWidth : media.size.width;
        // Cada etiqueta entra entera en su espacio: la letra sigue la escala del
        // sistema hasta 1,3x y se achica un poco solo si "Solicitudes" no cabe.
        final scale = wordFitScale(
          context,
          texts: [for (final i in items) i.label.replaceAll(' ', '\u00A0')],
          style: _labelStyle,
          width: width / items.length - 6,
          max: maxLabelScale,
        );
        final lineHeight = labelFontSize * scale * 1.2;
        // Indicador (32) + separación (4) + etiqueta + aire arriba y abajo.
        final height = (32 + 4 + lineHeight + 22).clamp(64.0, 84.0);
        return DecoratedBox(
          decoration: const BoxDecoration(
            color: HyColors.surface,
            border: Border(top: BorderSide(color: HyColors.border)),
          ),
          child: MediaQuery(
            data: media.copyWith(textScaler: TextScaler.linear(scale)),
            child: NavigationBarTheme(
              data: NavigationBarThemeData(
                backgroundColor: HyColors.surface,
                surfaceTintColor: Colors.transparent,
                indicatorColor: HyColors.primarySoft,
                height: height,
                labelPadding: const EdgeInsets.only(top: 4),
                labelTextStyle: WidgetStateProperty.resolveWith(
                  (states) => _labelStyle.copyWith(
                    // Etiqueta elegida en naranja oscuro de la marca (contraste
                    // AA en letra chica); el ícono y el fondo van en naranja.
                    color: states.contains(WidgetState.selected) ? HyColors.primaryDark : HyColors.textSecondary,
                    fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
                iconTheme: WidgetStateProperty.resolveWith(
                  (states) => IconThemeData(
                    size: iconSize,
                    color: states.contains(WidgetState.selected) ? HyColors.primary : HyColors.textSecondary,
                  ),
                ),
              ),
              child: NavigationBar(
                key: const Key('app-bottom-nav'),
                selectedIndex: currentIndex,
                onDestinationSelected: onTap,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: [
                  for (var i = 0; i < items.length; i++)
                    NavigationDestination(
                      key: Key('nav-${items[i].label}'),
                      tooltip: items[i].label,
                      label: items[i].label,
                      icon: _badge(items[i].icon, i == 3 ? unread : 0),
                      selectedIcon: _badge(items[i].selectedIcon, i == 3 ? unread : 0),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _badge(IconData icon, int count) => count == 0
      ? Icon(icon)
      : Badge(label: Text(count > 9 ? '9+' : '$count'), backgroundColor: HyColors.primary, child: Icon(icon));
}
