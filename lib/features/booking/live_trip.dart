import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/env.dart';
import '../../core/services/location_service.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';

/// Dirección pública del viaje compartido. Vacía: la página web todavía no está
/// publicada y la app no ofrece enviar el enlace (se reemplaza en las pruebas).
final tripShareBaseUrlProvider = Provider<String>((ref) => Env.tripShareUrl);

Uri _mapUrl(double lat, double lng) => Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');

String _ago(DateTime at) {
  final s = DateTime.now().difference(at).inSeconds;
  if (s < 60) return 'hace ${s < 5 ? 'unos segundos' : '$s s'}';
  return 'hace ${s ~/ 60} min';
}

/// Profesional en camino: manda su ubicación con la pantalla abierta (nunca en
/// segundo plano) hasta que el cliente verifica la llegada. Puede pausarla.
class ProTripSharer extends ConsumerStatefulWidget {
  const ProTripSharer({super.key, required this.bookingId});

  final String bookingId;

  static const every = Duration(seconds: 20);

  @override
  ConsumerState<ProTripSharer> createState() => _ProTripSharerState();
}

class _ProTripSharerState extends ConsumerState<ProTripSharer> {
  Timer? _timer;
  bool _paused = false;
  DateTime? _lastSent;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    _send();
    _timer = Timer.periodic(ProTripSharer.every, (_) => _send());
  }

  Future<void> _send() async {
    try {
      final p = await ref.read(locationServiceProvider).current();
      await ref.read(backendProvider).shareTripLocation(widget.bookingId, p);
      if (mounted) {
        setState(() {
          _lastSent = DateTime.now();
          _problem = null;
        });
      }
    } catch (e) {
      final err = AppError.from(e);
      // Si el pedido ya no está en camino (llegada verificada), se deja de mandar.
      if (err.code == 'HMY_TRIP_NOT_ACTIVE') {
        _timer?.cancel();
        return;
      }
      if (mounted) setState(() => _problem = err.message);
    }
  }

  Future<void> _toggle(bool share) async {
    setState(() => _paused = !share);
    if (share) {
      _start();
    } else {
      _timer?.cancel();
      await runGuarded(context, () => ref.read(backendProvider).stopTripLocation(widget.bookingId));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.sm),
    child: AppCard(
      key: const Key('pro-trip-sharer'),
      color: _paused ? null : HyColors.primarySoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _paused ? Icons.location_off_outlined : Icons.share_location_rounded,
                color: HyColors.primaryDark,
                size: 28,
              ),
              const SizedBox(width: HySpacing.sm),
              Expanded(
                child: Text(
                  _paused ? 'Ubicación en pausa' : 'Compartiendo tu ubicación con el cliente',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              Switch(key: const Key('pro-trip-switch'), value: !_paused, onChanged: _toggle),
            ],
          ),
          Text(
            _paused
                ? 'El cliente no ve dónde estás. Actívala para que sepa que vas en camino.'
                : 'Solo mientras vas en camino y con esta pantalla abierta. Se apaga sola cuando el cliente '
                      'verifica tu llegada.',
            style: const TextStyle(color: HyColors.textSecondary),
          ),
          if (!_paused && _problem != null)
            Padding(
              padding: const EdgeInsets.only(top: HySpacing.xs),
              child: Text(
                '$_problem El cliente ve tu última ubicación.',
                style: const TextStyle(color: HyColors.danger),
              ),
            )
          else if (!_paused && _lastSent != null)
            Padding(
              padding: const EdgeInsets.only(top: HySpacing.xs),
              child: Text('Enviada ${_ago(_lastSent!)}', style: const TextStyle(color: HyColors.textMuted)),
            ),
        ],
      ),
    ),
  );
}

/// Cliente: dónde va el profesional, a qué distancia y en cuánto llegaría.
class CustomerTripCard extends ConsumerStatefulWidget {
  const CustomerTripCard({super.key, required this.bookingId});

  final String bookingId;

  static const every = Duration(seconds: 15);

