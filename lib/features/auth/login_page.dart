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

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key, required this.asProfessional});

  final bool asProfessional;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final backend = ref.read(backendProvider);
    try {
      await ref.read(entryIntentProvider.notifier).set(widget.asProfessional ? AppRole.professional : AppRole.customer);
      await backend.signIn(email: _email.text, password: _password.text);
      final user = backend.currentUser;
      if (user != null && !user.emailConfirmed) {
        if (mounted) context.go('${Routes.verify}?correo=${Uri.encodeComponent(_email.text.trim())}');
        return;
      }
      // Entra en el modo de la puerta elegida si el servidor lo permite.
      final account = await backend.myAccount();
      final wanted = widget.asProfessional && account.isApprovedProfessional ? AppRole.professional : AppRole.customer;
      if (account.activeRole != wanted) await backend.setActiveRole(wanted);
      ref.invalidate(accountProvider);
    } catch (e) {
      if (mounted) showError(context, AppError.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pro = widget.asProfessional;
    return AuthScaffold(
      title: pro ? 'Ingreso para profesionales' : 'Ingresa a tu cuenta',
      subtitle: pro ? 'Recibe pedidos, gestiona tus trabajos y tu billetera.' : 'Pide ayuda ¡Ya! cuando la necesites.',
      child: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DemoAccountsHint(professional: pro),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Correo electrónico',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
                validator: Validators.email,
              ),
              const SizedBox(height: HySpacing.md),
              PasswordField(
                controller: _password,
                validator: (v) => (v ?? '').isEmpty ? 'Escribe tu contraseña' : null,
                onSubmitted: (_) => _submit(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.push(Routes.forgot),
                  child: const Text('¿Olvidaste tu contraseña?'),
                ),
              ),
              const SizedBox(height: HySpacing.sm),
              PrimaryButton(
                label: 'Ingresar',
                loading: _loading,
                onPressed: _submit,
                color: pro ? HyColors.navy : null,
              ),
              const SizedBox(height: HySpacing.lg),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('¿No tienes cuenta?', style: TextStyle(fontSize: 16)),
                  TextButton(
                    onPressed: () => context.push('${Routes.register}?rol=${pro ? 'pro' : 'cliente'}'),
                    child: Text(pro ? 'Regístrate como profesional' : 'Crear cuenta'),
                  ),
                ],
              ),
              const Divider(height: HySpacing.xxl),
              TextButton.icon(
                onPressed: () => context.pushReplacement('${Routes.login}?rol=${pro ? 'cliente' : 'pro'}'),
                icon: Icon(pro ? Icons.home_repair_service_outlined : Icons.engineering_outlined),
                label: Text(pro ? 'Necesito un servicio' : '¿Eres profesional? Ingresa aquí'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
