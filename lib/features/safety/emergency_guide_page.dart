import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import 'emergency_numbers.dart';

const _ifInDanger = <String>[
  'Sal a un lugar seguro o donde haya otras personas.',
  'Llama tú al 110 (Policía) o al número que corresponda.',
  'Avisa a alguien de confianza dónde estás.',
  'Cuando estés a salvo, repórtalo en la app para que el equipo revise el caso.',
];

const _tips = <(String, String)>[
  (
    'Antes de que llegue',
    'Revisa en la solicitud el nombre, la foto y la insignia "Verificado" del profesional. '
        'Acuerda el trabajo y el precio por el chat de la app.',
  ),
  (
    'Cuando llegue',
    'Comprueba que es la misma persona de la foto. Pídele el código de 6 números y escríbelo en "Verificar llegada". '
        'Si no tiene el código o no es la persona, no le abras.',
  ),
  (
    'Durante el trabajo',
    'Si puedes, no estés solo en casa o avisa a alguien con "Compartir mi viaje". '
        'Guarda dinero, documentos y objetos de valor. No compartas contraseñas, tarjetas ni códigos.',
  ),
  (
    'Si algo no está bien',
    'Puedes pedirle que se vaya y cancelar la solicitud. Reporta lo que pasó desde la solicitud, '
        'el chat o su perfil (menú ⋮). Tu reporte es confidencial.',
  ),
];

/// Guía de emergencia: números públicos, qué hacer y consejos. Es estática:
/// no llama a nadie por su cuenta ni envía datos.
class EmergencyGuidePage extends StatelessWidget {
  const EmergencyGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Guía de emergencia')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: HySpacing.xxl),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.sm),
                const NotEmergencyServiceBanner(),
                const SectionHeader(title: 'Números de emergencia en Bolivia'),
                const EmergencyNumbersList(),
                const SizedBox(height: HySpacing.xs),
                const Text(
                  'Son números públicos y gratuitos. Si uno no responde, llama al 110.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
                const SectionHeader(title: 'Si estás en peligro ahora'),
                for (final (i, step) in _ifInDanger.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HySpacing.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${i + 1}.', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(width: HySpacing.xs),
                        Expanded(child: Text(step, style: const TextStyle(fontSize: 16))),
                      ],
                    ),
                  ),
                const SectionHeader(title: 'Consejos para recibir a un profesional en casa'),
                for (final (title, body) in _tips)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HySpacing.xs),
                    child: AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: text.titleMedium),
                          const SizedBox(height: 4),
                          Text(body, style: const TextStyle(fontSize: 16, height: 1.4)),
                        ],
                      ),
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
