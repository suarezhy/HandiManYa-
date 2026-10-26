import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/env.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/professional.dart';
import '../../data/providers.dart';
import '../../router.dart';

/// Mapa del inicio con los profesionales aprobados y disponibles ahora. Cada
/// punto es aproximado (lo calcula el servidor). Si no hay nadie, en vez de un
/// mapa vacío va un aviso corto.
///
/// Para pedir pocos datos y pocos mosaicos: el mapa no se arrastra ni hace
/// zoom (no compite con el desplazamiento de la página), y la lista se vuelve
/// a pedir cada [refreshEvery] solo mientras el inicio está a la vista y la
/// app abierta.
class HomeMapSection extends ConsumerStatefulWidget {
  const HomeMapSection({super.key});

  static const refreshEvery = Duration(minutes: 2);

  /// Alto del mapa: unos 200-240 px según la pantalla.
  static double heightFor(BuildContext context) => (MediaQuery.sizeOf(context).height * 0.28).clamp(200.0, 240.0);

  @override
  ConsumerState<HomeMapSection> createState() => _HomeMapSectionState();
}

class _HomeMapSectionState extends ConsumerState<HomeMapSection> with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(HomeMapSection.refreshEvery, (_) => _refreshIfVisible());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver a la app, la disponibilidad pudo cambiar.
    if (state == AppLifecycleState.resumed) _refreshIfVisible();
  }

  void _refreshIfVisible() {
    if (!mounted || !TickerMode.valuesOf(context).enabled) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    ref.invalidate(homeMapProvider);
  }

  @override
  Widget build(BuildContext context) {
    final map = ref.watch(homeMapProvider);
    final height = HomeMapSection.heightFor(context);
    final data = map.value;
    if (data != null && data.professionals.isNotEmpty && data.cityLatitude != null) {
      return _LiveMap(key: const Key('home-map'), data: data, height: height);
    }
    if (map.hasError && data == null) {
      return ErrorView(error: map.error!, onRetry: () => ref.invalidate(homeMapProvider));
    }
    if (map.isLoading && data == null) {
      return Container(
        key: const Key('home-map-loading'),
        height: height,
        decoration: BoxDecoration(color: HyColors.surfaceMuted, borderRadius: BorderRadius.circular(HyRadii.xl)),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: HyColors.primary),
      );
    }
    return const _NoneAvailable();
  }
}

class _LiveMap extends ConsumerWidget {
  const _LiveMap({super.key, required this.data, required this.height});

  final HomeMapData data;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiles = ref.watch(mapTileUrlProvider);
    final pros = data.professionals;
    final points = [for (final p in pros) LatLng(p.latitude, p.longitude)];
    final count = pros.length;
    return Semantics(
      container: true,
      label: count == 1
          ? 'Mapa: 1 profesional disponible ahora cerca de ti'
          : 'Mapa: $count profesionales disponibles ahora cerca de ti',
      child: Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HyRadii.xl),
          border: Border.all(color: HyColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            FlutterMap(
              // Si cambian los puntos, el mapa se vuelve a encuadrar.
              key: ValueKey(Object.hashAll([data.cityName, ...points])),
              options: MapOptions(
                initialCenter: LatLng(data.cityLatitude!, data.cityLongitude!),
                initialZoom: 12,
                initialCameraFit: CameraFit.coordinates(
                  coordinates: points,
                  padding: const EdgeInsets.fromLTRB(36, 56, 36, 36),
                  maxZoom: 14,
                  minZoom: 10,
                ),
                backgroundColor: HyColors.surfaceMuted,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              ),
              children: [
                if (tiles != null)
                  TileLayer(
                    urlTemplate: tiles,
                    // Lo pide la política de uso de OpenStreetMap.
                    userAgentPackageName: 'bo.handimanya.handimanya',
                    maxNativeZoom: 19,
                  ),
                MarkerLayer(
                  markers: [
                    for (final p in pros)
                      Marker(
                        point: LatLng(p.latitude, p.longitude),
                        width: 48,
                        height: 48,
                        child: _ProMarker(pro: p),
                      ),
                  ],
                ),
              ],
            ),
            Positioned(
              left: HySpacing.sm,
              top: HySpacing.sm,
              child: _AvailableChip(count: count),
            ),
            if (tiles != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: Semantics(
                  link: true,
                  label: 'Datos del mapa: ${Env.mapAttribution}',
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: () => launchUrl(Uri.parse(Env.mapAttributionUrl), mode: LaunchMode.externalApplication),
                    child: Container(
                      key: const Key('home-map-attribution'),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      color: Colors.white.withValues(alpha: 0.85),
                      child: const Text(
                        Env.mapAttribution,
                        style: TextStyle(fontSize: 11, color: HyColors.textSecondary),
                        textScaler: TextScaler.noScaling,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AvailableChip extends StatelessWidget {
  const _AvailableChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: HyColors.surface,
          borderRadius: BorderRadius.circular(HyRadii.pill),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 6, offset: Offset(0, 2))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(color: HyColors.green, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              count == 1 ? '1 disponible ahora' : '$count disponibles ahora',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              textScaler: TextScaler.noScaling,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProMarker extends StatelessWidget {
  const _ProMarker({required this.pro});

  final MapProfessional pro;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Ver a ${pro.displayName}',
      excludeSemantics: true,
      child: GestureDetector(
        key: Key('home-map-pin-${pro.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => showMapProfessionalPreview(context, pro),
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: HyColors.surface,
              border: Border.all(color: HyColors.primary, width: 3),
              boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 2))],
            ),
            alignment: Alignment.center,
            child: PersonAvatar(name: pro.displayName, url: pro.photoUrl, size: 32),
          ),
        ),
      ),
    );
  }
}

/// Vista previa al tocar un punto: nombre, servicio, calificación y el perfil.
Future<void> showMapProfessionalPreview(BuildContext context, MapProfessional pro) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (sheet) => SafeArea(
    child: Padding(
      key: const Key('home-map-preview'),
      padding: const EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, HySpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PersonAvatar(name: pro.displayName, url: pro.photoUrl, size: 56),
              const SizedBox(width: HySpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pro.displayName, style: Theme.of(sheet).textTheme.titleMedium),
                    if (pro.category != null)
                      Text(pro.category!, style: const TextStyle(color: HyColors.textSecondary)),
                    const SizedBox(height: 2),
                    RatingLabel(rating: pro.ratingAvg, count: pro.ratingCount),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: HySpacing.sm),
          const Row(
            children: [
              Icon(Icons.circle, size: 10, color: HyColors.green),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Disponible ahora. La ubicación del mapa es aproximada.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: HySpacing.md),
          FilledButton(
            key: const Key('home-map-preview-profile'),
            onPressed: () {
              Navigator.pop(sheet);
              context.push(Routes.professional(pro.id));
            },
            style: FilledButton.styleFrom(minimumSize: const Size(0, HySizes.touch)),
            child: const Text('Ver perfil'),
          ),
        ],
      ),
    ),
  ),
);

/// Nadie disponible: un aviso corto en vez de un mapa vacío.
class _NoneAvailable extends StatelessWidget {
  const _NoneAvailable();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key('home-map-empty'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(color: HyColors.primarySoft, shape: BoxShape.circle),
            child: const Icon(Icons.person_search_outlined, size: 20, color: HyColors.primaryDark),
          ),
          const SizedBox(width: HySpacing.sm),
          const Expanded(
            child: Text(
              'Aún no hay profesionales disponibles en tu zona. Puedes solicitar un servicio ahora o '
              'programarlo para después.',
              style: TextStyle(color: HyColors.textSecondary, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
