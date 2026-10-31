import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/country.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import '../../router.dart';

/// El precio de una solicitud (0062): lo acordado y bloqueado, o la
/// negociación en curso con las propuestas de cada lado.
class PricePanel extends ConsumerWidget {
  const PricePanel({super.key, required this.b});

  final BookingDetail b;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Después de cada acción (también si falló) se vuelve a leer el pedido:
    // el otro pudo cambiar su propuesta o aceptar otra.
    Future<void> run(Future<void> Function() action, {String? success}) async {
      await runGuarded(context, action, success: success);
      ref.invalidate(bookingDetailProvider(b.id));
      ref.invalidate(myBookingsProvider(!b.viewerIsCustomer));
    }

    final p = b.price;
    if (p.agreed) return _Agreed(b: b, run: run);
    if (!b.status.isOpen) return const SizedBox.shrink();
    final api = ref.read(backendProvider);
    final me = ref.watch(authUserProvider).value?.id;
    final children = <Widget>[];

    if (b.viewerIsCustomer) {
      final mine = p.openIn(b.professional?.id, byCustomer: true);
      children.add(
        _Line(
          key: const Key('price-mine'),
          label: 'Tu precio',
          value: mine == null ? 'Sin precio. Los profesionales te propondrán uno.' : Fmt.bsShort(mine.amount),
        ),
      );
      final proposals = b.professional == null ? p.openProposals : [?p.openIn(b.professional!.id, byCustomer: false)];
      for (final o in proposals) {
        children.add(
          _OfferTile(
            key: Key('proposal-${o.id}'),
            offer: o,
            who: o.professional?.displayName ?? b.professional?.displayName ?? 'Profesional',
            rating: o.professional,
            actions: [
              PrimaryButton(
                key: Key('proposal-accept-${o.id}'),
                label: 'Aceptar ${Fmt.bsShort(o.amount)}',
                onPressed: () => run(() => api.acceptPriceOffer(o.id), success: '¡Listo! Precio acordado'),
              ),
              _Two(
                left: SecondaryButton(
                  key: Key('proposal-counter-${o.id}'),
                  label: 'Contraofertar',
                  onPressed: () async {
                    final r = await showPriceSheet(context, title: 'Tu contraoferta', initial: o.amount);
                    if (r != null) {
                      await run(
                        () => api.proposePrice(
                          b.id,
                          r.amount,
                          kind: o.kind,
                          note: r.note,
                          professionalId: o.professionalId,
                        ),
                        success: 'Contraoferta enviada',
                      );
                    }
                  },
                ),
                right: SecondaryButton(
                  key: Key('proposal-reject-${o.id}'),
                  label: 'Rechazar',
                  onPressed: () => run(() => api.rejectPriceOffer(o.id)),
                ),
              ),
            ],
          ),
        );
      }
    } else if (me != null) {
      final theirs = p.customerOfferFor(me);
      final mine = p.openIn(me, byCustomer: false);
      children.add(
        _Line(
          key: const Key('price-customer'),
          label: 'Precio del cliente',
          value: theirs == null ? 'No puso precio. Propón el tuyo.' : Fmt.bsShort(theirs.amount),
        ),
      );
      if (theirs != null && (theirs.note ?? '').isNotEmpty) _note(children, theirs.note!);
      if (mine != null) {
        children.add(
          _Line(
            key: const Key('price-my-proposal'),
            label: 'Tu propuesta',
            value:
                '${Fmt.bsShort(mine.amount)}${mine.kind == PriceKind.inspection ? ' (visita)' : ''} · esperando al cliente',
          ),
        );
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.sm),
      child: AppCard(
        key: const Key('price-panel'),
        color: HyColors.warningSoft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Precio',
              style: TextStyle(color: HyColors.textSecondary, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            const Text(
              'Nadie empieza el trabajo hasta que los dos acepten un precio.',
              style: TextStyle(color: HyColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: HySpacing.xs),
            ...children,
            _History(offers: p.offers),
          ],
        ),
      ),
    );
  }

  static void _note(List<Widget> children, String note) => children.add(
    Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.xs),
      child: Text(note, style: const TextStyle(color: HyColors.textSecondary)),
    ),
  );
}

