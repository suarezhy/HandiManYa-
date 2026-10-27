import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/button_row.dart';
import '../../data/models/admin.dart';
import '../../data/models/booking.dart';
import '../../data/models/wallet.dart';
import '../../data/providers.dart';
import 'admin_common.dart';
import '../../core/widgets/word_safe_text.dart';

// ======================================================================= Recargas
class AdminTopupsPage extends ConsumerWidget {
  const AdminTopupsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const OneLineText('Recargas'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Por revisar'),
              Tab(text: 'Todas'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final s in const ['pending', 'all']) _TopupList(status: s),
          ],
        ),
      ),
    );
  }
}

class _TopupList extends ConsumerWidget {
  const _TopupList({required this.status});

  final String status;

  Future<void> _review(BuildContext context, WidgetRef ref, AdminTopup t, bool approve) async {
    String? note;
    if (approve) {
      if (!await confirmDialog(
        context,
        title: '¿Acreditar ${Fmt.bs(t.amount)}?',
        message:
            'Confírmalo solo si viste el pago en la cuenta de la empresa. El saldo se suma a ${t.displayName} y queda registrado.',
        confirm: 'Acreditar',
      )) {
        return;
      }
    } else {
      note = await promptText(
        context,
        title: 'Rechazar recarga',
        label: 'Motivo (lo verá el profesional)',
        hint: 'Ej.: no encontramos el pago',
        confirm: 'Rechazar',
      );
      if (note == null) return;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).reviewTopup(t.id, approve: approve, note: note),
      success: approve ? 'Recarga acreditada' : 'Recarga rechazada',
    );
    if (ok) {
      ref
        ..invalidate(adminTopupsProvider)
        ..invalidate(adminDashboardProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminList<AdminTopup>(
      value: ref.watch(adminTopupsProvider(status)),
      onRefresh: () => ref.refresh(adminTopupsProvider(status).future),
      emptyTitle: 'No hay recargas por revisar',
      header: const Padding(
        padding: EdgeInsets.only(bottom: HySpacing.sm),
        child: InfoBanner(
          text:
              'Acreditar suma el saldo a la billetera del profesional; no es un ingreso. '
              'Un comprobante no prueba que el dinero llegó: concílialo con tu extracto en Finanzas y Bancos.',
        ),
      ),
      itemBuilder: (context, t) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: OneLineText(
                    Fmt.bs(t.amount),
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                  ),
                ),
                ToneChip(t.status.label, switch (t.status) {
                  TopupStatus.approved => StatusTone.success,
                  TopupStatus.pending => StatusTone.warning,
                  _ => StatusTone.danger,
                }),
              ],
            ),
            InfoLine(Icons.person_outline, t.displayName),
            InfoLine(Icons.payments_outlined, t.methodName ?? 'Método no indicado'),
            InfoLine(Icons.tag, t.reference == null ? 'Sin número de comprobante' : 'Comprobante ${t.reference}'),
            InfoLine(Icons.schedule, Fmt.dateTime(t.createdAt)),
            if (t.reviewNote != null) InfoLine(Icons.notes, t.reviewNote!),
            const SizedBox(height: HySpacing.xs),
            if (t.hasProof)
              EvidenceImage(url: t.proofUrl, bytes: t.proofBytes, label: 'Comprobante de pago')
            else
              const InfoBanner(
                icon: Icons.receipt_long_outlined,
                tone: StatusTone.warning,
                text: 'No adjuntó foto del comprobante. Verifica el pago con el número de transacción.',
              ),
            if (t.status == TopupStatus.pending) ...[
              const SizedBox(height: HySpacing.sm),
              ButtonRow(
                spacing: HySpacing.xs,
                children: [
                  SecondaryButton(label: 'Rechazar', onPressed: () => _review(context, ref, t, false)),
                  PrimaryButton(
                    label: 'Acreditar',
                    color: HyColors.greenDark,
                    onPressed: () => _review(context, ref, t, true),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ======================================================================= Comisiones
class AdminCommissionsPage extends ConsumerWidget {
  const AdminCommissionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = {for (final c in ref.watch(categoriesProvider).value ?? const []) c.id: c.name};
    final cities = {for (final c in ref.watch(citiesProvider).value ?? const []) c.id: c.shortName};
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Comisiones')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Nueva regla'),
      ),
      body: AdminList<CommissionRule>(
        value: ref.watch(commissionRulesProvider),
        hasFab: true,
        onRefresh: () => ref.refresh(commissionRulesProvider.future),
        emptyTitle: 'Todavía no hay reglas. Sin reglas no se cobra comisión.',
        emptyIcon: Icons.percent,
        header: const Padding(
          padding: EdgeInsets.only(bottom: HySpacing.sm),
          child: InfoBanner(
            text: 'Se aplica la regla activa más específica: categoría y ciudad, luego solo categoría, luego solo ciudad, luego la general. Los montos los defines tú; la app no inventa porcentajes.',
          ),
        ),
        itemBuilder: (context, r) => AppCard(
          onTap: () => _edit(context, r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(r.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                  ToneChip(r.isActive ? 'Activa' : 'Inactiva', r.isActive ? StatusTone.success : StatusTone.neutral),
                ],
              ),
              InfoLine(
                Icons.filter_alt_outlined,
                [
                  r.categoryId == null ? 'Todas las categorías' : cats[r.categoryId] ?? 'Categoría ${r.categoryId}',
                  r.cityId == null ? 'todas las ciudades' : cities[r.cityId] ?? 'Ciudad ${r.cityId}',
                ].join(' · '),
              ),
              InfoLine(
                Icons.percent,
                [
                  if (r.ratePercent != null) '${Fmt.rating(r.ratePercent!)} % del trabajo',
                  if (r.fixedFee != null) '${Fmt.bs(r.fixedFee!)} fijo',
                ].join(' o '),
              ),
              InfoLine(
                Icons.lock_clock_outlined,
                'Reserva mínima al aceptar: ${Fmt.bs(r.reserveAmount)} · se cobra al completar',
              ),
              InfoLine(Icons.account_balance_wallet_outlined, 'Saldo mínimo para aceptar: ${Fmt.bs(r.minBalance)}'),
            ],
          ),
        ),
      ),
    );
  }

  void _edit(BuildContext context, CommissionRule? rule) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _RuleSheet(rule: rule),
  );
}

