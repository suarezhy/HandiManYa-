import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/finance.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/photo_picker.dart';
import '../common/unsaved_changes.dart';
import '../management/management_common.dart';
import '../security/confirm_identity.dart';
import 'admin_common.dart';
import 'drilldown_pages.dart';
import '../../core/widgets/word_safe_text.dart';

// Finanzas y Bancos: solo el Propietario. El router no deja entrar a otro rol
// y cada función del servidor vuelve a exigir is_admin(). Los montos salen de
// la base; sin conexión con un banco, nada se marca como recibido solo.

/// Mes a resumir, como 'YYYY-MM'.
final financeSummaryProvider = FutureProvider.family<FinanceSummary, String>((ref, month) {
  final p = month.split('-');
  return ref.watch(backendProvider).financeSummary(month: DateTime(int.parse(p[0]), int.parse(p[1])));
});
final receivingAccountsProvider = FutureProvider<List<ReceivingAccount>>(
  (ref) => ref.watch(backendProvider).receivingAccounts(),
);

/// (tipo, profesional): los dos opcionales.
final financeTransactionsProvider = FutureProvider.family<List<FinanceTransaction>, (String?, String?)>(
  (ref, k) => ref.watch(backendProvider).financeTransactions(kind: k.$1, professionalId: k.$2, limit: 100),
);

/// (filtro, mes 'YYYY-MM' o null, búsqueda).
final financeTopupsProvider = FutureProvider.family<FinanceList<ReconcileTopup>, (TopupFilter, String?, String)>(
  (ref, k) => ref.watch(backendProvider).financeTopups(k.$1, month: _monthOf(k.$2), query: k.$3),
);

/// (tipo, mes 'YYYY-MM' o null, búsqueda, profesional).
final financeLedgerProvider =
    FutureProvider.family<FinanceList<FinanceTransaction>, (String?, String?, String, String?)>(
      (ref, k) => ref
          .watch(backendProvider)
          .financeLedger(kind: k.$1, month: _monthOf(k.$2), query: k.$3, professionalId: k.$4),
    );

DateTime? _monthOf(String? key) {
  if (key == null) return null;
  final p = key.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]));
}

final commissionDebtsProvider = FutureProvider<FinanceList<CommissionDebt>?>(
  (ref) => ref.watch(backendProvider).commissionDebts(),
);
final financeAuditProvider = FutureProvider<List<FinanceAuditEntry>>(
  (ref) => ref.watch(backendProvider).financeAudit(),
);

void _refreshFinance(WidgetRef ref) => ref
  ..invalidate(financeSummaryProvider)
  ..invalidate(receivingAccountsProvider)
  ..invalidate(financeTransactionsProvider)
  ..invalidate(financeTopupsProvider)
  ..invalidate(financeLedgerProvider)
  ..invalidate(financeAuditProvider)
  ..invalidate(commissionDebtsProvider)
  ..invalidate(adminDashboardProvider);

String _monthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

String _monthLabel(String key) {
  final p = key.split('-');
  final s = DateFormat('MMMM y', 'es').format(DateTime(int.parse(p[0]), int.parse(p[1])));
  return s[0].toUpperCase() + s.substring(1);
}

/// Pide un código nuevo antes de un cambio de dinero o de datos bancarios.
Future<String?> _confirm(BuildContext context, String operation, {List<(String, String)> details = const []}) async {
  final c = await confirmIdentity(
    context,
    operation: operation,
    details: details,
    submitLabel: 'Confirmar',
    codeOnly: true,
  );
  return c?.serverMethod;
}

// ============================================================ Resumen
class FinancePage extends ConsumerStatefulWidget {
  const FinancePage({super.key});

