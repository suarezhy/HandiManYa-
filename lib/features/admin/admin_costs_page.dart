import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/costs.dart';
import '../../data/providers.dart';
import '../security/confirm_identity.dart';
import 'admin_common.dart';
import '../../core/widgets/trailing_row.dart';
import '../../core/widgets/word_safe_text.dart';

final costDashboardProvider = FutureProvider<CostDashboard>((ref) => ref.watch(backendProvider).costDashboard());

String _usd(double v) => 'US\$ ${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)}';

String _price(CostVendor v) => switch (v.billing) {
  'mensual' => '${_usd(v.fixedUsd)} al mes',
  'anual' => '${_usd(v.fixedUsd)} al año',
  'unico' => '${_usd(v.fixedUsd)} una vez',
  _ when v.unitPriceUsd == 0 => 'Sin costo por ${v.unit}',
  _ => 'US\$ ${v.unitPriceUsd.toStringAsFixed(v.unitPriceUsd < 0.1 ? 4 : 2)} por ${v.unit}',
};

StatusTone _tone(VendorStatus s) => switch (s) {
  VendorStatus.off => StatusTone.neutral,
  VendorStatus.sandbox => StatusTone.info,
  VendorStatus.free => StatusTone.success,
  VendorStatus.paid => StatusTone.warning,
};

/// Costos del mes: uso de los planes gratis, cargos hasta hoy, proyección a fin
/// de mes y alertas. Nada pagado se activa ni cobra sin la autorización del dueño.
class AdminCostsPage extends ConsumerWidget {
  const AdminCostsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(costDashboardProvider);
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Costos del mes')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(costDashboardProvider),
        child: ListView(
          padding: bottomSafePadding(context, top: HySpacing.sm),
          children: [
            PageBody(
              child: switch (d) {
                AsyncData(:final value) => _Body(value),
                AsyncError(:final error) => ErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(costDashboardProvider),
                ),
                _ => const LoadingView(),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body(this.d);

  final CostDashboard d;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = <String, List<CostVendor>>{};
    for (final v in d.vendors) {
      groups.putIfAbsent(v.category, () => []).add(v);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          key: const Key('cost-summary'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mes ${d.month} · día ${d.daysElapsed.floor()} de ${d.daysInMonth.round()}',
                style: const TextStyle(color: HyColors.textSecondary),
              ),
              const SizedBox(height: HySpacing.xs),
              Text(
                'Gastado: ${_usd(d.costSoFarUsd)}',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              Text(
                'Proyectado a fin de mes: ${_usd(d.projectedUsd)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              if (d.oneTimeUsd > 0)
                Text(
                  'Pagos únicos autorizados: ${_usd(d.oneTimeUsd)}',
                  style: const TextStyle(color: HyColors.textSecondary),
                ),
            ],
          ),
        ),
        const SizedBox(height: HySpacing.sm),
        const InfoBanner(
          icon: Icons.shield_outlined,
          text:
              'Nada pagado se activa ni cobra sin tu autorización. Si se acaba un plan gratis o se llega a un tope, '
              'el uso se frena y te avisamos; no se cobra de más.',
        ),
        if (d.alerts.isNotEmpty) ...[
          const SectionHeader(title: 'Alertas'),
          for (final a in d.alerts)
            Padding(
              padding: const EdgeInsets.only(bottom: HySpacing.xs),
              child: InfoBanner(
                icon: Icons.warning_amber_rounded,
                tone: a.level == CostLevel.blocked || a.level == CostLevel.nearCap
                    ? StatusTone.danger
                    : StatusTone.warning,
                text: a.message,
              ),
            ),
        ],
        for (final g in groups.entries) ...[
          SectionHeader(title: _categoryLabel(g.key)),
          for (final v in g.value)
            Padding(
              padding: const EdgeInsets.only(bottom: HySpacing.sm),
              child: _VendorCard(v),
            ),
        ],
        const SectionHeader(title: 'Últimos 6 meses'),
        AppCard(
          child: Column(
            children: [
              for (final h in d.history)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(h.month)),
                      Text(_usd(h.costUsd), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: HySpacing.md),
        SecondaryButton(
          label: 'Revisar ahora',
          icon: Icons.manage_search,
          onPressed: () async {
            final ok = await runGuarded(context, () async {
              final n = await ref.read(backendProvider).runCostMonitors();
              if (context.mounted) showMessage(context, n == 0 ? 'Sin avisos nuevos.' : '$n aviso(s) nuevo(s).');
            });
            if (ok) ref.invalidate(costDashboardProvider);
          },
        ),
      ],
    );
  }

  static String _categoryLabel(String c) => switch (c) {
    'infraestructura' => 'Infraestructura',
    'identidad' => 'Verificación de identidad',
    'mensajes' => 'Mensajes y avisos',
    'ia' => 'Inteligencia artificial',
    'tiendas' => 'Tiendas de apps',
    _ => 'Web',
  };
}

class _VendorCard extends ConsumerWidget {
  const _VendorCard(this.v);

  final CostVendor v;

  Future<void> _stop(BuildContext context, WidgetRef ref) async {
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).setVendor(v.key, VendorStatus.off),
      success: '${v.name}: apagado. No se usará ni cobrará.',
    );
    if (ok) ref.invalidate(costDashboardProvider);
  }

