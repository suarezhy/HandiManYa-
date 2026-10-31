import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/providers.dart';
import 'auth_scaffold.dart';

/// Recuperar la cuenta sin el celular: código al correo que la persona
/// agregó y confirmó en su perfil. Después cambia su número en
/// Perfil → Información personal. Sirve también para las cuentas antiguas
/// creadas con correo (entran sin contraseña y agregan su celular).
class RecoverAccountPage extends ConsumerStatefulWidget {
  const RecoverAccountPage({super.key});

  @override
  ConsumerState<RecoverAccountPage> createState() => _RecoverAccountPageState();
}

class _RecoverAccountPageState extends ConsumerState<RecoverAccountPage> with ResendCooldown {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _sent = false;
  bool _loading = false;
  final _action = GlobalKey(debugLabel: 'recover-action');

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final ok = await runGuarded(context, () => ref.read(backendProvider).sendEmailLoginCode(_email.text));
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (ok) _sent = true;
    });
    if (ok) startCooldown();
  }

  Future<void> _verify() async {
    if (!_form.currentState!.validate() || _loading) return;
    setState(() => _loading = true);
    await runGuarded(context, () async {
      await ref.read(backendProvider).verifyEmailLoginCode(email: _email.text, code: _code.text);
      ref.invalidate(accountProvider);
    });
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) => AuthScaffold(
    title: 'Recupera tu cuenta',
    keepVisible: _action,
    subtitle: _sent
        ? 'Si ${_email.text.trim()} está en una cuenta, te llegó un código. Revisa también la carpeta de spam.'
        : 'Escribe el correo que agregaste en tu perfil. Te enviaremos un código para entrar y cambiar tu número.',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            key: const Key('recover-email'),
            controller: _email,
            enabled: !_sent,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Correo electrónico', prefixIcon: Icon(Icons.mail_outline)),
            validator: Validators.email,
          ),
          const SizedBox(height: HySpacing.md),
          if (_sent) ...[
            CodeField(controller: _code, onCompleted: _verify),
            const SizedBox(height: HySpacing.lg),
            KeyedSubtree(
              key: _action,
              child: PrimaryButton(label: 'Continuar', loading: _loading, onPressed: _verify),
            ),
            TextButton(
              onPressed: cooldown > 0 ? null : _send,
              child: Text(resendLabel, textAlign: TextAlign.center),
            ),
          ] else
            KeyedSubtree(
              key: _action,
              child: PrimaryButton(label: 'Continuar', loading: _loading, onPressed: _send),
            ),
          const SizedBox(height: HySpacing.xl),
          Text(
            '¿No agregaste un correo? Escríbenos a ${Env.supportEmail} desde otro número. Para proteger tu cuenta, '
            'te pediremos tu carnet de identidad y lo revisa una persona del equipo antes de cambiar el número.',
            style: const TextStyle(color: HyColors.textSecondary, fontSize: 15),
          ),
        ],
      ),
    ),
  );
}
