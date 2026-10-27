import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/button_row.dart';
import '../../data/models/booking.dart';
import '../../data/models/professional.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/safety_menu.dart';
import '../../core/widgets/word_safe_text.dart';

class ProfessionalProfilePage extends ConsumerWidget {
  const ProfessionalProfilePage({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(professionalDetailProvider(id));
    return Scaffold(
      appBar: AppBar(
        title: const OneLineText('Profesional'),
        actions: [if (detail.value case final d?) SafetyMenuButton(userId: id, name: d.summary.displayName)],
      ),
      body: detail.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(professionalDetailProvider(id))),
        data: (d) => d == null
            ? const EmptyState(
                icon: Icons.person_off_outlined,
                title: 'Este perfil no está disponible',
                message: 'Puede que el profesional ya no esté activo.',
              )
            : _Body(detail: d),
      ),
      bottomNavigationBar: detail.value == null ? null : _BottomActions(detail: detail.value!),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.detail});

  final ProfessionalDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = detail.summary;
    final text = Theme.of(context).textTheme;
    final reviews = ref.watch(professionalReviewsProvider(s.id));
    return ListView(
      padding: const EdgeInsets.only(bottom: HySpacing.xxl),
      children: [
        PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: PersonAvatar(name: s.displayName, url: s.photoUrl, size: 104),
              ),
              const SizedBox(height: HySpacing.md),
              Center(
                child: Text(s.displayName, textAlign: TextAlign.center, style: text.headlineSmall),
              ),
              const SizedBox(height: 4),
              Center(
                child: Wrap(
                  spacing: HySpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      s.primaryCategory ?? '',
                      style: const TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w800, fontSize: 17),
                    ),
                    if (s.isVerified) const VerifiedBadge(),
                  ],
                ),
              ),
              const SizedBox(height: HySpacing.xs),
              Center(
                child: RatingLabel(rating: s.ratingAvg, count: s.ratingCount),
              ),
              const SizedBox(height: HySpacing.xs),
              Center(child: AvailabilityDot(available: s.isAvailable)),
              const SizedBox(height: HySpacing.lg),
              Row(
                children: [
                  _Stat(value: detail.yearsExperience?.toString() ?? '—', label: 'años'),
                  _Stat(value: '${s.completedJobs}', label: 'trabajos'),
                  _Stat(value: '${s.ratingCount}', label: 'reseñas'),
                ],
              ),
              const SizedBox(height: HySpacing.md),
              _InfoRow(icon: Icons.place_outlined, text: 'Atiende en: ${s.areaLabel}'),
              const SizedBox(height: HySpacing.xs),
              const _InfoRow(
                icon: Icons.shield_outlined,
                text: 'Por tu seguridad, la ubicación exacta del profesional no se muestra.',
              ),
              if ((detail.bio ?? '').isNotEmpty) ...[
                const SectionHeader(title: 'Sobre mí'),
                Text(detail.bio!, style: text.bodyLarge),
              ],
              if (detail.services.isNotEmpty) ...[
                const SectionHeader(title: 'Servicios y precios'),
                for (final sv in detail.services)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HySpacing.xs),
                    child: AppCard(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(sv.specialty ?? sv.category, style: text.titleSmall),
                                if (sv.specialty != null && sv.specialty != sv.category)
                                  Text(sv.category, style: const TextStyle(color: HyColors.textMuted)),
                              ],
                            ),
                          ),
                          Text(
                            sv.priceFrom == null ? 'A cotizar' : 'Desde ${Fmt.bsShort(sv.priceFrom!)}',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                if ((detail.priceNote ?? '').isNotEmpty)
                  Text(detail.priceNote!, style: const TextStyle(color: HyColors.textSecondary)),
              ],
              if (detail.availability.isNotEmpty) ...[
                const SectionHeader(title: 'Horario de atención'),
                for (final a in detail.availability)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(a.label, style: text.bodyLarge),
                  ),
              ],
              if (detail.portfolioUrls.isNotEmpty) ...[
                const SectionHeader(title: 'Trabajos realizados'),
                SizedBox(
                  height: 120,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: detail.portfolioUrls.length,
                    separatorBuilder: (_, _) => const SizedBox(width: HySpacing.xs),
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(HyRadii.md),
                      child: Image.network(
                        detail.portfolioUrls[i],
                        width: 120,
                        height: 120,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const ColoredBox(
                          color: HyColors.surfaceMuted,
                          child: SizedBox.square(dimension: 120, child: Icon(Icons.broken_image_outlined)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const SectionHeader(title: 'Reseñas'),
              reviews.when(
                loading: () => const LoadingView(),
                error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(professionalReviewsProvider(s.id))),
                data: (list) => list.isEmpty
                    ? const Text('Todavía no tiene reseñas.', style: TextStyle(color: HyColors.textMuted))
                    : Column(children: [for (final r in list) _ReviewTile(review: r)]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(vertical: HySpacing.sm),
      decoration: BoxDecoration(
        color: HyColors.surface,
        borderRadius: BorderRadius.circular(HyRadii.md),
        border: Border.all(color: HyColors.border),
      ),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          WordSafeText(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 20, color: HyColors.textMuted),
      const SizedBox(width: HySpacing.xs),
      Expanded(
        child: Text(text, style: const TextStyle(color: HyColors.textSecondary, fontSize: 15)),
      ),
    ],
  );
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.review});

  final Review review;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.sm),
    child: AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Semantics(
                label: '${review.rating} de 5 estrellas',
                excludeSemantics: true,
                child: Row(
                  children: [
                    for (var i = 1; i <= 5; i++)
                      Icon(
                        i <= review.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                        color: HyColors.star,
                        size: 20,
                      ),
                  ],
                ),
              ),
              const Spacer(),
              Text(Fmt.shortDate(review.createdAt), style: const TextStyle(color: HyColors.textMuted, fontSize: 14)),
            ],
          ),
          if ((review.comment ?? '').isNotEmpty) ...[
            const SizedBox(height: HySpacing.xs),
            Text(review.comment!, style: const TextStyle(fontSize: 16)),
          ],
          const SizedBox(height: 4),
          Text('— ${review.authorFirstName}', style: const TextStyle(color: HyColors.textSecondary)),
          if ((review.professionalReply ?? '').isNotEmpty) ...[
            const SizedBox(height: HySpacing.xs),
            Container(
              padding: const EdgeInsets.all(HySpacing.sm),
              decoration: BoxDecoration(color: HyColors.surfaceMuted, borderRadius: BorderRadius.circular(HyRadii.sm)),
              child: Text('Respuesta: ${review.professionalReply!}'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _BottomActions extends ConsumerWidget {
  const _BottomActions({required this.detail});

  final ProfessionalDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = detail.summary;
    final me = ref.watch(accountProvider).value?.id;
    if (me == s.id) return const SizedBox.shrink();
    final category = s.primaryCategoryId == null ? '' : '&categoria=${s.primaryCategoryId}';
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: HyColors.surface,
          border: Border(top: BorderSide(color: HyColors.border)),
        ),
        padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.page, HySpacing.sm),
        // heightFactor: 1 para que la barra no ocupe toda la pantalla (tapaba la barra superior).
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: HySizes.maxContentWidth),
            child: ButtonRow(
              flex: const [1, 3],
              children: [
                SecondaryButton(
                  label: 'Programar',
                  icon: Icons.event_outlined,
                  onPressed: () => context.push('${Routes.requestPro(s.id, BookingMode.scheduled)}$category'),
                ),
                PrimaryButton(
                  label: s.isAvailable ? 'Pedir ahora' : 'No disponible',
                  icon: Icons.bolt_rounded,
                  onPressed: s.isAvailable
                      ? () => context.push('${Routes.requestPro(s.id, BookingMode.now)}$category')
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
