import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/providers.dart';
import '../../core/widgets/word_safe_text.dart';

const _faq = <(String, String)>[
  (
    '¿Cómo funciona ¡Ya!?',
    'Eliges el servicio y tu zona. Avisamos a los profesionales verificados disponibles cerca de ti. Aceptan tu precio o te proponen otro, y nadie empieza hasta que los dos acepten el mismo. Te mostramos quién es y puedes chatear con él.',
  ),
  (
    '¿Y si prefiero programar?',
    'Busca un profesional, revisa su perfil y elige "Programar". Indica día y hora; el profesional confirma o te envía una cotización.',
  ),
  (
    '¿Cómo pago?',
    'Pagas directamente al profesional, en efectivo o por QR, cuando el trabajo termina. HandiMan ¡Ya! no cobra al cliente por usar la app.',
  ),
  (
    '¿Quién ve mi dirección?',
    'Solo el profesional que acepta tu solicitud, y solo mientras el trabajo está activo. Antes de aceptar, los profesionales solo ven tu zona.',
  ),
  (
    '¿Los profesionales están verificados?',
    'Sí. Antes de recibir pedidos revisamos su carnet de identidad y sus datos. Verás la insignia "Verificado" en su perfil.',
  ),
  (
    '¿Cómo cancelo?',
    'Abre la solicitud en "Solicitudes" y toca "Cancelar". Te pediremos el motivo para mejorar el servicio.',
  ),
  (
    'Tuve un problema con un trabajo',
    'Abre la solicitud y toca "Reportar un problema". Nuestro equipo revisará el caso con ambas partes.',
  ),
  (
    'Soy profesional: ¿cómo funciona la billetera?',
    'Tu billetera tiene saldo prepagado. Al aceptar un trabajo se reserva la comisión; se cobra cuando el trabajo se completa y se libera si se cancela. Puedes recargar por transferencia o QR.',
  ),
];

class SupportPage extends StatelessWidget {
  const SupportPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Ayuda y soporte')),
      body: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.sm),
                const InfoBanner(
                  icon: Icons.support_agent_outlined,
                  text: 'Si tu problema es con una solicitud, ábrela y toca "Reportar un problema". Así tenemos todos los datos del trabajo.',
                ),
                const SizedBox(height: HySpacing.sm),
                SecondaryButton(
                  label: 'Escribir al equipo',
                  icon: Icons.mail_outline,
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => const _ContactSheet(),
                  ),
                ),
                const SectionHeader(title: 'Preguntas frecuentes'),
                for (final (q, a) in _faq)
                  Card(
                    margin: const EdgeInsets.only(bottom: HySpacing.xs),
                    child: ExpansionTile(
                      shape: const Border(),
                      title: Text(q, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      childrenPadding: const EdgeInsets.fromLTRB(HySpacing.md, 0, HySpacing.md, HySpacing.md),
                      children: [Text(a, style: const TextStyle(fontSize: 16, height: 1.4))],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactSheet extends ConsumerStatefulWidget {
  const _ContactSheet();

  @override
  ConsumerState<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends ConsumerState<_ContactSheet> {
  final _form = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _body = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _sending = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).contactSupport(subject: _subject.text, body: _body.text),
      success: 'Recibimos tu mensaje. Te responderemos por la app.',
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
    child: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Escribir al equipo', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: HySpacing.md),
          TextFormField(
            controller: _subject,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Asunto'),
            validator: (v) => (v ?? '').trim().length < 3 ? 'Escribe el asunto' : null,
          ),
          TextFormField(
            controller: _body,
            maxLines: 5,
            minLines: 3,
            maxLength: 3000,
            decoration: const InputDecoration(labelText: 'Tu mensaje'),
            validator: (v) => (v ?? '').trim().length < 5 ? 'Cuéntanos un poco más' : null,
          ),
          const SizedBox(height: HySpacing.sm),
          PrimaryButton(label: 'Enviar', loading: _sending, onPressed: _send),
        ],
      ),
    ),
  );
}
