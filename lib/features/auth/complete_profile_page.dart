import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../legal/legal_texts.dart';
import 'auth_scaffold.dart';

/// Después del primer código: nombre, ciudad y cómo quiere usar la app.
/// Quien elige ofrecer sus servicios sigue con su perfil profesional
/// (servicios y documentos), que revisa el equipo antes de aprobarlo.
class CompleteProfilePage extends ConsumerStatefulWidget {
  const CompleteProfilePage({super.key});

  @override
  ConsumerState<CompleteProfilePage> createState() => _CompleteProfilePageState();
}

class _CompleteProfilePageState extends ConsumerState<CompleteProfilePage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  int? _cityId;
  late AppRole _role = ref.read(entryIntentProvider) == AppRole.professional ? AppRole.professional : AppRole.customer;
  bool _terms = false;
  bool _termsError = false;
  bool _loading = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final valid = _form.currentState!.validate();
    setState(() => _termsError = !_terms);
    if (!valid || !_terms) return;
    setState(() => _loading = true);
    await runGuarded(context, () async {
      final api = ref.read(backendProvider);
      await ref.read(entryIntentProvider.notifier).set(_role);
      await api.completeSignup(fullName: _name.text, cityId: _cityId!, acceptTerms: true);
      // Queda registrada la versión de lo que aceptó.
      for (final doc in const [LegalDoc.terms, LegalDoc.privacy, LegalDoc.acceptableUse]) {
        try {
          await api.recordConsent(doc.key, legalVersion);
        } catch (_) {
          // No bloquea el ingreso; se vuelve a registrar en la próxima aceptación.
        }
      }
      ref.invalidate(accountProvider);
    });
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final cities = ref.watch(citiesProvider).value ?? const [];
    final pro = _role == AppRole.professional;
    return AuthScaffold(
      showBack: false,
      title: 'Ya casi terminamos',
      subtitle: 'Cuéntanos cómo te llamas y dónde estás.',
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('profile-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.name],
              decoration: const InputDecoration(labelText: 'Nombre y apellido', prefixIcon: Icon(Icons.person_outline)),
              validator: Validators.fullName,
            ),
            const SizedBox(height: HySpacing.md),
            DropdownButtonFormField<int>(
              key: const Key('profile-city'),
              initialValue: _cityId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Ciudad', prefixIcon: Icon(Icons.location_city_outlined)),
              items: [for (final c in cities) DropdownMenuItem(value: c.id, child: Text(c.name))],
              onChanged: (v) => setState(() => _cityId = v),
              validator: (v) => v == null ? 'Elige tu ciudad' : null,
            ),
            const SizedBox(height: HySpacing.lg),
            const Text(
              '¿Cómo quieres usar HandiMan ¡Ya!?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: HySpacing.xs),
            _RoleOption(
              key: const Key('role-customer'),
              selected: !pro,
              icon: Icons.home_repair_service_rounded,
              title: 'Necesito servicios',
              subtitle: 'Encuentra profesionales verificados cerca de ti',
              onTap: () => setState(() => _role = AppRole.customer),
            ),
            const SizedBox(height: HySpacing.sm),
            _RoleOption(
              key: const Key('role-professional'),
              selected: pro,
              icon: Icons.engineering_rounded,
              title: 'Quiero ofrecer mis servicios',
              subtitle: 'Después eliges tus servicios y subes tus documentos para la verificación',
              onTap: () => setState(() => _role = AppRole.professional),
            ),
            const SizedBox(height: HySpacing.xs),
            const Text(
              'Con la misma cuenta puedes pedir servicios y, si te aprobamos, también trabajar como profesional.',
              style: TextStyle(color: HyColors.textMuted, fontSize: 14),
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
              key: const Key('profile-continue'),
              label: 'Continuar',
              loading: _loading,
              onPressed: _submit,
              color: pro ? HyColors.navy : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleOption extends StatelessWidget {
  const _RoleOption({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? HyColors.primary.withValues(alpha: 0.08) : HyColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HyRadii.lg),
        side: BorderSide(color: selected ? HyColors.primary : HyColors.border, width: selected ? 2 : 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HyRadii.lg),
        child: Padding(
          padding: const EdgeInsets.all(HySpacing.md),
          child: Row(
            children: [
              Icon(icon, color: selected ? HyColors.primary : HyColors.textSecondary, size: 30),
              const SizedBox(width: HySpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    Text(subtitle, style: const TextStyle(fontSize: 14, color: HyColors.textSecondary)),
                  ],
                ),
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
            Checkbox(key: const Key('profile-terms'), value: value, onChanged: (v) => onChanged(v ?? false)),
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
