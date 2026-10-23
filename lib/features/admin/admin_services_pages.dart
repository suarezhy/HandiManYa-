import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/category_icon.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/problem_icon.dart';
import '../../data/models/booking.dart';
import '../../data/models/catalog.dart';
import '../../data/providers.dart';
import '../../router.dart';
import 'admin_common.dart';

final adminServiceCategoriesProvider = FutureProvider<List<ServiceCategory>>(
  (ref) => ref.watch(backendProvider).adminServiceCategories(),
);
final adminProblemsProvider = FutureProvider.family<List<ServiceProblem>, int>(
  (ref, categoryId) => ref.watch(backendProvider).adminProblems(categoryId),
);

const _categoryIconNames = [
  'plumbing',
  'electrical_services',
  'cleaning_services',
  'format_paint',
  'construction',
  'carpenter',
  'yard',
  'home_repair_service',
  'directions_car',
  'ac_unit',
  'key',
  'content_cut',
  'spa',
  'child_care',
  'pets',
  'school',
  'celebration',
  'gavel',
  'history_edu',
  'build',
];

const _docLabels = {
  null: 'No pide documento extra',
  'antecedentes': 'Antecedentes (FELCC)',
  'certificado': 'Título o matrícula',
  'nombramiento_notarial': 'Nombramiento de notario (DIRNOPLU)',
};

/// Quita tildes y espacios para armar el identificador de una categoría nueva.
String slugify(String name) {
  const from = 'áéíóúüñ';
  const to = 'aeiouun';
  var s = name.trim().toLowerCase();
  for (var i = 0; i < from.length; i++) {
    s = s.replaceAll(from[i], to[i]);
  }
  return s.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
}

/// Mueve un elemento una posición y devuelve los ids en el nuevo orden.
List<int> moved(List<int> ids, int index, int delta) {
  final list = List.of(ids);
  final j = index + delta;
  if (j < 0 || j >= list.length) return list;
  final x = list.removeAt(index);
  list.insert(j, x);
  return list;
}

// ===================================================================== Categorías
class AdminServiceCategoriesTab extends ConsumerWidget {
  const AdminServiceCategoriesTab({super.key});

