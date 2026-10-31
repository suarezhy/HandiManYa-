import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/location_service.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/geo.dart';
import '../../data/providers.dart';
import '../../core/widgets/word_safe_text.dart';

final serviceLocationProvider = FutureProvider.autoDispose<ServiceLocation?>(
  (ref) => ref.watch(backendProvider).serviceLocation(),
);

/// Base y radio de trabajo: definen qué pedidos ¡Ya! le llegan al profesional.
class ServiceAreaPage extends ConsumerWidget {
  const ServiceAreaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(serviceLocationProvider);
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Mi zona de trabajo')),
      body: current.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(serviceLocationProvider)),
        data: (loc) => _Form(initial: loc),
      ),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({required this.initial});

  final ServiceLocation? initial;

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  late GeoPoint? _point = widget.initial == null ? null : GeoPoint(widget.initial!.latitude, widget.initial!.longitude);
  late double _radius = (widget.initial?.radiusKm ?? 10).toDouble();
  bool _locating = false;
  bool _saving = false;

  Future<void> _locate() async {
    if (!await explainLocationUse(context, professional: true) || !mounted) return;
    setState(() => _locating = true);
    try {
      final p = await ref.read(locationServiceProvider).current();
      if (mounted) setState(() => _point = p);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    final p = _point;
    if (p == null) return;
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => ref
          .read(backendProvider)
          .setServiceLocation(latitude: p.latitude, longitude: p.longitude, radiusKm: _radius.round()),
      success: 'Zona de trabajo guardada',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(serviceLocationProvider);
      if (context.canPop()) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: bottomSafePadding(context, top: HySpacing.md, bottom: HySpacing.md),
      children: [
        PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Te llegarán pedidos ¡Ya! que estén dentro de esta distancia desde tu punto de partida.',
                style: text.bodyLarge,
              ),
              const SizedBox(height: HySpacing.md),
              AppCard(
                color: _point == null ? null : HyColors.greenSoft,
                child: Row(
                  children: [
                    Icon(
                      _point == null ? Icons.location_off_outlined : Icons.check_circle,
                      color: _point == null ? HyColors.textMuted : HyColors.greenDark,
                    ),
                    const SizedBox(width: HySpacing.sm),
                    Expanded(
                      child: Text(
                        _point == null
                            ? 'Todavía no marcaste tu punto de partida. Mientras tanto, recibes pedidos según tus zonas.'
                            : 'Punto de partida guardado.',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: HySpacing.sm),
              SecondaryButton(
                label: _locating ? 'Buscando tu ubicación…' : (_point == null ? 'Usar mi ubicación' : 'Actualizar'),
                icon: Icons.my_location_rounded,
                onPressed: _locating ? null : _locate,
              ),
              const SectionHeader(title: '¿Hasta qué distancia vas?'),
              Text('${_radius.round()} km', style: text.headlineSmall?.copyWith(color: HyColors.primaryDark)),
              Slider(
                value: _radius,
                min: 1,
                max: 30,
                divisions: 29,
                label: '${_radius.round()} km',
                activeColor: HyColors.primary,
                onChanged: (v) => setState(() => _radius = v),
              ),
              const InfoBanner(
                icon: Icons.lock_outline,
                text: 'Los clientes no ven tu punto de partida. Solo lo usamos para calcular distancias.',
              ),
              const SizedBox(height: HySpacing.xl),
              PrimaryButton(label: 'Guardar', loading: _saving, onPressed: _point == null ? null : _save),
            ],
          ),
        ),
      ],
    );
  }
}
