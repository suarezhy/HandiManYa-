import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/location_service.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/bolivia_geo.dart';
import '../../core/utils/category_order.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/text_fit.dart';
import '../../core/widgets/button_row.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/category_icon.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/problem_icon.dart';
import '../../data/models/booking.dart';
import '../../data/models/catalog.dart';
import '../../data/models/geo.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/city_picker.dart';
import '../common/photo_picker.dart';
import '../common/unsaved_changes.dart';
import 'choose_professional_page.dart';
import '../../core/widgets/word_safe_text.dart';

enum _Step { category, problems, details, place }

/// Pedido de servicio: (categoría) → ¿qué necesitas solucionar? → cuéntanos →
/// ¿dónde es?
///
/// Sin `professionalId` termina con dos caminos: "Lo necesito ¡Ya!" (llega a
/// todos los profesionales disponibles de la zona y el primero que acepta lo
/// toma) o "Programar para después" (el cliente elige a la persona y el
/// horario). Con `professionalId` va directo a esa persona.
class RequestFlowPage extends ConsumerStatefulWidget {
  const RequestFlowPage({super.key, this.professionalId, this.initialMode = BookingMode.now, this.initialCategoryId});

  final String? professionalId;
  final BookingMode initialMode;
  final int? initialCategoryId;

  @override
  ConsumerState<RequestFlowPage> createState() => _RequestFlowPageState();
}

class _RequestFlowPageState extends ConsumerState<RequestFlowPage> {
  final _problemsForm = GlobalKey<FormState>();
  final _describeForm = GlobalKey<FormState>();
  final _addressForm = GlobalKey<FormState>();
  final _otherText = TextEditingController();
  final _description = TextEditingController();
  final _address = TextEditingController();
  final _reference = TextEditingController();
  final _destination = TextEditingController();
  final _categorySearch = TextEditingController();
  String _categoryQuery = '';

  late final _steps = [
    if (widget.initialCategoryId == null) _Step.category,
    _Step.problems,
    _Step.details,
    _Step.place,
  ];
  int _index = 0;
  late int? _categoryId = widget.initialCategoryId;
  final _selected = <int>{};
  late BookingMode _mode = widget.initialMode;
  int? _zoneId;

  /// Municipio donde se hace el servicio. Es de este pedido: empieza en la
  /// ciudad del cliente, pero puede ser cualquier municipio de Bolivia y no
  /// cambia la ciudad guardada del cliente.
  int? _serviceCityId;

  /// Aviso cuando el GPS da un punto fuera de Bolivia.
  String? _gpsNotice;
  DateTime? _date;
  TimeOfDay? _time;
  int _duration = 120;
  PaymentMethod _payment = PaymentMethod.cash;
  bool _sending = false;
  String? _scheduleError;
  GeoPoint? _point;
  bool _locating = false;
  List<PhotoUpload> _photos = const [];

  /// Grúa: tipo de vehículo (obligatorio) y destino.
  String? _vehicle;
  String? _vehicleError;
  static const vehicleTypes = ['Auto', 'Camioneta', 'Moto', 'Minibús', 'Camión'];

  bool get _isYa => widget.professionalId == null;

  /// Ya hay algo del pedido que se perdería al salir.
  bool get _dirty =>
      _index > 0 ||
      _categoryId != widget.initialCategoryId ||
      _selected.isNotEmpty ||
      _photos.isNotEmpty ||
      [_otherText, _description, _address, _reference, _destination].any((c) => c.text.trim().isNotEmpty);
  _Step get _step => _steps[_index];

  @override
  void dispose() {
    for (final c in [_otherText, _description, _address, _reference, _destination, _categorySearch]) {
      c.dispose();
    }
    super.dispose();
  }

  ServiceCategory? get _category =>
      (ref.read(categoriesProvider).value ?? const <ServiceCategory>[]).where((c) => c.id == _categoryId).firstOrNull;

  List<ServiceProblem> get _problems =>
      _categoryId == null ? const [] : (ref.read(problemsProvider(_categoryId!)).value ?? const []);

  bool get _isTow => _category?.slug == 'grua';

  /// Una opción que lleva a otra categoría (en Mecánica, "Grúa"): se pasa a
  /// esa categoría y se eligen sus opciones.
  void _openCategory(int id) => setState(() {
    _categoryId = id;
    _selected.clear();
    _otherText.clear();
  });

