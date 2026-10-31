import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';

/// Un número público de emergencias.
class EmergencyNumber {
  const EmergencyNumber(this.number, this.label, this.detail);

  final String number;
  final String label;
  final String detail;
}

/// Números públicos de emergencia de Bolivia (nacionales, gratuitos).
///
/// Antes de publicar la app, confirmar cada número con una fuente oficial
/// (Policía Boliviana y Ministerio de Salud). No se incluyen números locales de
/// una sola ciudad.
const boliviaEmergencyNumbers = <EmergencyNumber>[
  EmergencyNumber('110', 'Policía', 'Radio Patrullas 110. Si corres peligro o hay un delito.'),
  EmergencyNumber('118', 'Ambulancia', 'Emergencias médicas.'),
  EmergencyNumber('119', 'Bomberos', 'Incendio, fuga de gas o rescate.'),
];

/// Lo que la app no hace. Se muestra junto a los números.
const notEmergencyServiceText =
    'HandiMan ¡Ya! no es un servicio de emergencias. La app no avisa a la Policía, '
    'a una ambulancia ni a los bomberos, y nadie de HandiMan ¡Ya! va a ir a tu domicilio. '
    'Si estás en peligro, llama tú directamente.';

/// Aviso visible de que la app no atiende emergencias.
class NotEmergencyServiceBanner extends StatelessWidget {
  const NotEmergencyServiceBanner({super.key});

  @override
  Widget build(BuildContext context) => const InfoBanner(
    key: Key('not-emergency-service'),
    icon: Icons.warning_amber_rounded,
    tone: StatusTone.danger,
    text: notEmergencyServiceText,
  );
}

/// Lista de números con "Llamar" (abre el teléfono) y "Copiar".
class EmergencyNumbersList extends StatelessWidget {
  const EmergencyNumbersList({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [for (final n in boliviaEmergencyNumbers) _NumberCard(n: n)],
  );
}

class _NumberCard extends StatelessWidget {
  const _NumberCard({required this.n});

  final EmergencyNumber n;

  Future<void> _copy(BuildContext context, {bool afterFailedCall = false}) async {
    try {
      await Clipboard.setData(ClipboardData(text: n.number));
    } catch (_) {
      // Sin portapapeles: igual mostramos el número en el mensaje.
    }
    if (!context.mounted) return;
    showMessage(
      context,
      afterFailedCall
          ? 'No pudimos abrir el teléfono. Marca el ${n.number} (lo copiamos).'
          : 'Copiamos el ${n.number} (${n.label}).',
    );
  }

  Future<void> _call(BuildContext context) async {
    var ok = false;
    try {
      ok = await launchUrl(
        Uri(scheme: 'tel', path: n.number),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) await _copy(context, afterFailedCall: true);
  }

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: HySpacing.xs),
    child: Padding(
      padding: const EdgeInsets.all(HySpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                n.number,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: HyColors.danger),
              ),
              const SizedBox(width: HySpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    Text(n.detail, style: const TextStyle(color: HyColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: HySpacing.xs),
          Wrap(
            spacing: HySpacing.xs,
            runSpacing: HySpacing.xs,
            children: [
              FilledButton.icon(
                key: Key('emergency-call-${n.number}'),
                style: FilledButton.styleFrom(
                  backgroundColor: HyColors.danger,
                  minimumSize: const Size(0, HySizes.touch),
                ),
                onPressed: () => _call(context),
                icon: const Icon(Icons.call),
                label: Text('Llamar al ${n.number}'),
              ),
              OutlinedButton.icon(
                key: Key('emergency-copy-${n.number}'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, HySizes.touch)),
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy),
                label: const Text('Copiar'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