  @override
  ConsumerState<CustomerTripCard> createState() => _CustomerTripCardState();
}

class _CustomerTripCardState extends ConsumerState<CustomerTripCard> {
  Timer? _timer;
  TripLocation? _trip;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(CustomerTripCard.every, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await ref.read(backendProvider).tripLocation(widget.bookingId);
      if (mounted) {
        setState(() {
          _trip = t;
          _failed = false;
        });
      }
      if (!t.live) _timer?.cancel();
    } catch (_) {
      // Mala conexión: se mantiene lo último que se vio y se reintenta.
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _trip;
    if (t == null || !t.live) return const SizedBox.shrink();
    final String title;
    final String detail;
    if (!t.hasPoint) {
      title = 'Tu profesional va en camino';
      detail = 'Todavía no recibimos su ubicación. Aparecerá aquí cuando la comparta.';
    } else {
      title = [
        if (t.distanceKm != null) 'A ${t.distanceKm!.toStringAsFixed(1).replaceAll('.', ',')} km',
        if (t.etaMinutes != null) 'unos ${t.etaMinutes} min',
      ].join(' · ');
      detail = t.stale
          ? 'No recibimos su ubicación hace un rato (puede ser la señal). Última: ${_ago(t.updatedAt!)}.'
          : 'Actualizada ${_ago(t.updatedAt!)}. El tiempo es aproximado.';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: HySpacing.sm),
      child: AppCard(
        key: const Key('customer-trip'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_car_filled_outlined, color: HyColors.primaryDark, size: 28),
                const SizedBox(width: HySpacing.sm),
                Expanded(
                  child: Text(
                    title.isEmpty ? 'Tu profesional va en camino' : title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(detail, style: const TextStyle(color: HyColors.textSecondary)),
            if (_failed) const Text('Sin conexión: reintentando…', style: TextStyle(color: HyColors.textMuted)),
            if (t.hasPoint) ...[
              const SizedBox(height: HySpacing.sm),
              SecondaryButton(
                label: 'Ver en el mapa',
                icon: Icons.map_outlined,
                onPressed: () async {
                  final ok = await launchUrl(_mapUrl(t.latitude!, t.longitude!), mode: LaunchMode.externalApplication);
                  if (!ok && context.mounted) showMessage(context, 'No pudimos abrir el mapa.');
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Compartir mi viaje": el cliente manda por WhatsApp (desde su teléfono) un
/// enlace para que un contacto de confianza siga el servicio.
Future<void> showShareTripSheet(BuildContext context, BookingDetail b) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (c) => _ShareTripSheet(b: b),
);

class _ShareTripSheet extends ConsumerStatefulWidget {
  const _ShareTripSheet({required this.b});

  final BookingDetail b;

  @override
  ConsumerState<_ShareTripSheet> createState() => _ShareTripSheetState();
}

class _ShareTripSheetState extends ConsumerState<_ShareTripSheet> {
  final _name = TextEditingController();
  bool _busy = false;
  List<TripShare> _shares = const [];

  @override
  void initState() {
    super.initState();
    _loadShares();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadShares() async {
    try {
      final s = await ref.read(backendProvider).tripShares(widget.b.id);
      if (mounted) setState(() => _shares = s);
    } catch (_) {}
  }

  Future<void> _share() async {
    final base = ref.read(tripShareBaseUrlProvider);
    setState(() => _busy = true);
    await runGuarded(context, () async {
      final token = await ref.read(backendProvider).createTripShare(widget.b.id, contactName: _name.text);
      final pro = widget.b.professional?.displayName ?? 'el profesional';
      final text =
          'Te comparto mi servicio de HandiMan ¡Ya! (${widget.b.category}) con $pro. '
          'Aquí puedes ver si va en camino y cuándo se verifica su llegada: $base/viaje/$token';
      final ok = await launchUrl(
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw const AppError('No pudimos abrir WhatsApp. ¿Está instalado en tu teléfono?');
    });
    await _loadShares();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(tripShareBaseUrlProvider).isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
      // Con letra grande en celulares chicos no entra: se desplaza.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Compartir mi viaje', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: HySpacing.xs),
            const Text(
              'Manda un enlace por WhatsApp a alguien de confianza. Verá quién te atiende, si va en camino y '
              'cuándo se verifica su llegada. No verá tu dirección ni tu teléfono. El enlace vence cuando termina '
              'el trabajo, y puedes anularlo cuando quieras.',
              style: TextStyle(fontSize: 16, color: HyColors.textSecondary),
            ),
            const SizedBox(height: HySpacing.md),
            if (!ready)
              const InfoBanner(
                icon: Icons.schedule,
                tone: StatusTone.warning,
                text: 'Muy pronto: estamos preparando la página que verá tu contacto.',
              )
            else ...[
              TextField(
                key: const Key('share-contact-name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '¿A quién se lo mandas? (opcional)', counterText: ''),
              ),
              const SizedBox(height: HySpacing.sm),
              PrimaryButton(
                key: const Key('share-whatsapp'),
                label: 'Enviar por WhatsApp',
                icon: Icons.send_rounded,
                loading: _busy,
                onPressed: _share,
              ),
            ],
            if (_shares.isNotEmpty) ...[
              const SizedBox(height: HySpacing.md),
              const Text('Compartido con', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final s in _shares)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text(s.contactName ?? 'Contacto'),
                  subtitle: Text(s.viewedAt == null ? 'Todavía no lo abrió' : 'Lo abrió ${_ago(s.viewedAt!)}'),
                  trailing: TextButton(
                    onPressed: () async {
                      final ok = await runGuarded(
                        context,
                        () => ref.read(backendProvider).revokeTripShare(s.id),
                        success: 'Enlace anulado',
                      );
                      if (ok) await _loadShares();
                    },
                    child: const Text('Anular'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Página pública del enlace: la abre el contacto de confianza, sin cuenta.
class TripSharePage extends ConsumerWidget {
  const TripSharePage({super.key, required this.token});

  final String token;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(_sharedTripProvider(token));
    return Scaffold(
      appBar: AppBar(title: const BrandLogo(height: 28), centerTitle: true, automaticallyImplyLeading: false),
      body: trip.when(
        loading: () => const LoadingView(),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(HySpacing.page),
            child: Text(AppError.from(e).message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
          ),
        ),
        data: (t) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(_sharedTripProvider(token)),
          child: ListView(
            padding: const EdgeInsets.all(HySpacing.page),
            children: [
              Text(
                '${t.customerFirstName} compartió su servicio contigo',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: HySpacing.md),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.professionalName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                    if (t.professionalVerified) const VerifiedBadge(compact: true),
                    Text('${t.category} · Solicitud ${t.code}', style: const TextStyle(color: HyColors.textSecondary)),
                    const SizedBox(height: HySpacing.sm),
                    Text(
                      t.arrivalVerifiedAt != null ? 'Llegada verificada' : t.status.label,
                      key: const Key('shared-status'),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    if (t.trip case final trip? when trip.hasPoint) ...[
                      Text(
                        'Ubicación actualizada ${_ago(trip.updatedAt!)}',
                        style: const TextStyle(color: HyColors.textMuted),
                      ),
                      const SizedBox(height: HySpacing.sm),
                      SecondaryButton(
                        label: 'Ver en el mapa',
                        icon: Icons.map_outlined,
                        onPressed: () =>
                            launchUrl(_mapUrl(trip.latitude!, trip.longitude!), mode: LaunchMode.externalApplication),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: HySpacing.md),
              const Text(
                'Si algo te preocupa, llama a la persona que te compartió este enlace. Ante una emergencia, '
                'llama a la Policía (110).',
                style: TextStyle(color: HyColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final _sharedTripProvider = FutureProvider.autoDispose.family<SharedTrip, String>(
  (ref, token) => ref.watch(backendProvider).sharedTrip(token),
);
