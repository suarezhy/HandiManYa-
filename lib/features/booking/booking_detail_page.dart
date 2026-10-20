import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/photo_picker.dart';
import '../common/safety_menu.dart';

/// Detalle de una solicitud. Muestra el estado en tiempo real y solo las
/// acciones que el servidor permite en ese estado para quien la mira.
class BookingDetailPage extends ConsumerWidget {
  const BookingDetailPage({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(bookingDetailProvider(id));
    return Scaffold(
      appBar: AppBar(
        title: Text(detail.value == null ? 'Solicitud' : 'Solicitud ${detail.value!.code}'),
        actions: [
          if (detail.value case final b?)
            if (b.viewerIsCustomer && b.professional != null)
              SafetyMenuButton(userId: b.professional!.id, name: b.professional!.displayName, bookingId: b.id)
            else if (!b.viewerIsCustomer)
              SafetyMenuButton(userId: b.customerId, name: b.customerFirstName, bookingId: b.id),
        ],
      ),
      body: detail.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(bookingDetailProvider(id))),
        data: (b) => RefreshIndicator(
          color: HyColors.primary,
          onRefresh: () async => ref.invalidate(bookingDetailProvider(id)),
          child: ListView(
            padding: const EdgeInsets.only(bottom: HySpacing.xxl),
            children: [PageBody(child: _Content(b: b))],
          ),
        ),
      ),
      bottomNavigationBar: detail.value == null ? null : _Actions(b: detail.value!),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.b});

  final BookingDetail b;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final hint = b.viewerIsCustomer ? b.status.customerHint() : b.status.professionalHint();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: HySpacing.xs),
        _StatusHeader(b: b, hint: hint),
        const SizedBox(height: HySpacing.md),

        if (b.viewerIsCustomer && b.professional != null) ...[
          AppCard(
            onTap: () => context.push(Routes.professional(b.professional!.id)),
            child: Row(
              children: [
                PersonAvatar(name: b.professional!.displayName, url: b.professional!.photoUrl, size: 56),
                const SizedBox(width: HySpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: HySpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(b.professional!.displayName, style: text.titleMedium),
                          if (b.professional!.isVerified) const VerifiedBadge(compact: true),
                        ],
                      ),
                      RatingLabel(rating: b.professional!.ratingAvg, count: b.professional!.ratingCount),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: HyColors.textMuted),
              ],
            ),
          ),
          const SizedBox(height: HySpacing.sm),
        ],
        if (!b.viewerIsCustomer) ...[
          AppCard(
            child: Row(
              children: [
                PersonAvatar(name: b.customerFirstName, size: 48),
                const SizedBox(width: HySpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Cliente', style: TextStyle(color: HyColors.textMuted)),
                      Text(b.customerFirstName, style: text.titleMedium),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: HySpacing.sm),
        ],

        if (b.quoteAmount != null) ...[
          AppCard(
            color: b.status == BookingStatus.quoteSent ? HyColors.warningSoft : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Cotización',
                  style: TextStyle(color: HyColors.textSecondary, fontWeight: FontWeight.w600),
                ),
                Text(Fmt.bs(b.quoteAmount!), style: text.headlineSmall),
                if ((b.quoteNote ?? '').isNotEmpty) Text(b.quoteNote!, style: const TextStyle(fontSize: 16)),
              ],
            ),
          ),
          const SizedBox(height: HySpacing.sm),
        ],

        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Line(icon: Icons.build_outlined, label: 'Servicio', value: b.category),
              _Line(
                icon: b.mode == BookingMode.now ? Icons.bolt_rounded : Icons.event_outlined,
                label: 'Cuándo',
                value: b.mode == BookingMode.now
                    ? 'Ahora (pedido ${Fmt.relative(b.createdAt)})'
                    : '${Fmt.date(b.scheduledStart!)}, ${Fmt.time(b.scheduledStart!)}',
              ),
              _Line(icon: Icons.place_outlined, label: 'Zona', value: b.areaLabel),
              if (b.distanceKm != null)
                _Line(
                  icon: Icons.near_me_outlined,
                  label: 'Distancia',
                  value: 'A unos ${Fmt.km(b.distanceKm!)} de tu base (aproximado)',
                ),
              if (b.paymentMethod != null)
                _Line(
                  icon: b.paymentMethod!.icon,
                  label: 'Pago',
                  value: '${b.paymentMethod!.label}, directo al profesional',
                ),
              if (b.finalAmount != null)
                _Line(icon: Icons.payments_outlined, label: 'Monto final', value: Fmt.bs(b.finalAmount!)),
              const Divider(height: HySpacing.lg),
              if (b.problems.isNotEmpty) ...[
                const Text(
                  'Qué necesita',
                  style: TextStyle(color: HyColors.textSecondary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                for (final p in b.problems)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(Icons.check_circle_outline, size: 20, color: HyColors.primary),
                        ),
                        const SizedBox(width: HySpacing.xs),
                        Expanded(
                          child: Text(p, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: HySpacing.sm),
              ],
              if (b.problems.isEmpty || b.description != b.problems.join('. ')) ...[
                const Text(
                  'Descripción',
                  style: TextStyle(color: HyColors.textSecondary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(b.description, style: const TextStyle(fontSize: 17)),
              ],
              if (b.safetyNote != null) ...[
                const SizedBox(height: HySpacing.md),
                InfoBanner(icon: Icons.shield_outlined, tone: StatusTone.warning, text: b.safetyNote!),
              ],
              if (b.photos.isNotEmpty) ...[const SizedBox(height: HySpacing.md), BookingPhotosStrip(photos: b.photos)],
            ],
          ),
        ),
        const SizedBox(height: HySpacing.sm),

        if (b.address != null)
          AppCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.home_outlined, color: HyColors.primary),
                const SizedBox(width: HySpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Dirección',
                        style: TextStyle(color: HyColors.textSecondary, fontWeight: FontWeight.w600),
                      ),
                      Text(b.address!.line, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                      if ((b.address!.reference ?? '').isNotEmpty)
                        Text(b.address!.reference!, style: const TextStyle(color: HyColors.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copiar dirección',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: b.address!.line));
                    showMessage(context, 'Dirección copiada');
                  },
                ),
              ],
            ),
          ),
        if (b.address != null && !b.viewerIsCustomer) ...[
          const SizedBox(height: HySpacing.sm),
          PrimaryButton(
            label: 'Cómo llegar',
            icon: Icons.directions_rounded,
            color: HyColors.navy,
            onPressed: () async {
              final ok = await launchUrl(b.address!.directionsUrl, mode: LaunchMode.externalApplication);
              if (!ok && context.mounted) showMessage(context, 'No pudimos abrir el mapa. Copia la dirección.');
            },
          ),
        ],
        if (b.address == null && !b.viewerIsCustomer)
          const InfoBanner(icon: Icons.lock_outline, text: 'La dirección exacta se muestra cuando aceptas el trabajo.'),

        if (b.status == BookingStatus.workFinished || b.status == BookingStatus.completed) ...[
          const SizedBox(height: HySpacing.sm),
          _PaymentStatus(b: b),
        ],

        if (b.events.isNotEmpty) ...[
          const SectionHeader(title: 'Historial'),
          for (final e in b.events.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: HySpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(color: e.status.tone.foreground, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: HySpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.status.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        if ((e.note ?? '').isNotEmpty)
                          Text(e.note!, style: const TextStyle(color: HyColors.textSecondary)),
                      ],
                    ),
                  ),
                  Text(Fmt.dateTime(e.at), style: const TextStyle(color: HyColors.textMuted, fontSize: 14)),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.b, required this.hint});

  final BookingDetail b;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final searching = b.status == BookingStatus.awaitingResponse && b.viewerIsCustomer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HySpacing.md),
      decoration: BoxDecoration(color: b.status.tone.background, borderRadius: BorderRadius.circular(HyRadii.lg)),
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (searching) ...[
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 3, color: HyColors.primary),
                  ),
                  const SizedBox(width: HySpacing.sm),
                ],
                Expanded(
                  child: Text(
                    b.status.label,
                    style: TextStyle(color: b.status.tone.foreground, fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(hint, style: TextStyle(color: b.status.tone.foreground, fontSize: 16)),
            ],
            if (searching && (b.offersSent ?? 0) > 0) ...[
              const SizedBox(height: 4),
              Text(
                b.offersSent == 1 ? 'Avisamos a 1 profesional.' : 'Avisamos a ${b.offersSent} profesionales.',
                style: TextStyle(color: b.status.tone.foreground, fontWeight: FontWeight.w600),
              ),
            ],
            if (b.status == BookingStatus.cancelled && (b.cancelReason ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Motivo: ${b.cancelReason}', style: TextStyle(color: b.status.tone.foreground)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: HyColors.textMuted),
        const SizedBox(width: HySpacing.xs),
        SizedBox(
          width: 96,
          child: Text(label, style: const TextStyle(color: HyColors.textSecondary, fontSize: 15)),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}

class _PaymentStatus extends StatelessWidget {
  const _PaymentStatus({required this.b});

  final BookingDetail b;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Pago directo',
          style: TextStyle(color: HyColors.textSecondary, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        _Ack(done: b.customerPaidAck, text: 'El cliente indicó que pagó'),
        _Ack(done: b.professionalPaidAck, text: 'El profesional indicó que recibió el pago'),
        const SizedBox(height: 4),
        const Text(
          'HandiMan ¡Ya! no recibe ni verifica este pago. Si no coinciden, puedes reportar un problema.',
          style: TextStyle(color: HyColors.textMuted, fontSize: 14),
        ),
      ],
    ),
  );
}

class _Ack extends StatelessWidget {
  const _Ack({required this.done, required this.text});

  final bool done;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        done ? Icons.check_circle : Icons.radio_button_unchecked,
        color: done ? HyColors.success : HyColors.textMuted,
        size: 20,
      ),
      const SizedBox(width: HySpacing.xs),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
    ],
  );
}

