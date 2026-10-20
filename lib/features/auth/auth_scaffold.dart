import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/brand_logo.dart';
import '../../data/demo/demo_backend.dart';
import '../../data/models/user.dart';
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

/// En modo demostración muestra el código y los números de prueba.
class DemoAccountsHint extends ConsumerWidget {
  const DemoAccountsHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(isDemoProvider)) return const SizedBox.shrink();
    String n(String p) => p.substring(4);
    return Container(
      margin: const EdgeInsets.only(bottom: HySpacing.lg),
      padding: const EdgeInsets.all(HySpacing.sm),
      decoration: BoxDecoration(color: HyColors.infoSoft, borderRadius: BorderRadius.circular(HyRadii.md)),
      child: Text(
        'Modo demostración: no se envía nada y el código es ${DemoBackend.demoCode}.\n'
        'Cliente ${n(DemoBackend.customerPhone)} · Profesional ${n(DemoBackend.professionalPhone)} · '
        'Admin ${n(DemoBackend.adminPhone)}. Cualquier otro número crea una cuenta nueva.',
        style: const TextStyle(color: HyColors.info, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Celular de Bolivia con +591 fijo.
class PhoneField extends StatelessWidget {
  const PhoneField({super.key, required this.controller, this.onSubmitted, this.label = 'Número de celular'});

  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;
  final String label;

  @override
  Widget build(BuildContext context) => TextFormField(
    key: const Key('phone-field'),
    controller: controller,
    keyboardType: TextInputType.phone,
    autofillHints: const [AutofillHints.telephoneNumberNational],
    textInputAction: TextInputAction.done,
    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 1),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d +\-]')), LengthLimitingTextInputFormatter(16)],
    decoration: InputDecoration(
      labelText: label,
      hintText: '7123 4567',
      prefixIcon: const Icon(Icons.phone_iphone),
      prefixText: '🇧🇴 +591  ',
    ),
    validator: Validators.boliviaPhone,
    onFieldSubmitted: onSubmitted,
  );
}

/// WhatsApp o SMS.
class ChannelPicker extends StatelessWidget {
  const ChannelPicker({super.key, required this.value, required this.onChanged});

  final CodeChannel value;
  final ValueChanged<CodeChannel> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('¿Por dónde quieres recibir el código?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: HySpacing.xs),
      SegmentedButton<CodeChannel>(
        segments: const [
          ButtonSegment(
            value: CodeChannel.whatsapp,
            label: Text('WhatsApp', key: Key('channel-whatsapp')),
            icon: Icon(Icons.chat_rounded),
          ),
          ButtonSegment(
            value: CodeChannel.sms,
            label: Text('SMS', key: Key('channel-sms')),
            icon: Icon(Icons.sms_outlined),
          ),
        ],
        selected: {value},
        showSelectedIcon: false,
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    ],
  );
}

/// Las 6 cifras del código. Se envía solo al completar los 6 números.
class CodeField extends StatelessWidget {
  const CodeField({super.key, required this.controller, required this.onCompleted, this.fieldKey});

  final TextEditingController controller;
  final VoidCallback onCompleted;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) => TextFormField(
    key: fieldKey ?? const Key('code-field'),
    controller: controller,
    autofocus: true,
    keyboardType: TextInputType.number,
    autofillHints: const [AutofillHints.oneTimeCode],
    textAlign: TextAlign.center,
    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 10),
    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
    decoration: const InputDecoration(labelText: 'Código de 6 números', hintText: '······'),
    validator: Validators.otp,
    onChanged: (v) {
      if (v.length == 6) onCompleted();
    },
  );
}

/// +591 7123 4567
String formatBoliviaPhone(String phone) {
  final d = phone.replaceFirst('+591', '');
  return d.length == 8 ? '+591 ${d.substring(0, 4)} ${d.substring(4)}' : phone;
}

/// Cuenta regresiva para volver a pedir un código.
mixin ResendCooldown<T extends StatefulWidget> on State<T> {
  int cooldown = 0;
  Timer? _cooldownTimer;

  void startCooldown([int seconds = 60]) {
    _cooldownTimer?.cancel();
    setState(() => cooldown = seconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || cooldown <= 1) {
        t.cancel();
        if (mounted) setState(() => cooldown = 0);
        return;
      }
      setState(() => cooldown--);
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }
}
