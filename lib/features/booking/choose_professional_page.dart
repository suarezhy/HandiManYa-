import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/catalog.dart';
import '../../data/models/professional.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/professional_card.dart';
import 'request_flow_page.dart';

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

/// "Programar para después": el cliente elige quién hará el trabajo y cuándo.
/// La solicitud llega solo a esa persona, que acepta, rechaza o envía una
/// cotización.
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
      appBar: AppBar(title: const Text('Elige quién lo hará')),
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
                  const InfoBanner(
                    icon: Icons.event_available_outlined,
                    text:
                        'Toca a un profesional para elegir el día y la hora. Puede aceptar o enviarte una cotización.',
                  ),
                  const SizedBox(height: HySpacing.md),
                  ...switch (results) {
                    AsyncData(:final value) when value.isEmpty => [
                      EmptyState(
                        icon: Icons.person_search_outlined,
                        title: 'Todavía no hay profesionales de ${a.category.name} en tu ciudad',
                        message: a.category.allowsYa
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
    context.go(Routes.requests);
    context.push(Routes.booking(id));
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
  DateTime? _date;
  TimeOfDay? _time;
  int _duration = 120;
  String? _error;
  bool _sending = false;

  Future<void> _send() async {
    final start = (_date == null || _time == null)
        ? null
        : DateTime(_date!.year, _date!.month, _date!.day, _time!.hour, _time!.minute);
    if (start == null) return setState(() => _error = 'Elige el día y la hora');
    if (start.isBefore(DateTime.now().add(const Duration(minutes: 30)))) {
      return setState(() => _error = 'Elige una hora con al menos 30 minutos de anticipación');
    }
    setState(() {
      _error = null;
      _sending = true;
    });
    final api = ref.read(backendProvider);
    try {
      final id = await api.create(
        widget.args.draft.scheduledWith(professionalId: widget.pro.id, start: start, durationMinutes: _duration),
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
    padding: EdgeInsets.fromLTRB(
      HySpacing.page,
      0,
      HySpacing.page,
      MediaQuery.viewInsetsOf(context).bottom + HySpacing.lg,
    ),
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
