import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import '../booking/my_requests_page.dart';
import '../../core/widgets/word_safe_text.dart';

/// Pedidos nuevos (ofertas ¡Ya! y solicitudes directas) o trabajos del profesional.
class ProJobsPage extends ConsumerWidget {
  const ProJobsPage({super.key, required this.incoming});

  final bool incoming;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookings = ref.watch(myBookingsProvider(true));
    Widget body(List<BookingSummary> Function(List<BookingSummary>) pick, Widget empty) => bookings.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(myBookingsProvider(true))),
      data: (list) => BookingList(bookings: pick(list), asProfessional: true, empty: empty),
    );

    if (incoming) {
      return Scaffold(
        appBar: AppBar(title: const OneLineText('Pedidos nuevos')),
        body: body(
          (l) => l.where((b) => b.isOffer || b.status.isOpen).toList(),
          const EmptyState(
            icon: Icons.inbox_outlined,
            title: 'No hay pedidos nuevos',
            message: 'Activa "Disponible para ¡Ya!" en Inicio para recibir pedidos de clientes cerca de ti.',
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const OneLineText('Mis trabajos'),
          bottom: const TabBar(
            labelStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            indicatorColor: HyColors.primary,
            labelColor: HyColors.navy,
            tabs: [
              Tab(text: 'Activos'),
              Tab(text: 'Historial'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            body(
              (l) => l.where((b) => !b.isOffer && (b.status.isActive || b.status == BookingStatus.disputed)).toList(),
              const EmptyState(
                icon: Icons.handyman_outlined,
                title: 'No tienes trabajos activos',
                message: 'Cuando aceptes un pedido aparecerá aquí.',
              ),
            ),
            body(
              (l) => l.where((b) => !b.isOffer && b.status.isClosed).toList(),
              const EmptyState(
                icon: Icons.history,
                title: 'Todavía no hay historial',
                message: 'Aquí verás tus trabajos completados y cancelados.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
