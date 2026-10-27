import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/trailing_row.dart';
import '../../core/widgets/word_safe_text.dart';
import '../../data/models/ads.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import '../common/photo_picker.dart';
import '../common/unsaved_changes.dart';
import '../home/home_ad.dart';
import 'admin_common.dart';

// Publicidad propia del inicio: solo el Propietario. El router no deja entrar
// a otro rol y cada función del servidor vuelve a exigir is_admin().

final _day = DateFormat('d MMM y', 'es');

String _dates(OwnerAd a) => switch ((a.startsAt, a.endsAt)) {
  (null, null) => 'Sin fechas: sale mientras esté aprobado',
  (final s?, null) => 'Desde el ${_day.format(s)}',
  (null, final e?) => 'Hasta el ${_day.format(e.subtract(const Duration(minutes: 1)))}',
  (final s?, final e?) => '${_day.format(s)} al ${_day.format(e.subtract(const Duration(minutes: 1)))}',
};

String _rate(int views, int clicks) =>
    views == 0 ? '' : ' (${(clicks * 100 / views).toStringAsFixed(1).replaceAll('.', ',')}%)';

(String, StatusTone) _state(OwnerAd a) => switch (a.status) {
  AdStatus.approved when a.live => ('En el inicio', StatusTone.success),
  AdStatus.approved when a.startsAt != null && a.startsAt!.isAfter(DateTime.now()) => ('Programado', StatusTone.info),
  AdStatus.approved => ('Terminado', StatusTone.neutral),
  AdStatus.draft => ('Por aprobar', StatusTone.warning),
  AdStatus.paused => ('Pausado', StatusTone.neutral),
  AdStatus.removed => ('Quitado', StatusTone.neutral),
};

class AdminAdsPage extends ConsumerWidget {
  const AdminAdsPage({super.key});

