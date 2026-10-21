import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/safety_menu.dart';

Future<void> _sheet(BuildContext context, Widget Function(BuildContext) builder) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (c) => Padding(
    padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, MediaQuery.viewInsetsOf(c).bottom + HySpacing.lg),
    child: SingleChildScrollView(child: builder(c)),
  ),
);

/// "Compartir mi viaje": la app no guarda una lista de contactos. Se comparte
/// un enlace por servicio, desde la solicitud activa.
Future<void> showTrustedContactInfo(BuildContext context) => _sheet(
  context,
  (c) => Column(
    key: const Key('trusted-contact-sheet'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Compartir mi viaje', style: Theme.of(c).textTheme.titleLarge),
      const SizedBox(height: HySpacing.sm),
      const Text(
        'Cuando un profesional acepta tu solicitud, abre la solicitud y toca "Compartir mi viaje". '
        'Envías un enlace por WhatsApp a la persona que elijas.',
        style: TextStyle(fontSize: 16, height: 1.4),
      ),
      const SizedBox(height: HySpacing.xs),
      const Text(
        'Con el enlace ve el nombre del profesional, si está verificado, el estado del servicio y su ubicación '
        'mientras viene. Nunca ve tu dirección ni tu teléfono. El enlace vence en 12 horas o cuando el trabajo '
        'termina, y puedes anularlo cuando quieras.',
        style: TextStyle(fontSize: 16, height: 1.4),
      ),
      const SizedBox(height: HySpacing.sm),
      const InfoBanner(text: 'La app no guarda una lista de contactos de confianza: eliges a quién enviarlo cada vez.'),
      const SizedBox(height: HySpacing.md),
      SecondaryButton(
        label: 'Ver mis solicitudes',
        icon: Icons.receipt_long_outlined,
        onPressed: () {
          Navigator.pop(c);
          context.go(Routes.requests);
        },
      ),
    ],
  ),
);

/// Personas bloqueadas: se bloquea y desbloquea desde el chat, el perfil o la
/// solicitud (menú ⋮).
Future<void> showBlockedInfo(BuildContext context, int count) => _sheet(
  context,
  (c) => Column(
    key: const Key('blocked-sheet'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Personas bloqueadas', style: Theme.of(c).textTheme.titleLarge),
      const SizedBox(height: HySpacing.sm),
      Text(
        count == 0
            ? 'No bloqueaste a nadie.'
            : count == 1
            ? 'Bloqueaste a 1 persona.'
            : 'Bloqueaste a $count personas.',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: HySpacing.xs),
      const Text(
        'Para bloquear o desbloquear a alguien, abre su perfil, el chat o la solicitud y toca el menú ⋮. '
        'Con una persona bloqueada no pueden escribirse y no se envían pedidos ¡Ya! entre ustedes.',
        style: TextStyle(fontSize: 16, height: 1.4),
      ),
    ],
  ),
);

/// "Reportar un problema de seguridad": se elige el servicio (así el equipo
/// tiene todos los datos) o se escribe al equipo si no fue en un servicio.
Future<void> showSafetyReportSheet(BuildContext context, {required bool asProfessional}) =>
    _sheet(context, (c) => _SafetyReport(asProfessional: asProfessional, pageContext: context));

class _SafetyReport extends ConsumerStatefulWidget {
  const _SafetyReport({required this.asProfessional, required this.pageContext});

  final bool asProfessional;
  final BuildContext pageContext;

  @override
  ConsumerState<_SafetyReport> createState() => _SafetyReportState();
}

class _SafetyReportState extends ConsumerState<_SafetyReport> {
  final _body = TextEditingController();
  bool _writing = false;
  bool _sending = false;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_body.text.trim().length < 5) {
      showMessage(context, 'Cuéntanos un poco más');
      return;
    }
    setState(() => _sending = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).contactSupport(subject: 'Problema de seguridad', body: _body.text),
      success: 'Recibimos tu mensaje. El equipo lo revisará y te responderá por la app.',
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final bookings = ref.watch(myBookingsProvider(widget.asProfessional));
    final withPerson = [
      for (final b in bookings.value ?? const <BookingSummary>[])
        if (b.otherUserId != null) b,
    ].take(5).toList();
    return Column(
      key: const Key('safety-report-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Reportar un problema de seguridad', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: HySpacing.xs),
        const InfoBanner(
          icon: Icons.local_police_outlined,
          tone: StatusTone.danger,
          text:
              'Si estás en peligro ahora, llama a la Policía al 110. El equipo revisa los reportes, '
              'pero no es una respuesta inmediata.',
        ),
        const SizedBox(height: HySpacing.sm),
        const Text(
          '¿Pasó en un servicio? Elígelo para reportar a la persona. Tu reporte es confidencial.',
          style: TextStyle(fontSize: 16),
        ),
        if (bookings.isLoading && !bookings.hasValue)
          const Padding(
            padding: EdgeInsets.all(HySpacing.md),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (withPerson.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: HySpacing.sm),
            child: Text('Todavía no tienes servicios con otra persona.', style: TextStyle(color: HyColors.textMuted)),
          )
        else
          for (final b in withPerson)
            ListTile(
              key: Key('safety-report-booking-${b.id}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.flag_outlined, color: HyColors.danger),
              title: Text(b.otherName ?? 'Persona del servicio'),
              subtitle: Text('${b.category} · ${b.status.label} · ${b.code}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                showReportSheet(
                  widget.pageContext,
                  userId: b.otherUserId!,
                  name: b.otherName ?? 'esta persona',
                  bookingId: b.id,
                );
              },
            ),
        const Divider(height: HySpacing.lg),
        if (!_writing)
          SecondaryButton(
            key: const Key('safety-report-write'),
            label: 'No fue en un servicio: escribir al equipo',
            icon: Icons.mail_outline,
            onPressed: () => setState(() => _writing = true),
          )
        else ...[
          TextField(
            key: const Key('safety-report-body'),
            controller: _body,
            maxLines: 5,
            minLines: 3,
            maxLength: 3000,
            decoration: const InputDecoration(labelText: 'Cuéntanos qué pasó'),
          ),
          const SizedBox(height: HySpacing.xs),
          PrimaryButton(label: 'Enviar al equipo', loading: _sending, onPressed: _send),
        ],
      ],
    );
  }
}
