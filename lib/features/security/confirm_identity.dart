import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/device_auth.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../auth/auth_scaffold.dart';

/// Preferencia de este teléfono: el profesional activó huella o rostro aquí.
String biometricPrefKey(String userId) => 'security.biometric.$userId';

/// Huella o rostro activados en este teléfono Y en la cuenta (servidor).
final biometricEnabledProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(authUserProvider).value;
  if (user == null) return false;
  if (!(ref.watch(prefsProvider).getBool(biometricPrefKey(user.id)) ?? false)) return false;
  return ref.watch(backendProvider).biometricEnabled();
});

/// Preferencia de este teléfono: pedir huella o rostro al abrir la app.
String appLockPrefKey(String userId) => 'security.applock.$userId';

class AppLockEnabled extends Notifier<bool> {
  @override
  bool build() {
    final user = ref.watch(authUserProvider).value;
    if (user == null) return false;
    final prefs = ref.watch(prefsProvider);
    return (prefs.getBool(biometricPrefKey(user.id)) ?? false) && (prefs.getBool(appLockPrefKey(user.id)) ?? false);
  }

  Future<void> set(bool on) async {
    final user = ref.read(authUserProvider).value;
    if (user == null) return;
    state = on;
    await ref.read(prefsProvider).setBool(appLockPrefKey(user.id), on);
  }
}

final appLockEnabledProvider = NotifierProvider<AppLockEnabled, bool>(AppLockEnabled.new);

final deviceBiometricsProvider = FutureProvider<Set<DeviceBiometric>>(
  (ref) => ref.watch(deviceAuthProvider).available(),
);

/// Resultado de una confirmación exitosa. [serverMethod] es lo que se envía a
/// la base (`otp` o `biometric`); la base vuelve a validar.
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
  bool codeOnly = false,
}) => showModalBottomSheet<IdentityConfirmation>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => ConfirmIdentitySheet(
    operation: operation,
    amount: amount,
    details: details,
    submitLabel: submitLabel,
    codeOnly: codeOnly,
  ),
);

class ConfirmIdentitySheet extends ConsumerStatefulWidget {
  const ConfirmIdentitySheet({
    super.key,
    required this.operation,
    this.amount,
    this.details = const [],
    this.submitLabel = 'Confirmar y enviar',
    this.codeOnly = false,
  });

  final String operation;
  final double? amount;
  final List<(String, String)> details;
  final String submitLabel;
  final bool codeOnly;

  @override
  ConsumerState<ConfirmIdentitySheet> createState() => _ConfirmIdentitySheetState();
}

class _ConfirmIdentitySheetState extends ConsumerState<ConfirmIdentitySheet> with ResendCooldown {
  final _code = TextEditingController();

  /// null = código por WhatsApp o SMS.
  DeviceBiometric? _method;
  var _channel = CodeChannel.whatsapp;
  bool _picked = false;
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  String? get _phone => ref.read(backendProvider).currentUser?.phone;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final phone = _phone;
    if (phone == null) {
      return setState(() => _error = 'Agrega tu celular en Perfil > Información personal para recibir códigos.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(backendProvider).sendPhoneCode(phone: phone, channel: _channel);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _codeSent = true;
      });
      startCooldown();
    } catch (e) {
      final err = AppError.from(e);
      if (mounted) {
        setState(() {
          _busy = false;
          // Ya hay un código en camino: se puede escribir igual.
          if (err.code == 'HMY_OTP_TOO_SOON') _codeSent = true;
          _error = err.message;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final biometric = _method;
    if (biometric == null) {
      if (!_codeSent) return _sendCode();
      if (!RegExp(r'^\d{6}$').hasMatch(_code.text)) {
        return setState(() => _error = 'Escribe el código de 6 números.');
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        // Verificar el código es un inicio de sesión nuevo: el servidor exige
        // que sea de hace menos de 5 minutos y lo usa para una sola operación.
        await ref.read(backendProvider).verifyPhoneCode(phone: _phone!, code: _code.text);
        _code.clear();
        if (mounted) Navigator.pop(context, const IdentityConfirmation('otp', 'Código'));
      } catch (e) {
        _code.clear();
        final err = AppError.from(e);
        if (mounted) {
          setState(() {
            _busy = false;
            _error = '${err.message} No se envió nada.';
          });
        }
      }
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
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
        DeviceAuthResult.lockedOut => 'La ${biometric.short} quedó bloqueada por muchos intentos. Usa un código.',
        DeviceAuthResult.unavailable => 'La ${biometric.short} no está disponible ahora. Usa un código.',
        _ => 'No pudimos confirmar que eres tú. No se envió nada.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.codeOnly
        ? const <DeviceBiometric>{}
        : (ref.watch(deviceBiometricsProvider).value ?? const <DeviceBiometric>{});
    final enabled = !widget.codeOnly && (ref.watch(biometricEnabledProvider).value ?? false);
    final options = enabled ? device.toList() : const <DeviceBiometric>[];
    if (!_picked && options.isNotEmpty) _method = options.first;
    if (_method != null && !options.contains(_method)) _method = null;
    final amount = widget.amount;
    final phone = ref.watch(authUserProvider).value?.phone;

    return Padding(
      padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
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
              key: const Key('confirm-code'),
              icon: Icons.sms_outlined,
              label: 'Código por celular',
              detail: phone == null ? null : formatPhone(phone),
              selected: _method == null,
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _picked = true;
                      _method = null;
                      _error = null;
                    }),
            ),
            if (!widget.codeOnly && !enabled && device.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: HySpacing.xs),
                child: Text(
                  'Puedes activar huella o rostro en Perfil > Seguridad.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
              ),
            if (_method == null && !_codeSent) ...[
              const SizedBox(height: HySpacing.sm),
              ChannelPicker(value: _channel, onChanged: (c) => setState(() => _channel = c)),
            ],
            if (_method == null && _codeSent) ...[
              const SizedBox(height: HySpacing.sm),
              Text(
                'Te enviamos un código por ${_channel.label}. Vence en 5 minutos.',
                style: const TextStyle(color: HyColors.textSecondary),
              ),
              const SizedBox(height: HySpacing.xs),
              CodeField(controller: _code, onCompleted: _submit, fieldKey: const Key('confirm-code-field')),
              TextButton(onPressed: cooldown > 0 || _busy ? null : _sendCode, child: Text(resendLabel)),
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
              label: _method != null
                  ? 'Confirmar con ${_method!.short}'
                  : _codeSent
                  ? widget.submitLabel
                  : 'Enviarme el código',
              icon: _method == null ? Icons.lock_open_rounded : Icons.fingerprint,
              loading: _busy,
              onPressed: _submit,
            ),
            const SizedBox(height: HySpacing.xs),
            TextButton(
              key: const Key('confirm-cancel'),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(HySizes.touch)),
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({
    super.key,
    required this.icon,
    required this.label,
    this.detail,
    required this.selected,
    this.onTap,
  });

  final IconData icon;
  final String label;

  /// Segunda línea (el celular): siempre entera en una línea; si no cabe,
  /// se achica un poco en vez de partirse.
  final String? detail;
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    if (detail != null)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          detail!,
                          key: const Key('confirm-code-phone'),
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: HyColors.textSecondary,
                            fontFeatures: [FontFeature.tabularFigures()],
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: HySpacing.xs),
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
