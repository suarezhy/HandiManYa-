import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/category_order.dart';
import '../../core/utils/text_fit.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/category_icon.dart';
import '../../core/widgets/common.dart';
import '../../data/models/catalog.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/city_picker.dart';
import '../common/professional_card.dart';
import 'home_map.dart';

class CustomerHomePage extends ConsumerWidget {
  const CustomerHomePage({super.key});

  /// Espacio al final de la lista para que el botón flotante "Pedir ¡Ya!"
  /// nunca tape lo último (alto del botón y su margen, con aire).
  static const fabClearance = 96.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).value;
    final categories = ref.watch(categoriesProvider);
    final nearby = ref.watch(nearbyProfessionalsProvider);
    final text = Theme.of(context).textTheme;

    Future<void> refresh() async {
      ref.invalidate(nearbyProfessionalsProvider);
      ref.invalidate(homeMapProvider);
      await Future.wait([ref.read(nearbyProfessionalsProvider.future), ref.read(homeMapProvider.future)]);
    }

    return Scaffold(
      // Una sola forma de pedir ya: el botón flotante, siempre a la vista
      // sobre la barra de abajo.
      floatingActionButton: const _YaFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: HyColors.primary,
          onRefresh: refresh,
          child: ListView(
            key: const Key('home-list'),
            padding: bottomSafePadding(context, bottom: fabClearance),
            children: [
              const _Header(),
              PageBody(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // En pantallas bajas o con letra grande el saludo se achica y
                    // la segunda línea se omite (el buscador ya la pregunta).
                    Builder(
                      builder: (context) {
                        final media = MediaQuery.of(context);
                        final compact = media.size.height < 700 || media.textScaler.scale(10) > 12;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: HySpacing.xxs),
                            Text(
                              account == null ? '¡Hola!' : '¡Hola, ${Fmt.firstName(account.fullName)}!',
                              style: compact ? text.titleLarge : text.headlineMedium,
                            ),
                            if (!compact) ...[
                              const SizedBox(height: 2),
                              Text(
                                '¿Qué servicio necesitas hoy?',
                                style: text.bodyLarge?.copyWith(color: HyColors.textSecondary),
                              ),
                            ],
                            SizedBox(height: compact ? HySpacing.sm : HySpacing.md),
                          ],
                        );
                      },
                    ),
                    const _SearchBar(),
                    const SizedBox(height: HySpacing.md),
                    const HomeMapSection(),
                    const SizedBox(height: HySpacing.xs),
                    Center(
                      child: TextButton.icon(
                        key: const Key('home-search-pros'),
                        onPressed: () => context.go(Routes.search),
                        icon: const Icon(Icons.search),
                        label: const Text('Buscar profesionales'),
                      ),
                    ),
                    SectionHeader(
                      title: 'Servicios',
                      actionLabel: 'Ver todos',
                      onAction: () => context.push(Routes.categories),
                    ),
                    categories.when(
                      data: (list) => HomeCategoryGrid(categories: list),
                      loading: () => const LoadingView(),
                      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(categoriesProvider)),
                    ),
                    nearby.when(
                      // Sin nadie cerca no se repite el aviso: ya lo dice el mapa.
                      data: (list) => list.isEmpty
                          ? const SizedBox.shrink()
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SectionHeader(
                                  title: 'Profesionales cerca de ti',
                                  actionLabel: 'Ver más',
                                  onAction: () => context.go(Routes.search),
                                ),
                                for (final p in list.take(6)) ...[
                                  ProfessionalCard(pro: p),
                                  const SizedBox(height: HySpacing.sm),
                                ],
                              ],
                            ),
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: HySpacing.lg),
                        child: Center(child: CircularProgressIndicator(color: HyColors.primary)),
                      ),
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

