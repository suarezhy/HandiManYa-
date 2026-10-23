import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';

/// Estado de la llegada de un pedido (nunca incluye el código).
final bookingArrivalProvider = FutureProvider.autoDispose.family<BookingArrival, String>((ref, id) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).arrival(id);
});

/// Aviso dentro del detalle: qué falta para verificar la llegada, o que ya está.
class ArrivalCard extends ConsumerWidget {
  const ArrivalCard({super.key, required this.b});

  final BookingDetail b;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relevant = {
      BookingStatus.onTheWay,
      BookingStatus.inProgress,
      BookingStatus.workFinished,
      BookingStatus.completed,
      BookingStatus.disputed,
    }.contains(b.status);
    if (!relevant) return const SizedBox.shrink();
    final a = ref.watch(bookingArrivalProvider(b.id)).value;
    if (a == null) return const SizedBox.shrink();
    if (a.verified) {
      return Padding(
        padding: const EdgeInsets.only(bottom: HySpacing.sm),
        child: AppCard(
          key: const Key('arrival-verified'),
          color: HyColors.successSoft,
          child: Row(
            children: [
              const Icon(Icons.verified_user_rounded, color: HyColors.success, size: 30),
              const SizedBox(width: HySpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Llegada verificada', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    Text(
                      a.byTeam
                          ? 'La verificó nuestro equipo.'
                          : b.viewerIsCustomer
                          ? 'Confirmaste con el código que llegó la persona correcta.'
                          : 'El cliente confirmó tu llegada con el código.',
                      style: const TextStyle(color: HyColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (b.status != BookingStatus.onTheWay) return const SizedBox.shrink();
    final waiting = a.stage == ArrivalStage.waitingPin;
    final text = b.viewerIsCustomer
        ? (waiting
              ? 'Tu profesional dice que llegó. Pídele el código de 6 números y escríbelo en "Verificar llegada". '
                    'No le des acceso a tu casa hasta verificarlo.'
              : 'Cuando llegue, te dará un código de 6 números para verificar que es la persona correcta.')
        : (waiting
              ? 'Dicta el código al cliente para que verifique tu llegada.'
              : 'Al llegar, toca "He llegado". El cliente verificará tu llegada con un código.');
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.sm),
      child: AppCard(
        key: const Key('arrival-pending'),
        color: HyColors.warningSoft,
        child: Row(
          children: [
            const Icon(Icons.pin_outlined, color: HyColors.textSecondary, size: 28),
            const SizedBox(width: HySpacing.sm),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 16))),
          ],
        ),
      ),
    );
  }
}

/// El código que ve solo el profesional, con su vencimiento.
Future<void> showArrivalPinSheet(BuildContext context, ArrivalPin pin) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (c) => Padding(
    padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(c) + HySpacing.lg),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Tu código de llegada', style: Theme.of(c).textTheme.headlineSmall),
        const SizedBox(height: HySpacing.xs),
        const Text(
          'Proporciona este código al cliente para verificar tu llegada.',
          style: TextStyle(fontSize: 16, color: HyColors.textSecondary),
        ),
        const SizedBox(height: HySpacing.lg),
        Semantics(
          label: 'Código ${pin.pin.split('').join(' ')}',
          child: ExcludeSemantics(
            child: Text(
              '${pin.pin.substring(0, 3)} ${pin.pin.substring(3)}',
              key: const Key('arrival-pin'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w900, letterSpacing: 6),
            ),
          ),
        ),
        const SizedBox(height: HySpacing.sm),
        _ExpiresIn(at: pin.expiresAt),
        const SizedBox(height: HySpacing.lg),
        PrimaryButton(label: 'Listo', onPressed: () => Navigator.pop(c)),
      ],
    ),
  ),
);

class _ExpiresIn extends StatefulWidget {
  const _ExpiresIn({required this.at});

  final DateTime at;

  @override
  State<_ExpiresIn> createState() => _ExpiresInState();
}

class _ExpiresInState extends State<_ExpiresIn> {
  late final Timer _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.at.difference(DateTime.now());
    final text = left.isNegative
        ? 'Este código venció. Toca "He llegado" otra vez para generar uno nuevo.'
        : 'Vence en ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
    return Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: HyColors.textMuted),
    );
  }
}

/// "Verificar llegada": 6 casillas. Devuelve true si quedó verificada.
Future<bool> showVerifyArrivalSheet(BuildContext context, String bookingId) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (c) => _VerifyArrivalSheet(bookingId: bookingId),
  );
  return ok ?? false;
}

class _VerifyArrivalSheet extends ConsumerStatefulWidget {
  const _VerifyArrivalSheet({required this.bookingId});

  final String bookingId;

  @override
  ConsumerState<_VerifyArrivalSheet> createState() => _VerifyArrivalSheetState();
}

class _VerifyArrivalSheetState extends ConsumerState<_VerifyArrivalSheet> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_code.text.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(backendProvider).verifyArrivalPin(widget.bookingId, _code.text);
      if (!mounted) return;
      if (r.result == ArrivalCheckResult.verified) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _code.clear();
        _error = switch (r.result) {
          ArrivalCheckResult.wrong =>
            'El código no es correcto. Te quedan ${r.attemptsLeft} intentos. Revisa con el profesional.',
          ArrivalCheckResult.locked =>
            'Ese código se bloqueó por intentos fallidos. Pídele al profesional que genere uno nuevo.',
          ArrivalCheckResult.expired => 'El código venció. Pídele al profesional que genere uno nuevo.',
          ArrivalCheckResult.verified => null,
        };
      });
    } catch (e) {
      if (mounted) setState(() => _error = AppError.from(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = _code.text;
    return Padding(
      padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Verificar llegada', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: HySpacing.xs),
          const Text(
            'Escribe el código de 6 números que te da el profesional.',
            style: TextStyle(fontSize: 16, color: HyColors.textSecondary),
          ),
          const SizedBox(height: HySpacing.lg),
          // Un solo campo (pegar y autocompletar funcionan) dibujado como 6 casillas.
          Stack(
            children: [
              Row(
                children: [
                  for (var i = 0; i < 6; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 58,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: HyColors.surface,
                          borderRadius: BorderRadius.circular(HyRadii.md),
                          border: Border.all(
                            color: i == digits.length && _focus.hasFocus ? HyColors.primary : HyColors.border,
                            width: i == digits.length && _focus.hasFocus ? 2 : 1,
                          ),
                        ),
                        child: Text(
                          i < digits.length ? digits[i] : '',
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Positioned.fill(
                child: Opacity(
                  opacity: 0.01,
                  child: TextField(
                    key: const Key('arrival-code-field'),
                    controller: _code,
                    focusNode: _focus,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    showCursor: false,
                    enableInteractiveSelection: false,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                    decoration: const InputDecoration(border: InputBorder.none, counterText: ''),
                    onChanged: (v) {
                      setState(() {});
                      if (v.length == 6) _submit();
                    },
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: HySpacing.sm),
            Text(
              _error!,
              key: const Key('arrival-error'),
              style: const TextStyle(color: HyColors.danger, fontSize: 15),
            ),
          ],
          const SizedBox(height: HySpacing.lg),
          PrimaryButton(
            key: const Key('arrival-submit'),
            label: 'Verificar',
            loading: _busy,
            onPressed: digits.length == 6 ? _submit : null,
          ),
        ],
      ),
    );
  }
}
