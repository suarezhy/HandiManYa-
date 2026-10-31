import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/catalog.dart';
import '../../data/models/professional.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/professional_card.dart';
import 'request_flow_page.dart';
import '../../core/widgets/word_safe_text.dart';

/// Lo que el pedido ya tiene cuando el cliente elige "Programar para después".
class ChooseProfessionalArgs {
  const ChooseProfessionalArgs({
    required this.draft,
    required this.category,
    required this.problems,
    this.photos = const [],
  });

  final BookingDraft draft;
  final ServiceCategory category;
  final List<String> problems;
  final List<PhotoUpload> photos;
}

/// "Programar para después": el cliente ya eligió el día y la hora. Puede
/// publicar la solicitud para los profesionales de su zona (queda "Pendiente de
/// profesional" hasta que alguien la acepta) o elegir a una persona, que acepta,
/// rechaza o envía una cotización.
class ChooseProfessionalPage extends ConsumerWidget {
  const ChooseProfessionalPage({super.key, required this.args});

  final ChooseProfessionalArgs? args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = args;
    if (a == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          icon: Icons.refresh,
          title: 'Vuelve a empezar tu pedido',
          action: PrimaryButton(label: 'Ir al inicio', expand: false, onPressed: () => context.go(Routes.home)),
        ),
      );
    }
    final filters = SearchFilters(cityId: a.draft.cityId, categoryId: a.draft.categoryId);
    final results = ref.watch(searchResultsProvider(filters));
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Elige quién lo hará')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(searchResultsProvider(filters).future),
        child: ListView(
          padding: bottomSafePadding(context),
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(a.category.name, style: Theme.of(context).textTheme.titleLarge),
                  if (a.problems.isNotEmpty)
                    Text(a.problems.join(' · '), style: const TextStyle(color: HyColors.textSecondary, fontSize: 16)),
                  const SizedBox(height: HySpacing.sm),
                  if (a.draft.scheduledStart != null) ...[
                    _PublishCard(args: a),
                    const SizedBox(height: HySpacing.md),
                    const InfoBanner(
                      icon: Icons.person_search_outlined,
                      text: 'O elige a un profesional: la solicitud le llega solo a esa persona.',
                    ),
                  ] else
                    const InfoBanner(
                      icon: Icons.event_available_outlined,
                      text: 'Toca a un profesional para elegir el día y la hora. Puede aceptar o enviarte una cotización.',
                    ),
                  const SizedBox(height: HySpacing.md),
                  ...switch (results) {
                    AsyncData(:final value) when value.isEmpty => [
                      EmptyState(
                        icon: Icons.person_search_outlined,
                        title: 'Todavía no hay profesionales de ${a.category.name} en tu ciudad',
                        message: a.draft.scheduledStart != null
                            ? 'Publica la solicitud y te avisamos cuando alguien la acepte.'
                            : a.category.allowsYa
                            ? 'Vuelve atrás y prueba con "Lo necesito ¡Ya!".'
                            : 'Vuelve a intentarlo más tarde.',
                      ),
                    ],
                    AsyncData(:final value) => [
                      for (final p in value)
                        Padding(
                          padding: const EdgeInsets.only(bottom: HySpacing.sm),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ProfessionalCard(pro: p, onTap: () => _schedule(context, ref, a, p)),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () => context.push(Routes.professional(p.id)),
                                  child: Text('Ver perfil de ${p.displayName.split(' ').first}'),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    AsyncError(:final error) => [
                      ErrorView(error: error, onRetry: () => ref.invalidate(searchResultsProvider(filters))),
                    ],
                    _ => [const LoadingView()],
                  },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _schedule(BuildContext context, WidgetRef ref, ChooseProfessionalArgs a, ProfessionalSummary pro) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ScheduleSheet(args: a, pro: pro),
    );
    if (id == null || !context.mounted) return;
    ref.invalidate(myBookingsProvider(false));
    openNewBooking(context, id);
  }
}