/// Precio acordado: fijo hasta que los dos acepten una contraoferta (0067).
class _Agreed extends ConsumerWidget {
  const _Agreed({required this.b, required this.run});

  final BookingDetail b;
  final Future<void> Function(Future<void> Function() action, {String? success}) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = b.price;
    final api = ref.read(backendProvider);
    final change = p.openChange;
    final changeIsMine = change != null && change.byCustomer == b.viewerIsCustomer;
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.sm),
      child: AppCard(
        key: const Key('price-agreed'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 20, color: HyColors.success),
                const SizedBox(width: HySpacing.xs),
                Expanded(
                  child: Text(
                    p.agreedKind == PriceKind.inspection ? 'Visita de inspección acordada' : 'Precio acordado',
                    style: const TextStyle(color: HyColors.textSecondary, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            Text(
              Fmt.bsShort(p.total!),
              key: const Key('price-total'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (p.acceptedTotal != null)
              _Line(
                key: const Key('price-initial'),
                label: p.agreedKind == PriceKind.inspection ? 'Visita acordada al principio' : 'Precio inicial',
                value: Fmt.bsShort(p.agreedAmount!),
              )
            else if (p.acceptedExtras.isNotEmpty) ...[
              _Line(
                label: p.agreedKind == PriceKind.inspection ? 'Visita' : 'Trabajo',
                value: Fmt.bsShort(p.agreedAmount!),
              ),
              for (final o in p.acceptedExtras) _Line(label: o.kind.label, value: Fmt.bsShort(o.amount)),
            ],
            if (b.paymentMethod != null)
              _Line(label: 'Pago', value: '${b.paymentMethod!.label}, directo al profesional'),
            const Text(
              'Ninguno de los dos puede cambiarlo solo.',
              style: TextStyle(color: HyColors.textMuted, fontSize: 14),
            ),
            for (final o in p.awaitingFunds)
              Padding(
                key: Key('awaiting-funds-${o.id}'),
                padding: const EdgeInsets.only(top: HySpacing.sm),
                child: InfoBanner(
                  icon: Icons.hourglass_bottom_rounded,
                  tone: StatusTone.warning,
                  text: b.viewerIsCustomer
                      ? '${_what(o)} aceptado, pero todavía no cuenta: el profesional tiene que recargar su saldo. '
                            'El precio acordado sigue igual.'
                      : '${_what(o)} aceptado. Cuenta cuando recargues saldo para su comisión.',
                ),
              ),
            if (p.awaitingFunds.isNotEmpty)
              Wrap(
                spacing: HySpacing.xs,
                children: [
                  if (!b.viewerIsCustomer)
                    TextButton(onPressed: () => context.push(Routes.wallet), child: const Text('Recargar saldo')),
                  for (final o in p.awaitingFunds)
                    TextButton(
                      key: Key('awaiting-cancel-${o.id}'),
                      onPressed: () => run(() => api.cancelPriceOffer(o.id), success: 'Anulado'),
                      child: Text('Anular ${Fmt.bsShort(o.amount)}'),
                    ),
                ],
              ),
            if (change != null) ...[
              const Divider(height: HySpacing.lg),
              _OfferTile(
                key: Key('change-${change.id}'),
                offer: change,
                who: change.kind == PriceKind.total
                    ? (changeIsMine
                          ? 'Tu contraoferta'
                          : (b.viewerIsCustomer ? 'Contraoferta del profesional' : 'Contraoferta del cliente'))
                    : (changeIsMine
                          ? 'Tu pedido'
                          : (b.viewerIsCustomer ? 'El profesional pide' : 'El cliente propone')),
                current: change.kind == PriceKind.total ? p.total : null,
                actions: changeIsMine
                    ? [
                        const Text('Esperando la respuesta.', style: TextStyle(color: HyColors.textSecondary)),
                        TextButton(
                          key: Key('change-withdraw-${change.id}'),
                          onPressed: () => run(() => api.cancelPriceOffer(change.id)),
                          child: const Text('Retirar'),
                        ),
                      ]
                    : [
                        // Antes de aceptar, el profesional ve la comisión del total nuevo.
                        if (!b.viewerIsCustomer && change.kind == PriceKind.total && b.commissionRate != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: HySpacing.xs),
                            child: Text(
                              'Comisión ${_rate(b.commissionRate!)} %: '
                              '${Fmt.bs((change.amount * b.commissionRate!).round() / 100)}. Se cobra cuando el '
                              'cliente marca "Ya pagué".',
                              key: const Key('change-commission'),
                              style: const TextStyle(color: HyColors.textSecondary, fontSize: 14),
                            ),
                          ),
                        PrimaryButton(
                          key: Key('change-accept-${change.id}'),
                          label: 'Aceptar ${Fmt.bsShort(change.amount)}',
                          onPressed: () => run(
                            () => api.acceptPriceOffer(change.id),
                            success: change.kind == PriceKind.total
                                ? 'Nuevo precio acordado: ${Fmt.bsShort(change.amount)}'
                                : 'Monto aceptado',
                          ),
                        ),
                        _Two(
                          left: SecondaryButton(
                            key: Key('change-counter-${change.id}'),
                            label: 'Contraofertar',
                            onPressed: () async {
                              if (change.kind == PriceKind.total) {
                                final r = await showCounterofferSheet(
                                  context,
                                  current: p.total!,
                                  initial: change.amount,
                                  commissionRate: b.viewerIsCustomer ? null : b.commissionRate,
                                );
                                if (r != null) {
                                  await run(
                                    () => api.proposePrice(b.id, r.amount, kind: PriceKind.total, note: r.note),
                                    success: 'Contraoferta enviada',
                                  );
                                }
                                return;
                              }
                              final r = await showPriceSheet(context, title: 'Tu contraoferta', initial: change.amount);
                              if (r != null) {
                                await run(
                                  () => api.proposePrice(b.id, r.amount, kind: change.kind, note: r.note),
                                  success: 'Contraoferta enviada',
                                );
                              }
                            },
                          ),
                          right: SecondaryButton(
                            key: Key('change-reject-${change.id}'),
                            label: 'Rechazar',
                            onPressed: () => run(() => api.rejectPriceOffer(change.id)),
                          ),
                        ),
                      ],
              ),
            ],
            _History(offers: p.offers),
          ],
        ),
      ),
    );
  }
}

