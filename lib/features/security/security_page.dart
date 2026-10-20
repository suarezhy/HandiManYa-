import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/device_auth.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/providers.dart';
import 'confirm_identity.dart';

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
      appBar: AppBar(title: const Text('Seguridad')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: HySpacing.xxl),
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
                  (AsyncData(value: final d), AsyncData(value: final on)) when d.isNotEmpty => AppCard(
                    child: SwitchListTile(
                      key: const Key('biometric-switch'),
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(
                        d.contains(DeviceBiometric.face) ? Icons.face_retouching_natural : Icons.fingerprint,
                        size: 32,
                        color: HyColors.primary,
                      ),
                      title: Text(
                        'Usar ${d.map((b) => b.short).join(' o ')}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        on ? 'Activado en este teléfono' : 'Desactivado: confirmas con un código a tu celular',
                      ),
                      value: on,
                      onChanged: _busy ? null : (v) => _toggle(v, d),
                    ),
                  ),
                  (AsyncData(value: final d), _) when d.isEmpty => const InfoBanner(
                    icon: Icons.phonelink_lock_outlined,
                    text: 'Este dispositivo no tiene huella ni reconocimiento facial configurados. Confirmarás con un código a tu celular.',
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
                  AppCard(
                    child: SwitchListTile(
                      key: const Key('app-lock-switch'),
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.lock_person_outlined, size: 32, color: HyColors.primary),
                      title: const Text(
                        'Pedirla al abrir la app',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text('Tu sesión sigue abierta; solo se desbloquea con tu huella o rostro.'),
                      value: ref.watch(appLockEnabledProvider),
                      onChanged: (v) => ref.read(appLockEnabledProvider.notifier).set(v),
                    ),
                  ),
                ],
                const SizedBox(height: HySpacing.md),
                const InfoBanner(
                  icon: Icons.verified_user_outlined,
                  text: 'Tu huella y tu rostro nunca salen del teléfono: los revisa el propio teléfono y HandiMan ¡Ya! no los ve ni los guarda. Para entrar usas tu celular y un código; no hay contraseñas.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