  bool get _otherSelected => _problems.any((p) => p.isOther && _selected.contains(p.id));

  DateTime? get _scheduledStart => (_date == null || _time == null)
      ? null
      : DateTime(_date!.year, _date!.month, _date!.day, _time!.hour, _time!.minute);

  void _chooseCategory(int id) => setState(() {
    if (_categoryId != id) {
      _selected.clear();
      _otherText.clear();
    }
    _categoryId = id;
    _index++;
  });

  void _next() {
    switch (_step) {
      case _Step.category:
        if (_categoryId == null) return;
      case _Step.problems:
        final formOk = _problemsForm.currentState!.validate();
        if (_isTow) setState(() => _vehicleError = _vehicle == null ? 'Elige el tipo de vehículo' : null);
        if (_selected.isEmpty || !formOk || (_isTow && _vehicle == null)) return;
      case _Step.details:
        if (!_describeForm.currentState!.validate()) return;
        if (!_isYa && _mode == BookingMode.scheduled) {
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
      case _Step.place:
        return;
    }
    setState(() => _index++);
  }

  /// El municipio del servicio: el elegido en el paso 4 o, si no se cambió,
  /// la ciudad del cliente.
  int? get _serviceCity => _serviceCityId ?? ref.read(currentCityProvider)?.id;

  void _setServiceCity(int id) => setState(() {
    if (id != _serviceCity) _zoneId = null;
    _serviceCityId = id;
  });

  BookingDraft? _draft({required BookingMode mode}) {
    final cityId = _serviceCity;
    if (cityId == null || _categoryId == null) return null;
    return BookingDraft(
      categoryId: _categoryId!,
      cityId: cityId,
      mode: mode,
      description: _isTow ? 'Vehículo: $_vehicle. ${_description.text.trim()}'.trim() : _description.text.trim(),
      address: _address.text.trim(),
      addressReference: _reference.text.trim().isEmpty ? null : _reference.text.trim(),
      zoneId: _zoneId,
      professionalId: widget.professionalId,
      scheduledStart: mode == BookingMode.scheduled ? _scheduledStart : null,
      durationMinutes: _duration,
      paymentMethod: _payment,
      latitude: _point?.latitude,
      longitude: _point?.longitude,
      problemIds: [
        for (final p in _problems)
          if (_selected.contains(p.id)) p.id,
      ],
      otherText: _otherSelected ? _otherText.text.trim() : null,
      destination: _isTow ? _destination.text.trim() : null,
    );
  }

  List<String> get _selectedLabels => [
    for (final p in _problems)
      if (_selected.contains(p.id)) p.isOther ? '${p.name}: ${_otherText.text.trim()}' : p.name,
  ];

  Future<void> _submit() async {
    if (!_addressForm.currentState!.validate()) return;
    final draft = _draft(mode: _isYa ? BookingMode.now : _mode);
    if (draft == null) return;
    setState(() => _sending = true);
    try {
      final id = await ref.read(backendProvider).create(draft);
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

  void _scheduleLater() {
    if (!_addressForm.currentState!.validate()) return;
    final draft = _draft(mode: BookingMode.scheduled);
    final category = _category;
    if (draft == null || category == null) return;
    context.push(
      Routes.chooseProfessional,
      extra: ChooseProfessionalArgs(draft: draft, category: category, problems: _selectedLabels, photos: _photos),
    );
  }

  Future<void> _useMyLocation() async {
    if (!await explainLocationUse(context, professional: false) || !mounted) return;
    setState(() => _locating = true);
    try {
      final p = await ref.read(locationServiceProvider).current();
      final cities = await ref.read(citiesProvider.future);
      if (!mounted) return;
      final fix = resolveGpsFix(p, cities);
      setState(() {
        _point = fix.point;
        _gpsNotice = fix.outsideBolivia ? outsideBoliviaMessage : null;
        final city = fix.city;
        if (city != null) {
          if (city.id != _serviceCity) _zoneId = null;
          _serviceCityId = city.id;
        }
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  String get _title => switch (_step) {
    _Step.category => '¿Qué servicio necesitas?',
    _Step.problems => '¿Qué necesitas solucionar?',
    _Step.details => 'Cuéntanos más',
    _Step.place => '¿Dónde es?',
  };

  @override
  Widget build(BuildContext context) {
    final category = (ref.watch(categoriesProvider).value ?? const <ServiceCategory>[])
        .where((c) => c.id == _categoryId)
        .firstOrNull;
    final total = _steps.length;
    // Atrás vuelve al paso anterior; en el primero, si ya se eligió o escribió
    // algo, pregunta antes de salir.
    return UnsavedChangesScope(
      dirty: _dirty,
      stepBack: _index > 0 ? () => setState(() => _index--) : null,
      message: 'Tu pedido todavía no se envió. Si sales ahora, se pierde lo que elegiste y escribiste.',
      child: Scaffold(
        appBar: AppBar(
          title: OneLineText(
            widget.professionalId != null
                ? (_mode == BookingMode.now ? 'Solicitar ahora' : 'Programar servicio')
                : (category?.name ?? 'Pedir ¡Ya!'),
          ),
        ),
        body: Column(
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: 'Paso ${_index + 1} de $total',
                    excludeSemantics: true,
                    child: Row(
                      children: [
                        for (var i = 0; i < total; i++)
                          Expanded(
                            child: Container(
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(
                                color: i <= _index ? HyColors.primary : HyColors.border,
                                borderRadius: BorderRadius.circular(HyRadii.pill),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: HySpacing.sm),
                  Text('Paso ${_index + 1} de $total', style: const TextStyle(color: HyColors.textMuted)),
                  Semantics(header: true, child: Text(_title, style: Theme.of(context).textTheme.headlineSmall)),
                ],
              ),
            ),
            const SizedBox(height: HySpacing.sm),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: HySpacing.xl),
                child: PageBody(
                  child: switch (_step) {
                    _Step.category => _categoryStep(),
                    _Step.problems => _problemStep(category),
                    _Step.details => _describeStep(category),
                    _Step.place => _addressStep(category),
                  },
                ),
              ),
            ),
            // Botones fijos abajo, sobre la zona de gestos/navegación del
            // teléfono; el contenido se desplaza por encima y nunca queda tapado.
            DecoratedBox(
              decoration: const BoxDecoration(
                color: HyColors.surface,
                border: Border(top: BorderSide(color: HyColors.border)),
              ),
              child: SafeArea(
                top: false,
                child: PageBody(
                  padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.page, HySpacing.sm),
                  child: _actions(category),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(ServiceCategory? category) {
    if (_step != _Step.place) {
      final enabled = switch (_step) {
        _Step.category => _categoryId != null,
        _Step.problems => _selected.isNotEmpty,
        _ => true,
      };
      return PrimaryButton(label: 'Continuar', onPressed: enabled ? _next : null);
    }
    if (!_isYa) {
      return PrimaryButton(label: 'Enviar solicitud', icon: Icons.send_rounded, loading: _sending, onPressed: _submit);
    }
    final allowsYa = category?.allowsYa ?? true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (allowsYa) ...[
          PrimaryButton(label: 'Lo necesito ¡Ya!', icon: Icons.bolt_rounded, loading: _sending, onPressed: _submit),
          const SizedBox(height: HySpacing.xs),
          SecondaryButton(label: 'Programar', icon: Icons.event_outlined, onPressed: _sending ? null : _scheduleLater),
        ] else
          PrimaryButton(label: 'Elegir profesional', icon: Icons.event_outlined, onPressed: _scheduleLater),
      ],
    );
  }

  Widget _categoryStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _CategorySearchField(controller: _categorySearch, onChanged: (q) => setState(() => _categoryQuery = q)),
      const SizedBox(height: HySpacing.sm),
      _categoryList(),
    ],
  );

  Widget _categoryList() {
    final categories = ref.watch(categoriesProvider);
    return categories.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(categoriesProvider)),
      data: (list) {
        // Mismo orden que el inicio: primero los servicios del hogar a pedido.
        final shown = orderCategories(
          list,
          slug: (c) => c.slug,
          name: (c) => c.name,
        ).where((c) => categoryMatchesQuery(_categoryQuery, [c.name, c.description, c.slug])).toList();
        if (shown.isEmpty) {
          return EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No encontramos "${_categoryQuery.trim()}"',
            message: 'Prueba con otra palabra, por ejemplo "fuga", "luz" o "llave".',
            action: TextButton(
              onPressed: () => setState(() {
                _categorySearch.clear();
                _categoryQuery = '';
              }),
              child: const Text('Ver todos los servicios'),
            ),
          );
        }
        return Column(
          children: [
            for (final c in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: HySpacing.xs),
                child: _CategoryOption(category: c, selected: c.id == _categoryId, onTap: () => _chooseCategory(c.id)),
              ),
          ],
        );
      },
    );
  }

  Widget _problemStep(ServiceCategory? category) {
    if (_categoryId == null) return const SizedBox.shrink();
    final problems = ref.watch(problemsProvider(_categoryId!));
    return problems.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(problemsProvider(_categoryId!))),
      data: (list) => Form(
        key: _problemsForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (category != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: _CategoryChip(category: category),
              ),
              const SizedBox(height: HySpacing.xs),
            ],
            const Text(
              'Toca todo lo que necesites. Puedes elegir más de una opción.',
              style: TextStyle(color: HyColors.textSecondary, fontSize: 16),
            ),
            if (category?.safetyNote != null) ...[
              const SizedBox(height: HySpacing.sm),
              InfoBanner(icon: Icons.shield_outlined, tone: StatusTone.warning, text: category!.safetyNote!),
            ],
            const SizedBox(height: HySpacing.md),
            ProblemGrid(
              problems: category == null
                  ? list
                  : orderProblems(list, categorySlug: category.slug, name: (p) => p.name, isOther: (p) => p.isOther),
              selected: _selected,
              icon: category?.icon ?? 'build',
              onToggle: (p) => p.opensCategoryId != null
                  ? _openCategory(p.opensCategoryId!)
                  : setState(() => _selected.contains(p.id) ? _selected.remove(p.id) : _selected.add(p.id)),
            ),
            if (category?.slug == 'grua') ...[
              const SizedBox(height: HySpacing.lg),
              Text('Tipo de vehículo', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: HySpacing.xs),
              Wrap(
                spacing: HySpacing.xs,
                runSpacing: HySpacing.xs,
                children: [
                  for (final v in vehicleTypes)
                    ChoiceChip(
                      key: ValueKey('vehicle-$v'),
                      label: Text(v),
                      selected: _vehicle == v,
                      onSelected: (_) => setState(() {
                        _vehicle = v;
                        _vehicleError = null;
                      }),
                    ),
                ],
              ),
              if (_vehicleError != null) ...[
                const SizedBox(height: HySpacing.xxs),
                Text(_vehicleError!, style: const TextStyle(color: HyColors.danger)),
              ],
              const SizedBox(height: HySpacing.md),
              TextFormField(
                key: const ValueKey('tow-destination'),
                controller: _destination,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 300,
                decoration: const InputDecoration(
                  labelText: 'Destino',
                  hintText: 'Taller, casa u otra dirección',
                  prefixIcon: Icon(Icons.flag_outlined),
                ),
                validator: (v) => (v ?? '').trim().length < 3 ? 'Escribe el destino' : null,
              ),
              const Text(
                'Solo lo verá quien acepte tu pedido.',
                style: TextStyle(color: HyColors.textMuted, fontSize: 14),
              ),
            ],
            if (_otherSelected) ...[
              const SizedBox(height: HySpacing.md),
              TextFormField(
                key: const ValueKey('other-text'),
                controller: _otherText,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: '¿Qué necesitas?',
                  hintText: 'Escríbelo con tus palabras',
                  alignLabelWithHint: true,
                ),
                validator: (v) => (v ?? '').trim().length < 3 ? 'Cuéntanos qué necesitas' : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _describeStep(ServiceCategory? category) {
    return Form(
      key: _describeForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selectedLabels.isNotEmpty) ...[
            Wrap(
              spacing: HySpacing.xs,
              runSpacing: HySpacing.xs,
              children: [for (final l in _selectedLabels) Chip(label: Text(l))],
            ),
            const SizedBox(height: HySpacing.sm),
          ],
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
            minLines: 3,
            maxLines: 8,
            maxLength: 1500,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Detalles (opcional)',
              hintText: 'Ej.: Gotea debajo del lavaplatos desde ayer.',
              alignLabelWithHint: true,
            ),
            validator: (v) {
              final t = (v ?? '').trim();
              return t.isNotEmpty && t.length < 5 ? 'Escribe un poco más, o déjalo vacío' : null;
            },
          ),
          if (!_isYa && _mode == BookingMode.scheduled) ...[
            const SizedBox(height: HySpacing.md),
            Text('¿Cuándo?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: HySpacing.xs),
            ScheduleFields(
              date: _date,
              time: _time,
              duration: _duration,
              error: _scheduleError,
              onDate: (d) => setState(() => _date = d),
              onTime: (t) => setState(() => _time = t),
              onDuration: (d) => setState(() => _duration = d),
            ),
          ],
          const SizedBox(height: HySpacing.lg),
          PhotoPickerRow(photos: _photos, onChanged: (p) => setState(() => _photos = p)),
        ],
      ),
    );
  }

