import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/category_order.dart';
import '../../core/widgets/buttons.dart';
import '../../data/models/catalog.dart';

/// Servicios que suelen ir juntos. Se recomiendan primero en el buscador.
const _relatedGroups = [
  {
    'plomeria',
    'electricidad',
    'albanileria',
    'pintura',
    'carpinteria',
    'reparaciones-hogar',
    'cerrajeria',
    'aire-acondicionado',
  },
  {'limpieza', 'jardineria'},
  {'belleza', 'manicure'},
  {'ninera', 'mascotas'},
  {'clases', 'eventos'},
  {'asesoria-legal', 'notario'},
];

/// Los servicios relacionados con el principal, en el orden de la app.
List<ServiceCategory> relatedCategories(List<ServiceCategory> all, int? primaryId) {
  final primary = all.where((c) => c.id == primaryId).firstOrNull;
  if (primary == null) return const [];
  final group = _relatedGroups.where((g) => g.contains(primary.slug)).firstOrNull ?? const <String>{};
  return orderCategories(
    all.where((c) => c.id != primaryId && group.contains(c.slug)),
    slug: (c) => c.slug,
    name: (c) => c.name,
  );
}

/// Abre el buscador de servicios adicionales y devuelve la nueva selección
/// (o null si se cerró sin confirmar).
Future<Set<int>?> pickExtraServices(
  BuildContext context, {
  required List<ServiceCategory> categories,
  required int? primaryId,
  required Set<int> selected,
}) => showModalBottomSheet<Set<int>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => ServiceSelectorSheet(categories: categories, primaryId: primaryId, selected: selected),
);

class ServiceSelectorSheet extends StatefulWidget {
  const ServiceSelectorSheet({super.key, required this.categories, required this.primaryId, required this.selected});

  final List<ServiceCategory> categories;
  final int? primaryId;
  final Set<int> selected;

  @override
  State<ServiceSelectorSheet> createState() => _ServiceSelectorSheetState();
}

class _ServiceSelectorSheetState extends State<ServiceSelectorSheet> {
  final _query = TextEditingController();
  late final Set<int> _picked = {...widget.selected}..remove(widget.primaryId);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim();
    final related = relatedCategories(widget.categories, widget.primaryId);
    final relatedIds = {for (final c in related) c.id};
    final others = orderCategories(
      widget.categories.where((c) => c.id != widget.primaryId && !relatedIds.contains(c.id)),
      slug: (c) => c.slug,
      name: (c) => c.name,
    );
    bool hit(ServiceCategory c) => q.isEmpty || categoryMatchesQuery(q, [c.name, c.slug, c.description]);
    final relatedHits = related.where(hit).toList();
    final otherHits = others.where(hit).toList();
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
              child: Text('Otros servicios que ofreces', style: Theme.of(context).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.page, HySpacing.xs),
              child: TextField(
                key: const Key('service-search'),
                controller: _query,
                decoration: const InputDecoration(hintText: 'Busca un servicio', prefixIcon: Icon(Icons.search)),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: ListView(
                key: const Key('service-list'),
                children: [
                  if (relatedHits.isNotEmpty) ...[
                    const _Header('Recomendados para ti'),
                    for (final c in relatedHits) _tile(c),
                  ],
                  if (otherHits.isNotEmpty) ...[
                    _Header(relatedHits.isEmpty && q.isEmpty ? 'Todos los servicios' : 'Otros servicios'),
                    for (final c in otherHits) _tile(c),
                  ],
                  if (relatedHits.isEmpty && otherHits.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(HySpacing.page),
                      child: Text(
                        'No encontramos "$q".',
                        style: const TextStyle(color: HyColors.textSecondary, fontSize: 16),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xs, HySpacing.page, HySpacing.sm),
                child: PrimaryButton(
                  key: const Key('service-done'),
                  label: _picked.isEmpty ? 'Listo' : 'Listo (${_picked.length})',
                  onPressed: () => Navigator.pop(context, _picked),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(ServiceCategory c) => CheckboxListTile(
    key: Key('service-${c.slug}'),
    value: _picked.contains(c.id),
    controlAffinity: ListTileControlAffinity.trailing,
    activeColor: HyColors.primary,
    title: Text(c.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    subtitle: c.requiredDoc == null
        ? null
        : Text(switch (c.requiredDoc) {
            'certificado' => 'Pide título o matrícula y revisión del equipo',
            'nombramiento_notarial' => 'Pide la resolución de nombramiento (DIRNOPLU) y revisión del equipo',
            _ => 'Pide antecedentes y revisión del equipo',
          }, style: const TextStyle(color: HyColors.textSecondary)),
    onChanged: (v) => setState(() => v == true ? _picked.add(c.id) : _picked.remove(c.id)),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.md, HySpacing.page, HySpacing.xxs),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: HyColors.textSecondary),
    ),
  );
}
