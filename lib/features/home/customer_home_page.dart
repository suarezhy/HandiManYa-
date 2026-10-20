import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/catalog.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/category_tile.dart';
import '../common/city_picker.dart';
import '../common/professional_card.dart';

class CustomerHomePage extends ConsumerWidget {
  const CustomerHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).value;
    final categories = ref.watch(categoriesProvider);
    final nearby = ref.watch(nearbyProfessionalsProvider);
    final promos = ref.watch(promotionsProvider).value ?? const [];
    final text = Theme.of(context).textTheme;

    Future<void> refresh() async {
      ref.invalidate(nearbyProfessionalsProvider);
      ref.invalidate(promotionsProvider);
      await ref.read(nearbyProfessionalsProvider.future);
    }

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: HyColors.primary,
          onRefresh: refresh,
          child: ListView(
            padding: const EdgeInsets.only(bottom: HySpacing.xxl),
            children: [
              const _Header(),
              PageBody(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: HySpacing.sm),
                    Text(
                      account == null ? '¡Hola!' : '¡Hola, ${Fmt.firstName(account.fullName)}!',
                      style: text.headlineMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '¿Qué servicio necesitas hoy?',
                      style: text.bodyLarge?.copyWith(color: HyColors.textSecondary),
                    ),
                    const SizedBox(height: HySpacing.md),
                    const _SearchBar(),
                    const SizedBox(height: HySpacing.lg),
                    YaButton(onPressed: () => context.push(Routes.ya)),
                    const SizedBox(height: HySpacing.xs),
                    Center(
                      child: TextButton.icon(
                        onPressed: () => context.go(Routes.search),
                        icon: const Icon(Icons.event_outlined),
                        label: const Text('Programar para después'),
                      ),
                    ),
                    if (promos.isNotEmpty) ...[const SizedBox(height: HySpacing.xs), _PromoBanner(promo: promos.first)],
                    SectionHeader(
                      title: 'Servicios',
                      actionLabel: 'Ver todos',
                      onAction: () => context.push(Routes.categories),
                    ),
                    categories.when(
                      data: (list) => _CategoryGrid(categories: list),
                      loading: () => const LoadingView(),
                      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(categoriesProvider)),
                    ),
                    SectionHeader(
                      title: 'Profesionales cerca de ti',
                      actionLabel: 'Ver más',
                      onAction: () => context.go(Routes.search),
                    ),
                    nearby.when(
                      data: (list) => list.isEmpty
                          ? const EmptyState(
                              icon: Icons.person_search_outlined,
                              title: 'Todavía no hay profesionales en tu ciudad',
                              message: 'Estamos sumando profesionales verificados. Prueba otra ciudad o vuelve pronto.',
                            )
                          : Column(
                              children: [
                                for (final p in list.take(6)) ...[
                                  ProfessionalCard(pro: p),
                                  const SizedBox(height: HySpacing.sm),
                                ],
                              ],
                            ),
                      loading: () => const LoadingView(),
                      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(nearbyProfessionalsProvider)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final city = ref.watch(currentCityProvider);
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;
    final account = ref.watch(accountProvider).value;
    return PageBody(
      padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.xs, 0),
      child: Row(
        children: [
          const BrandLogo(height: 34, showWordmark: false),
          const SizedBox(width: HySpacing.xs),
          Expanded(
            child: Semantics(
              button: true,
              label: 'Ciudad: ${city?.name ?? 'elige tu ciudad'}. Cambiar ciudad',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(HyRadii.md),
                onTap: () => showCityPicker(context, ref),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: HySizes.touch),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: HySpacing.xs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Tu ciudad', style: TextStyle(color: HyColors.textMuted, fontSize: 13)),
                        Row(
                          children: [
                            const Icon(Icons.place, size: 18, color: HyColors.primary),
                            const SizedBox(width: 2),
                            Flexible(
                              child: Text(
                                city?.shortName ?? 'Elegir',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                              ),
                            ),
                            const Icon(Icons.keyboard_arrow_down_rounded),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Notificaciones',
            iconSize: 28,
            onPressed: () => context.push(Routes.notifications),
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 9 ? '9+' : '$unread'),
              backgroundColor: HyColors.primary,
              child: const Icon(Icons.notifications_none_rounded),
            ),
          ),
          IconButton(
            tooltip: 'Mi perfil',
            onPressed: () => context.go(Routes.profile),
            icon: PersonAvatar(name: account?.fullName ?? '?', size: 36),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar();

  @override
  Widget build(BuildContext context) {
    return TextField(
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '¿Qué servicio necesitas?',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: IconButton(
          tooltip: 'Filtros',
          icon: const Icon(Icons.tune_rounded),
          onPressed: () => context.go('${Routes.search}?filtros=1'),
        ),
      ),
      onSubmitted: (q) => context.go('${Routes.search}?q=${Uri.encodeQueryComponent(q.trim())}'),
    );
  }
}

class _PromoBanner extends StatelessWidget {
  const _PromoBanner({required this.promo});

  final Promotion promo;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HyRadii.xl),
        gradient: const LinearGradient(
          colors: [HyColors.navy, HyColors.navySoft],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -30,
            bottom: -30,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(color: HyColors.green.withValues(alpha: 0.25), shape: BoxShape.circle),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(HySpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${promo.title} '),
                      const TextSpan(
                        text: '¡Encuéntrala Ya!',
                        style: TextStyle(color: HyColors.primary),
                      ),
                    ],
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, height: 1.2),
                ),
                if (promo.subtitle != null) ...[
                  const SizedBox(height: HySpacing.xs),
                  Text(promo.subtitle!, style: const TextStyle(color: Colors.white, fontSize: 16)),
                ],
                const SizedBox(height: HySpacing.md),
                FilledButton(
                  onPressed: () => context.push(promo.ctaRoute.startsWith('/buscar') ? Routes.ya : promo.ctaRoute),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, HySizes.touch)),
                  child: Text(promo.ctaLabel),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({required this.categories});

  final List<ServiceCategory> categories;

  @override
  Widget build(BuildContext context) {
    final showMore = categories.length > 8;
    final shown = categories.take(showMore ? 7 : 8).toList();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth > 520 ? 4 : (scale > 1.3 ? 3 : 4);
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: HySpacing.sm,
          crossAxisSpacing: HySpacing.sm,
          childAspectRatio: scale > 1.2 ? 0.68 : 0.82,
          children: [
            for (final c in shown)
              CategoryTile(label: c.name, icon: c.icon, onTap: () => context.push(Routes.service(c.id))),
            if (showMore) CategoryTile(label: 'Ver más', icon: 'more', onTap: () => context.push(Routes.categories)),
          ],
        );
      },
    );
  }
}