class _RuleSheet extends ConsumerStatefulWidget {
  const _RuleSheet({this.rule});

  final CommissionRule? rule;

  @override
  ConsumerState<_RuleSheet> createState() => _RuleSheetState();
}

class _RuleSheetState extends ConsumerState<_RuleSheet> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.rule?.name ?? '');
  late final _rate = TextEditingController(text: _fmt(widget.rule?.ratePercent));
  late final _fixed = TextEditingController(text: _fmt(widget.rule?.fixedFee));
  late final _reserve = TextEditingController(text: _fmt(widget.rule?.reserveAmount));
  late final _min = TextEditingController(text: _fmt(widget.rule?.minBalance));
  late int? _category = widget.rule?.categoryId;
  late int? _city = widget.rule?.cityId;
  late bool _active = widget.rule?.isActive ?? true;
  bool _saving = false;

  static String _fmt(double? v) => v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());
  static double? _num(String v) => double.tryParse(v.trim().replaceAll(',', '.'));

  @override
  void dispose() {
    for (final c in [_name, _rate, _fixed, _reserve, _min]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _money(String? v, {double max = 10000}) {
    if ((v ?? '').trim().isEmpty) return null;
    final n = _num(v!);
    if (n == null || n < 0 || n > max) return 'Revisa el número';
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_rate.text.trim().isEmpty && _fixed.text.trim().isEmpty) {
      showMessage(context, 'Escribe un porcentaje o un cargo fijo.');
      return;
    }
    setState(() => _saving = true);
    final rule = CommissionRule(
      id: widget.rule?.id,
      name: _name.text,
      categoryId: _category,
      cityId: _city,
      ratePercent: _num(_rate.text),
      fixedFee: _num(_fixed.text),
      reserveAmount: _num(_reserve.text) ?? 0,
      minBalance: _num(_min.text) ?? 0,
      captureAt: CommissionMilestone.completed,
      isActive: _active,
    );
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).saveCommissionRule(rule),
      success: 'Regla guardada',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref
        ..invalidate(commissionRulesProvider)
        ..invalidate(adminDashboardProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(categoriesProvider).value ?? const [];
    final cities = ref.watch(citiesProvider).value ?? const [];
    final numberInput = [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')), LengthLimitingTextInputFormatter(8)];
    return Padding(
      padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.rule == null ? 'Nueva regla de comisión' : 'Editar regla',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: HySpacing.md),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ej.: Electricidad Santa Cruz'),
                validator: (v) => (v ?? '').trim().length < 3 ? 'Escribe un nombre' : null,
              ),
              const SizedBox(height: HySpacing.sm),
              DropdownButtonFormField<int?>(
                initialValue: _category,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Categoría'),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Todas las categorías')),
                  for (final c in cats) DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _category = v),
              ),
              const SizedBox(height: HySpacing.sm),
              DropdownButtonFormField<int?>(
                initialValue: _city,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Ciudad'),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Toda Bolivia')),
                  for (final c in cities) DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _city = v),
              ),
              const SizedBox(height: HySpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _rate,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: numberInput,
                      decoration: const InputDecoration(labelText: 'Porcentaje', suffixText: '%'),
                      validator: (v) => _money(v, max: 100),
                    ),
                  ),
                  const SizedBox(width: HySpacing.sm),
                  Expanded(
                    child: TextFormField(
                      controller: _fixed,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: numberInput,
                      decoration: const InputDecoration(labelText: 'Cargo fijo', prefixText: 'Bs '),
                      validator: _money,
                    ),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Si pones los dos, se usa el porcentaje cuando hay monto final y el cargo fijo cuando no.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
              ),
              const SizedBox(height: HySpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _reserve,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: numberInput,
                      decoration: const InputDecoration(labelText: 'Reserva al aceptar', prefixText: 'Bs '),
                      validator: _money,
                    ),
                  ),
                  const SizedBox(width: HySpacing.sm),
                  Expanded(
                    child: TextFormField(
                      controller: _min,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: numberInput,
                      decoration: const InputDecoration(labelText: 'Saldo mínimo', prefixText: 'Bs '),
                      validator: _money,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HySpacing.sm),
              const InfoBanner(
                icon: Icons.info_outline,
                text:
                    'Al aceptar se reserva la comisión completa (o esta reserva, si es mayor). Se cobra al completar '
                    'y vuelve al saldo si se cancela. Si falta saldo, queda pendiente y se cobra de la próxima recarga.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Regla activa', style: TextStyle(fontWeight: FontWeight.w700)),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
              const SizedBox(height: HySpacing.sm),
              PrimaryButton(label: 'Guardar regla', loading: _saving, onPressed: _save),
            ],
          ),
        ),
      ),
    );
  }
}