  Future<void> _change(BuildContext context, WidgetRef ref) async {
    final choice = await showDialog<(VendorStatus, double)>(context: context, builder: (_) => _ChangeDialog(v));
    if (choice == null || !context.mounted) return;
    final (status, cap) = choice;
    String? method;
    final moreUse = status.index > v.status.index || (status == VendorStatus.paid && cap > v.monthlyCapUsd);
    if (moreUse) {
      final c = await confirmIdentity(
        context,
        operation: status == VendorStatus.paid ? 'Autorizar gasto: ${v.name}' : 'Activar: ${v.name}',
        details: [
          ('Estado', status.label),
          if (status == VendorStatus.paid && v.metered) ('Tope mensual', _usd(cap)),
          ('Precio', _price(v)),
        ],
        submitLabel: 'Confirmar y autorizar',
      );
      if (c == null) return;
      method = c.serverMethod;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).setVendor(v.key, status, monthlyCapUsd: cap, authMethod: method),
      success: 'Listo. Queda registrado en la auditoría.',
    );
    if (ok) ref.invalidate(costDashboardProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final percent = v.freeUsedPercent;
    return AppCard(
      key: Key('vendor-${v.key}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TrailingRow(
            leading: const SizedBox.shrink(),
            gap: HySpacing.xs,
            minBodyWidth: 140,
            body: WordSafeText(v.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            trailing: ToneChip(v.status.label, _tone(v.status)),
          ),
          InfoLine(Icons.sell_outlined, _price(v)),
          if (v.freeUnits > 0) ...[
            InfoLine(
              Icons.redeem_outlined,
              'Gratis este mes: ${v.usedUnits.toStringAsFixed(0)} de ${v.freeUnits} ${v.unit == 'verificación' ? 'verificaciones' : v.unit}',
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(
                value: (percent ?? 0) / 100,
                minHeight: 8,
                borderRadius: BorderRadius.circular(HyRadii.pill),
                color: (percent ?? 0) >= 80 ? HyColors.warning : HyColors.green,
              ),
            ),
          ],
          if (v.sandboxUnits > 0)
            InfoLine(Icons.science_outlined, 'Pruebas este mes: ${v.sandboxUnits.toStringAsFixed(0)} (sin costo)'),
          if (v.metered && v.usedUnits > 0 && v.freeUnits == 0)
            InfoLine(Icons.data_usage, 'Uso este mes: ${v.usedUnits.toStringAsFixed(0)}'),
          if (v.costSoFarUsd > 0 || v.projectedUsd > 0)
            InfoLine(
              Icons.receipt_long_outlined,
              'Cargos: ${_usd(v.costSoFarUsd)} · proyectado ${_usd(v.projectedUsd)}',
            ),
          if (v.status == VendorStatus.paid && v.metered)
            InfoLine(Icons.lock_outline, 'Tope mensual: ${_usd(v.monthlyCapUsd)}'),
          if (v.blocked > 0) InfoLine(Icons.block, 'Frenados este mes: ${v.blocked} (no se cobraron)'),
          if (v.notes != null) InfoLine(Icons.notes, v.notes!),
          const SizedBox(height: HySpacing.sm),
          Wrap(
            spacing: HySpacing.sm,
            children: [
              OutlinedButton(
                key: Key('vendor-change-${v.key}'),
                onPressed: () => _change(context, ref),
                child: const Text('Cambiar'),
              ),
              if (v.status != VendorStatus.off)
                TextButton(
                  key: Key('vendor-stop-${v.key}'),
                  onPressed: () => _stop(context, ref),
                  child: const Text('Apagar'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChangeDialog extends StatefulWidget {
  const _ChangeDialog(this.v);

  final CostVendor v;

  @override
  State<_ChangeDialog> createState() => _ChangeDialogState();
}

class _ChangeDialogState extends State<_ChangeDialog> {
  late VendorStatus _status = widget.v.status;
  late final _cap = TextEditingController(
    text: widget.v.monthlyCapUsd > 0 ? widget.v.monthlyCapUsd.toStringAsFixed(0) : '',
  );

  @override
  void dispose() {
    _cap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.v;
    final options = [
      for (final s in VendorStatus.values)
        if (s != VendorStatus.sandbox || v.hasSandbox) s,
    ];
    final cap = double.tryParse(_cap.text.replaceAll(',', '.')) ?? 0;
    final needsCap = _status == VendorStatus.paid && v.metered;
    return AlertDialog(
      title: Text(v.name),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<VendorStatus>(
              groupValue: _status,
              onChanged: (s) => setState(() => _status = s!),
              child: Column(
                children: [
                  for (final s in options)
                    RadioListTile<VendorStatus>(
                      key: Key('vendor-option-${s.key}'),
                      value: s,
                      title: Text(s.label),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            if (needsCap)
              TextField(
                key: const Key('vendor-cap'),
                controller: _cap,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Tope mensual (US\$)', helperText: 'Al llegar, se frena.'),
                onChanged: (_) => setState(() {}),
              ),
            if (_status == VendorStatus.paid)
              const Padding(
                padding: EdgeInsets.only(top: HySpacing.sm),
                child: Text(
                  'Autorizar un gasto pide confirmar que eres tú.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Volver')),
        FilledButton(
          key: const Key('vendor-save'),
          onPressed: needsCap && cap <= 0 ? null : () => Navigator.pop(context, (_status, needsCap ? cap : 0.0)),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