  Widget _addressStep(ServiceCategory? category) {
    final cities = ref.watch(citiesProvider).value ?? const <City>[];
    final cityId = _serviceCityId ?? ref.watch(currentCityProvider)?.id;
    final city = cities.where((c) => c.id == cityId).firstOrNull;
    final zones = cityId == null ? const <Zone>[] : (ref.watch(zonesProvider(cityId)).value ?? const <Zone>[]);
    final allowsYa = category?.allowsYa ?? true;
    return Form(
      key: _addressForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _GpsCard(
            point: _point,
            city: city,
            locating: _locating,
            onTap: _useMyLocation,
            onClear: () => setState(() => _point = null),
          ),
          if (_gpsNotice != null) ...[
            const SizedBox(height: HySpacing.sm),
            InfoBanner(
              key: const Key('gps-outside-bolivia'),
              icon: Icons.public_off_outlined,
              tone: StatusTone.warning,
              text: _gpsNotice!,
            ),
          ],
          const SizedBox(height: HySpacing.md),
          CityField(
            key: const Key('service-city'),
            value: cityId,
            label: 'Municipio del servicio',
            onChanged: _setServiceCity,
            validator: (v) => v == null ? 'Elige el municipio donde es el servicio' : null,
          ),
          const SizedBox(height: HySpacing.xxs),
          const Text(
            'Puede ser cualquier lugar de Bolivia, aunque no sea tu ciudad.',
            style: TextStyle(color: HyColors.textMuted, fontSize: 14),
          ),
          const SizedBox(height: HySpacing.md),
          DropdownButtonFormField<int?>(
            key: ValueKey('zone-$cityId'),
            initialValue: _zoneId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Zona', prefixIcon: Icon(Icons.map_outlined)),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('Todo el municipio')),
              for (final z in zones) DropdownMenuItem<int?>(value: z.id, child: Text(z.name)),
            ],
            // Lo elegido en una línea, sin cortarse, aun con letra grande.
            selectedItemBuilder: (_) => [
              const OneLineText('Todo el municipio'),
              for (final z in zones) OneLineText(z.name),
            ],
            onChanged: (v) => setState(() => _zoneId = v),
          ),
          const SizedBox(height: HySpacing.md),
          TextFormField(
            controller: _address,
            textCapitalization: TextCapitalization.sentences,
            autofillHints: const [AutofillHints.fullStreetAddress],
            decoration: InputDecoration(
              labelText: _isTow ? 'Ubicación' : 'Dirección',
              hintText: _isTow ? 'Dónde está el vehículo' : 'Calle, número y barrio',
              prefixIcon: Icon(_isTow ? Icons.directions_car_outlined : Icons.home_outlined),
            ),
            validator: (v) => (v ?? '').trim().length < 5 ? 'Escribe la dirección' : null,
          ),
          const SizedBox(height: HySpacing.md),
          TextFormField(
            controller: _reference,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Referencia',
              hintText: 'Ej.: portón negro, frente a la plaza',
              prefixIcon: Icon(Icons.signpost_outlined),
            ),
          ),
          const SizedBox(height: HySpacing.sm),
          const InfoBanner(
            key: Key('address-privacy'),
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
          if (_isYa && !allowsYa) ...[
            const SizedBox(height: HySpacing.lg),
            const InfoBanner(
              icon: Icons.verified_user_outlined,
              tone: StatusTone.warning,
              text: 'Para este servicio eliges tú a la persona: verás su perfil y calificaciones antes de pedir.',
            ),
          ],
          if (_isYa && allowsYa && cityId != null && _categoryId != null) ...[
            const SizedBox(height: HySpacing.lg),
            _AvailableCount(categoryId: _categoryId!, cityId: cityId, zoneId: _zoneId, point: _point),
          ],
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.category});

  final ServiceCategory category;

  @override
  Widget build(BuildContext context) =>
      Chip(avatar: Icon(categoryIcon(category.icon), size: 20), label: OneLineText(category.name));
}