String _rate(double r) => r.toStringAsFixed(r % 1 == 0 ? 0 : 1);

String _what(PriceOffer o) => o.kind == PriceKind.total
    ? 'Nuevo total de ${Fmt.bsShort(o.amount)}'
    : '${o.kind.label} de ${Fmt.bsShort(o.amount)}';

class _OfferTile extends StatelessWidget {
  const _OfferTile({
    super.key,
    required this.offer,
    required this.who,
    this.rating,
    this.current,
    required this.actions,
  });

  final PriceOffer offer;
  final String who;
  final BookingProfessional? rating;

  /// Contraoferta del total: el precio de ahora, para mostrar la diferencia.
  final double? current;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: HySpacing.xs),
    padding: const EdgeInsets.all(HySpacing.sm),
    decoration: BoxDecoration(
      color: HyColors.surface,
      borderRadius: BorderRadius.circular(HyRadii.md),
      border: Border.all(color: HyColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: HySpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(who, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            if (rating != null && rating!.isVerified) const VerifiedBadge(compact: true),
            if (rating != null) RankBadge(tier: rating!.rankTier, compact: true),
            if (rating != null) RatingLabel(rating: rating!.ratingAvg, count: rating!.ratingCount),
          ],
        ),
        Text(
          '${offer.kind.label}: ${Fmt.bsShort(offer.amount)}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        if (current != null)
          Text(
            'Precio actual: ${Fmt.bsShort(current!)} · Diferencia: '
            '${offer.amount >= current! ? '+' : '−'}${Fmt.bsShort((offer.amount - current!).abs())}',
            key: Key('change-diff-${offer.id}'),
            style: const TextStyle(color: HyColors.textSecondary),
          ),
        if ((offer.note ?? '').isNotEmpty) Text(offer.note!, style: const TextStyle(color: HyColors.textSecondary)),
        const SizedBox(height: HySpacing.xs),
        ...actions,
      ],
    ),
  );
}

