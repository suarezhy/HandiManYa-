import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/brand_logo.dart';
import '../../data/demo/demo_backend.dart';
import '../../data/providers.dart';

/// Marco común de las pantallas de acceso: logo, título y contenido con
/// desplazamiento (nada se corta con letra grande).
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({super.key, required this.title, this.subtitle, required this.child, this.showBack = true});

  final String title;
  final String? subtitle;
  final Widget child;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: HyColors.surface,
      appBar: showBack ? AppBar(backgroundColor: HyColors.surface) : null,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.md, HySpacing.page, HySpacing.xxl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BrandLogo(height: 40),
                  const SizedBox(height: HySpacing.xl),
                  Semantics(header: true, child: Text(title, style: text.headlineMedium)),
                  if (subtitle != null) ...[
                    const SizedBox(height: HySpacing.xs),
                    Text(subtitle!, style: text.bodyLarge?.copyWith(color: HyColors.textSecondary)),
                  ],
                  const SizedBox(height: HySpacing.xl),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// En modo demostración muestra las cuentas de prueba.
class DemoAccountsHint extends ConsumerWidget {
  const DemoAccountsHint({super.key, required this.professional});

  final bool professional;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(isDemoProvider)) return const SizedBox.shrink();
    final email = professional ? DemoBackend.professionalEmail : DemoBackend.customerEmail;
    return Container(
      margin: const EdgeInsets.only(bottom: HySpacing.lg),
      padding: const EdgeInsets.all(HySpacing.sm),
      decoration: BoxDecoration(color: HyColors.infoSoft, borderRadius: BorderRadius.circular(HyRadii.md)),
      child: Text(
        'Cuenta de prueba: $email · contraseña ${DemoBackend.demoPassword}\n'
        'Código de verificación de correo: ${DemoBackend.demoCode}',
        style: const TextStyle(color: HyColors.info, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.label = 'Contraseña',
    this.validator,
    this.autofillHints = const [AutofillHints.password],
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final Iterable<String> autofillHints;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    obscureText: _hidden,
    autofillHints: widget.autofillHints,
    validator: widget.validator,
    onFieldSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      labelText: widget.label,
      prefixIcon: const Icon(Icons.lock_outline),
      suffixIcon: IconButton(
        tooltip: _hidden ? 'Mostrar contraseña' : 'Ocultar contraseña',
        icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
        onPressed: () => setState(() => _hidden = !_hidden),
      ),
    ),
  );
}