/// Tarjetas grandes de "¿Qué necesitas solucionar?". Se pueden elegir varias.
class ProblemGrid extends StatelessWidget {
  const ProblemGrid({
    super.key,
    required this.problems,
    required this.selected,
    required this.onToggle,
    this.icon = 'build',
  });

  final List<ServiceProblem> problems;
  final Set<int> selected;
  final ValueChanged<ServiceProblem> onToggle;

  /// Ícono de la categoría (define los colores).
  final String icon;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        const gap = HySpacing.xs;
        // Dos columnas solo si en cada tarjeta entra cada palabra entera y
        // queda lugar para leer (unas dos palabras por línea); si no, una sola
        // columna a todo el ancho. Nunca se parte una palabra ("cañe / ría").
        final half = (box.maxWidth - gap) / 2 - _ProblemCard.chrome;
        final names = [for (final p in problems) p.name];
        final fits =
            wordFitScale(context, texts: names, style: _ProblemCard.labelStyle, width: half - 1) >=
            MediaQuery.textScalerOf(context).scale(1);
        final columns = fits && half >= 140 * MediaQuery.textScalerOf(context).scale(1) ? 2 : 1;
        return Column(
          children: [
            for (var r = 0; r < problems.length; r += columns) ...[
              if (r > 0) const SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = r; i < r + columns; i++) ...[
                      if (i > r) const SizedBox(width: gap),
                      Expanded(
                        child: i < problems.length
                            ? _ProblemCard(
                                problem: problems[i],
                                selected: selected.contains(problems[i].id),
                                icon: icon,
                                onTap: () => onToggle(problems[i]),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Una opción: compacta (mín. 56 dp de alto), con su ícono, el texto y una
/// marca. Elegida: borde y fondo naranja con ✓. Se pueden elegir varias.
class _ProblemCard extends StatelessWidget {
  const _ProblemCard({required this.problem, required this.selected, required this.icon, required this.onTap});

  static const labelStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.2);

  /// Ancho de todo lo que no es el texto: relleno (12 + 12), ícono (36),
  /// separación (12 + 4), marca (24) y borde (2 + 2).
  static const chrome = 12.0 + 12 + 36 + 12 + 4 + 24 + 4;

  final ServiceProblem problem;
  final bool selected;
  final String icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = categoryColors(icon);
    return Semantics(
      key: ValueKey('problem-${problem.id}'),
      button: true,
      selected: selected,
      label: problem.name,
      excludeSemantics: true,
      child: Material(
        color: selected ? HyColors.primarySoft : HyColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HyRadii.md),
          side: BorderSide(color: selected ? HyColors.primary : HyColors.border, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: HySpacing.xs),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: selected ? HyColors.primary : bg,
                      borderRadius: BorderRadius.circular(HyRadii.sm),
                    ),
                    child: Icon(problemIcon(problem.icon), color: selected ? HyColors.onPrimary : fg, size: 22),
                  ),
                  const SizedBox(width: HySpacing.sm),
                  Expanded(child: Text(problem.name, style: labelStyle)),
                  const SizedBox(width: HySpacing.xxs),
                  Icon(
                    selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                    key: ValueKey('problem-check-${problem.id}'),
                    color: selected ? HyColors.primary : HyColors.textMuted,
                    size: 24,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Día, hora y duración de un servicio programado.
class ScheduleFields extends StatelessWidget {
  const ScheduleFields({
    super.key,
    required this.date,
    required this.time,
    required this.duration,
    required this.onDate,
    required this.onTime,
    required this.onDuration,
    this.error,
  });

  final DateTime? date;
  final TimeOfDay? time;
  final int duration;
  final ValueChanged<DateTime> onDate;
  final ValueChanged<TimeOfDay> onTime;
  final ValueChanged<int> onDuration;
  final String? error;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ButtonRow(
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text(date == null ? 'Elegir día' : Fmt.shortDate(date!)),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate: date ?? now,
                firstDate: now,
                lastDate: now.add(const Duration(days: 60)),
                helpText: 'Elige el día',
              );
              if (d != null) onDate(d);
            },
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.schedule),
            label: Text(time == null ? 'Elegir hora' : time!.format(context)),
            onPressed: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: time ?? const TimeOfDay(hour: 9, minute: 0),
                helpText: 'Elige la hora',
              );
              if (t != null) onTime(t);
            },
          ),
        ],
      ),
      const SizedBox(height: HySpacing.sm),
      DropdownButtonFormField<int>(
        initialValue: duration,
        decoration: const InputDecoration(labelText: 'Duración aproximada'),
        items: const [
          DropdownMenuItem(value: 60, child: Text('1 hora')),
          DropdownMenuItem(value: 120, child: Text('2 horas')),
          DropdownMenuItem(value: 240, child: Text('Medio día')),
          DropdownMenuItem(value: 480, child: Text('Día completo')),
        ],
        onChanged: (v) => onDuration(v ?? 120),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: HySpacing.xs),
          child: Text(error!, style: const TextStyle(color: HyColors.danger)),
        ),
      const SizedBox(height: HySpacing.xs),
      const Text('Hora de Bolivia.', style: TextStyle(color: HyColors.textMuted, fontSize: 14)),
    ],
  );
}

