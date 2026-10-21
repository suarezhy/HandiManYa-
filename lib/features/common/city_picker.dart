import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/catalog.dart';
import '../../data/providers.dart';

/// Texto en minúsculas y sin tildes, para buscar "potosi" o "POTOSÍ" igual.
String foldForSearch(String s) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñ';
  const to = 'aaaaeeeeiiiioooouuuun';
  final buf = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    buf.write(i < 0 ? ch : to[i]);
  }
  return buf.toString().trim();
}

/// Filtra municipios por departamento y por nombre de municipio, provincia o
/// departamento. Primero los que empiezan con lo escrito, luego el resto.
List<City> filterCities(List<City> cities, {String query = '', int? departmentId}) {
  final inDept = departmentId == null ? cities : cities.where((c) => c.departmentId == departmentId).toList();
  final q = foldForSearch(query);
  if (q.isEmpty) return inDept;
  int rank(City c) {
    final name = foldForSearch(c.name);
    if (name.startsWith(q)) return 0;
    if (name.split(RegExp(r'[\s-]+')).any((w) => w.startsWith(q))) return 1;
    if (name.contains(q)) return 2;
    return 3;
  }

  final hits = [
    for (final c in inDept)
      if (foldForSearch('${c.name} ${c.province ?? ''} ${c.department ?? ''}').contains(q)) c,
  ];
  // sort es estable: dentro de cada rango se mantiene el orden original.
  final ranked = [for (var i = 0; i < hits.length; i++) (i, rank(hits[i]), hits[i])]
    ..sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
  return [for (final r in ranked) r.$3];
}

/// Abre el buscador de municipios de toda Bolivia y devuelve el elegido.
Future<City?> pickCity(BuildContext context, {int? selectedId, String title = '¿Dónde estás?'}) {
  return showModalBottomSheet<City>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => CityPickerSheet(selectedId: selectedId, title: title),
  );
}

/// Cambia el municipio con el que se busca en la app.
Future<void> showCityPicker(BuildContext context, WidgetRef ref) async {
  final city = await pickCity(context, selectedId: ref.read(currentCityProvider)?.id);
  if (city != null) await ref.read(selectedCityProvider.notifier).select(city.id);
}

class CityPickerSheet extends ConsumerStatefulWidget {
  const CityPickerSheet({super.key, this.selectedId, this.title = '¿Dónde estás?'});

  final int? selectedId;
  final String title;

  @override
  ConsumerState<CityPickerSheet> createState() => _CityPickerSheetState();
}

class _CityPickerSheetState extends ConsumerState<CityPickerSheet> {
  final _query = TextEditingController();
  int? _department;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(citiesProvider);
    final cities = filterCities(async.value ?? const [], query: _query.text, departmentId: _department);
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
              child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xxs, HySpacing.page, HySpacing.sm),
              child: Text(
                'Elige tu municipio. Estamos en los 9 departamentos de Bolivia.',
                style: TextStyle(color: HyColors.textSecondary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
              child: TextField(
                key: const Key('city-search'),
                controller: _query,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Busca tu municipio, pueblo o provincia',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Borrar',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(_query.clear),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: HySpacing.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
              child: Row(
                children: [
                  for (final entry in [
                    const MapEntry<int?, String>(null, 'Toda Bolivia'),
                    ...boliviaDepartments.entries,
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: HySpacing.xs),
                      child: ChoiceChip(
                        key: Key('city-dept-${entry.key ?? 0}'),
                        label: Text(entry.value),
                        selected: _department == entry.key,
                        onSelected: (_) => setState(() => _department = entry.key),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: HySpacing.xs),
            Expanded(
              child: async.isLoading && cities.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : cities.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(HySpacing.page),
                      child: Text(
                        'No encontramos "${_query.text.trim()}". Prueba con el nombre de tu municipio o de tu provincia.',
                        style: const TextStyle(color: HyColors.textSecondary, fontSize: 16),
                      ),
                    )
                  : ListView.builder(
                      key: const Key('city-list'),
                      itemCount: cities.length,
                      itemBuilder: (c, i) {
                        final city = cities[i];
                        final selected = city.id == widget.selectedId;
                        return ListTile(
                          key: Key('city-${city.slug}'),
                          minTileHeight: HySizes.touch + 8,
                          leading: Icon(
                            selected ? Icons.radio_button_checked : Icons.radio_button_off,
                            color: selected ? HyColors.primary : HyColors.textMuted,
                          ),
                          title: Text(city.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                          subtitle: city.place.isEmpty ? null : Text(city.place),
                          selected: selected,
                          onTap: () => Navigator.pop(c, city),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Campo de formulario que muestra el municipio elegido y abre el buscador.
class CityField extends ConsumerWidget {
  const CityField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Municipio o ciudad',
    this.validator,
  });

  final int? value;
  final ValueChanged<int> onChanged;
  final String label;
  final FormFieldValidator<int>? validator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cities = ref.watch(citiesProvider).value ?? const <City>[];
    City? city;
    for (final c in cities) {
      if (c.id == value) city = c;
    }
    return FormField<int>(
      // Se reconstruye cuando cambia el valor elegido desde afuera.
      key: ValueKey(value),
      initialValue: value,
      validator: validator,
      builder: (field) => InkWell(
        borderRadius: BorderRadius.circular(HyRadii.md),
        onTap: () async {
          final picked = await pickCity(context, selectedId: value, title: label);
          if (picked != null) {
            field.didChange(picked.id);
            onChanged(picked.id);
          }
        },
        child: InputDecorator(
          isEmpty: city == null,
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: const Icon(Icons.location_on_outlined),
            suffixIcon: const Icon(Icons.search),
            errorText: field.errorText,
          ),
          child: city == null
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(city.name, style: const TextStyle(fontSize: 16)),
                    if (city.place.isNotEmpty)
                      Text(city.place, style: const TextStyle(fontSize: 13, color: HyColors.textSecondary)),
                  ],
                ),
        ),
      ),
    );
  }
}
