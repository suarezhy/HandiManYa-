import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/bolivia_geo.dart';
import '../../core/widgets/buttons.dart';
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

/// Ciudades que se sugieren antes de escribir: capitales y El Alto.
const mainCitySlugs = [
  'santa-cruz',
  'la-paz',
  'el-alto',
  'cochabamba',
  'sucre',
  'oruro',
  'potosi',
  'tarija',
  'trinidad',
  'cobija',
];

/// Elegir municipio con dos caminos simples: escribir la ciudad (con
/// sugerencias) o usar la ubicación actual y confirmarla. Busca en los 339
/// municipios de Bolivia; si dos se llaman parecido, se distinguen por su
/// provincia y departamento.
class CityPickerSheet extends ConsumerStatefulWidget {
  const CityPickerSheet({super.key, this.selectedId, this.title = '¿Dónde estás?'});

  final int? selectedId;
  final String title;

  @override
  ConsumerState<CityPickerSheet> createState() => _CityPickerSheetState();
}

class _CityPickerSheetState extends ConsumerState<CityPickerSheet> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  bool _locating = false;
  City? _gpsCity;
  String? _gpsError;

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _useLocation(List<City> cities) async {
    setState(() {
      _locating = true;
      _gpsError = null;
      _gpsCity = null;
    });
    try {
      final p = await ref.read(locationServiceProvider).current();
      if (!mounted) return;
      setState(() {
        if (!isInBolivia(p.latitude, p.longitude)) {
          _gpsError = 'Tu ubicación está fuera de Bolivia. Escribe tu ciudad.';
        } else {
          _gpsCity = nearestCity(cities, p.latitude, p.longitude);
          if (_gpsCity == null) _gpsError = 'No pudimos reconocer tu ciudad. Escríbela.';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _gpsError = AppError.from(e).message);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(citiesProvider);
    final all = async.value ?? const <City>[];
    final typed = _query.text.trim();
    final List<City> shown;
    if (typed.isEmpty) {
      final bySlug = {for (final c in all) c.slug: c};
      shown = [
        for (final s in mainCitySlugs)
          if (bySlug[s] != null) bySlug[s]!,
      ];
      final current = all.where((c) => c.id == widget.selectedId).firstOrNull;
      if (current != null && !shown.contains(current)) shown.insert(0, current);
    } else {
      shown = filterCities(all, query: typed).take(40).toList();
    }
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
            const SizedBox(height: HySpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
              child: TextField(
                key: const Key('city-search'),
                controller: _query,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Escribe tu ciudad',
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
            const SizedBox(height: HySpacing.xs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
              child: _gpsCity == null
                  ? OutlinedButton.icon(
                      key: const Key('city-gps'),
                      onPressed: _locating || all.isEmpty ? null : () => _useLocation(all),
                      icon: _locating
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.my_location),
                      label: Text(_locating ? 'Buscando tu ubicación…' : 'Usar mi ubicación actual'),
                    )
                  : _GpsConfirm(
                      city: _gpsCity!,
                      onConfirm: () => Navigator.pop(context, _gpsCity),
                      onChange: () {
                        setState(() => _gpsCity = null);
                        _focus.requestFocus();
                      },
                    ),
            ),
            if (_gpsError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xs, HySpacing.page, 0),
                child: Text(
                  _gpsError!,
                  key: const Key('city-gps-error'),
                  style: const TextStyle(color: HyColors.danger, fontSize: 15),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.md, HySpacing.page, HySpacing.xxs),
              child: Text(
                typed.isEmpty ? 'Ciudades principales' : 'Sugerencias',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: HyColors.textSecondary),
              ),
            ),
            Expanded(
              child: async.isLoading && all.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : shown.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(HySpacing.page),
                      child: Text(
                        'No encontramos "$typed". Revisa cómo se escribe o prueba con el nombre de tu provincia.',
                        style: const TextStyle(color: HyColors.textSecondary, fontSize: 16),
                      ),
                    )
                  : ListView.builder(
                      key: const Key('city-list'),
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + HySpacing.md),
                      itemCount: shown.length,
                      itemBuilder: (c, i) {
                        final city = shown[i];
                        final selected = city.id == widget.selectedId;
                        return ListTile(
                          key: Key('city-${city.slug}'),
                          minTileHeight: HySizes.touch + 8,
                          leading: Icon(
                            selected ? Icons.check_circle : Icons.location_city_outlined,
                            color: selected ? HyColors.primary : HyColors.textMuted,
                          ),
                          title: Text(city.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                          // Provincia y departamento: distinguen municipios con nombres parecidos.
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

/// La ciudad que sugiere el GPS: se confirma o se cambia.
class _GpsConfirm extends StatelessWidget {
  const _GpsConfirm({required this.city, required this.onConfirm, required this.onChange});

  final City city;
  final VoidCallback onConfirm;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('city-gps-result'),
    padding: const EdgeInsets.all(HySpacing.sm),
    decoration: BoxDecoration(
      color: HyColors.surface,
      borderRadius: BorderRadius.circular(HyRadii.md),
      border: Border.all(color: HyColors.primary, width: 1.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Según tu ubicación estás en', style: TextStyle(color: HyColors.textSecondary)),
        Text(city.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        if (city.place.isNotEmpty) Text(city.place, style: const TextStyle(color: HyColors.textSecondary)),
        const SizedBox(height: HySpacing.xs),
        PrimaryButton(key: const Key('city-gps-confirm'), label: 'Sí, usar ${city.name}', onPressed: onConfirm),
        TextButton(key: const Key('city-gps-change'), onPressed: onChange, child: const Text('No, elegir otra')),
      ],
    ),
  );
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
