import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/country.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/word_safe_text.dart';
import '../../data/models/booking.dart' show StatusTone, StatusToneColors;
import '../../data/models/wallet.dart';
import '../../data/providers.dart';
import 'wallet_page.dart';

// Recargar mi billetera (0065): monto → "Generar QR bancario" → pago → saldo
// acreditado. El saldo se acredita solo con el aviso del banco verificado en
// el servidor; esta pantalla solo muestra el estado. Sin proveedor de QR queda
// la transferencia bancaria, que el equipo verifica.

final qrRechargesProvider = FutureProvider.autoDispose<List<QrRecharge>>((ref) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).qrRecharges();
});

final qrRechargeProvider = FutureProvider.autoDispose.family<QrRecharge?, String>((ref, id) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).qrRecharge(id);
});

final rechargeBankAccountsProvider = FutureProvider.autoDispose<List<RechargeBankAccount>>(
  (ref) => ref.watch(backendProvider).rechargeBankAccounts(),
);

const _presets = [20.0, 50.0, 100.0];

extension QrRechargeStatusTone on QrRechargeStatus {
  StatusTone get tone => switch (this) {
    QrRechargeStatus.pendingPayment => StatusTone.brand,
    QrRechargeStatus.verifying => StatusTone.warning,
    QrRechargeStatus.credited => StatusTone.success,
    QrRechargeStatus.rejected || QrRechargeStatus.reversed => StatusTone.danger,
    QrRechargeStatus.expired => StatusTone.neutral,
  };
}

class QrStatusChip extends StatelessWidget {
  const QrStatusChip(this.status, {super.key});

  final QrRechargeStatus status;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: 6),
    decoration: BoxDecoration(color: status.tone.background, borderRadius: BorderRadius.circular(HyRadii.pill)),
    child: Text(
      status.label,
      style: TextStyle(color: status.tone.foreground, fontWeight: FontWeight.w700, fontSize: 14),
    ),
  );
}

class RechargePage extends ConsumerStatefulWidget {
  const RechargePage({super.key});

  @override
  ConsumerState<RechargePage> createState() => _RechargePageState();
}

class _RechargePageState extends ConsumerState<RechargePage> {
  double? _preset = 50;
  final _other = TextEditingController();
  var _creating = false;

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  double? get _amount => _preset ?? double.tryParse(_other.text.replaceAll(',', '.'));

  String? get _amountError {
    final a = _amount;
    if (_preset != null) return null;
    if (_other.text.isEmpty) return null;
    if (a == null) return 'Escribe el monto';
    if (a < 10) return 'El mínimo es ${Fmt.bsShort(10)}';
    if (a > 5000) return 'El máximo es ${Fmt.bsShort(5000)}';
    return null;
  }

