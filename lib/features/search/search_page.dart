import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/catalog.dart';
import '../../data/models/professional.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/city_picker.dart';
import '../common/professional_card.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialCategoryId, this.initialQuery, this.initialAvailableNow = false});

  final int? initialCategoryId;
  final String? initialQuery;
  final bool initialAvailableNow;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late final TextEditingController _query = TextEditingController(text: widget.initialQuery ?? '');
  late SearchFilters _filters = SearchFilters(
    categoryId: widget.initialCategoryId,
    query: widget.initialQuery ?? '',
    availableNow: widget.initialAvailableNow,
  );
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (GoRouterState.of(context).uri.queryParameters['filtros'] == '1') _openFilters();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQuery(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _filters = _filters.copyWith(query: v));
    });
  }

  Future<void> _openFilters() async {
    final city = ref.read(currentCityProvider);
    final result = await showModalBottomSheet<SearchFilters>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _FiltersSheet(initial: _filters, cityId: city?.id),
    );
    if (result != null) setState(() => _filters = result);
  }

  @override
  Widget build(BuildContext context) {
    final city = ref.watch(currentCityProvider);
    final effective = _filters.copyWith(cityId: () => city?.id);
    final results = ref.watch(searchResultsProvider(effective));
    final categories = ref.watch(categoriesProvider).value ?? const <ServiceCategory>[];
    final zones = city == null ? const <Zone>[] : (ref.watch(zonesProvider(city.id)).value ?? const <Zone>[]);
    String? catName(int? id) => categories.where((c) => c.id == id).firstOrNull?.name;
    String? zoneName(int? id) => zones.where((z) => z.id == id).firstOrNull?.name;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Buscar profesionales'),
        actions: [
          TextButton.icon(
            onPressed: () => showCityPicker(context, ref),
            icon: const Icon(Icons.place, color: HyColors.primary),
            label: Text(city?.shortName ?? 'Ciudad'),
          ),
        ],
      ),
      body: Column(
        children: [
          PageBody(
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    onChanged: _onQuery,
                    onSubmitted: (v) => setState(() => _filters = _filters.copyWith(query: v)),
                    decoration: InputDecoration(
                      hintText: 'Nombre, servicio o zona',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Borrar',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _query.clear();
                                setState(() => _filters = _filters.copyWith(query: ''));
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: HySpacing.xs),
                Badge(
                  isLabelVisible: _filters.activeFilterCount > 0,
                  label: Text('${_filters.activeFilterCount}'),
                  backgroundColor: HyColors.primary,
                  child: IconButton.filledTonal(
                    tooltip: 'Filtros',
                    iconSize: 28,
                    style: IconButton.styleFrom(minimumSize: const Size(56, 56)),
                    onPressed: _openFilters,
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 60,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.page, vertical: HySpacing.xs),
              children: [
                FilterChip(
                  label: const Text('Disponible ahora'),
                  avatar: const Icon(Icons.bolt, size: 18),
                  selected: _filters.availableNow,
                  onSelected: (v) => setState(() => _filters = _filters.copyWith(availableNow: v)),
                ),
                const SizedBox(width: HySpacing.xs),
                if (_filters.categoryId != null) ...[
                  InputChip(
                    label: Text(catName(_filters.categoryId) ?? 'Servicio'),
                    onDeleted: () => setState(() => _filters = _filters.copyWith(categoryId: () => null)),
                    deleteButtonTooltipMessage: 'Quitar filtro',
                  ),
                  const SizedBox(width: HySpacing.xs),
                ],
                if (_filters.zoneId != null) ...[
                  InputChip(
                    label: Text(zoneName(_filters.zoneId) ?? 'Zona'),
                    onDeleted: () => setState(() => _filters = _filters.copyWith(zoneId: () => null)),
                    deleteButtonTooltipMessage: 'Quitar filtro',
                  ),
                  const SizedBox(width: HySpacing.xs),
                ],
                if (_filters.minRating != null) ...[
                  InputChip(
                    label: Text('${_filters.minRating!.toStringAsFixed(0)}+ estrellas'),
                    onDeleted: () => setState(() => _filters = _filters.copyWith(minRating: () => null)),
                    deleteButtonTooltipMessage: 'Quitar filtro',
                  ),
                  const SizedBox(width: HySpacing.xs),
                ],
                ActionChip(
                  avatar: const Icon(Icons.sort, size: 18),
                  label: Text(_filters.sort.label),
                  onPressed: _openFilters,
                ),
              ],
            ),
          ),
          Expanded(
            child: results.when(
              loading: () => const LoadingView(),
              error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(searchResultsProvider(effective))),
              data: (list) => list.isEmpty
                  ? SingleChildScrollView(
                      child: EmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'No encontramos profesionales con esos filtros',
                        message: _filters.availableNow
                            ? 'Prueba quitar "Disponible ahora" o pide ¡Ya! y avisamos a quien se conecte.'
                            : 'Prueba con otra palabra, otra zona o quita algunos filtros.',
                        action: SecondaryButton(
                          label: 'Quitar filtros',
                          expand: false,
                          onPressed: () {
                            _query.clear();
                            setState(() => _filters = const SearchFilters());
                          },
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xs, HySpacing.page, HySpacing.xxl),
                      itemCount: list.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(height: HySpacing.sm),
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return Semantics(
                            liveRegion: true,
                            child: Text(
                              list.length == 1 ? '1 profesional' : '${list.length} profesionales',
                              style: const TextStyle(color: HyColors.textSecondary, fontWeight: FontWeight.w600),
                            ),
                          );
                        }
                        return ProfessionalCard(pro: list[i - 1]);
                      },
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            context.push(_filters.categoryId == null ? Routes.ya : '${Routes.ya}?categoria=${_filters.categoryId}'),
        backgroundColor: HyColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.bolt_rounded),
        label: const Text('Pedir ¡Ya!', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _FiltersSheet extends ConsumerStatefulWidget {
  const _FiltersSheet({required this.initial, required this.cityId});

  final SearchFilters initial;
  final int? cityId;

  @override
  ConsumerState<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends ConsumerState<_FiltersSheet> {
  late SearchFilters f = widget.initial;

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).value ?? const [];
    final zones = widget.cityId == null ? const <Zone>[] : (ref.watch(zonesProvider(widget.cityId!)).value ?? const []);
    final text = Theme.of(context).textTheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, HySpacing.lg),
              children: [
                Text('Filtros', style: text.headlineSmall),
                const SizedBox(height: HySpacing.md),
                Text('Ordenar por', style: text.titleMedium),
                const SizedBox(height: HySpacing.xs),
                Wrap(
                  spacing: HySpacing.xs,
                  runSpacing: HySpacing.xs,
                  children: [
                    for (final s in SortOption.values)
                      ChoiceChip(
                        label: Text(s.label),
                        selected: f.sort == s,
                        onSelected: (_) => setState(() => f = f.copyWith(sort: s)),
                      ),
                  ],
                ),
                const SizedBox(height: HySpacing.lg),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Solo disponibles ahora',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  value: f.availableNow,
                  onChanged: (v) => setState(() => f = f.copyWith(availableNow: v)),
                ),
                const SizedBox(height: HySpacing.md),
                DropdownButtonFormField<int?>(
                  initialValue: f.categoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Servicio'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('Todos los servicios')),
                    for (final c in categories) DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) => setState(() => f = f.copyWith(categoryId: () => v)),
                ),
                const SizedBox(height: HySpacing.md),
                DropdownButtonFormField<int?>(
                  initialValue: f.zoneId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Zona'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('Toda la ciudad')),
                    for (final z in zones) DropdownMenuItem<int?>(value: z.id, child: Text(z.name)),
                  ],
                  onChanged: (v) => setState(() => f = f.copyWith(zoneId: () => v)),
                ),
                const SizedBox(height: HySpacing.lg),
                Text('Calificación mínima', style: text.titleMedium),
                const SizedBox(height: HySpacing.xs),
                Wrap(
                  spacing: HySpacing.xs,
                  children: [
                    ChoiceChip(
                      label: const Text('Cualquiera'),
                      selected: f.minRating == null,
                      onSelected: (_) => setState(() => f = f.copyWith(minRating: () => null)),
                    ),
                    for (final r in [3.0, 4.0, 4.5])
                      ChoiceChip(
                        avatar: const Icon(Icons.star_rounded, color: HyColors.star, size: 18),
                        label: Text(r == 4.5 ? '4,5+' : '${r.toStringAsFixed(0)}+'),
                        selected: f.minRating == r,
                        onSelected: (_) => setState(() => f = f.copyWith(minRating: () => r)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xs, HySpacing.page, HySpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: SecondaryButton(
                      label: 'Limpiar',
                      onPressed: () => Navigator.pop(context, SearchFilters(query: f.query)),
                    ),
                  ),
                  const SizedBox(width: HySpacing.sm),
                  Expanded(
                    flex: 2,
                    child: PrimaryButton(label: 'Ver resultados', onPressed: () => Navigator.pop(context, f)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
