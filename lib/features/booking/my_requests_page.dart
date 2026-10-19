import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import '../../router.dart';
import 'booking_card.dart';

/// "Solicitudes" del cliente: activas e historial.
class MyRequestsPage extends ConsumerWidget {
  const MyRequestsPage({super.key, required this.asProfessional});

  final bool asProfessional;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookings = ref.watch(myBookingsProvider(asProfessional));
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mis solicitudes'),
          bottom: const TabBar(
            labelStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            indicatorColor: HyColors.primary,
            labelColor: HyColors.navy,
            tabs: [
              Tab(text: 'En curso'),
              Tab(text: 'Historial'),
            ],
          ),
        ),
        body: bookings.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(myBookingsProvider(asProfessional))),
          data: (list) {
            final open = list.where((b) => !b.status.isClosed).toList();
            final closed = list.where((b) => b.status.isClosed).toList();
            return TabBarView(
              children: [
                BookingList(
                  bookings: open,
                  asProfessional: asProfessional,
                  empty: EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'No tienes solicitudes en curso',
                    message: 'Cuando pidas un servicio, aquí verás su estado en tiempo real.',
                    action: PrimaryButton(
                      label: 'Pedir ¡Ya!',
                      icon: Icons.bolt_rounded,
                      expand: false,
                      onPressed: () => context.push(Routes.ya),
                    ),
                  ),
                ),
                BookingList(
                  bookings: closed,
                  asProfessional: asProfessional,
                  empty: const EmptyState(
                    icon: Icons.history,
                    title: 'Todavía no hay historial',
                    message: 'Aquí aparecerán tus trabajos completados y cancelados.',
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class BookingList extends ConsumerWidget {
  const BookingList({super.key, required this.bookings, required this.asProfessional, required this.empty});

  final List<BookingSummary> bookings;
  final bool asProfessional;
  final Widget empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      color: HyColors.primary,
      onRefresh: () async => ref.invalidate(myBookingsProvider(asProfessional)),
      child: bookings.isEmpty
          ? ListView(children: [empty])
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.md, HySpacing.page, HySpacing.xxl),
              itemCount: bookings.length,
              separatorBuilder: (_, _) => const SizedBox(height: HySpacing.sm),
              itemBuilder: (_, i) => Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: HySizes.maxContentWidth),
                  child: BookingCard(booking: bookings[i], asProfessional: asProfessional),
                ),
              ),
            ),
    );
  }
}