  Future<void> _generate() async {
    final a = _amount;
    if (a == null || _amountError != null || _creating) return;
    setState(() => _creating = true);
    try {
      final r = await ref.read(backendProvider).createQrRecharge(a);
      ref.invalidate(qrRechargesProvider);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QrRechargePage(rechargeId: r.id)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(qrRechargesProvider);
    final topups = ref.watch(topupsProvider).value ?? const <TopupRequest>[];
    final valid = _amount != null && _amountError == null;
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Recargar mi billetera')),
      body: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.md),
                Text('¿Cuánto quieres recargar?', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: HySpacing.sm),
                Wrap(
                  spacing: HySpacing.sm,
                  runSpacing: HySpacing.sm,
                  children: [
                    for (final p in _presets)
                      ChoiceChip(
                        key: Key('recharge-preset-${p.toInt()}'),
                        label: Text(Fmt.bsShort(p), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                        selected: _preset == p,
                        onSelected: (_) => setState(() => _preset = p),
                      ),
                    ChoiceChip(
                      key: const Key('recharge-preset-other'),
                      label: const Text('Otro monto', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      selected: _preset == null,
                      onSelected: (_) => setState(() => _preset = null),
                    ),
                  ],
                ),
                if (_preset == null) ...[
                  const SizedBox(height: HySpacing.md),
                  TextField(
                    key: const Key('recharge-other-amount'),
                    controller: _other,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                      LengthLimitingTextInputFormatter(7),
                    ],
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Monto',
                      prefixText: kCountry.moneyPrefix,
                      helperText: 'Entre ${Fmt.bsShort(10)} y ${Fmt.bsShort(5000)}',
                      errorText: _amountError,
                    ),
                  ),
                ],
                const SizedBox(height: HySpacing.lg),
                PrimaryButton(
                  key: const Key('recharge-generate-qr'),
                  label: 'Generar QR bancario',
                  icon: Icons.qr_code_2_rounded,
                  loading: _creating,
                  onPressed: valid ? _generate : null,
                ),
                const SizedBox(height: HySpacing.sm),
                SecondaryButton(
                  key: const Key('recharge-transfer'),
                  label: 'Transferencia bancaria',
                  icon: Icons.account_balance_outlined,
                  onPressed: () => showTransferTopupSheet(context, ref),
                ),
                const SizedBox(height: HySpacing.sm),
                const InfoBanner(
                  text:
                      'El saldo se acredita cuando el banco confirma el pago. Una captura de pantalla o un mensaje '
                      'no acreditan saldo. Con transferencia, el equipo verifica el pago antes de acreditarlo.',
                ),
                if (topups.isNotEmpty) ...[
                  const SectionHeader(title: 'Transferencias bancarias'),
                  for (final t in topups) TopupTile(topup: t),
                ],
                const SectionHeader(title: 'Historial de recargas con QR'),
                switch (history) {
                  AsyncData(:final value) when value.isEmpty => const Text(
                    'Todavía no generaste ningún QR.',
                    style: TextStyle(color: HyColors.textMuted),
                  ),
                  AsyncData(:final value) => AppCard(
                    padding: const EdgeInsets.symmetric(horizontal: HySpacing.md),
                    child: Column(
                      children: [
                        for (var i = 0; i < value.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _QrHistoryTile(recharge: value[i]),
                        ],
                      ],
                    ),
                  ),
                  AsyncError(:final error) => ErrorView(
                    error: error,
                    onRetry: () => ref.invalidate(qrRechargesProvider),
                  ),
                  _ => const LoadingView(),
                },
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QrHistoryTile extends StatelessWidget {
  const _QrHistoryTile({required this.recharge});

  final QrRecharge recharge;

  @override
  Widget build(BuildContext context) => InkWell(
    key: Key('qr-history-${recharge.id}'),
    onTap: () =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QrRechargePage(rechargeId: recharge.id))),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: HySpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Fmt.bs(recharge.creditedAmount ?? recharge.amount),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                Text(
                  '${recharge.reference} · ${Fmt.dateTime(recharge.createdAt)}'
                  '${recharge.simulated ? ' · simulado' : ''}',
                  style: const TextStyle(color: HyColors.textSecondary, fontSize: 14),
                ),
              ],
            ),
          ),
          const SizedBox(width: HySpacing.xs),
          Flexible(child: QrStatusChip(recharge.status)),
        ],
      ),
    ),
  );
}

/// Un QR: lo que hay que pagar, hasta cuándo, y su estado al día.
class QrRechargePage extends ConsumerStatefulWidget {
  const QrRechargePage({super.key, required this.rechargeId});

  final String rechargeId;

  @override
  ConsumerState<QrRechargePage> createState() => _QrRechargePageState();
}

class _QrRechargePageState extends ConsumerState<QrRechargePage> {
  Timer? _poll;
  var _simulating = false;

  @override
  void initState() {
    super.initState();
    // Por si el aviso en tiempo real no llega: se revisa cada 5 segundos
    // mientras espera el pago o la verificación.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      final r = ref.read(qrRechargeProvider(widget.rechargeId)).value;
      if (r == null || !r.status.isFinal) ref.invalidate(qrRechargeProvider(widget.rechargeId));
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _simulate() async {
    setState(() => _simulating = true);
    try {
      await ref.read(backendProvider).simulateQrPayment(widget.rechargeId);
      ref
        ..invalidate(qrRechargeProvider(widget.rechargeId))
        ..invalidate(qrRechargesProvider)
        ..invalidate(walletProvider)
        ..invalidate(ledgerProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _simulating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(qrRechargeProvider(widget.rechargeId));
    ref.listen(qrRechargeProvider(widget.rechargeId), (prev, next) {
      if (prev?.value?.status != QrRechargeStatus.credited && next.value?.status == QrRechargeStatus.credited) {
        ref
          ..invalidate(walletProvider)
          ..invalidate(ledgerProvider);
      }
    });
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Pago con QR')),
      body: switch (value) {
        AsyncData(value: null) => const EmptyState(
          icon: Icons.qr_code_2_rounded,
          title: 'No encontramos este QR',
          message: 'Vuelve a tu billetera y genera uno nuevo.',
        ),
        AsyncData(value: final r?) => _QrView(recharge: r, simulating: _simulating, onSimulate: _simulate),
        AsyncError(:final error) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(qrRechargeProvider(widget.rechargeId)),
        ),
        _ => const LoadingView(),
      },
    );
  }
}

class _QrView extends StatelessWidget {
  const _QrView({required this.recharge, required this.simulating, required this.onSimulate});

  final QrRecharge recharge;
  final bool simulating;
  final VoidCallback onSimulate;

