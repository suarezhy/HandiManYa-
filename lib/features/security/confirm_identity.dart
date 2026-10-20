import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/device_auth.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../data/providers.dart';

/// Preferencia de este teléfono: el profesional activó huella o rostro aquí.
String biometricPrefKey(String userId) => 'security.biometric.$userId';

/// Huella o rostro activados en este teléfono Y en la cuenta (servidor).
final biometricEnabledProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(authUserProvider).value;
  if (user == null) return false;
  if (!(ref.watch(prefsProvider).getBool(biometricPrefKey(user.id)) ?? false)) return false;
  return ref.watch(backendProvider).biometricEnabled();
});

final deviceBiometricsProvider = FutureProvider<Set<DeviceBiometric>>(
  (ref) => ref.watch(deviceAuthProvider).available(),
);

/// Resultado de una confirmación exitosa. [serverMethod] es lo que se envía a
/// la base (`password` o `biometric`); la base vuelve a validar.
class IdentityConfirmation {
  const IdentityConfirmation(this.serverMethod, this.label);

  final String serverMethod;
  final String label;
}

/// Pantalla "Confirma que eres tú" antes de una operación de dinero.
/// Devuelve null si el usuario cancela o la confirmación falla: en ese caso
/// no se debe enviar nada.
Future<IdentityConfirmation?> confirmIdentity(
  BuildContext context, {
  required String operation,
  double? amount,
  List<(String, String)> details = const [],
  String submitLabel = 'Confirmar y enviar',
  bool passwordOnly = false,
}) => showModalBottomSheet<IdentityConfirmation>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => ConfirmIdentitySheet(
    operation: operation,
    amount: amount,
    details: details,
    submitLabel: submitLabel,
    passwordOnly: passwordOnly,
  ),
);

class ConfirmIdentitySheet extends ConsumerStatefulWidget {
  const ConfirmIdentitySheet({
    super.key,
    required this.operation,
    this.amount,
    this.details = const [],
    this.submitLabel = 'Confirmar y enviar',
    this.passwordOnly = false,
  });

  final String operation;
  final double? amount;
  final List<(String, String)> details;
  final String submitLabel;
  final bool passwordOnly;

  @override
  ConsumerState<ConfirmIdentitySheet> createState() => _ConfirmIdentitySheetState();
}

class _ConfirmIdentitySheetState extends ConsumerState<ConfirmIdentitySheet> {
  final _password = TextEditingController();

  /// null = contraseña.
  DeviceBiometric? _method;
  bool _picked = false;
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final biometric = _method;
    if (biometric == null && _password.text.isEmpty) {
      return setState(() => _error = 'Escribe tu contraseña.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    if (biometric == null) {
      try {
        await ref.read(backendProvider).confirmPassword(_password.text);
        _password.clear();
        if (mounted) Navigator.pop(context, const IdentityConfirmation('password', 'Contraseña'));
      } catch (e) {
        _password.clear();
        final err = AppError.from(e);
        if (mounted) {
          setState(() {
            _busy = false;
            _error = err.code == 'invalid_credentials'
                ? 'La contraseña no es correcta. No se envió nada.'
                : '${err.message} No se envió nada.';
          });
        }
      }
      return;
    }
    final result = await ref
        .read(deviceAuthProvider)
        .authenticate('Confirma ${widget.operation.toLowerCase()} en HandiMan ¡Ya!');
    if (!mounted) return;
    if (result == DeviceAuthResult.success) {
      Navigator.pop(context, IdentityConfirmation('biometric', biometric.label));
      return;
    }
    setState(() {
      _busy = false;
      _error = switch (result) {
        DeviceAuthResult.canceled => 'Cancelaste la confirmación. No se envió nada.',
        DeviceAuthResult.lockedOut => 'La ${biometric.short} quedó bloqueada por muchos intentos. Usa tu contraseña.',
        DeviceAuthResult.unavailable => 'La ${biometric.short} no está disponible ahora. Usa tu contraseña.',
        _ => 'No pudimos confirmar que eres tú. No se envió nada.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.passwordOnly
        ? const <DeviceBiometric>{}
        : (ref.watch(deviceBiometricsProvider).value ?? const <DeviceBiometric>{});
    final enabled = !widget.passwordOnly && (ref.watch(biometricEnabledProvider).value ?? false);
    final options = enabled ? device.toList() : const <DeviceBiometric>[];
    if (!_picked && options.isNotEmpty) _method = options.first;
    if (_method != null && !options.contains(_method)) _method = null;
    final amount = widget.amount;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        HySpacing.page,
        0,
        HySpacing.page,
        MediaQuery.viewInsetsOf(context).bottom + HySpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Confirma que eres tú', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: HySpacing.sm),
            Container(
              key: const Key('confirm-summary'),
              padding: const EdgeInsets.all(HySpacing.md),
              decoration: BoxDecoration(color: HyColors.primarySoft, borderRadius: BorderRadius.circular(HyRadii.lg)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.operation, style: const TextStyle(fontSize: 16, color: HyColors.textSecondary)),
                  if (amount != null)
                    Text(
                      Fmt.bs(amount),
                      key: const Key('confirm-amount'),
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: HyColors.text),
                    ),
                  for (final (label, value) in widget.details)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('$label: $value', style: const TextStyle(fontSize: 15)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: HySpacing.md),
            const Text('Elige cómo confirmar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: HySpacing.xs),
            for (final o in options)
              _MethodTile(
                key: Key('confirm-${o.name}'),
                icon: o == DeviceBiometric.face ? Icons.face_retouching_natural : Icons.fingerprint,
                label: o.label,
                selected: _method == o,
                onTap: _busy
                    ? null
                    : () => setState(() {
                        _picked = true;
                        _method = o;
                        _error = null;
                      }),
              ),
            _MethodTile(
              key: const Key('confirm-password'),
              icon: Icons.password_rounded,
              label: 'Contraseña',
              selected: _method == null,
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _picked = true;
                      _method = null;
                      _error = null;
                    }),
            ),
            if (!widget.passwordOnly && !enabled && device.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: HySpacing.xs),
                child: Text(
                  'Puedes activar huella o rostro en Perfil → Seguridad.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
              ),
            if (_method == null) ...[
              const SizedBox(height: HySpacing.sm),
              TextField(
                key: const Key('confirm-password-field'),
                controller: _password,
                obscureText: _hide,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Contraseña de tu cuenta',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    tooltip: _hide ? 'Mostrar contraseña' : 'Ocultar contraseña',
                    icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: HySpacing.sm),
                child: Text(
                  _error!,
                  key: const Key('confirm-error'),
                  style: const TextStyle(color: HyColors.danger, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: HySpacing.md),
            PrimaryButton(
              key: const Key('confirm-submit'),
              label: _method == null ? widget.submitLabel : 'Confirmar con ${_method!.short}',
              icon: _method == null ? Icons.lock_open_rounded : Icons.fingerprint,
              loading: _busy,
              onPressed: _submit,
            ),
            const SizedBox(height: HySpacing.xs),
            TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
          ],
        ),
      ),
    );
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({super.key, required this.icon, required this.label, required this.selected, this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.xs),
    child: Material(
      color: selected ? HyColors.primarySoft : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HyRadii.md),
        side: BorderSide(color: selected ? HyColors.primary : HyColors.border, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(HyRadii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 28, color: selected ? HyColors.primary : HyColors.textSecondary),
              const SizedBox(width: HySpacing.sm),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? HyColors.primary : HyColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
