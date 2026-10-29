import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/country.dart';
import '../../core/services/device_auth.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/wallet.dart';
import '../../data/providers.dart';
import '../common/photo_picker.dart';
import '../security/confirm_identity.dart';
import '../../core/widgets/trailing_row.dart';
import '../../core/widgets/word_safe_text.dart';

/// Billetera prepagada del profesional: saldo, recargas y movimientos.
class WalletPage extends ConsumerWidget {
  const WalletPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallet = ref.watch(walletProvider);
    final ledger = ref.watch(ledgerProvider);
    final topups = ref.watch(topupsProvider).value ?? const <TopupRequest>[];
    final pending = topups.where((t) => t.status == TopupStatus.pending).toList();

    return Scaffold(
      appBar: AppBar(title: const OneLineText('Mi billetera')),
      body: RefreshIndicator(
        color: HyColors.primary,
        onRefresh: () async {
          ref
            ..invalidate(walletProvider)
            ..invalidate(ledgerProvider)
            ..invalidate(topupsProvider);
        },
        child: ListView(
          padding: bottomSafePadding(context),
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: HySpacing.sm),
                  wallet.when(
                    loading: () => const LoadingView(),
                    error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(walletProvider)),
                    data: (w) => _BalanceCard(wallet: w),
                  ),
                  const SizedBox(height: HySpacing.md),
                  PrimaryButton(
                    label: 'Recargar saldo',
                    icon: Icons.add_card,
                    onPressed: () => _showTopupSheet(context, ref),
                  ),
                  const SizedBox(height: HySpacing.sm),
                  const InfoBanner(
                    text:
                        'Antes de aceptar ves la comisión. Al aceptar reservamos la comisión completa de tu saldo; '
                        'se cobra cuando el trabajo se completa y se devuelve si se cancela. Si falta saldo al '
                        'completar, queda pendiente y se descuenta de tu próxima recarga.',
                  ),
                  if (pending.isNotEmpty) ...[
                    const SectionHeader(title: 'Recargas en revisión'),
                    for (final t in pending) _TopupTile(topup: t),
                  ],
                  const SectionHeader(title: 'Historial de movimientos'),
                  ledger.when(
                    loading: () => const LoadingView(),
                    error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(ledgerProvider)),
                    data: (list) => list.isEmpty
                        ? const Text('Todavía no hay movimientos.', style: TextStyle(color: HyColors.textMuted))
                        : AppCard(
                            padding: const EdgeInsets.symmetric(horizontal: HySpacing.md),
                            child: Column(
                              children: [
                                for (var i = 0; i < list.length; i++) ...[
                                  if (i > 0) const Divider(height: 1),
                                  _LedgerTile(entry: list[i]),
                                ],
                              ],
                            ),
                          ),
                  ),
                  if (topups.any((t) => t.status != TopupStatus.pending)) ...[
                    const SectionHeader(title: 'Historial de recargas'),
                    for (final t in topups.where((t) => t.status != TopupStatus.pending)) _TopupTile(topup: t),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.wallet});

  final Wallet wallet;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(HySpacing.lg),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(HyRadii.xl),
      gradient: const LinearGradient(
        colors: [HyColors.navy, HyColors.navySoft],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Saldo disponible (${kCountry.currencySymbol})',
          style: const TextStyle(color: Colors.white70, fontSize: 16),
        ),
        const SizedBox(height: 4),
        Text(
          Fmt.bs(wallet.available),
          style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: HySpacing.sm),
        Row(
          children: [
            const Icon(Icons.lock_clock_outlined, color: HyColors.primary, size: 20),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Reservado en trabajos: ${Fmt.bs(wallet.reserved)}',
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _LedgerTile extends StatelessWidget {
  const _LedgerTile({required this.entry});

  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final delta = entry.availableDelta;
    final positive = delta > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HySpacing.sm),
      // Con letra grande el monto baja debajo del detalle en vez de apretarlo.
      child: TrailingRow(
        leading: Icon(
          positive ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
          color: positive ? HyColors.green : HyColors.textSecondary,
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.type.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            if ((entry.note ?? '').isNotEmpty) Text(entry.note!, style: const TextStyle(color: HyColors.textSecondary)),
            Text(Fmt.dateTime(entry.createdAt), style: const TextStyle(color: HyColors.textMuted, fontSize: 13)),
          ],
        ),
        trailing: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              delta == 0 ? '—' : '${positive ? '+' : '−'}${Fmt.bs(delta.abs())}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: positive ? HyColors.greenDark : HyColors.text,
              ),
            ),
            Text(
              'Saldo ${Fmt.bs(entry.availableAfter)}',
              style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopupTile extends StatelessWidget {
  const _TopupTile({required this.topup});

  final TopupRequest topup;

  @override
  Widget build(BuildContext context) {
    final tone = switch (topup.status) {
      TopupStatus.pending => StatusTone.warning,
      TopupStatus.approved => StatusTone.success,
      TopupStatus.rejected => StatusTone.danger,
      TopupStatus.cancelled => StatusTone.neutral,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.xs),
      child: AppCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(Fmt.bs(topup.amount), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  Text(Fmt.dateTime(topup.createdAt), style: const TextStyle(color: HyColors.textMuted)),
                  if ((topup.reviewNote ?? '').isNotEmpty) Text(topup.reviewNote!),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: tone.background, borderRadius: BorderRadius.circular(HyRadii.pill)),
              child: Text(
                topup.status.label,
                style: TextStyle(color: tone.foreground, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showTopupSheet(BuildContext context, WidgetRef ref) async {
  final receipt = await showModalBottomSheet<TopupReceipt>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _TopupSheet(),
  );
  if (receipt == null || !context.mounted) return;
  await Navigator.of(context)
      .push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => TopupReceiptPage(receipt: receipt)));
}

/// Lo que se muestra después de enviar una recarga.
class TopupReceipt {
  const TopupReceipt({
    required this.id,
    required this.amount,
    required this.methodName,
    this.reference,
    required this.confirmedWith,
    required this.createdAt,
  });

  final int id;
  final double amount;
  final String methodName;
  final String? reference;
  final String confirmedWith;
  final DateTime createdAt;
}

class _TopupSheet extends ConsumerStatefulWidget {
  const _TopupSheet();

  @override
  ConsumerState<_TopupSheet> createState() => _TopupSheetState();
}

class _TopupSheetState extends ConsumerState<_TopupSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  int? _methodId;
  PhotoUpload? _proof;
  bool _sending = false;
  bool _confirming = false;

  // Mismo intento = misma clave: si la respuesta se pierde y se reintenta, el
  // servidor devuelve la misma solicitud en vez de crear otra.
  String? _clientKey;
  String? _clientKeyFor;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _confirming) return; // un toque a la vez
    if (!_formKey.currentState!.validate()) return;
    final methods = ref.read(topupMethodsProvider).value ?? const <TopupMethod>[];
    final method = methods.where((m) => m.id == _methodId).firstOrNull;
    if (method == null) return;
    final amount = double.parse(_amount.text.replaceAll(',', '.'));
    final reference = _reference.text.trim().isEmpty ? null : _reference.text.trim();
    _confirming = true;
    final IdentityConfirmation? confirmation;
    try {
      confirmation = await confirmIdentity(
        context,
        operation: 'Recarga de saldo',
        amount: amount,
        details: [('Método de pago', method.name), if (reference != null) ('Comprobante', reference)],
      );
    } finally {
      _confirming = false;
    }
    if (confirmation == null || !mounted) return; // cancelada o fallida: no se envía nada
    setState(() => _sending = true);
    try {
      final attempt = '$amount|${method.id}|$reference|${identityHashCode(_proof)}';
      if (_clientKeyFor != attempt) {
        _clientKey = newOperationKey();
        _clientKeyFor = attempt;
      }
      final id = await ref
          .read(backendProvider)
          .requestTopup(
            amount: amount,
            methodId: method.id,
            reference: reference,
            proof: _proof,
            authMethod: confirmation.serverMethod,
            clientKey: _clientKey!,
          );
      _clientKey = null;
      _clientKeyFor = null;
      ref
        ..invalidate(topupsProvider)
        ..invalidate(walletProvider)
        ..invalidate(ledgerProvider);
      if (!mounted) return;
      Navigator.pop(
        context,
        TopupReceipt(
          id: id,
          amount: amount,
          methodName: method.name,
          reference: reference,
          confirmedWith: confirmation.label,
          createdAt: DateTime.now(),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final methods = ref.watch(topupMethodsProvider).value ?? const <TopupMethod>[];
    final selected = methods.where((m) => m.id == _methodId).firstOrNull;
    return Padding(
      padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Recargar saldo', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: HySpacing.xs),
              const Text(
                'Haz la transferencia o el pago por QR y luego registra aquí el monto. El equipo lo verifica y acredita tu saldo.',
                style: TextStyle(color: HyColors.textSecondary, fontSize: 15),
              ),
              const SizedBox(height: HySpacing.md),
              RadioGroup<int>(
                groupValue: _methodId,
                onChanged: (v) => setState(() => _methodId = v),
                child: Column(
                  children: [
                    for (final m in methods)
                      RadioListTile<int>(
                        contentPadding: EdgeInsets.zero,
                        value: m.id,
                        title: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                  ],
                ),
              ),
              if (selected != null) ...[
                InfoBanner(icon: Icons.receipt_long_outlined, text: selected.instructions),
                const SizedBox(height: HySpacing.md),
              ],
              TextFormField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: InputDecoration(labelText: 'Monto', prefixText: kCountry.moneyPrefix),
                validator: (v) {
                  final n = double.tryParse((v ?? '').replaceAll(',', '.'));
                  if (n == null || n <= 0) return 'Escribe el monto';
                  if (n < 10) return 'El monto mínimo es ${Fmt.bsShort(10)}';
                  return null;
                },
              ),
              const SizedBox(height: HySpacing.md),
              TextFormField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Número de comprobante (opcional)',
                  prefixIcon: Icon(Icons.tag),
                ),
              ),
              const SizedBox(height: HySpacing.md),
              _ProofPicker(proof: _proof, onChanged: (p) => setState(() => _proof = p)),
              const SizedBox(height: HySpacing.lg),
              PrimaryButton(
                key: const Key('topup-continue'),
                label: 'Continuar',
                icon: Icons.lock_outline,
                loading: _sending,
                onPressed: _methodId == null ? null : _send,
              ),
              const SizedBox(height: HySpacing.xs),
              const Text(
                'Antes de enviar te pediremos confirmar que eres tú.',
                textAlign: TextAlign.center,
                style: TextStyle(color: HyColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Foto del comprobante de pago. Ayuda a verificar la recarga más rápido.
class _ProofPicker extends StatelessWidget {
  const _ProofPicker({required this.proof, required this.onChanged});

  final PhotoUpload? proof;
  final ValueChanged<PhotoUpload?> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = proof;
    if (p == null) {
      return OutlinedButton.icon(
        onPressed: () async {
          final picked = await pickPhoto(context);
          if (picked != null) onChanged(picked);
        },
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('Adjuntar foto del comprobante'),
      );
    }
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(HyRadii.md),
          child: Image.memory(p.bytes, width: 64, height: 64, fit: BoxFit.cover),
        ),
        const SizedBox(width: HySpacing.sm),
        const Expanded(
          child: Text('Comprobante adjunto', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        TextButton(onPressed: () => onChanged(null), child: const Text('Quitar')),
      ],
    );
  }
}

/// Comprobante de la solicitud de recarga enviada.
class TopupReceiptPage extends StatelessWidget {
  const TopupReceiptPage({super.key, required this.receipt});

  final TopupReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    final rows = [
      ('Monto', Fmt.bs(r.amount)),
      ('Método de pago', r.methodName),
      if (r.reference != null) ('Comprobante', r.reference!),
      ('Solicitud', 'N.º ${r.id}'),
      ('Fecha', Fmt.dateTime(r.createdAt)),
      ('Confirmado con', r.confirmedWith),
      ('Estado', 'Pendiente de verificación'),
    ];
    return Scaffold(
      key: const Key('topup-receipt'),
      appBar: AppBar(title: const OneLineText('Solicitud enviada'), automaticallyImplyLeading: false),
      body: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.md),
                const Icon(Icons.check_circle_rounded, color: HyColors.green, size: 72),
                const SizedBox(height: HySpacing.sm),
                Text(
                  'Recibimos tu solicitud de recarga',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: HySpacing.md),
                AppCard(
                  child: Column(
                    children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        if (i > 0) const Divider(height: HySpacing.md),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                rows[i].$1,
                                style: const TextStyle(color: HyColors.textSecondary, fontSize: 16),
                              ),
                            ),
                            Flexible(
                              child: Text(
                                rows[i].$2,
                                textAlign: TextAlign.right,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: HySpacing.md),
                const InfoBanner(
                  icon: Icons.hourglass_top_rounded,
                  text: 'Tu saldo sube cuando el equipo verifique el pago. Te avisaremos en Notificaciones, dentro de la app.',
                ),
                const SizedBox(height: HySpacing.lg),
                PrimaryButton(label: 'Listo', onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
