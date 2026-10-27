import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/device_auth.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/buttons.dart';
import '../../data/providers.dart';
import 'confirm_identity.dart';

/// Si la persona lo activó en Perfil → Seguridad, la app pide huella o rostro
/// al abrirla o al volver después de un rato; el cuadro del sistema se abre
/// solo. Moverse dentro de la app no lo vuelve a pedir. La sesión de
/// Supabase sigue abierta (no se piden códigos de nuevo); esto solo protege
/// el teléfono si otra persona lo toma. Quien no puede usar la biometría
/// sale de la cuenta y vuelve a entrar con un código.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  /// Tiempo en segundo plano antes de volver a pedirla.
  @visibleForTesting
  static Duration relockAfter = const Duration(minutes: 2);

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> with WidgetsBindingObserver {
  bool _locked = false;

  /// Al abrir la app se decide una vez, cuando ya se sabe quién tiene la sesión.
  bool _decided = false;
  DateTime? _pausedAt;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      if (away >= AppLockGate.relockAfter && ref.read(appLockEnabledProvider)) _lock();
    }
  }

  /// Bloquea y abre enseguida el cuadro de huella del sistema, sin que haya
  /// que tocar "Desbloquear". Si la persona lo cancela o falla, no se vuelve a
  /// abrir solo: queda el botón.
  void _lock() {
    setState(() {
      _locked = true;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _locked) _unlock();
    });
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(deviceAuthProvider).authenticate('Desbloquea HandiMan ¡Ya!');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result == DeviceAuthResult.success) {
        _locked = false;
      } else {
        _error = switch (result) {
          DeviceAuthResult.canceled || DeviceAuthResult.success => null,
          DeviceAuthResult.lockedOut =>
            'Hubo demasiados intentos. Desbloquea el teléfono y vuelve a probar, o entra con un código.',
          DeviceAuthResult.unavailable =>
            'Este teléfono ya no tiene huella ni rostro configurados. Entra con un código.',
          DeviceAuthResult.failed => 'No pudimos confirmar que eres tú. Prueba de nuevo o entra con un código.',
        };
      }
    });
  }

  Future<void> _useCode() async {
    await ref.read(backendProvider).signOut();
    if (mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    // Si se desactiva o se cierra la sesión, no queda nada bloqueado.
    if (!_decided && ref.watch(authUserProvider).hasValue) {
      _decided = true;
      if (ref.read(appLockEnabledProvider)) {
        _locked = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _locked) _unlock();
        });
      }
    }
    ref.listen(appLockEnabledProvider, (_, on) {
      if (!on && _locked) setState(() => _locked = false);
    });
    if (!_locked) return widget.child;
    return Scaffold(
      key: const Key('app-lock'),
      backgroundColor: HyColors.surface,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(HySpacing.page),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: BrandLogo(height: 48)),
                  const SizedBox(height: HySpacing.xl),
                  const Icon(Icons.lock_person_outlined, size: 56, color: HyColors.primary),
                  const SizedBox(height: HySpacing.md),
                  const Text(
                    'Desbloquea la app',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: HySpacing.sm),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: HyColors.danger),
                      ),
                    ),
                  const SizedBox(height: HySpacing.lg),
                  PrimaryButton(
                    key: const Key('app-unlock'),
                    label: 'Desbloquear',
                    icon: Icons.fingerprint,
                    loading: _busy,
                    onPressed: _unlock,
                  ),
                  TextButton(onPressed: _busy ? null : _useCode, child: const Text('Entrar con un código')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
