import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/device_auth.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/providers.dart';
import 'confirm_identity.dart';
import '../../core/widgets/word_safe_text.dart';

/// Perfil → Seguridad: activar o desactivar la confirmación con huella o rostro
/// para las operaciones con dinero (recargas y, más adelante, retiros).
class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key});

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  bool _busy = false;

  Future<void> _toggle(bool on, Set<DeviceBiometric> device) async {
    if (_busy) return;
    final user = ref.read(authUserProvider).value;
    if (user == null) return;
    setState(() => _busy = true);
    final prefs = ref.read(prefsProvider);
    final backend = ref.read(backendProvider);
    try {
      if (on) {
        // 1) Código nuevo (el servidor exige que sea recién verificado para activar).
        final ok = await confirmIdentity(
          context,
          operation: 'Activar huella o rostro',
          submitLabel: 'Confirmar',
          codeOnly: true,
        );
        if (ok == null || !mounted) return;
        // 2) Probar la biometría del teléfono antes de activarla.
        final result = await ref.read(deviceAuthProvider).authenticate('Activa la confirmación en HandiMan ¡Ya!');
        if (!mounted) return;
        if (result != DeviceAuthResult.success) {
          showMessage(context, 'No se activó: no pudimos confirmar tu ${device.first.short}.');
          return;
        }
        await backend.setBiometricEnabled(true, authMethod: ok.serverMethod);
        await prefs.setBool(biometricPrefKey(user.id), true);
        if (mounted) showMessage(context, 'Listo. Podrás confirmar tus recargas con tu ${device.first.short}.');
      } else {
        await backend.setBiometricEnabled(false);
        await prefs.remove(biometricPrefKey(user.id));
        await prefs.remove(appLockPrefKey(user.id));
        if (mounted) showMessage(context, 'Desactivado. Confirmarás con un código a tu celular.');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      ref.invalidate(biometricEnabledProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(deviceBiometricsProvider);
    final enabled = ref.watch(biometricEnabledProvider);
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Seguridad')),
      body: ListView(
        padding: EdgeInsets.only(bottom: HySpacing.xxl + MediaQuery.paddingOf(context).bottom),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(title: 'Confirmar operaciones con dinero'),
                const Text(
                  'Cada recarga de saldo pide confirmar que eres tú, aunque ya hayas ingresado a la app.',
                  style: TextStyle(fontSize: 16, color: HyColors.textSecondary),
                ),
                const SizedBox(height: HySpacing.md),
                switch ((device, enabled)) {
                  (AsyncData(value: final d), AsyncData(value: final on)) when d.isNotEmpty => _SettingCard(
                    switchKey: const Key('biometric-switch'),
                    icon: d.contains(DeviceBiometric.face) ? Icons.face_retouching_natural : Icons.fingerprint,
                    title: 'Usar ${d.map((b) => b.short).join(' o ')}',
                    subtitle: on ? 'Activado en este teléfono' : 'Desactivado: confirmas con un código a tu celular',
                    value: on,
                    onChanged: _busy ? null : (v) => _toggle(v, d),
                  ),
                  // En el navegador no hay acceso a la huella ni al rostro del equipo,
                  // aunque el iPad o el teléfono los tengan.
                  (AsyncData(value: final d), _) when d.isEmpty && kIsWeb => const _SecurityNote(
                    'En la versión web no se puede usar la huella ni el rostro. '
                    'Confirmarás con un código a tu celular. En la app para Android o iPhone puedes activarlos.',
                    icon: Icons.language,
                  ),
                  (AsyncData(value: final d), _) when d.isEmpty => const _SecurityNote(
                    'Este teléfono no tiene huella ni rostro configurados. '
                    'Confirmarás con un código a tu celular. Puedes configurarlos en los ajustes del teléfono.',
                    icon: Icons.phonelink_lock_outlined,
                  ),
                  (AsyncError(), _) || (_, AsyncError()) => ErrorView(
                    error: (device.error ?? enabled.error)!,
                    onRetry: () => ref
                      ..invalidate(deviceBiometricsProvider)
                      ..invalidate(biometricEnabledProvider),
                  ),
                  _ => const LoadingView(),
                },
                if (enabled.value == true) ...[
                  const SizedBox(height: HySpacing.sm),
                  _SettingCard(
                    switchKey: const Key('app-lock-switch'),
                    icon: Icons.lock_person_outlined,
                    title: 'Pedirla al abrir la app',
                    subtitle: 'Tu sesión sigue abierta; solo se desbloquea con tu huella o rostro.',
                    value: ref.watch(appLockEnabledProvider),
                    onChanged: (v) => ref.read(appLockEnabledProvider.notifier).set(v),
                  ),
                ],
                const SizedBox(height: HySpacing.lg),
                // Cierto: local_auth deja la verificación al sistema operativo y la app
                // solo recibe "sí" o "no"; al servidor solo va si está activado.
                if (!kIsWeb)
                  const _SecurityNote(
                    'Tu huella y rostro se verifican de forma segura en tu dispositivo. '
                    'HandiMan ¡Ya! no almacena tus datos biométricos.',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Un ajuste con interruptor, compacto y con el texto alineado al título.
class _SettingCard extends StatelessWidget {
  const _SettingCard({
    required this.switchKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final Key switchKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: HySpacing.xxs),
    child: SwitchListTile(
      key: switchKey,
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: HySpacing.xs,
      horizontalTitleGap: HySpacing.sm,
      secondary: Icon(icon, size: 26, color: HyColors.primary),
      title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 14, color: HyColors.textSecondary)),
      value: value,
      onChanged: onChanged,
    ),
  );
}

/// Nota breve en gris con un ícono pequeño, sin recuadro.
class _SecurityNote extends StatelessWidget {
  const _SecurityNote(this.text, {this.icon = Icons.shield_outlined});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('security-note'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(icon, size: 18, color: HyColors.textSecondary),
      ),
      const SizedBox(width: HySpacing.xs),
      Expanded(
        child: Text(text, style: const TextStyle(fontSize: 14, height: 1.35, color: HyColors.textSecondary)),
      ),
    ],
  );
}
