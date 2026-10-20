import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/city_picker.dart';
import '../legal/legal_texts.dart';

/// Perfil compartido por cliente y profesional. Desde aquí se cambia de modo.
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountProvider);
    final city = ref.watch(currentCityProvider);
    final account = accountAsync.value;
    if (account == null) return const Scaffold(body: LoadingView());
    final text = Theme.of(context).textTheme;

    Future<void> switchRole(AppRole role) async {
      final ok = await runGuarded(context, () => ref.read(backendProvider).setActiveRole(role));
      if (ok) ref.invalidate(accountProvider);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Mi perfil')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: HySpacing.xxl),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.sm),
                AppCard(
                  child: Row(
                    children: [
                      PersonAvatar(name: account.fullName, size: 64),
                      const SizedBox(width: HySpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(account.fullName, style: text.titleLarge),
                            Text(account.email, style: const TextStyle(color: HyColors.textSecondary)),
                            if (account.phone != null)
                              Text(account.phone!, style: const TextStyle(color: HyColors.textSecondary)),
                            const SizedBox(height: 4),
                            _ModeChip(professional: account.isProfessionalMode),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Editar perfil',
                        onPressed: () => context.push(Routes.editProfile),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: HySpacing.md),
                _RoleCard(account: account, onSwitch: switchRole),
                if (account.isAdmin) ...[
                  const SizedBox(height: HySpacing.sm),
                  _Tile(
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Panel de administración',
                    subtitle: 'Verificaciones, recargas, reportes y más',
                    onTap: () => context.go(Routes.admin),
                  ),
                ],
                const SectionHeader(title: 'Cuenta'),
                _Tile(
                  icon: Icons.place_outlined,
                  title: 'Ciudad',
                  subtitle: city?.name ?? 'Elegir ciudad',
                  onTap: () => showCityPicker(context, ref),
                ),
                if (account.isProfessionalMode)
                  _Tile(
                    icon: Icons.account_balance_wallet_outlined,
                    title: 'Billetera',
                    subtitle: 'Saldo, recargas y movimientos',
                    onTap: () => context.push(Routes.wallet),
                  ),
                if (account.isApprovedProfessional)
                  _Tile(
                    icon: Icons.radar_outlined,
                    title: 'Mi zona de trabajo',
                    subtitle: 'Punto de partida y distancia',
                    onTap: () => context.push(Routes.serviceArea),
                  ),
                if (account.isApprovedProfessional)
                  _Tile(
                    icon: Icons.badge_outlined,
                    title: 'Mi perfil profesional',
                    subtitle: 'Como te ven los clientes',
                    onTap: () => context.push(Routes.professional(account.id)),
                  ),
                _Tile(
                  icon: Icons.notifications_none_rounded,
                  title: 'Notificaciones',
                  onTap: () => context.push(Routes.notifications),
                ),
                _Tile(
                  icon: Icons.shield_outlined,
                  title: 'Seguridad',
                  subtitle: 'Huella, rostro y confirmación de recargas',
                  onTap: () => context.push(Routes.security),
                ),
                const SectionHeader(title: 'Ayuda y legal'),
                _Tile(
                  icon: Icons.support_agent_outlined,
                  title: 'Ayuda y soporte',
                  subtitle: 'Preguntas frecuentes y contacto',
                  onTap: () => context.push(Routes.support),
                ),
                for (final doc in LegalDoc.values)
                  if (account.roles.contains(AppRole.professional) ||
                      account.professionalStatus != VerificationStatus.notStarted ||
                      (doc != LegalDoc.commissions && doc != LegalDoc.proRules))
                    _Tile(
                      icon: doc == LegalDoc.privacy ? Icons.privacy_tip_outlined : Icons.description_outlined,
                      title: doc.title,
                      onTap: () => showLegalDoc(context, doc),
                    ),
                const SizedBox(height: HySpacing.lg),
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await confirmDialog(
                      context,
                      title: '¿Cerrar sesión?',
                      message: 'Podrás volver a ingresar con tu correo y contraseña.',
                      confirm: 'Cerrar sesión',
                    );
                    if (ok && context.mounted) await runGuarded(context, () => ref.read(backendProvider).signOut());
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Cerrar sesión'),
                ),
                const SizedBox(height: HySpacing.sm),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: HyColors.danger),
                  onPressed: account.deletionRequested
                      ? null
                      : () async {
                          final ok = await confirmDialog(
                            context,
                            title: '¿Eliminar tu cuenta?',
                            message: 'Revisaremos tu pedido y eliminaremos tus datos personales. Las solicitudes en curso deben terminar o cancelarse antes.',
                            confirm: 'Pedir eliminación',
                            destructive: true,
                          );
                          if (!ok || !context.mounted) return;
                          final done = await runGuarded(
                            context,
                            () => ref.read(backendProvider).requestAccountDeletion(),
                            success: 'Recibimos tu pedido de eliminación.',
                          );
                          if (done) ref.invalidate(accountProvider);
                        },
                  child: Text(account.deletionRequested ? 'Eliminación de cuenta solicitada' : 'Eliminar mi cuenta'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.professional});

  final bool professional;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: (professional ? HyColors.green : HyColors.primary).withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(HyRadii.pill),
    ),
    child: Text(
      professional ? 'Modo profesional' : 'Modo cliente',
      style: TextStyle(color: professional ? HyColors.greenDark : HyColors.primaryDark, fontWeight: FontWeight.w700),
    ),
  );
}

