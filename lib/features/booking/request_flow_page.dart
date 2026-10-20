import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/location_service.dart';
import '../../data/models/geo.dart';
import '../common/photo_picker.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/category_icon.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/catalog.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/city_picker.dart';

/// Pedido de servicio en 3 pasos: qué necesitas → cuéntanos → dónde.
///
/// Sin `professionalId` es un pedido ¡Ya!: llega a todos los profesionales
/// disponibles de la zona y el primero que acepta lo toma. Con
/// `professionalId` va directo a esa persona (ahora o programado).
class RequestFlowPage extends ConsumerStatefulWidget {
  const RequestFlowPage({super.key, this.professionalId, this.initialMode = BookingMode.now, this.initialCategoryId});

  final String? professionalId;
  final BookingMode initialMode;
  final int? initialCategoryId;

  @override
  ConsumerState<RequestFlowPage> createState() => _RequestFlowPageState();
}

class _RequestFlowPageState extends ConsumerState<RequestFlowPage> {
  final _describeForm = GlobalKey<FormState>();
  final _addressForm = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _address = TextEditingController();
  final _reference = TextEditingController();

  late int _step = widget.initialCategoryId == null ? 0 : 1;
  late int? _categoryId = widget.initialCategoryId;
  late BookingMode _mode = widget.initialMode;
  int? _zoneId;
  DateTime? _date;
  TimeOfDay? _time;
  int _duration = 120;
  PaymentMethod _payment = PaymentMethod.cash;
  bool _sending = false;
  String? _scheduleError;
  GeoPoint? _point;
  bool _locating = false;
  List<PhotoUpload> _photos = const [];

  bool get _isYa => widget.professionalId == null;