  @override
  Widget build(BuildContext context) {
    final r = recharge;
    final pending = r.status == QrRechargeStatus.pendingPayment;
    return ListView(
      padding: bottomSafePadding(context),
      children: [
        PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: HySpacing.md),
              Wrap(
                spacing: HySpacing.sm,
                runSpacing: HySpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    Fmt.bs(r.creditedAmount ?? r.amount),
                    key: const Key('qr-amount'),
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: HyColors.navy),
                  ),
                  QrStatusChip(r.status, key: const Key('qr-status')),
                ],
              ),
              Text(
                'Referencia ${r.reference}',
                key: const Key('qr-reference'),
                style: const TextStyle(color: HyColors.textSecondary, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: HySpacing.md),
              if (pending) ...[
                Center(child: r.simulated ? const _SimulatedQr() : const _QrUnavailable()),
                const SizedBox(height: HySpacing.sm),
                Text(
                  'Vence a las ${Fmt.time(r.expiresAt)}. Paga el monto exacto de ${Fmt.bs(r.amount)}.',
                  key: const Key('qr-expiry'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
                if (r.simulated) ...[
                  const SizedBox(height: HySpacing.md),
                  SecondaryButton(
                    key: const Key('qr-simulate'),
                    label: simulating ? 'Simulando…' : 'Simular el pago (solo desarrollo)',
                    onPressed: simulating ? null : onSimulate,
                  ),
                ],
              ],
              ...switch (r.status) {
                QrRechargeStatus.pendingPayment => [
                  const SizedBox(height: HySpacing.sm),
                  const InfoBanner(
                    text: 'Cuando el banco confirme el pago, el saldo aparece solo en tu billetera y te avisamos.',
                  ),
                ],
                QrRechargeStatus.verifying => [
                  InfoBanner(
                    key: const Key('qr-verifying'),
                    tone: StatusTone.warning,
                    icon: Icons.hourglass_top_rounded,
                    text:
                        '${r.reviewReasonLabel ?? 'Recibimos un pago'}. El equipo lo revisa antes de acreditarlo. '
                        'Te avisamos cuando esté listo.',
                  ),
                ],
                QrRechargeStatus.credited => [
                  InfoBanner(
                    key: const Key('qr-credited'),
                    tone: StatusTone.success,
                    icon: Icons.check_circle_outline,
                    text:
                        'Saldo acreditado: ${Fmt.bs(r.creditedAmount ?? r.amount)}.'
                        '${r.simulated ? ' Es saldo simulado de desarrollo, no dinero real.' : ''}',
                  ),
                ],
                QrRechargeStatus.expired => [
                  const InfoBanner(
                    key: Key('qr-expired'),
                    tone: StatusTone.warning,
                    icon: Icons.timer_off_outlined,
                    text: 'Este QR venció. Si no pagaste, genera uno nuevo. Si ya pagaste, escribe a soporte.',
                  ),
                ],
                QrRechargeStatus.rejected => [
                  const InfoBanner(
                    tone: StatusTone.danger,
                    icon: Icons.cancel_outlined,
                    text: 'Esta recarga no se acreditó. Si pagaste, escribe a soporte.',
                  ),
                ],
                QrRechargeStatus.reversed => [
                  const InfoBanner(
                    tone: StatusTone.danger,
                    icon: Icons.undo_rounded,
                    text: 'Esta recarga se revirtió. Revisa el historial de tu billetera.',
                  ),
                ],
              },
              if (r.status.isFinal) ...[
                const SizedBox(height: HySpacing.md),
                PrimaryButton(label: 'Volver a mi billetera', onPressed: () => Navigator.of(context).maybePop()),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// QR de desarrollo: no es un código que un banco pueda leer.
class _SimulatedQr extends StatelessWidget {
  const _SimulatedQr();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('qr-simulated'),
    width: 240,
    padding: const EdgeInsets.all(HySpacing.md),
    decoration: BoxDecoration(
      color: HyColors.surfaceMuted,
      borderRadius: BorderRadius.circular(HyRadii.lg),
      border: Border.all(color: HyColors.warning, width: 2),
    ),
    child: const Column(
      children: [
        Icon(Icons.qr_code_2_rounded, size: 120, color: HyColors.textMuted),
        Text(
          'QR SIMULADO',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: HyColors.warning),
        ),
        SizedBox(height: 4),
        Text(
          'Solo para pruebas de desarrollo. No se puede pagar en ningún banco.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14),
        ),
      ],
    ),
  );
}

class _QrUnavailable extends StatelessWidget {
  const _QrUnavailable();

  @override
  Widget build(BuildContext context) =>
      const InfoBanner(tone: StatusTone.warning, text: 'No se pudo mostrar el QR. Usa Transferencia bancaria.');
}
