import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/models/booking.dart';
import '../../data/models/costs.dart';
import '../../data/models/drilldown.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import 'admin_common.dart';

/// Personas por grupo (los mismos que cuenta el panel) y búsqueda.
final peopleProvider = FutureProvider.autoDispose.family<Listed<PersonRow>, (PeopleFilter, String)>(
  (ref, k) => ref.watch(backendProvider).adminPeople(k.$1, query: k.$2),
);

/// Suspender a alguien (pide el motivo, que verá la persona).
Future<void> showSuspendSheet(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required String name,
}) async {
  final reason = await promptText(
    context,
    title: 'Suspender a $name',
    label: 'Motivo (lo verá la persona)',
    hint: 'Ej.: varios reportes de cobro indebido',
    confirm: 'Suspender',
    minLength: 5,
  );
  if (reason == null || !context.mounted) return;
  final ok = await runGuarded(
    context,
    () => ref.read(backendProvider).setSuspension(userId, suspend: true, reason: reason),
    success: 'Cuenta suspendida',
  );
  if (ok) {
    ref
      ..invalidate(adminUsersProvider)
      ..invalidate(peopleProvider)
      ..invalidate(adminReportsProvider)
      ..invalidate(adminDashboardProvider);
  }
}

class AdminUsersPage extends ConsumerStatefulWidget {
  const AdminUsersPage({super.key, this.initialFilter = PeopleFilter.all});

  final PeopleFilter initialFilter;

