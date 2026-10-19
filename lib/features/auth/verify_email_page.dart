import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/providers.dart';
import 'auth_scaffold.dart';

class VerifyEmailPage extends ConsumerStatefulWidget {
  const VerifyEmailPage({super.key, this.email});

  final String? email;

  @override
  ConsumerState<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends ConsumerState<VerifyEmailPage> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  bool _loading = false;
  int _cooldown = 0;
  Timer? _timer;

  String get _email => widget.email ?? ref.read(backendProvider).currentUser?.email ?? '';

  @override
  void dispose() {
    _code.dispose();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _verify() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    await runGuarded(context, () async {
      await ref.read(backendProvider).verifyEmailCode(email: _email, code: _code.text);
      ref.invalidate(accountProvider);
    });
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _resend() async {
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).resendEmailCode(_email),
      success: 'Te enviamos un nuevo código.',
    );
    if (!ok || !mounted) return;
    setState(() => _cooldown = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _cooldown <= 1) {
        t.cancel();
        if (mounted) setState(() => _cooldown = 0);
        return;
      }
      setState(() => _cooldown--);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Confirma tu correo',
      subtitle: 'Te enviamos un código de 6 números a $_email. Revisa también la carpeta de spam.',
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DemoAccountsHint(professional: false),
            TextFormField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 10),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              decoration: const InputDecoration(labelText: 'Código', hintText: '······'),
              validator: Validators.otp,
              onChanged: (v) {
                if (v.length == 6) _verify();
              },
            ),
            const SizedBox(height: HySpacing.lg),
            PrimaryButton(label: 'Confirmar', loading: _loading, onPressed: _verify),
            const SizedBox(height: HySpacing.md),
            TextButton(
              onPressed: _cooldown > 0 ? null : _resend,
              child: Text(_cooldown > 0 ? 'Puedes pedir otro código en $_cooldown s' : 'Enviar el código de nuevo'),
            ),
            TextButton(
              onPressed: () => ref.read(backendProvider).signOut(),
              child: const Text('Usar otro correo', style: TextStyle(color: HyColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}
