import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../router.dart';

class BookingCard extends StatelessWidget {
  const BookingCard({super.key, required this.booking, required this.asProfessional});

  final BookingSummary booking;
  final bool asProfessional;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final who =
        b.otherName ??
        (b.status.isPendingScheduled(b.mode)
            ? 'Sin asignar'
            : b.status == BookingStatus.awaitingResponse
            ? 'Buscando profesional…'
            : 'Sin asignar');
    final price = b.priceBs;
    final live = b.status.isOpen || b.status.isActive;
    return AppCard(
      key: Key('booking-card-${b.id}'),
      onTap: () => context.push(Routes.booking(b.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Solicitud #${b.code}',
                  key: Key('booking-code-${b.id}'),
                  style: const TextStyle(color: HyColors.textSecondary, fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: HySpacing.xs),
              Flexible(child: StatusChip(b.status, mode: b.mode)),
            ],
          ),
          const SizedBox(height: 2),
          Text(b.category, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: HySpacing.xs),
          if (b.problems.isNotEmpty)
            Text(
              b.problems.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          if (b.problems.isEmpty || b.description != b.problems.join('. '))
            Text(b.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: HySpacing.xs),
          price == null
              ? Text(
                  'Precio pendiente',
                  key: Key('booking-price-${b.id}'),
                  style: const TextStyle(color: HyColors.textMuted, fontSize: 17, fontWeight: FontWeight.w700),
                )
              : Text.rich(
                  key: Key('booking-price-${b.id}'),
                  TextSpan(
                    children: [
                      TextSpan(
                        text: b.status == BookingStatus.completed && b.finalAmount != null
                            ? 'Total '
                            : 'Precio acordado ',
                        style: const TextStyle(color: HyColors.textSecondary, fontSize: 15),
                      ),
                      TextSpan(
                        text: Fmt.bs(price),
                        style: const TextStyle(color: HyColors.navy, fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
          const SizedBox(height: HySpacing.xs),
          Wrap(
            spacing: HySpacing.md,
            runSpacing: 4,
            children: [
              _Meta(icon: asProfessional ? Icons.person_outline : Icons.engineering_outlined, text: who),
              _Meta(
                icon: b.mode == BookingMode.now ? Icons.bolt_rounded : Icons.event_outlined,
                text: b.mode == BookingMode.now
                    ? (live ? 'Ahora' : Fmt.dateTime(b.createdAt))
                    : Fmt.dateTime(b.scheduledStart ?? b.createdAt),
              ),
              _Meta(icon: Icons.place_outlined, text: b.zone ?? b.city.replaceAll(' de la Sierra', '')),
              if (b.distanceKm != null) _Meta(icon: Icons.near_me_outlined, text: 'A ${Fmt.km(b.distanceKm!)}'),
            ],
          ),
          if (b.isOffer && asProfessional) ...[
            const SizedBox(height: HySpacing.sm),
            InfoBanner(
              icon: b.mode == BookingMode.scheduled ? Icons.event_outlined : Icons.bolt_rounded,
              tone: StatusTone.brand,
              text: b.mode == BookingMode.scheduled
                  ? 'Solicitud programada cerca de ti. Ábrela para ver el precio.'
                  : 'Pedido ¡Ya! cerca de ti. Ábrelo para ver el precio.',
            ),
          ],
          if (!asProfessional && b.status == BookingStatus.completed && !b.hasReview) ...[
            const SizedBox(height: HySpacing.sm),
            const InfoBanner(icon: Icons.star_outline_rounded, tone: StatusTone.warning, text: 'Califica este trabajo'),
          ],
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: HyColors.textMuted),
      const SizedBox(width: 4),
      Flexible(
        child: Text(text, style: const TextStyle(color: HyColors.textSecondary, fontSize: 15)),
      ),
    ],
  );
}