/// Barra inferior con las acciones posibles según rol y estado.
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.b});

  final BookingDetail b;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    final ok = await runGuarded(context, action, success: success);
    if (ok) {
      ref.invalidate(bookingDetailProvider(widget.b.id));
      ref.invalidate(myBookingsProvider(!widget.b.viewerIsCustomer));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.b;
    final api = ref.read(backendProvider);
    final s = b.status;
    final primary = <Widget>[];
    final secondary = <Widget>[];

    void addChat() {
      if (b.conversationId != null && s.chatOpen) {
        secondary.add(
          SecondaryButton(
            label: 'Chat',
            icon: Icons.chat_bubble_outline,
            onPressed: () => context.push(Routes.chat(b.conversationId!)),
          ),
        );
      }
    }

    Future<void> cancel() async {
      final reason = await promptText(
        context,
        title: 'Cancelar solicitud',
        label: 'Motivo',
        confirm: 'Cancelar solicitud',
        hint: 'Cuéntanos por qué',
      );
      if (reason != null) await _run(() => api.cancel(b.id, reason), success: 'Solicitud cancelada');
    }

    Future<void> dispute() async {
      final reason = await promptText(
        context,
        title: 'Reportar un problema',
        label: '¿Qué pasó?',
        confirm: 'Enviar reporte',
        hint: 'Nuestro equipo revisará el caso',
        minLength: 5,
      );
      if (reason != null) await _run(() => api.openDispute(b.id, reason), success: 'Reporte enviado');
    }

    Future<void> ackPayment() =>
        _run(() => api.acknowledgePayment(b.id, b.paymentMethod ?? PaymentMethod.cash), success: 'Pago registrado');

    if (b.viewerIsCustomer) {
      switch (s) {
        case BookingStatus.requested || BookingStatus.awaitingResponse:
          secondary.add(SecondaryButton(label: 'Cancelar solicitud', onPressed: cancel));
        case BookingStatus.quoteSent:
          primary.add(
            PrimaryButton(
              label: 'Aceptar cotización',
              onPressed: () => _run(() => api.respondQuote(b.id, accept: true), success: '¡Listo! Trabajo confirmado'),
            ),
          );
          secondary.add(
            SecondaryButton(label: 'Rechazar', onPressed: () => _run(() => api.respondQuote(b.id, accept: false))),
          );
        case BookingStatus.confirmed:
          addChat();
          secondary.add(SecondaryButton(label: 'Cancelar', onPressed: cancel));
        case BookingStatus.onTheWay || BookingStatus.inProgress:
          addChat();
          secondary.add(SecondaryButton(label: 'Reportar problema', onPressed: dispute));
        case BookingStatus.workFinished:
          primary.add(
            PrimaryButton(
              label: 'Confirmar trabajo terminado',
              icon: Icons.check_circle_outline,
              onPressed: () async {
                final ok = await confirmDialog(
                  context,
                  title: '¿El trabajo quedó bien?',
                  message: 'Al confirmar, la solicitud se marca como completada.',
                  confirm: 'Sí, confirmar',
                );
                if (ok) await _run(() => api.confirmCompletion(b.id), success: '¡Gracias! Trabajo completado');
              },
            ),
          );
          if (!b.customerPaidAck) secondary.add(SecondaryButton(label: 'Ya pagué', onPressed: ackPayment));
          secondary.add(SecondaryButton(label: 'Reportar problema', onPressed: dispute));
        case BookingStatus.completed:
          if (!b.hasReview) {
            primary.add(
              PrimaryButton(
                label: 'Calificar al profesional',
                icon: Icons.star_rounded,
                onPressed: () async {
                  final r = await showReviewSheet(context);
                  if (r != null) {
                    await _run(() => api.submitReview(b.id, r.$1, r.$2), success: '¡Gracias por tu reseña!');
                  }
                },
              ),
            );
          }
          if (!b.customerPaidAck) secondary.add(SecondaryButton(label: 'Ya pagué', onPressed: ackPayment));
          addChat();
        case BookingStatus.disputed:
          addChat();
        default:
          break;
      }
    } else {
      switch (s) {
        case BookingStatus.awaitingResponse when b.isOffer:
          primary.add(
            PrimaryButton(
              label: 'Aceptar pedido ¡Ya!',
              icon: Icons.bolt_rounded,
              onPressed: () =>
                  _run(() => api.accept(b.id, isOffer: true), success: '¡Trabajo tuyo! Ya puedes ver la dirección'),
            ),
          );
          secondary.add(
            SecondaryButton(
              label: 'No puedo',
              onPressed: () async {
                await _run(() => api.decline(b.id, isOffer: true));
                if (context.mounted) context.pop();
              },
            ),
          );
        case BookingStatus.requested:
          primary.add(
            PrimaryButton(
              label: 'Aceptar',
              onPressed: () => _run(() => api.accept(b.id, isOffer: false), success: 'Trabajo aceptado'),
            ),
          );
          secondary.add(
            SecondaryButton(
              label: 'Cotizar',
              onPressed: () async {
                final q = await showQuoteSheet(context);
                if (q != null) await _run(() => api.sendQuote(b.id, q.$1, q.$2), success: 'Cotización enviada');
              },
            ),
          );
          secondary.add(
            SecondaryButton(label: 'Rechazar', onPressed: () => _run(() => api.decline(b.id, isOffer: false))),
          );
        case BookingStatus.confirmed:
          primary.add(
            PrimaryButton(
              label: 'Voy en camino',
              icon: Icons.directions_walk,
              onPressed: () => _run(() => api.updateProgress(b.id, BookingStatus.onTheWay)),
            ),
          );
          secondary.add(
            SecondaryButton(
              label: 'Empecé',
              onPressed: () => _run(() => api.updateProgress(b.id, BookingStatus.inProgress)),
            ),
          );
          addChat();
          secondary.add(SecondaryButton(label: 'Cancelar', onPressed: cancel));
        case BookingStatus.onTheWay:
          primary.add(
            PrimaryButton(
              label: 'Empecé el trabajo',
              icon: Icons.handyman_outlined,
              onPressed: () => _run(() => api.updateProgress(b.id, BookingStatus.inProgress)),
            ),
          );
          addChat();
        case BookingStatus.inProgress:
          primary.add(
            PrimaryButton(
              label: 'Terminé el trabajo',
              icon: Icons.task_alt,
              onPressed: () async {
                final amount = await showAmountSheet(
                  context,
                  title: '¿Cuánto cobraste?',
                  hint: 'Monto acordado con el cliente (opcional)',
                  initial: b.quoteAmount,
                );
                if (amount == null) return;
                await _run(
                  () => api.updateProgress(b.id, BookingStatus.workFinished, finalAmount: amount.$1),
                  success: 'Avisamos al cliente',
                );
              },
            ),
          );
          addChat();
        case BookingStatus.workFinished || BookingStatus.completed:
          if (!b.professionalPaidAck) {
            primary.add(PrimaryButton(label: 'Recibí el pago', icon: Icons.payments_outlined, onPressed: ackPayment));
          }
          addChat();
        case BookingStatus.disputed:
          addChat();
        default:
          break;
      }
    }

    if (primary.isEmpty && secondary.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: HyColors.surface,
          border: Border(top: BorderSide(color: HyColors.border)),
        ),
        padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.page, HySpacing.sm),
        // heightFactor: 1 para que la barra no ocupe toda la pantalla.
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: HySizes.maxContentWidth),
            child: AbsorbPointer(
              absorbing: _busy,
              child: Opacity(
                opacity: _busy ? 0.6 : 1,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...primary,
                    if (primary.isNotEmpty && secondary.isNotEmpty) const SizedBox(height: HySpacing.xs),
                    if (secondary.isNotEmpty)
                      Row(
                        children: [
                          for (var i = 0; i < secondary.length; i++) ...[
                            if (i > 0) const SizedBox(width: HySpacing.xs),
                            Expanded(child: secondary[i]),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Devuelve (estrellas, comentario).
Future<(int, String?)?> showReviewSheet(BuildContext context) {
  var rating = 0;
  final comment = TextEditingController();
  return showModalBottomSheet<(int, String?)>(
    context: context,
    isScrollControlled: true,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => Padding(
        padding: EdgeInsets.fromLTRB(
          HySpacing.page,
          0,
          HySpacing.page,
          MediaQuery.of(c).viewInsets.bottom + HySpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Cómo fue el trabajo?', style: Theme.of(c).textTheme.headlineSmall),
            const SizedBox(height: HySpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    tooltip: '$i ${i == 1 ? 'estrella' : 'estrellas'}',
                    iconSize: 44,
                    onPressed: () => setState(() => rating = i),
                    icon: Icon(i <= rating ? Icons.star_rounded : Icons.star_outline_rounded, color: HyColors.star),
                  ),
              ],
            ),
            const SizedBox(height: HySpacing.sm),
            TextField(
              controller: comment,
              maxLines: 3,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Comentario (opcional)'),
            ),
            const SizedBox(height: HySpacing.sm),
            PrimaryButton(
              label: 'Enviar reseña',
              onPressed: rating == 0
                  ? null
                  : () => Navigator.pop(c, (rating, comment.text.trim().isEmpty ? null : comment.text.trim())),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Devuelve (monto, nota).
Future<(double, String?)?> showQuoteSheet(BuildContext context) async {
  final r = await showAmountSheet(
    context,
    title: 'Enviar cotización',
    hint: 'Precio total en Bs',
    withNote: true,
    required: true,
  );
  if (r == null || r.$1 == null) return null;
  return (r.$1!, r.$2);
}

/// Devuelve (monto o null, nota). Null si se cancela.
Future<(double?, String?)?> showAmountSheet(
  BuildContext context, {
  required String title,
  required String hint,
  double? initial,
  bool withNote = false,
  bool required = false,
}) {
  final amount = TextEditingController(text: initial?.toStringAsFixed(0) ?? '');
  final note = TextEditingController();
  final form = GlobalKey<FormState>();
  return showModalBottomSheet<(double?, String?)>(
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.fromLTRB(
        HySpacing.page,
        0,
        HySpacing.page,
        MediaQuery.of(c).viewInsets.bottom + HySpacing.lg,
      ),
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(c).textTheme.headlineSmall),
            const SizedBox(height: HySpacing.md),
            TextFormField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
              decoration: InputDecoration(labelText: hint, prefixText: 'Bs '),
              validator: (v) {
                final t = (v ?? '').replaceAll(',', '.').trim();
                if (t.isEmpty) return required ? 'Escribe el monto' : null;
                final n = double.tryParse(t);
                if (n == null || n <= 0 || n > 100000) return 'Revisa el monto';
                return null;
              },
            ),
            if (withNote) ...[
              const SizedBox(height: HySpacing.md),
              TextFormField(
                controller: note,
                maxLines: 2,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Detalle (opcional)', hintText: 'Ej.: incluye materiales'),
              ),
            ],
            const SizedBox(height: HySpacing.sm),
            PrimaryButton(
              label: 'Confirmar',
              onPressed: () {
                if (!form.currentState!.validate()) return;
                final t = amount.text.replaceAll(',', '.').trim();
                Navigator.pop(c, (
                  t.isEmpty ? null : double.parse(t),
                  note.text.trim().isEmpty ? null : note.text.trim(),
                ));
              },
            ),
          ],
        ),
      ),
    ),
  );
}
