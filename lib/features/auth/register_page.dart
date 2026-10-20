import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../legal/legal_texts.dart';
import 'auth_scaffold.dart';

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key, required this.asProfessional});

  final bool asProfessional;

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  int? _cityId;
  bool _terms = false;
  bool _termsError = false;
  bool _loading = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final valid = _form.currentState!.validate();
    setState(() => _termsError = !_terms);
    if (!valid || !_terms) return;
    setState(() => _loading = true);
    final ok = await runGuarded(context, () async {
      await ref.read(entryIntentProvider.notifier).set(widget.asProfessional ? AppRole.professional : AppRole.customer);
      await ref
          .read(backendProvider)
          .signUp(
            email: _email.text,
            password: _password.text,
            fullName: _name.text,
            phone: Validators.normalizeBoliviaPhone(_phone.text)!,
            cityId: _cityId!,
            wantsToBeProfessional: widget.asProfessional,
          );
    });
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) context.go('${Routes.verify}?correo=${Uri.encodeComponent(_email.text.trim())}');
  }

  @override
  Widget build(BuildContext context) {
    final cities = ref.watch(citiesProvider).value ?? const [];
    final pro = widget.asProfessional;
    return AuthScaffold(
      title: pro ? 'Regístrate como profesional' : 'Crea tu cuenta',
      subtitle: pro
          ? 'Primero creamos tu cuenta. Después completas tu perfil profesional y lo revisamos.'
          : 'Solo te pedimos lo necesario.',
      child: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Nombre y apellido',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: Validators.fullName,
              ),
              const SizedBox(height: HySpacing.md),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumberNational],
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d +\-]')),
                  LengthLimitingTextInputFormatter(16),
                ],
                decoration: const InputDecoration(
                  labelText: 'Celular',
                  hintText: '71234567',
                  prefixIcon: Icon(Icons.phone_iphone),
                  prefixText: '+591 ',
                ),
                validator: Validators.boliviaPhone,
              ),
              const SizedBox(height: HySpacing.md),
              DropdownButtonFormField<int>(
                initialValue: _cityId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Ciudad', prefixIcon: Icon(Icons.location_city_outlined)),
                items: [for (final c in cities) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) => setState(() => _cityId = v),
                validator: (v) => v == null ? 'Elige tu ciudad' : null,
              ),
              const SizedBox(height: HySpacing.md),
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
                label: 'Crea una contraseña',
                autofillHints: const [AutofillHints.newPassword],
                validator: Validators.password,
              ),
              const Padding(
                padding: EdgeInsets.only(top: HySpacing.xs, left: HySpacing.xs),
                child: Text(
                  'Al menos 8 caracteres, con letras y números.',
                  style: TextStyle(color: HyColors.textMuted, fontSize: 14),
                ),
              ),
              const SizedBox(height: HySpacing.md),
              _TermsCheckbox(
                value: _terms,
                showError: _termsError,
                onChanged: (v) => setState(() {
                  _terms = v;
                  if (v) _termsError = false;
                }),
              ),
              const SizedBox(height: HySpacing.lg),
              PrimaryButton(
                label: 'Crear cuenta',
                loading: _loading,
                onPressed: _submit,
                color: pro ? HyColors.navy : null,
              ),
              const SizedBox(height: HySpacing.md),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('¿Ya tienes cuenta?', style: TextStyle(fontSize: 16)),
                  TextButton(onPressed: () => context.pop(), child: const Text('Ingresar')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TermsCheckbox extends StatelessWidget {
  const _TermsCheckbox({required this.value, required this.onChanged, required this.showError});

  final bool value;
  final bool showError;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    const link = TextStyle(
      color: HyColors.primaryDark,
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.underline,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 16, color: HyColors.text),
                    children: [
                      const TextSpan(text: 'Acepto los '),
                      TextSpan(
                        text: 'Términos de uso',
                        style: link,
                        recognizer: TapGestureRecognizer()..onTap = () => showLegalDoc(context, LegalDoc.terms),
                      ),
                      const TextSpan(text: ' y la '),
                      TextSpan(
                        text: 'Política de privacidad',
                        style: link,
                        recognizer: TapGestureRecognizer()..onTap = () => showLegalDoc(context, LegalDoc.privacy),
                      ),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (showError)
          const Padding(
            padding: EdgeInsets.only(left: HySpacing.md),
            child: Text('Debes aceptar para continuar', style: TextStyle(color: HyColors.danger, fontSize: 14)),
          ),
      ],
    );
  }
}