/// Buscador del paso 1: filtra la lista sin importar tildes ni mayúsculas.
class _CategorySearchField extends StatelessWidget {
  const _CategorySearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('category-search'),
    controller: controller,
    onChanged: onChanged,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: 'Buscar servicio (ej.: plomería)',
      prefixIcon: const Icon(Icons.search),
      isDense: true,
      suffixIcon: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.text.isEmpty
            ? const SizedBox.shrink()
            : IconButton(
                tooltip: 'Borrar búsqueda',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
      ),
    ),
  );
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

/// Mensaje cuando el GPS da un punto fuera de Bolivia.
const outsideBoliviaMessage =
    'HandiMan ¡Ya! atiende en Bolivia. Escribe la dirección del lugar del servicio en Bolivia.';

/// Qué hacer con un punto del GPS: fuera de Bolivia no se usa (ni se envía);
/// dentro, se guarda y se sugiere el municipio más cercano (editable).
({GeoPoint? point, City? city, bool outsideBolivia}) resolveGpsFix(GeoPoint p, List<City> cities) {
  if (!isInBolivia(p.latitude, p.longitude)) return (point: null, city: null, outsideBolivia: true);
  return (point: p, city: nearestCity(cities, p.latitude, p.longitude), outsideBolivia: false);
}