  Future<void> _act(BuildContext context, WidgetRef ref, OwnerAd a, AdAction action) async {
    if (action == AdAction.remove &&
        !await confirmDialog(
          context,
          title: '¿Quitar "${a.title}"?',
          message: 'Deja de salir en el inicio. Sus vistas y toques se guardan.',
          confirm: 'Quitar',
          destructive: true,
        )) {
      return;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).setAdStatus(a.id, action),
      success: switch (action) {
        AdAction.approve => 'Aprobado. Sale en el inicio dentro de sus fechas.',
        AdAction.pause => 'Pausado. Ya no sale en el inicio.',
        AdAction.remove => 'Quitado.',
      },
    );
    if (ok) {
      ref.invalidate(ownerAdsProvider);
      ref.invalidate(homeAdProvider);
    }
  }

  void _edit(BuildContext context, [OwnerAd? ad]) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AdFormPage(ad: ad)));

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const OneLineText('Publicidad')),
    floatingActionButton: FloatingActionButton.extended(
      key: const Key('ads-add'),
      backgroundColor: HyColors.primary,
      foregroundColor: Colors.white,
      onPressed: () => _edit(context),
      icon: const Icon(Icons.add),
      label: const Text('Nuevo'),
    ),
    body: AdminList<OwnerAd>(
      value: ref.watch(ownerAdsProvider),
      hasFab: true,
      onRefresh: () => ref.refresh(ownerAdsProvider.future),
      emptyIcon: Icons.campaign_outlined,
      emptyTitle: 'Todavía no hay anuncios. Mientras no haya uno aprobado, el inicio no muestra publicidad.',
      header: const Padding(
        padding: EdgeInsets.only(bottom: HySpacing.sm),
        child: InfoBanner(
          icon: Icons.campaign_outlined,
          text:
              'Anuncios de negocios, vendidos y revisados por HandiMan ¡Ya!. Salen en el inicio solo aprobados y '
              'en fecha, y siempre dicen "Publicidad" o "Patrocinado". Se cuentan vistas y toques, sin datos de los clientes.',
        ),
      ),
      itemBuilder: (context, a) {
        final (state, tone) = _state(a);
        final removed = a.status == AdStatus.removed;
        return AppCard(
          key: Key('ad-${a.id}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: AlignmentDirectional.centerStart, child: ToneChip(state, tone)),
              const SizedBox(height: HySpacing.sm),
              HomeAdCard(ad: a.preview, preview: true),
              const SizedBox(height: HySpacing.sm),
              InfoLine(Icons.location_city_outlined, a.cityName ?? 'Todas las ciudades'),
              InfoLine(Icons.event_outlined, _dates(a)),
              InfoLine(
                Icons.bar_chart_rounded,
                '${a.impressions} vistas · ${a.clicks} toques${_rate(a.impressions, a.clicks)}',
              ),
              InfoLine(Icons.today_outlined, 'Hoy: ${a.impressionsToday} vistas · ${a.clicksToday} toques'),
              if (a.linkUrl != null) InfoLine(Icons.link, a.linkUrl!),
              if (!removed) ...[
                const SizedBox(height: HySpacing.xs),
                Wrap(
                  spacing: HySpacing.xs,
                  children: [
                    TextButton(
                      key: Key('ad-edit-${a.id}'),
                      onPressed: () => _edit(context, a),
                      child: const Text('Editar'),
                    ),
                    if (a.status == AdStatus.draft || a.status == AdStatus.paused)
                      OutlinedButton(
                        key: Key('ad-approve-${a.id}'),
                        onPressed: () => _act(context, ref, a, AdAction.approve),
                        child: const Text('Aprobar'),
                      ),
                    if (a.status == AdStatus.approved)
                      OutlinedButton(
                        key: Key('ad-pause-${a.id}'),
                        onPressed: () => _act(context, ref, a, AdAction.pause),
                        child: const Text('Pausar'),
                      ),
                    TextButton(
                      key: Key('ad-remove-${a.id}'),
                      onPressed: () => _act(context, ref, a, AdAction.remove),
                      child: const Text('Quitar', style: TextStyle(color: HyColors.danger)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

/// Crear o cambiar un anuncio. Siempre queda "por aprobar".
class AdFormPage extends ConsumerStatefulWidget {
  const AdFormPage({super.key, this.ad});

  final OwnerAd? ad;

  @override
  ConsumerState<AdFormPage> createState() => _AdFormPageState();
}

class _AdFormPageState extends ConsumerState<AdFormPage> {
  final _form = GlobalKey<FormState>();
  late final _advertiser = TextEditingController(text: widget.ad?.advertiser);
  late final _title = TextEditingController(text: widget.ad?.title);
  late final _body = TextEditingController(text: widget.ad?.body);
  late final _link = TextEditingController(text: widget.ad?.linkUrl);
  late var _label = widget.ad?.label ?? adLabels.first;
  late int? _cityId = widget.ad?.cityId;
  late DateTime? _from = widget.ad?.startsAt;

  /// Último día en que sale (el anuncio termina al final de ese día).
  late DateTime? _to = widget.ad?.endsAt?.subtract(const Duration(minutes: 1));
  PhotoUpload? _logo;
  PhotoUpload? _image;
  late String? _logoPath = widget.ad?.logoPath;
  late String? _imagePath = widget.ad?.imagePath;
  var _dirty = false;
  var _busy = false;

  @override
  void dispose() {
    for (final c in [_advertiser, _title, _body, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed([_]) {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _pick(bool logo) async {
    final p = await pickPhoto(context);
    if (p == null) return;
    setState(() {
      if (logo) {
        _logo = p;
      } else {
        _image = p;
      }
      _dirty = true;
    });
  }

  Future<void> _pickDate(bool from) async {
    final now = DateTime.now();
    final initial = (from ? _from : _to) ?? now;
    final d = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 366)),
    );
    if (d == null) return;
    setState(() {
      if (from) {
        _from = d;
      } else {
        _to = d;
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    final from = _from == null ? null : DateTime(_from!.year, _from!.month, _from!.day);
    final to = _to == null ? null : DateTime(_to!.year, _to!.month, _to!.day).add(const Duration(days: 1));
    if (from != null && to != null && !to.isAfter(from)) {
      return showMessage(context, 'El último día debe ser igual o después del primero.');
    }
    setState(() => _busy = true);
    final backend = ref.read(backendProvider);
    final ok = await runGuarded(context, () async {
      if (_logo != null) _logoPath = await backend.uploadAdImage(_logo!);
      if (_image != null) _imagePath = await backend.uploadAdImage(_image!);
      await backend.saveAd(
        AdDraft(
          id: widget.ad?.id,
          advertiser: _advertiser.text.trim(),
          title: _title.text.trim(),
          body: _body.text.trim().isEmpty ? null : _body.text.trim(),
          logoPath: _logoPath,
          imagePath: _imagePath,
          linkUrl: _link.text.trim().isEmpty ? null : _link.text.trim(),
          label: _label,
          cityId: _cityId,
          startsAt: from,
          endsAt: to,
        ),
      );
    }, success: 'Guardado. Apruébalo para que salga en el inicio.');
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    ref.invalidate(ownerAdsProvider);
    ref.invalidate(homeAdProvider);
    _dirty = false;
    Navigator.of(context).pop();
  }

  Widget _imageRow(String title, String hint, PhotoUpload? picked, String? saved, bool logo) => AppCard(
    child: TrailingRow(
      leading: picked != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(HyRadii.sm),
              child: Image.memory(picked.bytes, width: 48, height: 48, fit: BoxFit.cover),
            )
          : Icon(logo ? Icons.storefront_outlined : Icons.image_outlined, size: 40, color: HyColors.textMuted),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WordSafeText(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          WordSafeText(
            picked != null
                ? 'Lista para guardar'
                : saved != null
                ? 'Guardada'
                : hint,
            style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
          ),
        ],
      ),
      trailing: Wrap(
        children: [
          if (picked != null || saved != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      if (logo) {
                        _logo = null;
                        _logoPath = null;
                      } else {
                        _image = null;
                        _imagePath = null;
                      }
                      _dirty = true;
                    }),
              child: const Text('Quitar'),
            ),
          TextButton(
            key: Key(logo ? 'ad-logo' : 'ad-image'),
            onPressed: _busy ? null : () => _pick(logo),
            child: Text(picked != null || saved != null ? 'Cambiar' : 'Subir'),
          ),
        ],
      ),
    ),
  );

  Widget _dateField(String label, DateTime? value, bool from) => InputDecorator(
    decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.event_outlined)),
    child: TrailingRow(
      leading: const SizedBox.shrink(),
      gap: 0,
      body: InkWell(
        key: Key(from ? 'ad-from' : 'ad-to'),
        onTap: _busy ? null : () => _pickDate(from),
        child: OneLineText(value == null ? (from ? 'Desde hoy' : 'Sin fecha de fin') : _day.format(value)),
      ),
      trailing: value == null
          ? const SizedBox.shrink()
          : IconButton(
              tooltip: 'Quitar fecha',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() {
                if (from) {
                  _from = null;
                } else {
                  _to = null;
                }
                _dirty = true;
              }),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cities = ref.watch(citiesProvider).value ?? const [];
    final approved = widget.ad?.status == AdStatus.approved;
    return UnsavedChangesScope(
      dirty: _dirty,
      child: Scaffold(
        appBar: AppBar(title: OneLineText(widget.ad == null ? 'Nuevo anuncio' : 'Editar anuncio')),
        body: ListView(
          padding: bottomSafePadding(context, top: HySpacing.md),
          children: [
            PageBody(
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (approved)
                      const Padding(
                        padding: EdgeInsets.only(bottom: HySpacing.sm),
                        child: InfoBanner(
                          tone: StatusTone.warning,
                          icon: Icons.info_outline,
                          text: 'Al guardar cambios, el anuncio sale del inicio hasta que lo apruebes otra vez.',
                        ),
                      ),
                    TextFormField(
                      key: const Key('ad-advertiser'),
                      controller: _advertiser,
                      maxLength: 60,
                      textCapitalization: TextCapitalization.words,
                      onChanged: _changed,
                      decoration: const InputDecoration(labelText: 'Negocio', hintText: 'Ej.: Ferretería El Tornillo'),
                      validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe el nombre del negocio' : null,
                    ),
                    TextFormField(
                      key: const Key('ad-title'),
                      controller: _title,
                      maxLength: 50,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: _changed,
                      decoration: const InputDecoration(labelText: 'Título', hintText: 'Ej.: 10% en herramientas'),
                      validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe un título' : null,
                    ),
                    TextFormField(
                      key: const Key('ad-body'),
                      controller: _body,
                      maxLength: 120,
                      maxLines: 2,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: _changed,
                      decoration: const InputDecoration(labelText: 'Texto (opcional)'),
                    ),
                    TextFormField(
                      key: const Key('ad-link'),
                      controller: _link,
                      maxLength: 300,
                      keyboardType: TextInputType.url,
                      onChanged: _changed,
                      decoration: const InputDecoration(labelText: 'Enlace (opcional)', hintText: 'https://'),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        return t.isEmpty || isValidAdLink(t) ? null : 'Debe empezar con https:// y tener un dominio';
                      },
                    ),
                    DropdownButtonFormField<String>(
                      key: const Key('ad-label'),
                      initialValue: _label,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Etiqueta'),
                      items: [for (final l in adLabels) DropdownMenuItem(value: l, child: Text(l))],
                      onChanged: (v) => setState(() {
                        _label = v ?? _label;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: HySpacing.md),
                    DropdownButtonFormField<int?>(
                      key: ValueKey('ad-city-${cities.length}'),
                      initialValue: _cityId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Ciudad'),
                      items: [
                        const DropdownMenuItem<int?>(value: null, child: Text('Todas las ciudades')),
                        for (final c in cities) DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
                      ],
                      selectedItemBuilder: (_) => [
                        const OneLineText('Todas las ciudades'),
                        for (final c in cities) OneLineText(c.name),
                      ],
                      onChanged: (v) => setState(() {
                        _cityId = v;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: HySpacing.md),
                    _dateField('Primer día', _from, true),
                    const SizedBox(height: HySpacing.md),
                    _dateField('Último día', _to, false),
                    const SizedBox(height: HySpacing.md),
                    _imageRow('Logo', 'Cuadrado, opcional', _logo, _logoPath, true),
                    const SizedBox(height: HySpacing.sm),
                    _imageRow('Imagen', 'Horizontal (3 a 1), opcional', _image, _imagePath, false),
                    const SizedBox(height: HySpacing.lg),
                    PrimaryButton(key: const Key('ad-save'), label: 'Guardar', loading: _busy, onPressed: _save),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