  @override
  void dispose() {
    for (final c in [_description, _address, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime? get _scheduledStart => (_date == null || _time == null)
      ? null
      : DateTime(_date!.year, _date!.month, _date!.day, _time!.hour, _time!.minute);

  void _next() {
    if (_step == 0 && _categoryId == null) return;
    if (_step == 1) {
      if (!_describeForm.currentState!.validate()) return;
      if (_mode == BookingMode.scheduled) {
        final start = _scheduledStart;
        if (start == null) {
          setState(() => _scheduleError = 'Elige el día y la hora');
          return;
        }
        if (start.isBefore(DateTime.now().add(const Duration(minutes: 30)))) {
          setState(() => _scheduleError = 'Elige una hora con al menos 30 minutos de anticipación');
          return;
        }
      }
      setState(() => _scheduleError = null);
    }
    setState(() => _step++);
  }

  Future<void> _submit() async {
    if (!_addressForm.currentState!.validate()) return;
    final city = ref.read(currentCityProvider);
    if (city == null || _categoryId == null) return;
    setState(() => _sending = true);
    try {
      final id = await ref
          .read(backendProvider)
          .create(
            BookingDraft(
              categoryId: _categoryId!,
              cityId: city.id,
              mode: _mode,
              description: _description.text.trim(),
              address: _address.text.trim(),
              addressReference: _reference.text.trim().isEmpty ? null : _reference.text.trim(),
              zoneId: _zoneId,
              professionalId: widget.professionalId,
              scheduledStart: _mode == BookingMode.scheduled ? _scheduledStart : null,
              durationMinutes: _duration,
              paymentMethod: _payment,
              latitude: _point?.latitude,
              longitude: _point?.longitude,
            ),
          );
      if (_photos.isNotEmpty) {
        try {
          await ref.read(backendProvider).addPhotos(id, _photos);
        } catch (_) {
          if (mounted) {
            showMessage(context, 'Tu pedido se envió, pero no pudimos subir las fotos. Puedes mandarlas por el chat.');
          }
        }
      }
      ref.invalidate(myBookingsProvider(false));
      if (mounted) context.pushReplacement(Routes.booking(id));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _useMyLocation() async {
    if (!await explainLocationUse(context, professional: false) || !mounted) return;
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

  @override
  Widget build(BuildContext context) {
    final titles = ['¿Qué necesitas?', 'Cuéntanos qué pasa', '¿Dónde es?'];
    return PopScope(
      canPop: _step == 0 || (_step == 1 && widget.initialCategoryId != null),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _step--);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isYa ? 'Pedir ¡Ya!' : (_mode == BookingMode.now ? 'Solicitar ahora' : 'Programar servicio')),
        ),
        body: Column(
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: 'Paso ${_step + 1} de 3',
                    excludeSemantics: true,
                    child: Row(
                      children: [
                        for (var i = 0; i < 3; i++)
                          Expanded(
                            child: Container(
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(
                                color: i <= _step ? HyColors.primary : HyColors.border,
                                borderRadius: BorderRadius.circular(HyRadii.pill),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: HySpacing.sm),
                  Text('Paso ${_step + 1} de 3', style: const TextStyle(color: HyColors.textMuted)),
                  Semantics(header: true, child: Text(titles[_step], style: Theme.of(context).textTheme.headlineSmall)),
                ],
              ),
            ),
            const SizedBox(height: HySpacing.sm),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: HySpacing.xl),
                child: PageBody(
                  child: switch (_step) {
                    0 => _categoryStep(),
                    1 => _describeStep(),
                    _ => _addressStep(),
                  },
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: PageBody(
                padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xs, HySpacing.page, HySpacing.md),
                child: _step < 2
                    ? PrimaryButton(label: 'Continuar', onPressed: (_step == 0 && _categoryId == null) ? null : _next)
                    : PrimaryButton(
                        label: _isYa ? 'Pedir ¡Ya!' : 'Enviar solicitud',
                        icon: _isYa ? Icons.bolt_rounded : Icons.send_rounded,
                        loading: _sending,
                        onPressed: _submit,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryStep() {
    final categories = ref.watch(categoriesProvider);
    return categories.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(categoriesProvider)),
      data: (list) => Column(
        children: [
          for (final c in list)
            Padding(
              padding: const EdgeInsets.only(bottom: HySpacing.xs),
              child: _CategoryOption(
                category: c,
                selected: c.id == _categoryId,
                onTap: () => setState(() {
                  _categoryId = c.id;
                  _step = 1;
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _describeStep() {
    final category = (ref.watch(categoriesProvider).value ?? const <ServiceCategory>[])
        .where((c) => c.id == _categoryId)
        .firstOrNull;
    return Form(
      key: _describeForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (category != null) Chip(avatar: Icon(categoryIcon(category.icon), size: 20), label: Text(category.name)),
          const SizedBox(height: HySpacing.sm),
          if (!_isYa) ...[
            SegmentedButton<BookingMode>(
              segments: const [
                ButtonSegment(value: BookingMode.now, icon: Icon(Icons.bolt_rounded), label: Text('Ahora')),
                ButtonSegment(value: BookingMode.scheduled, icon: Icon(Icons.event), label: Text('Programar')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
              style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, HySizes.touch))),
            ),
            const SizedBox(height: HySpacing.md),
          ],
          TextFormField(
            controller: _description,
            minLines: 4,
            maxLines: 8,
            maxLength: 1500,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Describe el problema',
              hintText: 'Ej.: Se rompió la cañería debajo del lavaplatos y está saliendo agua.',
              alignLabelWithHint: true,
            ),
            validator: (v) => (v ?? '').trim().length < 10 ? 'Cuéntanos un poco más (al menos 10 letras)' : null,
          ),
          if (_mode == BookingMode.scheduled) ...[
            const SizedBox(height: HySpacing.md),
            Text('¿Cuándo?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: HySpacing.xs),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: Text(_date == null ? 'Elegir día' : Fmt.shortDate(_date!)),
                    onPressed: () async {
                      final now = DateTime.now();
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _date ?? now,
                        firstDate: now,
                        lastDate: now.add(const Duration(days: 60)),
                        helpText: 'Elige el día',
                      );
                      if (d != null) setState(() => _date = d);
                    },
                  ),
                ),
                const SizedBox(width: HySpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.schedule),
                    label: Text(_time == null ? 'Elegir hora' : _time!.format(context)),
                    onPressed: () async {
                      final t = await showTimePicker(
                        context: context,
                        initialTime: _time ?? const TimeOfDay(hour: 9, minute: 0),
                        helpText: 'Elige la hora',
                      );
                      if (t != null) setState(() => _time = t);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: HySpacing.sm),
            DropdownButtonFormField<int>(
              initialValue: _duration,
              decoration: const InputDecoration(labelText: 'Duración aproximada'),
              items: const [
                DropdownMenuItem(value: 60, child: Text('1 hora')),
                DropdownMenuItem(value: 120, child: Text('2 horas')),
                DropdownMenuItem(value: 240, child: Text('Medio día')),
                DropdownMenuItem(value: 480, child: Text('Día completo')),
              ],
              onChanged: (v) => setState(() => _duration = v ?? 120),
            ),
            if (_scheduleError != null)
              Padding(
                padding: const EdgeInsets.only(top: HySpacing.xs),
                child: Text(_scheduleError!, style: const TextStyle(color: HyColors.danger)),
              ),
            const SizedBox(height: HySpacing.xs),
            const Text('Hora de Bolivia.', style: TextStyle(color: HyColors.textMuted, fontSize: 14)),
          ],
          const SizedBox(height: HySpacing.lg),
          PhotoPickerRow(photos: _photos, onChanged: (p) => setState(() => _photos = p)),
        ],
      ),
    );
  }

  Widget _addressStep() {
    final city = ref.watch(currentCityProvider);
    final zones = city == null ? const <Zone>[] : (ref.watch(zonesProvider(city.id)).value ?? const <Zone>[]);
    return Form(
      key: _addressForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppCard(
            onTap: () => showCityPicker(context, ref),
            child: Row(
              children: [
                const Icon(Icons.location_city, color: HyColors.primary),
                const SizedBox(width: HySpacing.sm),
                Expanded(
                  child: Text(
                    city?.name ?? 'Elige tu ciudad',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                const Text(
                  'Cambiar',
                  style: TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(height: HySpacing.md),
          _GpsCard(
            point: _point,
            locating: _locating,
            onTap: _useMyLocation,
            onClear: () => setState(() => _point = null),
          ),
          const SizedBox(height: HySpacing.md),
          DropdownButtonFormField<int?>(
            initialValue: _zoneId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Zona', prefixIcon: Icon(Icons.map_outlined)),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('No sé / toda la ciudad')),
              for (final z in zones) DropdownMenuItem<int?>(value: z.id, child: Text(z.name)),
            ],
            onChanged: (v) => setState(() => _zoneId = v),
          ),
          const SizedBox(height: HySpacing.md),
          TextFormField(
            controller: _address,
            textCapitalization: TextCapitalization.sentences,
            autofillHints: const [AutofillHints.fullStreetAddress],
            decoration: const InputDecoration(
              labelText: 'Dirección',
              hintText: 'Calle, número y barrio',
              prefixIcon: Icon(Icons.home_outlined),
            ),
            validator: (v) => (v ?? '').trim().length < 5 ? 'Escribe la dirección' : null,
          ),
          const SizedBox(height: HySpacing.md),
          TextFormField(
            controller: _reference,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Referencia (opcional)',
              hintText: 'Ej.: portón negro, frente a la plaza',
              prefixIcon: Icon(Icons.signpost_outlined),
            ),
          ),
          const SizedBox(height: HySpacing.sm),
          const InfoBanner(
            icon: Icons.lock_outline,
            text: 'Tu dirección exacta solo la verá el profesional que acepte tu solicitud.',
          ),
          const SizedBox(height: HySpacing.lg),
          Text('¿Cómo vas a pagar?', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: HySpacing.xs),
          Row(
            children: [
              for (final p in PaymentMethod.values) ...[
                Expanded(
                  child: _PaymentOption(method: p, selected: _payment == p, onTap: () => setState(() => _payment = p)),
                ),
                if (p != PaymentMethod.values.last) const SizedBox(width: HySpacing.sm),
              ],
            ],
          ),
          const SizedBox(height: HySpacing.xs),
          const Text(
            'Pagas directo al profesional cuando termina el trabajo.',
            style: TextStyle(color: HyColors.textMuted, fontSize: 14),
          ),
          if (_isYa && city != null && _categoryId != null) ...[
            const SizedBox(height: HySpacing.lg),
            _AvailableCount(categoryId: _categoryId!, cityId: city.id, zoneId: _zoneId, point: _point),
          ],
        ],
      ),
    );
  }
}

class _CategoryOption extends StatelessWidget {
  const _CategoryOption({required this.category, required this.selected, required this.onTap});

  final ServiceCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = categoryColors(category.icon);
    return Semantics(
      selected: selected,
      child: AppCard(
        onTap: onTap,
        color: selected ? HyColors.primarySoft : null,
        padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(HyRadii.md)),
              child: Icon(categoryIcon(category.icon), color: fg),
            ),
            const SizedBox(width: HySpacing.md),
            Expanded(
              child: Text(category.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            Icon(
              selected ? Icons.check_circle : Icons.chevron_right_rounded,
              color: selected ? HyColors.primary : HyColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentOption extends StatelessWidget {
  const _PaymentOption({required this.method, required this.selected, required this.onTap});

  final PaymentMethod method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? HyColors.primarySoft : HyColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HyRadii.md),
        side: BorderSide(color: selected ? HyColors.primary : HyColors.border, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(HyRadii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: HySpacing.md, horizontal: HySpacing.xs),
          child: Column(
            children: [
              Icon(method.icon, size: 30, color: selected ? HyColors.primaryDark : HyColors.textSecondary),
              const SizedBox(height: 4),
              Text(
                method.label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _GpsCard extends StatelessWidget {
  const _GpsCard({required this.point, required this.locating, required this.onTap, required this.onClear});

  final GeoPoint? point;
  final bool locating;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (point == null) {
      return SecondaryButton(
        label: locating ? 'Buscando tu ubicación…' : 'Usar mi ubicación actual',
        icon: Icons.my_location_rounded,
        onPressed: locating ? null : onTap,
      );
    }
    return AppCard(
      color: HyColors.greenSoft,
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: HyColors.greenDark),
          const SizedBox(width: HySpacing.sm),
          const Expanded(
            child: Text(
              'Ubicación tomada. Buscaremos profesionales cerca de este punto.',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: onClear, child: const Text('Quitar')),
        ],
      ),
    );
  }
}

class _AvailableCount extends ConsumerWidget {
  const _AvailableCount({required this.categoryId, required this.cityId, this.zoneId, this.point});

  final int categoryId;
  final int cityId;
  final int? zoneId;
  final GeoPoint? point;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<int>(
      key: ValueKey('$categoryId-$cityId-$zoneId-${point?.latitude}-${point?.longitude}'),
      future: ref
          .read(backendProvider)
          .countYaAvailable(
            categoryId: categoryId,
            cityId: cityId,
            zoneId: zoneId,
            latitude: point?.latitude,
            longitude: point?.longitude,
          ),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox(height: 48);
        final n = snap.data!;
        return InfoBanner(
          icon: n > 0 ? Icons.bolt_rounded : Icons.hourglass_empty_rounded,
          tone: n > 0 ? StatusTone.success : StatusTone.warning,
          text: n == 0
              ? 'Ahora no hay profesionales disponibles para este servicio en tu zona. Prueba "toda la ciudad" o programa para después.'
              : n == 1
              ? '1 profesional disponible cerca de ti recibirá tu pedido.'
              : '$n profesionales disponibles cerca de ti recibirán tu pedido. El primero que acepte irá.',
        );
      },
    );
  }
}