/// Después de enviar: Mis solicitudes con la nueva abierta encima, así "Atrás"
/// vuelve a la lista y no al formulario. El push espera a que la lista esté.
void openNewBooking(BuildContext context, String id) {
  final router = GoRouter.of(context);
  router.go(Routes.requests);
  WidgetsBinding.instance.addPostFrameCallback((_) => router.push(Routes.booking(id)));
}

/// Publicar sin elegir profesional: queda "Pendiente de profesional".
class _PublishCard extends ConsumerStatefulWidget {
  const _PublishCard({required this.args});

  final ChooseProfessionalArgs args;

  @override
  ConsumerState<_PublishCard> createState() => _PublishCardState();
}

class _PublishCardState extends ConsumerState<_PublishCard> {
  bool _sending = false;

  Future<void> _publish() async {
    if (_sending) return;
    setState(() => _sending = true);
    final api = ref.read(backendProvider);
    try {
      final id = await api.create(widget.args.draft);
      if (widget.args.photos.isNotEmpty) {
        try {
          await api.addPhotos(id, widget.args.photos);
        } catch (_) {
          if (mounted) {
            showMessage(context, 'Tu pedido se envió, pero no pudimos subir las fotos. Puedes mandarlas por el chat.');
          }
        }
      }
      ref.invalidate(myBookingsProvider(false));
      if (!mounted) return;
      showMessage(context, 'Solicitud publicada. Queda pendiente hasta que un profesional la acepte.');
      openNewBooking(context, id);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.args.draft;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.event_outlined, color: HyColors.navy),
              const SizedBox(width: HySpacing.xs),
              Expanded(
                child: Text(
                  Fmt.dateTime(d.scheduledStart!),
                  key: const Key('schedule-when'),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: HySpacing.xxs),
          const Text(
            'Queda pendiente hasta que un profesional la acepte.',
            style: TextStyle(color: HyColors.textSecondary, fontSize: 15),
          ),
          const SizedBox(height: HySpacing.sm),
          PrimaryButton(
            key: const Key('schedule-publish'),
            label: 'Publicar solicitud',
            icon: Icons.send_rounded,
            loading: _sending,
            onPressed: _publish,
          ),
        ],
      ),
    );
  }
}

class _ScheduleSheet extends ConsumerStatefulWidget {
  const _ScheduleSheet({required this.args, required this.pro});

  final ChooseProfessionalArgs args;
  final ProfessionalSummary pro;

  @override
  ConsumerState<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<_ScheduleSheet> {
  // Empieza con el día y la hora que el cliente ya eligió.
  late DateTime? _date = widget.args.draft.scheduledStart;
  late TimeOfDay? _time = _date == null ? null : TimeOfDay.fromDateTime(_date!);
  late int _duration = widget.args.draft.scheduledStart == null ? 120 : widget.args.draft.durationMinutes;
  String? _error;
  bool _sending = false;

  Future<void> _send() async {
    final start = (_date == null || _time == null)
        ? null
        : DateTime(_date!.year, _date!.month, _date!.day, _time!.hour, _time!.minute);
    final error = scheduleError(start);
    if (error != null) return setState(() => _error = error);
    setState(() {
      _error = null;
      _sending = true;
    });
    final api = ref.read(backendProvider);
    try {
      final id = await api.create(
        widget.args.draft.scheduledWith(professionalId: widget.pro.id, start: start!, durationMinutes: _duration),
      );
      if (widget.args.photos.isNotEmpty) {
        try {
          await api.addPhotos(id, widget.args.photos);
        } catch (_) {
          if (mounted) {
            showMessage(context, 'Tu pedido se envió, pero no pudimos subir las fotos. Puedes mandarlas por el chat.');
          }
        }
      }
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('¿Cuándo vendría ${widget.pro.displayName}?', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: HySpacing.md),
          ScheduleFields(
            date: _date,
            time: _time,
            duration: _duration,
            error: _error,
            onDate: (d) => setState(() => _date = d),
            onTime: (t) => setState(() => _time = t),
            onDuration: (d) => setState(() => _duration = d),
          ),
          const SizedBox(height: HySpacing.md),
          PrimaryButton(label: 'Enviar solicitud', icon: Icons.send_rounded, loading: _sending, onPressed: _send),
        ],
      ),
    ),
  );
}