/// Dos botones lado a lado, o uno debajo del otro si no entran sin partir palabras.
class _Two extends StatelessWidget {
  const _Two({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: HySpacing.xs),
    child: LayoutBuilder(
      builder: (context, c) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        if ((c.maxWidth - HySpacing.xs) / 2 < 140 * scale) {
          return Column(
            children: [
              left,
              const SizedBox(height: HySpacing.xs),
              right,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: left),
            const SizedBox(width: HySpacing.xs),
            Expanded(child: right),
          ],
        );
      },
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(color: HyColors.textSecondary),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 16),
    ),
  );
}

/// Todas las propuestas, de la más nueva a la más vieja.
class _History extends StatelessWidget {
  const _History({required this.offers});

  final List<PriceOffer> offers;

  static String _status(OfferStatus s) => switch (s) {
    OfferStatus.open => 'esperando respuesta',
    OfferStatus.awaitingFunds => 'aceptado, esperando recarga',
    OfferStatus.accepted => 'aceptado',
    OfferStatus.rejected => 'rechazado',
    OfferStatus.superseded => 'reemplazado',
    OfferStatus.withdrawn => 'retirado',
    OfferStatus.expired => 'vencido',
  };

  @override
  Widget build(BuildContext context) {
    if (offers.length < 2) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('price-history'),
        tilePadding: EdgeInsets.zero,
        title: const Text('Historial de precios', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        children: [
          for (final o in offers.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '${o.byCustomer ? 'Cliente' : (o.professional?.displayName ?? 'Profesional')} · '
                      '${o.kind.label}: ${Fmt.bsShort(o.amount)} · ${_status(o.status)}',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  Text(Fmt.dateTime(o.createdAt), style: const TextStyle(color: HyColors.textMuted, fontSize: 13)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Lo que devuelve [showPriceSheet].
typedef PriceInput = ({double amount, PriceKind kind, String? note});

/// Proponer un precio. [kinds] con más de uno muestra para elegir (por
/// ejemplo, el trabajo completo o solo la visita de inspección).
/// [commission] muestra la comisión del monto escrito (solo el profesional).
Future<PriceInput?> showPriceSheet(
  BuildContext context, {
  required String title,
  double? initial,
  List<PriceKind> kinds = const [PriceKind.service],
  Future<CommissionQuote> Function(double amount)? commission,
}) {
  final amount = TextEditingController(
    text: initial == null ? '' : Fmt.bsShort(initial).replaceAll(RegExp(r'[^\d,]'), ''),
  );
  final note = TextEditingController();
  final form = GlobalKey<FormState>();
  var kind = kinds.first;
  CommissionQuote? quote;
  var quoteFor = -1.0;
  double? parse(String v) => double.tryParse(v.replaceAll('.', '').replaceAll(',', '.').trim());
  return showModalBottomSheet<PriceInput>(
    context: context,
    isScrollControlled: true,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        Future<void> refreshQuote() async {
          final n = parse(amount.text);
          if (commission == null || n == null || n <= 0 || n > 100000 || n == quoteFor) return;
          quoteFor = n;
          try {
            final q = await commission(n);
            if (c.mounted && quoteFor == n) setState(() => quote = q);
          } catch (_) {
            // Sin la comisión a la vista igual se puede proponer: la base revisa.
          }
        }

        if (quote == null && initial != null) refreshQuote();
        return Padding(
          padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(c) + HySpacing.lg),
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(c).textTheme.headlineSmall),
                const SizedBox(height: HySpacing.sm),
                if (kinds.length > 1) ...[
                  SegmentedButton<PriceKind>(
                    key: const Key('price-kind'),
                    showSelectedIcon: false,
                    segments: [
                      for (final k in kinds)
                        ButtonSegment(value: k, label: Text(k == PriceKind.service ? 'Trabajo completo' : k.label)),
                    ],
                    selected: {kind},
                    onSelectionChanged: (s) => setState(() => kind = s.first),
                  ),
                  if (kind == PriceKind.inspection)
                    const Padding(
                      padding: EdgeInsets.only(top: HySpacing.xs),
                      child: Text(
                        'Solo la visita para revisar. La reparación la cotizas después y el cliente la aprueba aparte.',
                        style: TextStyle(color: HyColors.textSecondary),
                      ),
                    ),
                  const SizedBox(height: HySpacing.sm),
                ],
                TextFormField(
                  key: const Key('price-amount'),
                  controller: amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                  decoration: InputDecoration(
                    labelText: 'Monto en ${kCountry.currencySymbol}',
                    prefixText: kCountry.moneyPrefix,
                  ),
                  onChanged: (_) => refreshQuote(),
                  validator: (v) {
                    final n = parse(v ?? '');
                    if (n == null || n <= 0 || n > 100000) return 'Escribe un monto entre 1 y 100.000';
                    return null;
                  },
                ),
                if (quote != null && quote!.hasRule) ...[
                  const SizedBox(height: HySpacing.xs),
                  CommissionText(quote: quote!),
                ],
                const SizedBox(height: HySpacing.sm),
                TextFormField(
                  controller: note,
                  maxLines: 2,
                  maxLength: 300,
                  decoration: const InputDecoration(
                    labelText: 'Detalle (opcional)',
                    hintText: 'Ej.: incluye materiales',
                  ),
                ),
                const SizedBox(height: HySpacing.xs),
                PrimaryButton(
                  key: const Key('price-send'),
                  label: 'Enviar',
                  onPressed: () {
                    if (!form.currentState!.validate()) return;
                    Navigator.pop(c, (
                      amount: parse(amount.text)!,
                      kind: kind,
                      note: note.text.trim().isEmpty ? null : note.text.trim(),
                    ));
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// "Comisión 10 %: Bs 20. Te quedan Bs 180." y, si falta saldo, cuánto. Se
/// cobra cuando el cliente marca "Ya pagué".
class CommissionText extends StatelessWidget {
  const CommissionText({super.key, required this.quote});

  final CommissionQuote quote;

  @override
  Widget build(BuildContext context) {
    final rate = quote.ratePercent == null
        ? ''
        : ' ${quote.ratePercent!.toStringAsFixed(quote.ratePercent! % 1 == 0 ? 0 : 1)} %';
    final base = 'Comisión$rate: ${Fmt.bs(quote.commission)}. Te quedan ${Fmt.bs(quote.net)}.';
    // Reglas finales (0066): nada se reserva; el saldo tiene que cubrir esta
    // comisión y la de los otros trabajos sin cobrar. Lo anotado sin cobrar no
    // se muestra: se resuelve con soporte.
    final short = quote.pendingDebt > 0
        ? ' Escribe a soporte para seguir aceptando trabajos.'
        : !quote.canCover
        ? quote.openCommissions > 0
              ? ' Te faltan ${Fmt.bs(quote.missing)} de saldo: tu saldo tiene que cubrir también las comisiones de '
                    'tus otros trabajos. Recarga para aceptar este precio.'
              : ' Te faltan ${Fmt.bs(quote.missing)} de saldo: recarga para aceptar este precio.'
        : '';
    return Text(
      base + short,
      key: const Key('commission-quote'),
      style: TextStyle(color: short.isEmpty ? HyColors.textSecondary : HyColors.danger, fontSize: 14),
    );
  }
}

/// La comisión del precio que el profesional está por aceptar, con recarga si falta saldo.
final commissionQuoteProvider = FutureProvider.autoDispose.family<CommissionQuote?, (String, double)>(
  (ref, k) => ref.watch(backendProvider).commissionForAmount(k.$1, k.$2),
);

class CommissionForAmount extends ConsumerWidget {
  const CommissionForAmount({super.key, required this.bookingId, required this.amount});

  final String bookingId;
  final double amount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(commissionQuoteProvider((bookingId, amount))).value;
    if (q == null || !q.hasRule) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.xs),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          CommissionText(quote: q),
          if (!q.canCover || q.pendingDebt > 0)
            TextButton(
              key: const Key('commission-topup'),
              onPressed: () => context.push(Routes.wallet),
              child: const Text('Recargar saldo'),
            ),
        ],
      ),
    );
  }
}

/// Contraoferta con el precio ya acordado (0067): se escribe el NUEVO TOTAL,
/// nunca un monto que se suma. Muestra el precio actual, la diferencia y el
/// total nuevo; al profesional, también la comisión del total nuevo.
Future<({double amount, String? note})?> showCounterofferSheet(
  BuildContext context, {
  required double current,
  double? initial,
  double? commissionRate,
}) {
  final amount = TextEditingController(
    text: initial == null ? '' : Fmt.bsShort(initial).replaceAll(RegExp(r'[^\d,]'), ''),
  );
  final note = TextEditingController();
  final form = GlobalKey<FormState>();
  double? parse(String v) => double.tryParse(v.replaceAll('.', '').replaceAll(',', '.').trim());
  return showModalBottomSheet<({double amount, String? note})>(
    context: context,
    isScrollControlled: true,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        final n = parse(amount.text);
        final diff = n == null ? null : n - current;
        return Padding(
          padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(c) + HySpacing.lg),
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Contraoferta', style: Theme.of(c).textTheme.headlineSmall),
                const SizedBox(height: HySpacing.xs),
                _Line(key: const Key('counter-current'), label: 'Precio actual', value: Fmt.bs(current)),
                const SizedBox(height: HySpacing.xs),
                TextFormField(
                  key: const Key('counter-amount'),
                  controller: amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                  decoration: InputDecoration(
                    labelText: 'Nuevo precio total en ${kCountry.currencySymbol}',
                    helperText: 'Escribe el total del trabajo, no lo que se suma.',
                    prefixText: kCountry.moneyPrefix,
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final n = parse(v ?? '');
                    if (n == null || n <= 0 || n > 100000) return 'Escribe un monto entre 1 y 100.000';
                    if (n == current) return 'Es el mismo precio actual';
                    return null;
                  },
                ),
                if (n != null && n > 0 && diff != 0) ...[
                  const SizedBox(height: HySpacing.xs),
                  _Line(
                    key: const Key('counter-diff'),
                    label: 'Diferencia',
                    value: '${diff! > 0 ? '+' : '−'}${Fmt.bs(diff.abs())}',
                  ),
                  _Line(key: const Key('counter-total'), label: 'Nuevo total', value: Fmt.bs(n)),
                  if (commissionRate != null)
                    Text(
                      'Comisión ${commissionRate.toStringAsFixed(commissionRate % 1 == 0 ? 0 : 1)} % del nuevo total: '
                      '${Fmt.bs((n * commissionRate).round() / 100)}. Se cobra cuando el cliente marca "Ya pagué".',
                      key: const Key('counter-commission'),
                      style: const TextStyle(color: HyColors.textSecondary, fontSize: 14),
                    ),
                ],
                const SizedBox(height: HySpacing.xs),
                const Text(
                  'El precio acordado no cambia hasta que la otra persona acepte.',
                  style: TextStyle(color: HyColors.textMuted, fontSize: 14),
                ),
                const SizedBox(height: HySpacing.sm),
                TextFormField(
                  controller: note,
                  maxLines: 2,
                  maxLength: 300,
                  decoration: const InputDecoration(
                    labelText: 'Motivo (opcional)',
                    hintText: 'Ej.: hay que cambiar otra pieza',
                  ),
                ),
                PrimaryButton(
                  key: const Key('counter-send'),
                  label: 'Enviar contraoferta',
                  onPressed: () {
                    if (!form.currentState!.validate()) return;
                    Navigator.pop(c, (
                      amount: parse(amount.text)!,
                      note: note.text.trim().isEmpty ? null : note.text.trim(),
                    ));
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