  @override
  ConsumerState<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends ConsumerState<FinancePage> {
  var _month = _monthKey(DateTime.now());

  void _shift(int months) {
    final p = _month.split('-');
    setState(() => _month = _monthKey(DateTime(int.parse(p[0]), int.parse(p[1]) + months)));
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(financeSummaryProvider(_month));
    final isCurrent = _month == _monthKey(DateTime.now());
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Finanzas y Bancos')),
      body: RefreshIndicator(
        onRefresh: () async {
          _refreshFinance(ref);
          await ref.read(financeSummaryProvider(_month).future);
        },
        child: ListView(
          padding: bottomSafePadding(context),
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: HySpacing.sm),
                  Row(
                    children: [
                      IconButton(
                        key: const Key('finance-prev-month'),
                        tooltip: 'Mes anterior',
                        onPressed: () => _shift(-1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: Text(
                          _monthLabel(_month),
                          key: const Key('finance-month'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        key: const Key('finance-next-month'),
                        tooltip: 'Mes siguiente',
                        onPressed: isCurrent ? null : () => _shift(1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                  switch (summary) {
                    AsyncData(:final value) => _FinanceSummaryView(s: value, isCurrent: isCurrent),
                    AsyncError(:final error) => ErrorView(
                      error: error,
                      onRetry: () => ref.invalidate(financeSummaryProvider(_month)),
                    ),
                    _ => const LoadingView(),
                  },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FinanceSummaryView extends StatelessWidget {
  const _FinanceSummaryView({required this.s, required this.isCurrent});

  final FinanceSummary s;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    void go(String route) => context.push(route);
    String movements(String kind) => '${Routes.adminFinanceMovements}?tipo=$kind&mes=${s.month}';
    String topups(TopupFilter f, {bool allMonths = false}) =>
        '${Routes.adminFinanceReconcile}?estado=${f.key}${allMonths ? '' : '&mes=${s.month}'}';
    const note = TextStyle(color: HyColors.textSecondary);
    return Column(
      key: const Key('finance-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!s.bankConnected)
          const InfoBanner(
            key: Key('finance-bank-pending'),
            icon: Icons.account_balance_outlined,
            tone: StatusTone.warning,
            text:
                'Conexión con el banco: Pendiente de configuración. Nada se marca como recibido solo: '
                'cada recarga queda "Sin verificar" hasta que la concilies con tu extracto.',
          ),
        const SectionHeader(title: 'Ingresos de la plataforma'),
        PanelGrid(
          minTileWidth: 170,
          children: [
            PanelStat(
              'Comisiones cobradas',
              null,
              key: const Key('fin-card-commission'),
              display: Fmt.bs(s.commissionEarnedBs),
              onTap: () => go(movements('commission_capture')),
            ),
            PanelStat(
              'Trabajos con comisión cobrada',
              s.commissionsCount,
              key: const Key('fin-card-commission-jobs'),
              onTap: () => go(movements('commission_capture')),
            ),
            if (s.commissionRefundedBs != 0)
              PanelStat(
                'Devoluciones a profesionales',
                null,
                key: const Key('fin-card-refunds'),
                display: Fmt.bs(s.commissionRefundedBs),
                onTap: () => go(movements('refund')),
              ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: HySpacing.xs),
          child: Text(
            'Lo único que gana la plataforma es la comisión que se cobra de la billetera del profesional: '
            'se reserva completa al aceptar, se cobra al completar y vuelve al saldo si se cancela. '
            'Lo que el cliente paga por el trabajo (en efectivo o QR) lo recibe el profesional y no pasa por aquí.',
            style: note,
          ),
        ),
        const SectionHeader(title: 'Fondos de billeteras (son de los profesionales)'),
        PanelGrid(
          minTileWidth: 170,
          children: [
            PanelStat(
              'Recargas acreditadas',
              null,
              key: const Key('fin-card-credited'),
              display: Fmt.bs(s.walletFundsReceivedBs),
              detail: s.walletFundsReceivedCount == 1 ? '1 recarga' : '${s.walletFundsReceivedCount} recargas',
              onTap: () => go(topups(TopupFilter.credited)),
            ),
            PanelStat(
              'Conciliadas con el banco',
              null,
              key: const Key('fin-card-reconciled'),
              display: Fmt.bs(s.walletFundsReconciledBs),
              onTap: () => go(topups(TopupFilter.reconciled)),
            ),
            PanelStat(
              'Sin verificar en el banco',
              s.walletFundsUnverifiedBs > 0 ? 1 : 0,
              key: const Key('fin-card-unverified'),
              tone: StatusTone.warning,
              display: Fmt.bs(s.walletFundsUnverifiedBs),
              onTap: () => go(topups(TopupFilter.unverified)),
            ),
            PanelStat(
              'No aparecen en el banco',
              s.walletFundsNotFoundBs > 0 ? 1 : 0,
              key: const Key('fin-card-not-found'),
              tone: StatusTone.danger,
              display: Fmt.bs(s.walletFundsNotFoundBs),
              onTap: () => go(topups(TopupFilter.notFound)),
            ),
            if (s.manualAdjustmentsBs != 0)
              PanelStat(
                'Ajustes manuales',
                null,
                key: const Key('fin-card-adjustments'),
                display: Fmt.bs(s.manualAdjustmentsBs),
                onTap: () => go(movements('adjustment')),
              ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: HySpacing.xs),
          child: Text(
            'Una recarga no es un ingreso: es saldo del profesional para pagar comisiones. '
            'Un comprobante subido no prueba que el dinero llegó al banco.',
            style: note,
          ),
        ),
        const SectionHeader(title: 'Ahora'),
        PanelGrid(
          minTileWidth: 170,
          children: [
            PanelStat(
              'Saldos disponibles',
              null,
              key: const Key('fin-card-available'),
              display: Fmt.bs(s.walletsAvailableBs),
              detail: s.walletsCount == 1 ? '1 billetera' : '${s.walletsCount} billeteras',
              onTap: () => go(Routes.adminFinanceWallets),
            ),
            PanelStat(
              'Saldos reservados',
              null,
              key: const Key('fin-card-reserved'),
              display: Fmt.bs(s.walletsReservedBs),
              detail: 'Comisiones de trabajos en curso',
              onTap: () => go('${Routes.adminFinanceWallets}?orden=reservado'),
            ),
            PanelStat(
              'Recargas por revisar',
              s.topupsPending,
              key: const Key('fin-card-pending'),
              tone: StatusTone.brand,
              detail: Fmt.bs(s.topupsPendingBs),
              onTap: () => go(Routes.adminTopups),
            ),
            const _DebtsStat(),
            PanelStat(
              'Acreditadas sin conciliar',
              s.topupsUnverifiedTotal,
              key: const Key('fin-card-unverified-all'),
              tone: StatusTone.warning,
              detail: '${Fmt.bs(s.topupsUnverifiedTotalBs)} · todos los meses',
              onTap: () => go(topups(TopupFilter.unverified, allMonths: true)),
            ),
          ],
        ),
        const SectionHeader(title: 'Últimos 6 meses'),
        AppCard(
          key: const Key('finance-months'),
          child: _MonthsTable(months: s.months.reversed.toList()),
        ),
        const SectionHeader(title: 'Bancos y control'),
        PanelTile(
          icon: Icons.account_balance_outlined,
          title: 'Cuentas de cobro y QR',
          subtitle: s.receivingAccountsActive == 0
              ? 'Pendiente de configuración'
              : '${s.receivingAccountsActive} activa(s) · ${s.receivingAccountsVerified} verificada(s)',
          onTap: () => go(Routes.adminFinanceAccounts),
        ),
        PanelTile(
          icon: Icons.fact_check_outlined,
          title: 'Conciliar recargas',
          subtitle: 'Compara cada recarga con tu extracto',
          count: s.topupsUnverifiedTotal,
          onTap: () => go(Routes.adminFinanceReconcile),
        ),
        PanelTile(
          icon: Icons.receipt_long_outlined,
          title: 'Movimientos',
          subtitle: 'Recargas, comisiones y ajustes, con su referencia',
          onTap: () => go(Routes.adminFinanceMovements),
        ),
        PanelTile(
          icon: Icons.history,
          title: 'Historial de cambios',
          subtitle: 'Quién aprobó, concilió o cambió datos de cobro',
          onTap: () => go(Routes.adminFinanceAudit),
        ),
        if (s.generatedAt != null)
          Padding(
            padding: const EdgeInsets.only(top: HySpacing.xs),
            child: Text(
              'Datos de la base al ${Fmt.dateTime(s.generatedAt!)}. Meses en hora de Bolivia.'
              '${isCurrent ? ' El mes en curso todavía no terminó.' : ''}',
              style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
            ),
          ),
      ],
    );
  }
}

// ============================================================ Conciliar
/// Recargas filtradas por estado y mes: lo que hay detrás de cada tarjeta de
/// fondos de billeteras. Desde aquí se concilia cada una.
class FinanceReconcilePage extends ConsumerStatefulWidget {
  const FinanceReconcilePage({super.key, this.initialFilter = TopupFilter.unverified, this.month});

  final TopupFilter initialFilter;

  /// 'YYYY-MM' o null para todos los meses.
  final String? month;

  @override
  ConsumerState<FinanceReconcilePage> createState() => _FinanceReconcilePageState();
}

class _FinanceReconcilePageState extends ConsumerState<FinanceReconcilePage> {
  late var _filter = widget.initialFilter;
  late String? _month = widget.month;
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final key = (_filter, _month, _query);
    final value = ref.watch(financeTopupsProvider(key));
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Recargas y banco')),
      body: AdminList<ReconcileTopup>(
        value: value.whenData((l) => l.items),
        onRefresh: () => ref.refresh(financeTopupsProvider(key).future),
        emptyIcon: Icons.account_balance_wallet_outlined,
        emptyTitle: switch (_filter) {
          TopupFilter.unverified => 'No hay recargas acreditadas sin conciliar en este periodo.',
          TopupFilter.reconciled => 'No hay recargas conciliadas en este periodo.',
          TopupFilter.notFound => 'Ninguna recarga marcada como no encontrada en este periodo.',
          TopupFilter.pending => 'No hay recargas por revisar.',
          _ => 'No hay recargas en este periodo.',
        },
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            drilldownChipRow(
              [for (final f in TopupFilter.values) (f, f.label)],
              _filter,
              (f) => setState(() => _filter = f),
              'topups-filter',
            ),
            const SizedBox(height: HySpacing.xs),
            _MonthFilter(month: _month, onChanged: (m) => setState(() => _month = m)),
            DrilldownSearchField(
              hint: 'Profesional, referencia o número',
              fieldKey: const Key('topups-search'),
              onChanged: (q) => setState(() => _query = q),
            ),
            const SizedBox(height: HySpacing.xs),
            if (value.value case final l?) _FinanceCountLine(l, noun: ('recarga', 'recargas')),
            Padding(
              padding: const EdgeInsets.only(bottom: HySpacing.sm),
              child: InfoBanner(
                text: _filter == TopupFilter.pending
                    ? 'Estas todavía no están acreditadas. Se revisan en Recargas; después se concilian aquí.'
                    : 'Busca cada recarga en tu extracto del banco por monto, fecha y referencia. '
                          'Un comprobante subido no prueba que el dinero llegó. Solo tú puedes marcarla; queda en el historial.',
              ),
            ),
          ],
        ),
        itemBuilder: (context, t) => _ReconcileCard(topup: t),
      ),
    );
  }
}

/// "3 recargas · Bs 120,00", y un aviso si la lista no está completa.
class _FinanceCountLine<T> extends StatelessWidget {
  const _FinanceCountLine(this.list, {required this.noun});

  final FinanceList<T> list;
  final (String, String) noun;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.xs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${list.total} ${list.total == 1 ? noun.$1 : noun.$2} · ${Fmt.bs(list.sumBs)}',
          key: const Key('finance-count'),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        if (list.isTruncated)
          Text(
            'Mostrando las ${list.items.length} más recientes. Busca o cambia el mes para ver el resto.',
            style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
          ),
        if (list.isPartial)
          const Text(
            'Lista parcial: el servidor todavía no tiene la última actualización; se muestran los últimos movimientos.',
            key: Key('finance-partial'),
            style: TextStyle(color: HyColors.warning, fontSize: 13),
          ),
      ],
    ),
  );
}

/// Mes anterior / siguiente, o todos los meses.
class _MonthFilter extends StatelessWidget {
  const _MonthFilter({required this.month, required this.onChanged});

  final String? month;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final now = _monthKey(DateTime.now());
    String shift(String m, int by) {
      final p = m.split('-');
      return _monthKey(DateTime(int.parse(p[0]), int.parse(p[1]) + by));
    }

    return Row(
      children: [
        IconButton(
          key: const Key('month-prev'),
          tooltip: 'Mes anterior',
          onPressed: () => onChanged(shift(month ?? now, -1)),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            month == null ? 'Todos los meses' : _monthLabel(month!),
            key: const Key('month-label'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          key: const Key('month-next'),
          tooltip: 'Mes siguiente',
          onPressed: month == null || month == now ? null : () => onChanged(shift(month!, 1)),
          icon: const Icon(Icons.chevron_right),
        ),
        TextButton(
          key: const Key('month-all'),
          onPressed: () => onChanged(month == null ? now : null),
          child: Text(month == null ? 'Este mes' : 'Todos'),
        ),
      ],
    );
  }
}

class _ReconcileCard extends ConsumerWidget {
  const _ReconcileCard({required this.topup});

  final ReconcileTopup topup;

  Future<void> _mark(BuildContext context, WidgetRef ref, BankStatus to) async {
    final t = topup;
    String? reference;
    int? accountId;
    if (to == BankStatus.reconciled) {
      final accounts = (await ref.read(receivingAccountsProvider.future)).where((a) => a.isActive).toList();
      if (!context.mounted) return;
      final r = await showModalBottomSheet<(String, int?)>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _ReconcileSheet(topup: t, accounts: accounts),
      );
      if (r == null) return;
      (reference, accountId) = r;
    } else if (!await confirmDialog(
      context,
      title: to == BankStatus.notFound ? '¿No aparece en el banco?' : '¿Volver a "sin verificar"?',
      message: to == BankStatus.notFound
          ? 'Marca ${Fmt.bs(t.amount)} de ${t.professionalName ?? 'este profesional'} como no encontrada en tu extracto. '
                'El saldo del profesional no cambia: si corresponde, ajústalo aparte con un motivo.'
          : 'La recarga vuelve a quedar pendiente de conciliar.',
      confirm: to == BankStatus.notFound ? 'Marcar no encontrada' : 'Volver a sin verificar',
      destructive: to == BankStatus.notFound,
    )) {
      return;
    }
    if (!context.mounted) return;
    final method = await _confirm(
      context,
      to.label,
      details: [
        ('Recarga', '#${t.id} · ${Fmt.bs(t.amount)}'),
        if (t.professionalName != null) ('Profesional', t.professionalName!),
        if (reference != null) ('Referencia del banco', reference),
      ],
    );
    if (method == null || !context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref
          .read(backendProvider)
          .reconcileTopup(t.id, to, bankReference: reference, accountId: accountId, authMethod: method),
      success: switch (to) {
        BankStatus.reconciled => 'Conciliada. Quedó en el historial.',
        BankStatus.notFound => 'Marcada como no encontrada. Quedó en el historial.',
        BankStatus.unverified => 'Volvió a "sin verificar".',
      },
    );
    if (ok) _refreshFinance(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = topup;
    final tone = switch (t.bankStatus) {
      BankStatus.reconciled => StatusTone.success,
      BankStatus.notFound => StatusTone.danger,
      BankStatus.unverified => StatusTone.warning,
    };
    return AppCard(
      key: Key('reconcile-${t.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(Fmt.bs(t.amount), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              ),
              if (t.isCredited) ToneChip(t.bankStatus.label, tone) else ToneChip(t.statusLabel, StatusTone.neutral),
            ],
          ),
          Text(t.professionalName ?? 'Profesional', style: const TextStyle(fontWeight: FontWeight.w700)),
          InfoLine(Icons.tag, 'Recarga #${t.id} · ${Fmt.dateTime(t.createdAt)}'),
          if (t.methodName != null) InfoLine(Icons.qr_code_2, t.methodName!),
          InfoLine(
            Icons.notes_outlined,
            'Referencia del profesional: ${(t.reference ?? '').isEmpty ? 'no escribió' : t.reference}',
          ),
          InfoLine(
            Icons.image_outlined,
            t.hasProof ? 'Subió un comprobante (no prueba que llegó al banco)' : 'Sin comprobante',
          ),
          if (t.isCredited) InfoLine(Icons.check, t.statusLabel),
          if (t.bankReference != null)
            InfoLine(Icons.account_balance_outlined, 'Referencia del banco: ${t.bankReference}'),
          if (t.bankAccountLabel != null)
            InfoLine(Icons.account_balance_wallet_outlined, 'Cuenta: ${t.bankAccountLabel}'),
          if (t.bankCheckedAt != null) InfoLine(Icons.schedule, 'Revisada ${Fmt.dateTime(t.bankCheckedAt!)}'),
          if (t.isCredited) ...[
            const SizedBox(height: HySpacing.xs),
            Wrap(
              spacing: HySpacing.xs,
              children: [
                if (t.bankStatus != BankStatus.reconciled)
                  FilledButton(
                    key: Key('reconcile-ok-${t.id}'),
                    onPressed: () => _mark(context, ref, BankStatus.reconciled),
                    child: const Text('Está en el banco'),
                  ),
                if (t.bankStatus != BankStatus.notFound)
                  OutlinedButton(
                    key: Key('reconcile-missing-${t.id}'),
                    onPressed: () => _mark(context, ref, BankStatus.notFound),
                    child: const Text('No aparece'),
                  ),
                if (t.bankStatus != BankStatus.unverified)
                  TextButton(
                    onPressed: () => _mark(context, ref, BankStatus.unverified),
                    child: const Text('Volver a sin verificar'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Referencia del extracto (obligatoria) y cuenta donde llegó.
class _ReconcileSheet extends StatefulWidget {
  const _ReconcileSheet({required this.topup, required this.accounts});

  final ReconcileTopup topup;
  final List<ReceivingAccount> accounts;

  @override
  State<_ReconcileSheet> createState() => _ReconcileSheetState();
}

class _ReconcileSheetState extends State<_ReconcileSheet> {
  final _ref = TextEditingController();
  final _form = GlobalKey<FormState>();
  int? _account;

  @override
  void initState() {
    super.initState();
    if (widget.accounts.length == 1) _account = widget.accounts.single.id;
  }

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, HySpacing.md + sheetBottomInset(context)),
    child: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Conciliar ${Fmt.bs(widget.topup.amount)}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: HySpacing.xs),
            const Text(
              'Escribe la referencia exacta del movimiento en tu extracto. Hazlo solo si viste el depósito en el banco.',
              style: TextStyle(color: HyColors.textSecondary),
            ),
            const SizedBox(height: HySpacing.sm),
            TextFormField(
              key: const Key('reconcile-reference'),
              controller: _ref,
              autofocus: true,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Referencia del banco',
                hintText: 'Ej.: número de operación',
              ),
              validator: (v) => (v ?? '').trim().length < 3 ? 'Escribe la referencia del extracto' : null,
            ),
            if (widget.accounts.isEmpty)
              const InfoBanner(text: 'Todavía no registraste cuentas de cobro. Puedes conciliar igual.')
            else
              DropdownButtonFormField<int?>(
                initialValue: _account,
                decoration: const InputDecoration(labelText: 'Cuenta donde llegó'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('No sé / no aplica')),
                  for (final a in widget.accounts)
                    DropdownMenuItem(value: a.id, child: Text('${a.label} ${a.accountMasked ?? ''}'.trim())),
                ],
                onChanged: (v) => setState(() => _account = v),
              ),
            const SizedBox(height: HySpacing.md),
            PrimaryButton(
              key: const Key('reconcile-continue'),
              label: 'Continuar',
              onPressed: () {
                if (_form.currentState!.validate()) Navigator.pop(context, (_ref.text.trim(), _account));
              },
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ],
        ),
      ),
    ),
  );
}

// ============================================================ Cuentas de cobro
class ReceivingAccountsPage extends ConsumerWidget {
  const ReceivingAccountsPage({super.key});

  Future<void> _setStatus(
    BuildContext context,
    WidgetRef ref,
    ReceivingAccount a, {
    bool? active,
    bool? verified,
  }) async {
    final toActive = active ?? a.isActive;
    final toVerified = verified ?? a.verified;
    final (title, message, confirm) = switch ((active, verified)) {
      (_, true) => (
        '¿Marcar como verificada?',
        'Confírmalo solo si tu banco te confirmó que "${a.label}" ${a.accountMasked ?? ''} recibe pagos a nombre de ${a.holderName}.',
        'Marcar verificada',
      ),
      (false, _) => (
        '¿Desactivar "${a.label}"?',
        'Deja de usarse para conciliar. El historial se mantiene.',
        'Desactivar',
      ),
      (true, _) => ('¿Volver a activar "${a.label}"?', 'Se podrá usar otra vez para conciliar.', 'Activar'),
      _ => ('¿Quitar la verificación?', 'La cuenta queda "sin verificar".', 'Quitar verificación'),
    };
    if (!await confirmDialog(context, title: title, message: message, confirm: confirm, destructive: active == false)) {
      return;
    }
    if (!context.mounted) return;
    final method = await _confirm(
      context,
      confirm,
      details: [('Cuenta', '${a.label} ${a.accountMasked ?? ''}'.trim())],
    );
    if (method == null || !context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref
          .read(backendProvider)
          .setReceivingAccount(a.id, active: toActive, verified: toVerified, authMethod: method),
      success: 'Listo. Quedó en el historial.',
    );
    if (ok) _refreshFinance(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const OneLineText('Cuentas de cobro y QR')),
    floatingActionButton: FloatingActionButton.extended(
      key: const Key('receiving-add'),
      backgroundColor: HyColors.primary,
      foregroundColor: Colors.white,
      onPressed: () =>
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReceivingAccountFormPage())),
      icon: const Icon(Icons.add),
      label: const Text('Agregar cuenta'),
    ),
    body: AdminList<ReceivingAccount>(
      value: ref.watch(receivingAccountsProvider),
      hasFab: true,
      onRefresh: () => ref.refresh(receivingAccountsProvider.future),
      emptyIcon: Icons.account_balance_outlined,
      emptyTitle: 'Pendiente de configuración: todavía no registraste cuentas de cobro.',
      header: const Padding(
        padding: EdgeInsets.only(bottom: HySpacing.sm),
        child: InfoBanner(
          text:
              'Solo datos para recibir pagos: banco, titular, número de cuenta y QR. '
              'Nunca escribas aquí contraseñas ni claves de tu banca por internet. Cada cambio pide un código y queda en el historial.',
        ),
      ),
      itemBuilder: (context, a) => AppCard(
        key: Key('receiving-${a.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(a.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
                if (!a.isActive)
                  const ToneChip('Desactivada', StatusTone.neutral)
                else
                  ToneChip(
                    a.verified ? 'Verificada' : 'Sin verificar',
                    a.verified ? StatusTone.success : StatusTone.warning,
                  ),
              ],
            ),
            InfoLine(Icons.account_balance_outlined, '${a.bankName} · ${a.type.label} · ${a.currency}'),
            InfoLine(Icons.person_outline, 'Titular: ${a.holderName}'),
            if (a.accountMasked != null) InfoLine(Icons.numbers, 'Cuenta ${a.accountMasked}'),
            if (a.qrPath != null) const InfoLine(Icons.qr_code_2, 'Tiene QR de cobro'),
            if (a.notes != null) InfoLine(Icons.notes_outlined, a.notes!),
            const SizedBox(height: HySpacing.xs),
            Wrap(
              spacing: HySpacing.xs,
              children: [
                TextButton(
                  key: Key('receiving-edit-${a.id}'),
                  onPressed: () =>
                      Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => ReceivingAccountFormPage(account: a))),
                  child: const Text('Editar'),
                ),
                if (a.isActive && !a.verified)
                  OutlinedButton(
                    key: Key('receiving-verify-${a.id}'),
                    onPressed: () => _setStatus(context, ref, a, verified: true),
                    child: const Text('Marcar verificada'),
                  ),
                if (a.isActive && a.verified)
                  TextButton(
                    onPressed: () => _setStatus(context, ref, a, verified: false),
                    child: const Text('Quitar verificación'),
                  ),
                TextButton(
                  key: Key('receiving-active-${a.id}'),
                  onPressed: () => _setStatus(context, ref, a, active: !a.isActive),
                  child: Text(
                    a.isActive ? 'Desactivar' : 'Activar',
                    style: TextStyle(color: a.isActive ? HyColors.danger : null),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Crear o cambiar una cuenta de cobro. Con cambios sin guardar, atrás
/// pregunta antes de salir.
class ReceivingAccountFormPage extends ConsumerStatefulWidget {
  const ReceivingAccountFormPage({super.key, this.account});

  final ReceivingAccount? account;

  @override
  ConsumerState<ReceivingAccountFormPage> createState() => _ReceivingAccountFormPageState();
}

class _ReceivingAccountFormPageState extends ConsumerState<ReceivingAccountFormPage> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.account?.label);
  late final _bank = TextEditingController(text: widget.account?.bankName);
  late final _holder = TextEditingController(text: widget.account?.holderName);
  late final _number = TextEditingController(text: widget.account?.accountNumber);
  late final _notes = TextEditingController(text: widget.account?.notes);
  late var _type = widget.account?.type ?? ReceivingAccountType.savings;
  late var _currency = widget.account?.currency ?? 'BOB';
  late final String? _qrPath = widget.account?.qrPath;
  PhotoUpload? _qr;
  var _dirty = false;
  var _busy = false;

  @override
  void dispose() {
    for (final c in [_label, _bank, _holder, _number, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed([_]) {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _pickQr() async {
    final p = await pickPhoto(context);
    if (p == null) return;
    setState(() {
      _qr = p;
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    final number = _number.text.trim();
    if (_type == ReceivingAccountType.qr && number.isEmpty && _qr == null && _qrPath == null) {
      return showMessage(context, 'Sube la imagen del QR de cobro o escribe un número de cuenta.');
    }
    final a = widget.account;
    final sensitive =
        a != null &&
        (a.bankName != _bank.text.trim() ||
            a.holderName != _holder.text.trim() ||
            (a.accountNumber ?? '') != number ||
            _qr != null);
    final method = await _confirm(
      context,
      a == null ? 'Agregar cuenta de cobro' : 'Cambiar cuenta de cobro',
      details: [
        ('Cuenta', _label.text.trim()),
        ('Banco', _bank.text.trim()),
        ('Titular', _holder.text.trim()),
        if (number.isNotEmpty) ('Número', maskAccount(number)),
        if (sensitive) ('Atención', 'vuelve a quedar sin verificar'),
      ],
    );
    if (method == null || !mounted) return;
    setState(() => _busy = true);
    final backend = ref.read(backendProvider);
    final ok = await runGuarded(
      context,
      () async {
        var qrPath = _qrPath;
        if (_qr != null) qrPath = await backend.uploadReceivingQr(_qr!);
        await backend.saveReceivingAccount(
          ReceivingAccountDraft(
            id: a?.id,
            label: _label.text.trim(),
            type: _type,
            bankName: _bank.text.trim(),
            holderName: _holder.text.trim(),
            accountNumber: number.isEmpty ? null : number,
            currency: _currency,
            qrPath: qrPath,
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          ),
          authMethod: method,
        );
      },
      success: a == null
          ? 'Cuenta agregada. Queda "sin verificar" hasta que la confirmes con tu banco.'
          : 'Cambios guardados.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    _refreshFinance(ref);
    _dirty = false;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    // En la demostración el QR guardado está en memoria; en Supabase es privado.
    final backend = ref.read(backendProvider);
    final qrPath = _qrPath;
    final Uint8List? existingQr = backend is DemoAppBackend && qrPath != null ? backend.receivingQrBytes(qrPath) : null;
    return UnsavedChangesScope(
      dirty: _dirty,
      child: Scaffold(
        appBar: AppBar(title: OneLineText(a == null ? 'Agregar cuenta de cobro' : 'Editar cuenta')),
        body: ListView(
          padding: bottomSafePadding(context, top: HySpacing.md),
          children: [
            PageBody(
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const InfoBanner(
                      icon: Icons.lock_outline,
                      text: 'Nunca escribas contraseñas, PIN ni claves de tu banca por internet. No se piden.',
                    ),
                    const SizedBox(height: HySpacing.sm),
                    TextFormField(
                      key: const Key('receiving-label'),
                      controller: _label,
                      maxLength: 60,
                      onChanged: _changed,
                      decoration: const InputDecoration(
                        labelText: 'Nombre para reconocerla',
                        hintText: 'Ej.: BNB principal',
                      ),
                      validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe un nombre' : null,
                    ),
                    DropdownButtonFormField<ReceivingAccountType>(
                      initialValue: _type,
                      decoration: const InputDecoration(labelText: 'Tipo'),
                      items: [
                        for (final t in ReceivingAccountType.values) DropdownMenuItem(value: t, child: Text(t.label)),
                      ],
                      onChanged: (v) => setState(() {
                        _type = v ?? _type;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: HySpacing.sm),
                    TextFormField(
                      key: const Key('receiving-bank'),
                      controller: _bank,
                      maxLength: 80,
                      onChanged: _changed,
                      decoration: const InputDecoration(labelText: 'Banco', hintText: 'Ej.: Banco Nacional de Bolivia'),
                      validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe el banco' : null,
                    ),
                    TextFormField(
                      key: const Key('receiving-holder'),
                      controller: _holder,
                      maxLength: 120,
                      onChanged: _changed,
                      decoration: const InputDecoration(labelText: 'Titular de la cuenta'),
                      validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe el titular' : null,
                    ),
                    TextFormField(
                      key: const Key('receiving-number'),
                      controller: _number,
                      maxLength: 30,
                      keyboardType: TextInputType.number,
                      onChanged: _changed,
                      decoration: InputDecoration(
                        labelText: _type == ReceivingAccountType.qr
                            ? 'Número de cuenta (opcional)'
                            : 'Número de cuenta',
                      ),
                      validator: (v) {
                        final n = (v ?? '').trim();
                        if (n.isEmpty) return _type == ReceivingAccountType.qr ? null : 'Escribe el número de cuenta';
                        return RegExp(r'^[0-9][0-9 -]{3,29}$').hasMatch(n) ? null : 'Solo números, espacios o guiones';
                      },
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: _currency,
                      decoration: const InputDecoration(labelText: 'Moneda'),
                      items: const [
                        DropdownMenuItem(value: 'BOB', child: Text('Bolivianos (Bs)')),
                        DropdownMenuItem(value: 'USD', child: Text('Dólares (US\$)')),
                      ],
                      onChanged: (v) => setState(() {
                        _currency = v ?? _currency;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: HySpacing.sm),
                    AppCard(
                      child: Row(
                        children: [
                          if (_qr != null)
                            Image.memory(_qr!.bytes, width: 64, height: 64, fit: BoxFit.cover)
                          else if (existingQr != null)
                            Image.memory(existingQr, width: 64, height: 64, fit: BoxFit.cover)
                          else
                            const Icon(Icons.qr_code_2, size: 48, color: HyColors.textMuted),
                          const SizedBox(width: HySpacing.sm),
                          Expanded(
                            child: Text(
                              _qr != null
                                  ? 'QR nuevo listo para guardar'
                                  : _qrPath != null
                                  ? 'QR de cobro guardado'
                                  : 'Sin QR de cobro',
                            ),
                          ),
                          TextButton(
                            key: const Key('receiving-qr'),
                            onPressed: _busy ? null : _pickQr,
                            child: Text(_qrPath != null || _qr != null ? 'Cambiar' : 'Subir QR'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: HySpacing.sm),
                    TextFormField(
                      controller: _notes,
                      maxLength: 300,
                      maxLines: 2,
                      onChanged: _changed,
                      decoration: const InputDecoration(labelText: 'Nota (opcional)'),
                    ),
                    if (a != null && a.verified)
                      const InfoBanner(
                        tone: StatusTone.warning,
                        icon: Icons.info_outline,
                        text: 'Si cambias banco, titular, número o QR, la cuenta vuelve a "sin verificar".',
                      ),
                    const SizedBox(height: HySpacing.md),
                    PrimaryButton(key: const Key('receiving-save'), label: 'Guardar', loading: _busy, onPressed: _save),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Comisiones que faltó cobrar al completar (0043).
class _DebtsStat extends ConsumerWidget {
  const _DebtsStat();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(commissionDebtsProvider);
    final l = d.value;
    return PanelStat(
      'Comisiones pendientes',
      l?.total,
      key: const Key('fin-card-debts'),
      tone: (l?.total ?? 0) > 0 ? StatusTone.danger : StatusTone.neutral,
      detail: switch (d) {
        AsyncData(value: null) => 'Se activa con el nuevo cobro de comisiones',
        AsyncData(value: final l?) => '${Fmt.bs(l.sumBs)} · se cobran de la próxima recarga',
        AsyncError() => 'No se pudo cargar',
        _ => null,
      },
      onTap: l == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CommissionDebtsPage())),
    );
  }
}

class CommissionDebtsPage extends ConsumerWidget {
  const CommissionDebtsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(commissionDebtsProvider);
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Comisiones pendientes')),
      body: AdminList<CommissionDebt>(
        value: value.whenData((l) => l?.items ?? const []),
        onRefresh: () => ref.refresh(commissionDebtsProvider.future),
        emptyIcon: Icons.check_circle_outline,
        emptyTitle: 'No hay comisiones pendientes.',
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (value.value case final l?) _FinanceCountLine(l, noun: ('pendiente', 'pendientes')),
            const Padding(
              padding: EdgeInsets.only(bottom: HySpacing.sm),
              child: InfoBanner(
                text:
                    'Faltó saldo al completar estos trabajos. El profesional no acepta trabajos nuevos hasta pagar, '
                    'y se descuenta solo de su próxima recarga; cada cobro queda en Movimientos.',
              ),
            ),
          ],
        ),
        itemBuilder: (context, d) => AppCard(
          key: Key('debt-${d.bookingId}'),
          padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
          onTap: () => context.push(Routes.opsBooking(d.bookingId)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.professionalName ?? 'Profesional', style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(
                      [
                        'Pedido ${d.bookingCode}',
                        if (d.completedAt != null) Fmt.dateTime(d.completedAt!),
                        if (d.captured != null) 'cobrado ${Fmt.bs(d.captured!)}',
                      ].join(' · '),
                      style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
              ),
              Text(
                Fmt.bs(d.amount),
                style: const TextStyle(fontWeight: FontWeight.w800, color: HyColors.danger),
              ),
              const Icon(Icons.chevron_right, color: HyColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================ Movimientos
class FinanceMovementsPage extends ConsumerStatefulWidget {
  const FinanceMovementsPage({super.key, this.initialKind, this.month, this.professionalId, this.professionalName});

  /// Tipo con el que abre (por ejemplo 'commission_capture' desde el panel).
  final String? initialKind;

  /// Mes 'AAAA-MM' con el que abre; null = todos los meses.
  final String? month;

  /// Solo los movimientos de esta billetera.
  final String? professionalId;
  final String? professionalName;

  @override
  ConsumerState<FinanceMovementsPage> createState() => _FinanceMovementsPageState();
}

class _FinanceMovementsPageState extends ConsumerState<FinanceMovementsPage> {
  late String? _kind = _kinds.any((k) => k.$1 == widget.initialKind) ? widget.initialKind : null;
  late String? _month = widget.month;
  var _query = '';

  static const _kinds = [
    (null, 'Todos'),
    ('commission_capture', 'Comisiones'),
    ('topup', 'Recargas'),
    ('adjustment', 'Ajustes'),
    ('refund', 'Devoluciones'),
  ];

  @override
  Widget build(BuildContext context) {
    final key = (_kind, _month, _query, widget.professionalId);
    final value = ref.watch(financeLedgerProvider(key));
    return Scaffold(
      appBar: AppBar(
        title: OneLineText(
          widget.professionalName == null ? 'Movimientos' : 'Movimientos de ${widget.professionalName}',
        ),
      ),
      body: AdminList<FinanceTransaction>(
        value: value.whenData((l) => l.items),
        onRefresh: () => ref.refresh(financeLedgerProvider(key).future),
        emptyIcon: Icons.receipt_long_outlined,
        emptyTitle: _month == null ? 'Sin movimientos de este tipo.' : 'Sin movimientos de este tipo en este mes.',
        header: Padding(
          padding: const EdgeInsets.only(bottom: HySpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_kind == 'commission_capture')
                const Padding(
                  padding: EdgeInsets.only(bottom: HySpacing.xs),
                  child: InfoBanner(
                    icon: Icons.info_outline,
                    text:
                        'Las comisiones son el único ingreso de la plataforma. El cliente le paga al profesional '
                        'en efectivo o QR; la comisión sale de la billetera del profesional.',
                  ),
                ),
              drilldownChipRow(_kinds, _kind, (k) => setState(() => _kind = k), 'movements-kind'),
              const SizedBox(height: HySpacing.xs),
              _MonthFilter(month: _month, onChanged: (m) => setState(() => _month = m)),
              DrilldownSearchField(
                hint: 'Profesional, pedido o referencia',
                fieldKey: const Key('movements-search'),
                onChanged: (q) => setState(() => _query = q),
              ),
              const SizedBox(height: HySpacing.xs),
              if (value.value case final l?) _FinanceCountLine(l, noun: ('movimiento', 'movimientos')),
            ],
          ),
        ),
        itemBuilder: (context, t) => _MovementCard(t),
      ),
    );
  }
}

class _MovementCard extends StatelessWidget {
  const _MovementCard(this.t);

  final FinanceTransaction t;

  @override
  Widget build(BuildContext context) {
    final delta = t.availableDelta + t.reservedDelta;
    final small = const TextStyle(color: HyColors.textSecondary, fontSize: 13);
    return AppCard(
      key: Key('movement-${t.id}'),
      padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
      onTap: t.bookingId == null ? null : () => context.push(Routes.opsBooking(t.bookingId!)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(t.label, style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              Text(
                t.entryType == 'commission_capture' ? '+${Fmt.bs(t.platformRevenue)}' : Fmt.bs(delta),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: t.entryType == 'commission_capture' ? HyColors.success : HyColors.text,
                ),
              ),
              if (t.bookingId != null) const Icon(Icons.chevron_right, color: HyColors.textMuted),
            ],
          ),
          Text(
            [
              t.professionalName ?? 'Profesional',
              Fmt.dateTime(t.createdAt),
              if (t.bookingCode != null) 'Pedido ${t.bookingCode}',
              if (t.categoryName != null) t.categoryName!,
            ].join(' · '),
            style: small,
          ),
          if (t.entryType == 'commission_capture')
            Text('Ingreso de la plataforma', style: small)
          else if (t.entryType == 'topup')
            Text(
              'Saldo del profesional · Banco: ${t.topupBankStatus?.label ?? BankStatus.unverified.label}',
              style: small,
            ),
          if ((t.reference ?? '').isNotEmpty)
            Text('Referencia: ${t.reference}', style: const TextStyle(color: HyColors.textMuted, fontSize: 13)),
          if ((t.note ?? '').isNotEmpty) Text(t.note!, style: const TextStyle(color: HyColors.textMuted, fontSize: 13)),
        ],
      ),
    );
  }
}

// ============================================================ Historial
class FinanceAuditPage extends ConsumerWidget {
  const FinanceAuditPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const OneLineText('Historial de cambios')),
    body: AdminList<FinanceAuditEntry>(
      value: ref.watch(financeAuditProvider),
      onRefresh: () => ref.refresh(financeAuditProvider.future),
      emptyIcon: Icons.history,
      emptyTitle: 'Todavía no hay cambios de dinero registrados.',
      itemBuilder: (context, e) {
        final d = e.details;
        final extra = [
          if (d['amount'] != null) Fmt.bs(num.tryParse('${d['amount']}') ?? 0),
          if (d['bank_reference'] != null) 'Ref. ${d['bank_reference']}',
          if (d['account'] is String) '${d['account']}',
          if (d['account_to'] != null) 'Cuenta ${d['account_to']}',
          if (d['label'] != null) '${d['label']}',
          if (d['auth_method'] != null) 'confirmado con código',
        ];
        return AppCard(
          padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.label, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(
                '${e.actorName} · ${Fmt.dateTime(e.createdAt)}${e.targetId == null ? '' : ' · #${e.targetId}'}',
                style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
              ),
              if (extra.isNotEmpty)
                Text(extra.join(' · '), style: const TextStyle(color: HyColors.textMuted, fontSize: 13)),
            ],
          ),
        );
      },
    ),
  );
}

/// Últimos meses: en tabla si entra; con letra grande o pantalla chica, cada
/// mes en su propio bloque (sin columnas apretadas ni palabras partidas).
class _MonthsTable extends StatelessWidget {
  const _MonthsTable({required this.months});

  final List<FinanceMonth> months;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(1) * (MediaQuery.boldTextOf(context) ? 1.1 : 1);
      if (box.maxWidth / scale >= 300) {
        return Column(
          children: [
            const Row(
              children: [
                Expanded(
                  child: Text('Mes', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                Expanded(
                  child: Text(
                    'Comisiones',
                    textAlign: TextAlign.end,
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Expanded(
                  child: Text(
                    'Recargas',
                    textAlign: TextAlign.end,
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const Divider(),
            for (final m in months)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(_monthLabel(m.month))),
                    Expanded(child: Text(Fmt.bs(m.commissionBs), textAlign: TextAlign.end)),
                    Expanded(
                      child: Text(
                        Fmt.bs(m.walletFundsBs),
                        textAlign: TextAlign.end,
                        style: const TextStyle(color: HyColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in months) ...[
            if (m != months.first) const Divider(),
            Text(_monthLabel(m.month), style: const TextStyle(fontWeight: FontWeight.w800)),
            Text('Comisiones: ${Fmt.bs(m.commissionBs)}'),
            Text('Recargas: ${Fmt.bs(m.walletFundsBs)}', style: const TextStyle(color: HyColors.textSecondary)),
          ],
        ],
      );
    },
  );
}