  Future<void> _afterChange(WidgetRef ref) async {
    ref
      ..invalidate(adminServiceCategoriesProvider)
      ..invalidate(adminCategoriesProvider)
      ..invalidate(categoriesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(adminServiceCategoriesProvider);
    final ids = [for (final c in value.value ?? const <ServiceCategory>[]) c.id];
    return AdminList<ServiceCategory>(
      value: value,
      onRefresh: () => ref.refresh(adminServiceCategoriesProvider.future),
      emptyTitle: 'Todavía no hay categorías',
      emptyIcon: Icons.category_outlined,
      header: Padding(
        padding: const EdgeInsets.only(bottom: HySpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const InfoBanner(
              text:
                  'Cada categoría abre su pantalla "¿Qué necesitas solucionar?" con sus opciones. '
                  'Las apagadas no aparecen en la app. Los cambios se ven sin actualizar la app.',
            ),
            const SizedBox(height: HySpacing.sm),
            SecondaryButton(
              label: 'Nueva categoría',
              icon: Icons.add,
              onPressed: () async {
                final saved = await showCategorySheet(context, sortOrder: (ids.length + 1) * 10);
                if (saved == true) await _afterChange(ref);
              },
            ),
          ],
        ),
      ),
      itemBuilder: (context, c) {
        final i = ids.indexOf(c.id);
        final (fg, bg) = categoryColors(c.icon);
        return AppCard(
          key: ValueKey('admin-cat-${c.id}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(HyRadii.md)),
                    child: Icon(categoryIcon(c.icon), color: fg),
                  ),
                  const SizedBox(width: HySpacing.sm),
                  Expanded(
                    child: Text(c.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                  _OrderButtons(
                    label: c.name,
                    canUp: i > 0,
                    canDown: i >= 0 && i < ids.length - 1,
                    onMove: (delta) async {
                      final ok = await runGuarded(
                        context,
                        () => ref.read(backendProvider).reorderCategories(moved(ids, i, delta)),
                      );
                      if (ok) await _afterChange(ref);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: HySpacing.xs,
                runSpacing: 4,
                children: [
                  if (!c.isActive) const ToneChip('Apagada', StatusTone.neutral),
                  if (c.isSensitive) ToneChip('Pide ${_docLabels[c.requiredDoc]}', StatusTone.warning),
                  if (!c.allowsYa) const ToneChip('Sin ¡Ya!', StatusTone.info),
                ],
              ),
              if (c.description != null) InfoLine(Icons.notes, c.description!),
              Wrap(
                spacing: HySpacing.xs,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => context.push(Routes.adminProblems(c.id)),
                    icon: const Icon(Icons.checklist_rounded),
                    label: const Text('Opciones'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final saved = await showCategorySheet(context, category: c);
                      if (saved == true) await _afterChange(ref);
                    },
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Editar'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<bool?> showCategorySheet(BuildContext context, {ServiceCategory? category, int sortOrder = 1000}) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CategorySheet(category: category, sortOrder: sortOrder),
    );

class _CategorySheet extends ConsumerStatefulWidget {
  const _CategorySheet({this.category, required this.sortOrder});

  final ServiceCategory? category;
  final int sortOrder;

  @override
  ConsumerState<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends ConsumerState<_CategorySheet> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.category?.name);
  late final _description = TextEditingController(text: widget.category?.description);
  late final _safety = TextEditingController(text: widget.category?.safetyNote);
  late final _proNote = TextEditingController(text: widget.category?.proNote);
  late String _icon = widget.category?.icon ?? 'build';
  late bool _allowsYa = widget.category?.allowsYa ?? true;
  late String? _doc = widget.category?.requiredDoc;
  late bool _active = widget.category?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _description, _safety, _proNote]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final base =
        widget.category ??
        ServiceCategory(id: 0, slug: slugify(_name.text), name: '', icon: _icon, sortOrder: widget.sortOrder);
    final saved = base.copyWith(
      name: _name.text.trim(),
      icon: _icon,
      description: () => _description.text.trim().isEmpty ? null : _description.text.trim(),
      allowsYa: _allowsYa,
      requiredDoc: () => _doc,
      safetyNote: () => _safety.text.trim().isEmpty ? null : _safety.text.trim(),
      proNote: () => _proNote.text.trim().isEmpty ? null : _proNote.text.trim(),
      isActive: _active,
    );
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).saveCategory(saved),
      success: widget.category == null ? 'Categoría creada con su opción "Otro servicio"' : 'Cambios guardados',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
    child: Form(
      key: _form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.category == null ? 'Nueva categoría' : 'Editar ${widget.category!.name}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: HySpacing.md),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nombre'),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe un nombre' : null,
            ),
            const SizedBox(height: HySpacing.sm),
            TextFormField(
              controller: _description,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Descripción corta (opcional)'),
            ),
            const SizedBox(height: HySpacing.sm),
            DropdownButtonFormField<String>(
              initialValue: _categoryIconNames.contains(_icon) ? _icon : 'build',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Ícono'),
              items: [
                for (final n in _categoryIconNames)
                  DropdownMenuItem(
                    value: n,
                    child: Row(
                      children: [
                        Icon(categoryIcon(n)),
                        const SizedBox(width: HySpacing.sm),
                        Text(n),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _icon = v ?? 'build'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Se puede pedir con ¡Ya!'),
              subtitle: const Text('Apágalo si el cliente debe elegir a la persona (por ejemplo, niñera).'),
              value: _allowsYa,
              onChanged: (v) => setState(() => _allowsYa = v),
            ),
            DropdownButtonFormField<String?>(
              initialValue: _doc,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Documento que debe tener aceptado el profesional'),
              items: [
                for (final e in _docLabels.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _doc = v),
            ),
            const SizedBox(height: HySpacing.sm),
            TextFormField(
              controller: _safety,
              minLines: 2,
              maxLines: 5,
              maxLength: 600,
              decoration: const InputDecoration(
                labelText: 'Regla de seguridad para el cliente (opcional)',
                alignLabelWithHint: true,
              ),
            ),
            TextFormField(
              controller: _proNote,
              minLines: 2,
              maxLines: 5,
              maxLength: 600,
              decoration: const InputDecoration(
                labelText: 'Requisito para el profesional (opcional)',
                alignLabelWithHint: true,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Activa'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            const SizedBox(height: HySpacing.sm),
            PrimaryButton(label: 'Guardar', loading: _saving, onPressed: _save),
          ],
        ),
      ),
    ),
  );
}

// ======================================================================= Opciones
class AdminProblemsPage extends ConsumerWidget {
  const AdminProblemsPage({super.key, required this.categoryId});

  final int categoryId;

  void _afterChange(WidgetRef ref) => ref
    ..invalidate(adminProblemsProvider(categoryId))
    ..invalidate(problemsProvider(categoryId));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = (ref.watch(adminServiceCategoriesProvider).value ?? const <ServiceCategory>[])
        .where((c) => c.id == categoryId)
        .firstOrNull;
    final value = ref.watch(adminProblemsProvider(categoryId));
    final ids = [for (final p in value.value ?? const <ServiceProblem>[]) p.id];
    return Scaffold(
      appBar: AppBar(title: Text(category == null ? 'Opciones' : 'Opciones de ${category.name}')),
      body: AdminList<ServiceProblem>(
        value: value,
        onRefresh: () => ref.refresh(adminProblemsProvider(categoryId).future),
        emptyTitle: 'Esta categoría todavía no tiene opciones',
        emptyIcon: Icons.checklist_rounded,
        header: Padding(
          padding: const EdgeInsets.only(bottom: HySpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const InfoBanner(
                text:
                    'Es lo que ve el cliente en "¿Qué necesitas solucionar?", en este orden. '
                    'Deja siempre una opción "Otro" para que pueda escribir lo que necesita.',
              ),
              const SizedBox(height: HySpacing.sm),
              SecondaryButton(
                label: 'Nueva opción',
                icon: Icons.add,
                onPressed: () async {
                  final saved = await _showProblemSheet(
                    context,
                    ServiceProblem(id: 0, categoryId: categoryId, name: '', sortOrder: (ids.length + 1) * 10),
                  );
                  if (saved == true) _afterChange(ref);
                },
              ),
            ],
          ),
        ),
        itemBuilder: (context, p) {
          final i = ids.indexOf(p.id);
          return AppCard(
            key: ValueKey('admin-problem-${p.id}'),
            padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: HySpacing.xs),
            child: Row(
              children: [
                Icon(problemIcon(p.icon), color: p.isActive ? HyColors.primaryDark : HyColors.textMuted),
                const SizedBox(width: HySpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: p.isActive ? null : HyColors.textMuted,
                        ),
                      ),
                      if (p.isOther) const Text('Pide que el cliente lo describa', style: TextStyle(fontSize: 14)),
                      if (!p.isActive) const Text('Apagada', style: TextStyle(fontSize: 14, color: HyColors.textMuted)),
                    ],
                  ),
                ),
                _OrderButtons(
                  label: p.name,
                  canUp: i > 0,
                  canDown: i >= 0 && i < ids.length - 1,
                  onMove: (delta) async {
                    final ok = await runGuarded(
                      context,
                      () => ref.read(backendProvider).reorderProblems(moved(ids, i, delta)),
                    );
                    if (ok) _afterChange(ref);
                  },
                ),
                IconButton(
                  tooltip: 'Editar ${p.name}',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    final saved = await _showProblemSheet(context, p);
                    if (saved == true) _afterChange(ref);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

Future<bool?> _showProblemSheet(BuildContext context, ServiceProblem problem) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ProblemSheet(problem: problem),
);

class _ProblemSheet extends ConsumerStatefulWidget {
  const _ProblemSheet({required this.problem});

  final ServiceProblem problem;

  @override
  ConsumerState<_ProblemSheet> createState() => _ProblemSheetState();
}

class _ProblemSheetState extends ConsumerState<_ProblemSheet> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.problem.name);
  late String _icon = widget.problem.icon;
  late bool _isOther = widget.problem.isOther;
  late bool _active = widget.problem.isActive;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => ref
          .read(backendProvider)
          .saveProblem(
            widget.problem.copyWith(name: _name.text.trim(), icon: _icon, isOther: _isOther, isActive: _active),
          ),
      success: widget.problem.id == 0 ? 'Opción agregada' : 'Cambios guardados',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
    child: Form(
      key: _form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.problem.id == 0 ? 'Nueva opción' : 'Editar opción',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: HySpacing.md),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ej.: Fuga de agua'),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe un nombre' : null,
            ),
            DropdownButtonFormField<String>(
              initialValue: problemIconNames.contains(_icon) ? _icon : 'build',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Ícono'),
              items: [
                for (final n in problemIconNames)
                  DropdownMenuItem(
                    value: n,
                    child: Row(
                      children: [
                        Icon(problemIcon(n)),
                        const SizedBox(width: HySpacing.sm),
                        Text(n),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _icon = v ?? 'build'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Es la opción "Otro"'),
              subtitle: const Text('Le pide al cliente que escriba lo que necesita.'),
              value: _isOther,
              onChanged: (v) => setState(() => _isOther = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Activa'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            const SizedBox(height: HySpacing.sm),
            PrimaryButton(label: 'Guardar', loading: _saving, onPressed: _save),
          ],
        ),
      ),
    ),
  );
}

class _OrderButtons extends StatelessWidget {
  const _OrderButtons({required this.label, required this.canUp, required this.canDown, required this.onMove});

  final String label;
  final bool canUp;
  final bool canDown;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Subir $label',
        icon: const Icon(Icons.arrow_upward_rounded),
        onPressed: canUp ? () => onMove(-1) : null,
      ),
      IconButton(
        tooltip: 'Bajar $label',
        icon: const Icon(Icons.arrow_downward_rounded),
        onPressed: canDown ? () => onMove(1) : null,
      ),
    ],
  );
}
