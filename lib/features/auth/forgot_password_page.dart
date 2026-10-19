import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/providers.dart';
import 'auth_scaffold.dart';

/// Recuperar contraseña en dos pasos: correo → código + nueva contraseña.
class ForgotPasswordPage extends ConsumerStatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  ConsumerState<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _codeSent = false;
  bool _loading = false;

  @override
  void dispose() {
    for (final c in [_email, _code, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final backend = ref.read(backendProvider);
    if (!_codeSent) {
      final ok = await runGuarded(context, () => backend.sendPasswordReset(_email.text));
      if (mounted) setState(() => _codeSent = ok);
    } else {
      await runGuarded(context, () async {
        await backend.verifyRecoveryCode(email: _email.text, code: _code.text);
        await backend.updatePassword(_password.text);
        ref.invalidate(accountProvider);
      }, success: 'Listo. Tu contraseña fue cambiada.');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Recupera tu contraseña',
      subtitle: _codeSent
          ? 'Escribe el código de 6 números que enviamos a ${_email.text.trim()} y tu nueva contraseña.'
          : 'Te enviaremos un código a tu correo.',
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_codeSent) const DemoAccountsHint(professional: false),
            TextFormField(
              controller: _email,
              enabled: !_codeSent,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Correo electrónico', prefixIcon: Icon(Icons.mail_outline)),
              validator: Validators.email,
            ),
            if (_codeSent) ...[
              const SizedBox(height: HySpacing.md),
              TextFormField(
                controller: _code,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                decoration: const InputDecoration(
                  labelText: 'Código de 6 números',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
                validator: Validators.otp,
              ),
              const SizedBox(height: HySpacing.md),
              PasswordField(
                controller: _password,
                label: 'Nueva contraseña',
                autofillHints: const [AutofillHints.newPassword],
                validator: Validators.password,
              ),
            ],
            const SizedBox(height: HySpacing.lg),
            PrimaryButton(
              label: _codeSent ? 'Cambiar contraseña' : 'Enviar código',
              loading: _loading,
              onPressed: _submit,
            ),
            if (_codeSent)
              TextButton(
                onPressed: () => setState(() => _codeSent = false),
                child: const Text('Cambiar correo', style: TextStyle(color: HyColors.textSecondary)),
              ),
          ],
        ),
      ),
    );
  }
}