/// Tarjeta para pasar de cliente a profesional (o al revés) o postularse.
class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.account, required this.onSwitch});

  final UserProfile account;
  final Future<void> Function(AppRole) onSwitch;

  @override
  Widget build(BuildContext context) {
    if (account.isProfessionalMode) {
      return _action(
        context,
        icon: Icons.person_outline,
        title: 'Cambiar a modo cliente',
        message: 'Pide servicios como cliente con la misma cuenta.',
        label: 'Usar como cliente',
        onPressed: () => onSwitch(AppRole.customer),
      );
    }
    if (account.isApprovedProfessional) {
      return _action(
        context,
        icon: Icons.handyman_outlined,
        title: 'Cambiar a modo profesional',
        message: 'Recibe pedidos ¡Ya! y gestiona tus trabajos.',
        label: 'Usar como profesional',
        onPressed: () => onSwitch(AppRole.professional),
      );
    }
    final status = account.professionalStatus;
    final message = switch (status) {
      VerificationStatus.submitted ||
      VerificationStatus.underReview => 'Tu postulación está en revisión. Te avisaremos apenas tengamos una respuesta.',
      VerificationStatus.rejected => 'Tu postulación necesita cambios. Revisa los comentarios y vuelve a enviarla.',
      VerificationStatus.suspended => 'Tu perfil profesional está suspendido. Escríbenos desde Ayuda.',
      VerificationStatus.reverificationRequired => 'Necesitamos verificar nuevamente tus datos.',
      VerificationStatus.draft => 'Tienes una postulación sin terminar.',
      _ => 'Ofrece tus servicios y gana clientes cerca de ti. La verificación es gratuita.',
    };
    return _action(
      context,
      icon: Icons.workspace_premium_outlined,
      title: status == VerificationStatus.notStarted
          ? '¿Quieres trabajar con HandiMan ¡Ya!?'
          : 'Postulación: ${status.label}',
      message: message,
      label: status.canEdit
          ? (status == VerificationStatus.notStarted ? 'Quiero ser profesional' : 'Continuar postulación')
          : 'Ver postulación',
      onPressed: status == VerificationStatus.suspended ? null : () => context.push(Routes.apply),
    );
  }

  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
    required String label,
    required VoidCallback? onPressed,
  }) => AppCard(
    color: HyColors.navy,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: HyColors.primary, size: 28),
            const SizedBox(width: HySpacing.xs),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: HySpacing.xs),
        Text(message, style: const TextStyle(color: Colors.white70, fontSize: 15)),
        const SizedBox(height: HySpacing.sm),
        FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(minimumSize: const Size(0, HySizes.touch)),
          child: Text(label),
        ),
      ],
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.title, this.subtitle, required this.onTap});

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