  @override
  ConsumerState<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends ConsumerState<AdminUsersPage> {
  late PeopleFilter _filter = widget.initialFilter;
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reactivate(AdminUser u) async {
    if (!await confirmDialog(
      context,
      title: '¿Reactivar a ${u.fullName}?',
      message: 'Podrá volver a usar la app. Si es profesional, vuelve a quedar aprobado.',
      confirm: 'Reactivar',
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).setSuspension(u.id, suspend: false),
      success: 'Cuenta reactivada',
    );
    if (ok) {
      ref
        ..invalidate(adminUsersProvider)
        ..invalidate(peopleProvider)
        ..invalidate(adminDashboardProvider);
    }
  }

  Future<void> _adjust(AdminUser u) async {
    final result = await showDialog<(double, String)>(
      context: context,
      builder: (_) => _AdjustDialog(name: u.fullName),
    );
    if (result == null || !mounted) return;
    await runGuarded(
      context,
      () => ref.read(backendProvider).adjustWallet(u.id, result.$1, result.$2),
      success: 'Saldo ajustado y registrado',
    );
  }

  @override
  Widget build(BuildContext context) {
    final key = (_filter, _query);
    final value = ref.watch(peopleProvider(key));
    return Scaffold(
      appBar: AppBar(title: Text(_filter.title)),
      body: Column(
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.sm),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final f in PeopleFilter.values)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: HySpacing.xs),
                          child: ChoiceChip(
                            key: Key('people-filter-${f.key}'),
                            label: Text(f.label),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: HySpacing.sm),
                TextField(
                  key: const Key('people-search'),
                  decoration: const InputDecoration(
                    hintText: 'Buscar por nombre, correo o celular',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 350), () => setState(() => _query = v.trim()));
                  },
                ),
                if (value case AsyncData(:final value) when value.items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: HySpacing.xs),
                    child: Text(
                      value.isPartial
                          ? 'Mostrando ${value.items.length} de ${value.total}. Busca para encontrar el resto.'
                          : value.total == 1
                          ? '1 persona'
                          : '${value.total} personas',
                      key: const Key('people-count'),
                      style: const TextStyle(color: HyColors.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AdminList<PersonRow>(
              value: value.whenData((l) => l.items),
              onRefresh: () => ref.refresh(peopleProvider(key).future),
              emptyTitle: _query.isEmpty ? 'Nadie en "${_filter.label.toLowerCase()}".' : 'No encontramos usuarios',
              emptyIcon: Icons.person_search_outlined,
              itemBuilder: (context, row) {
                final u = row.user;
                return AppCard(
                  key: Key('person-${u.id}'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          PersonAvatar(name: u.fullName, size: 44),
                          const SizedBox(width: HySpacing.sm),
                          Expanded(
                            child: Text(u.fullName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                          ),
                          if (u.isSuspended) const ToneChip('Suspendida', StatusTone.danger),
                          if (u.isAdmin) const ToneChip('Admin', StatusTone.info),
                        ],
                      ),
                      if (u.email != null) InfoLine(Icons.mail_outline, u.email!),
                      if (u.phone != null) InfoLine(Icons.phone_outlined, u.phone!),
                      InfoLine(
                        Icons.badge_outlined,
                        [
                          if (u.roles.contains(AppRole.professional) || u.professionalStatus != null)
                            'Profesional (${(u.professionalStatus ?? VerificationStatus.notStarted).label.toLowerCase()})'
                          else
                            'Cliente',
                          ?u.cityName,
                        ].join(' · '),
                      ),
                      if (row.isAvailable != null && u.professionalStatus == VerificationStatus.approved)
                        InfoLine(
                          row.isAvailable! ? Icons.toggle_on_outlined : Icons.toggle_off_outlined,
                          row.isAvailable! ? 'Disponible ahora' : 'No disponible ahora',
                        ),
                      if (row.identityStatus != null && row.identityStatus != IdentityStatus.none)
                        InfoLine(Icons.verified_user_outlined, 'Identidad: ${row.identityStatus!.label.toLowerCase()}'),
                      if (u.reportsAgainst > 0)
                        InfoLine(Icons.flag_outlined, '${u.reportsAgainst} reporte(s) en su contra'),
                      if (u.isSuspended)
                        InfoLine(
                          Icons.block,
                          'Suspendida ${Fmt.relative(u.suspendedAt!)}: ${u.suspensionReason ?? 'sin motivo'}',
                        ),
                      if (!u.isAdmin) ...[
                        const SizedBox(height: HySpacing.xs),
                        Wrap(
                          spacing: HySpacing.xs,
                          children: [
                            if (u.isSuspended)
                              OutlinedButton(onPressed: () => _reactivate(u), child: const Text('Reactivar'))
                            else
                              TextButton.icon(
                                onPressed: () => showSuspendSheet(context, ref, userId: u.id, name: u.fullName),
                                icon: const Icon(Icons.block, color: HyColors.danger),
                                label: const Text('Suspender', style: TextStyle(color: HyColors.danger)),
                              ),
                            // Ajustar saldo es dinero: solo el propietario.
                            if (u.professionalStatus == VerificationStatus.approved &&
                                (ref.watch(accountProvider).value?.isAdmin ?? false))
                              OutlinedButton(onPressed: () => _adjust(u), child: const Text('Ajustar saldo')),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog({required this.name});

  final String name;

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _add = true;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Ajustar saldo de ${widget.name}'),
    content: Form(
      key: _form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Sumar')),
                ButtonSegment(value: false, label: Text('Restar')),
              ],
              selected: {_add},
              onSelectionChanged: (v) => setState(() => _add = v.first),
            ),
            const SizedBox(height: HySpacing.sm),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
              decoration: const InputDecoration(labelText: 'Monto', prefixText: 'Bs '),
              validator: (v) {
                final n = double.tryParse((v ?? '').replaceAll(',', '.'));
                return n == null || n <= 0 || n > 10000 ? 'Revisa el monto' : null;
              },
            ),
            const SizedBox(height: HySpacing.sm),
            TextFormField(
              controller: _reason,
              decoration: const InputDecoration(labelText: 'Motivo (queda registrado)'),
              validator: (v) => (v ?? '').trim().length < 5 ? 'Escribe el motivo' : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Volver')),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          final n = double.parse(_amount.text.replaceAll(',', '.'));
          Navigator.pop(context, (_add ? n : -n, _reason.text.trim()));
        },
        child: const Text('Guardar'),
      ),
    ],
  );
}
