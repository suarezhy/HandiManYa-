import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../data/models/booking.dart';
import '../booking/live_trip.dart';
import '../common/safety_menu.dart';
import 'emergency_numbers.dart';

/// Enlace "Emergencia" dentro de una solicitud activa. Solo muestra los
/// números públicos y atajos a lo que ya existe (compartir el viaje y
/// reportar). No avisa a nadie por su cuenta.
class EmergencyLink extends StatelessWidget {
  const EmergencyLink({super.key, required this.b});

  final BookingDetail b;

  /// Con profesional asignado y el trabajo sin terminar (igual que el servidor
  /// para compartir el viaje).
  static bool showsFor(BookingDetail b) => b.status.isActive;

  @override
  Widget build(BuildContext context) {
    if (!showsFor(b)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('emergency-link'),
          style: TextButton.styleFrom(
            foregroundColor: HyColors.danger,
            minimumSize: const Size(0, HySizes.touch),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          onPressed: () => showEmergencySheet(context, b),
          icon: const Icon(Icons.emergency_outlined),
          label: const Text('Emergencia'),
        ),
      ),
    );
  }
}

Future<void> showEmergencySheet(BuildContext context, BookingDetail b) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (c) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.85,
    maxChildSize: 0.95,
    builder: (c, scroll) => _EmergencySheet(b: b, scroll: scroll, pageContext: context),
  ),
);

class _EmergencySheet extends StatelessWidget {
  const _EmergencySheet({required this.b, required this.scroll, required this.pageContext});

  final BookingDetail b;
  final ScrollController scroll;
  final BuildContext pageContext;

  ({String id, String name})? get _other {
    if (b.viewerIsCustomer) {
      final p = b.professional;
      return p == null ? null : (id: p.id, name: p.displayName);
    }
    return (id: b.customerId, name: b.customerFirstName);
  }

  @override
  Widget build(BuildContext context) {
    final other = _other;
    return ListView(
      controller: scroll,
      // La barra de navegación de Android y el indicador del iPhone.
      padding: EdgeInsets.fromLTRB(
        HySpacing.page,
        0,
        HySpacing.page,
        HySpacing.xl + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Text('Emergencia', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: HySpacing.sm),
        const NotEmergencyServiceBanner(),
        const SizedBox(height: HySpacing.md),
        const Text('Llama a un número público', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: HySpacing.xs),
        const EmergencyNumbersList(),
        const SizedBox(height: HySpacing.md),
        if (b.viewerIsCustomer) ...[
          const Text(
            'Avisa a alguien de confianza: le mandas un enlace para que siga este servicio.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: HySpacing.xs),
          SecondaryButton(
            key: const Key('emergency-share-trip'),
            label: 'Compartir mi viaje',
            icon: Icons.share_outlined,
            onPressed: () {
              Navigator.pop(context);
              showShareTripSheet(pageContext, b);
            },
          ),
          const SizedBox(height: HySpacing.md),
        ],
        if (other != null) ...[
          const Text(
            'Reporta lo que pasa al equipo de HandiMan ¡Ya!. Lo revisan personas, no es una respuesta inmediata '
            'ni reemplaza una llamada de emergencia.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: HySpacing.xs),
          SecondaryButton(
            key: const Key('emergency-report'),
            label: 'Reportar al equipo',
            icon: Icons.flag_outlined,
            onPressed: () {
              Navigator.pop(context);
              showReportSheet(pageContext, userId: other.id, name: other.name, bookingId: b.id);
            },
          ),
        ],
      ],
    );
  }
}
