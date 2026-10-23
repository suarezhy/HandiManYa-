import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/professional.dart';
import '../../router.dart';

class ProfessionalCard extends StatelessWidget {
  const ProfessionalCard({super.key, required this.pro, this.onTap});

  final ProfessionalSummary pro;

  /// Por defecto abre el perfil.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppCard(
      onTap: onTap ?? () => context.push(Routes.professional(pro.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PersonAvatar(name: pro.displayName, url: pro.photoUrl, size: 64),
              const SizedBox(width: HySpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: HySpacing.xs,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(pro.displayName, style: text.titleMedium),
                        if (pro.isVerified) const VerifiedBadge(compact: true),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      pro.primaryCategory ?? '',
                      style: const TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    RatingLabel(rating: pro.ratingAvg, count: pro.ratingCount),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: HySpacing.sm),
          Row(
            children: [
              const Icon(Icons.place_outlined, size: 18, color: HyColors.textMuted),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  pro.areaLabel,
                  style: const TextStyle(color: HyColors.textSecondary, fontSize: 15),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: HySpacing.xs),
          Wrap(
            spacing: HySpacing.md,
            runSpacing: HySpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AvailabilityDot(available: pro.isAvailable),
              if (pro.priceFrom != null)
                Text(
                  'Desde ${Fmt.bsShort(pro.priceFrom!)}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