/// "Pedir ¡Ya!": píldora naranja que flota sobre la barra de abajo. La letra
/// queda en una línea (si la del sistema es muy grande, se achica en vez de
/// partirse) y en negrita de 18 px por el contraste sobre naranja.
class _YaFab extends StatelessWidget {
  const _YaFab();

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    final maxWidth = screen > 0 ? screen - 2 * HySpacing.page : double.infinity;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: FloatingActionButton.extended(
        key: const Key('home-ya-fab'),
        heroTag: 'home-ya-fab',
        onPressed: () => context.push(Routes.ya),
        backgroundColor: HyColors.primary,
        foregroundColor: HyColors.onPrimary,
        elevation: 3,
        highlightElevation: 5,
        shape: const StadiumBorder(),
        extendedPadding: const EdgeInsets.symmetric(horizontal: 28),
        icon: const Icon(Icons.bolt_rounded, size: 26),
        label: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth - 28 * 2 - 26 - 12),
          child: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Pedir ¡Ya!',
              maxLines: 1,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 0.2),
            ),
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

/// Servicios del inicio. Primero los del hogar a pedido (mismo orden que en
/// "Pedir ¡Ya!"); el número de columnas se elige para que cada palabra entre
/// entera, y la altura de cada fila sale del contenido (nunca se desborda).
class HomeCategoryGrid extends StatelessWidget {
  const HomeCategoryGrid({super.key, required this.categories});

  final List<ServiceCategory> categories;

  static const _gap = HySpacing.xs;
  static const _labelStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.15);

  /// Ancho útil del texto dentro de una tarjeta (relleno 6 + 6, borde 1 + 1).
  static double _inner(double width, int columns) => (width - _gap * (columns - 1)) / columns - 14;

  @override
  Widget build(BuildContext context) {
    final ordered = orderCategories(categories, slug: (c) => c.slug, name: (c) => c.name);
    return LayoutBuilder(
      builder: (context, box) {
        final labels = [for (final c in ordered.take(12)) categoryShortLabel(slug: c.slug, name: c.name), 'Ver más'];
        final user = MediaQuery.textScalerOf(context).scale(100) / 100;
        final target = math.min(user, 1.3);
        final maxColumns = box.maxWidth >= 560 ? 6 : 4;
        var columns = 2;
        for (var c = maxColumns; c >= 3; c--) {
          final fit = wordFitScale(context, texts: labels, style: _labelStyle, width: _inner(box.maxWidth, c));
          if (fit >= target * 0.9) {
            columns = c;
            break;
          }
        }
        final scale = wordFitScale(
          context,
          texts: labels,
          style: _labelStyle,
          width: _inner(box.maxWidth, columns) - 1,
          max: 1.6,
        );
        final slots = columns * ((columns <= 4 ? 8 : 2 * columns) / columns).ceil();
        final showMore = ordered.length > slots;
        final tiles = <Widget>[
          for (final c in ordered.take(showMore ? slots - 1 : slots))
            _HomeCategoryTile(
              key: Key('home-category-${c.slug}'),
              label: categoryShortLabel(slug: c.slug, name: c.name),
              semanticLabel: c.name,
              icon: c.icon,
              compact: columns > 3,
              onTap: () => context.push(Routes.service(c.id)),
            ),
          if (showMore)
            _HomeCategoryTile(
              key: const Key('home-category-more'),
              label: 'Ver más',
              semanticLabel: 'Ver todos los servicios',
              icon: 'more',
              compact: columns > 3,
              onTap: () => context.push(Routes.categories),
            ),
        ];
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: Column(
            children: [
              for (var r = 0; r < tiles.length; r += columns) ...[
                if (r > 0) const SizedBox(height: _gap),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = r; i < r + columns; i++) ...[
                        if (i > r) const SizedBox(width: _gap),
                        Expanded(child: i < tiles.length ? tiles[i] : const SizedBox.shrink()),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _HomeCategoryTile extends StatelessWidget {
  const _HomeCategoryTile({
    super.key,
    required this.label,
    required this.semanticLabel,
    required this.icon,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final String semanticLabel;
  final String icon;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = categoryColors(icon);
    final tile = compact ? 48.0 : HySizes.iconTile;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: Material(
        color: HyColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HyRadii.lg),
          side: const BorderSide(color: HyColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: HySizes.touch),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: HySpacing.sm),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: tile,
                    height: tile,
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(HyRadii.md)),
                    child: Icon(categoryIcon(icon), color: fg, size: compact ? 26 : 30),
                  ),
                  const SizedBox(height: HySpacing.xs),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: HomeCategoryGrid._labelStyle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
