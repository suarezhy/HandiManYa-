import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../../router.dart';
import 'auth_scaffold.dart';

/// Una sola pantalla para entrar o crear la cuenta: celular, WhatsApp o SMS,
/// código de 6 números y "Continuar". Si el número es nuevo, se crea la
/// cuenta y sigue "Completa tu perfil"; si ya existe, entra a esa cuenta.
class PhoneAuthPage extends ConsumerStatefulWidget {
  const PhoneAuthPage({super.key});

  @override
  ConsumerState<PhoneAuthPage> createState() => _PhoneAuthPageState();
}

class _PhoneAuthPageState extends ConsumerState<PhoneAuthPage> with ResendCooldown {
  final _phoneForm = GlobalKey<FormState>();
  final _codeForm = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  var _channel = CodeChannel.whatsapp;
  String? _sentTo;
  bool _loading = false;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send({CodeChannel? channel}) async {
    final phone = _sentTo ?? Validators.normalizeBoliviaPhone(_phone.text);
    if (_sentTo == null && !_phoneForm.currentState!.validate()) return;
    if (phone == null || _loading) return;
    final via = channel ?? _channel;
    setState(() => _loading = true);
    try {
      await ref.read(backendProvider).sendPhoneCode(phone: phone, channel: via);
      if (!mounted) return;
      setState(() {
        _channel = via;
        _sentTo = phone;
        _code.clear();
      });
      startCooldown();
    } catch (e) {
      final err = AppError.from(e);
      if (mounted) {
        // Si ya hay un código en camino, se puede escribir igual.
        if (err.code == 'HMY_OTP_TOO_SOON' && _sentTo == null) setState(() => _sentTo = phone);
        showError(context, err);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify() async {
    if (!_codeForm.currentState!.validate() || _loading) return;
    setState(() => _loading = true);
    final ok = await runGuarded(context, () async {
      await ref.read(backendProvider).verifyPhoneCode(phone: _sentTo!, code: _code.text);
      ref.invalidate(accountProvider);
    });
    if (!mounted) return;
    setState(() => _loading = false);
    if (!ok) _code.clear();
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sentTo;
    return AuthScaffold(
      showBack: false,
      title: sent == null ? 'Bienvenido a HandiMan ¡Ya!' : 'Escribe el código',
      subtitle: sent == null
          ? 'Escribe tu número de celular. Te enviaremos un código para entrar o crear tu cuenta.'
          : 'Te lo enviamos por ${_channel.label} al ${formatBoliviaPhone(sent)}. Vence en 5 minutos.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [const DemoAccountsHint(), if (sent == null) ..._phoneStep() else ..._codeStep()],
      ),
    );
  }

  List<Widget> _phoneStep() => [
    Form(
      key: _phoneForm,
      child: PhoneField(controller: _phone, onSubmitted: (_) => _send()),
    ),
    const SizedBox(height: HySpacing.lg),
    ChannelPicker(value: _channel, onChanged: (c) => setState(() => _channel = c)),
    const SizedBox(height: HySpacing.xl),
    PrimaryButton(key: const Key('auth-continue'), label: 'Continuar', loading: _loading, onPressed: _send),
    const SizedBox(height: HySpacing.lg),
    const Text(
      'Usamos tu número solo para que entres a tu cuenta y para avisarte de tus servicios. '
      'No necesitas correo ni contraseña.',
      textAlign: TextAlign.center,
      style: TextStyle(color: HyColors.textMuted, fontSize: 14),
    ),
    const SizedBox(height: HySpacing.sm),
    TextButton(
      onPressed: () => context.push(Routes.recover),
      child: const Text('¿Ya no tienes tu número? Recupera tu cuenta'),
    ),
  ];

  List<Widget> _codeStep() {
    final other = _channel == CodeChannel.whatsapp ? CodeChannel.sms : CodeChannel.whatsapp;
    return [
      Form(
        key: _codeForm,
        child: CodeField(controller: _code, onCompleted: _verify),
      ),
      const SizedBox(height: HySpacing.lg),
      PrimaryButton(key: const Key('auth-continue'), label: 'Continuar', loading: _loading, onPressed: _verify),
      const SizedBox(height: HySpacing.md),
      TextButton(
        key: const Key('code-resend'),
        onPressed: cooldown > 0 || _loading ? null : () => _send(),
        child: Text(cooldown > 0 ? 'Puedes pedir otro código en $cooldown s' : 'Enviar el código de nuevo'),
      ),
      TextButton(
        key: const Key('code-other-channel'),
        onPressed: cooldown > 0 || _loading ? null : () => _send(channel: other),
        child: Text('Recibirlo por ${other.label}'),
      ),
      TextButton(
        onPressed: _loading ? null : () => setState(() => _sentTo = null),
        child: const Text('Cambiar número', style: TextStyle(color: HyColors.textSecondary)),
      ),
    ];
  }
}
