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
    final who = b.otherName ?? (b.status == BookingStatus.awaitingResponse ? 'Buscando profesional…' : 'Sin asignar');
    return AppCard(
      onTap: () => context.push(Routes.booking(b.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(b.category, style: Theme.of(context).textTheme.titleMedium)),
              StatusChip(b.status),
            ],
          ),
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
          Wrap(
            spacing: HySpacing.md,
            runSpacing: 4,
            children: [
              _Meta(icon: asProfessional ? Icons.person_outline : Icons.engineering_outlined, text: who),
              _Meta(
                icon: b.mode == BookingMode.now ? Icons.bolt_rounded : Icons.event_outlined,
                text: b.mode == BookingMode.now
                    ? 'Ahora · ${Fmt.relative(b.createdAt)}'
                    : Fmt.dateTime(b.scheduledStart ?? b.createdAt),
              ),
              _Meta(icon: Icons.place_outlined, text: b.zone ?? b.city.replaceAll(' de la Sierra', '')),
              if (b.distanceKm != null) _Meta(icon: Icons.near_me_outlined, text: 'A ${Fmt.km(b.distanceKm!)}'),
              if (b.quoteAmount != null) _Meta(icon: Icons.request_quote_outlined, text: Fmt.bs(b.quoteAmount!)),
            ],
          ),
          if (b.isOffer && asProfessional) ...[
            const SizedBox(height: HySpacing.sm),
            const InfoBanner(
              icon: Icons.bolt_rounded,
              tone: StatusTone.brand,
              text: 'Pedido ¡Ya! cerca de ti. Ábrelo para aceptarlo.',
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
      Text(text, style: const TextStyle(color: HyColors.textSecondary, fontSize: 15)),
    ],
  );
}