class _GpsCard extends StatelessWidget {
  const _GpsCard({
    required this.point,
    required this.city,
    required this.locating,
    required this.onTap,
    required this.onClear,
  });

  final GeoPoint? point;
  final City? city;
  final bool locating;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (point == null) {
      return SecondaryButton(
        label: locating ? 'Buscando tu ubicación…' : 'Usar mi ubicación',
        icon: Icons.my_location_rounded,
        onPressed: locating ? null : onTap,
      );
    }
    final near = city == null
        ? ''
        : ' cerca de ${city!.name}${city!.department == null ? '' : ', ${city!.department}'}';
    return AppCard(
      key: const Key('gps-taken'),
      color: HyColors.greenSoft,
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: HyColors.greenDark),
          const SizedBox(width: HySpacing.sm),
          Expanded(
            child: Text(
              'Ubicación tomada$near. Revisa el municipio y escribe la dirección; '
              'buscaremos profesionales cerca de este punto.',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
              ? 'Ahora no hay profesionales disponibles para este servicio en esta zona. Prueba con "Todo el municipio" o programa para después.'
              : n == 1
              ? '1 profesional disponible cerca de ti recibirá tu pedido.'
              : '$n profesionales disponibles cerca de ti recibirán tu pedido. El primero que acepte irá.',
        );
      },
    );
  }
}
