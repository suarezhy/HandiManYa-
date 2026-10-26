import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/category_order.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/catalog.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/city_picker.dart';
import '../common/unsaved_changes.dart';
import '../legal/legal_texts.dart';
import 'identity_check_card.dart';
import 'service_area_page.dart';
import 'service_selector.dart';

/// Postulación para ser profesional: datos, zonas, documentos y envío.
class ApplicationPage extends ConsumerWidget {
  const ApplicationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(applicationProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quiero ser profesional'),
        // Igual que el gesto atrás: pregunta si hay cambios sin guardar y, si
        // se llegó directo a esta pantalla, vuelve al inicio.
        leading: BackButton(onPressed: () => Navigator.maybePop(context)),
      ),
      body: app.when(
        loading: () => const UnsavedChangesScope(dirty: false, homeWhenFirst: true, child: LoadingView()),
        error: (e, _) => UnsavedChangesScope(
          dirty: false,
          homeWhenFirst: true,
          child: ErrorView(error: e, onRetry: () => ref.invalidate(applicationProvider)),
        ),
        data: (a) => a.status.canEdit
            ? _ApplicationForm(app: a)
            : UnsavedChangesScope(dirty: false, homeWhenFirst: true, child: _StatusView(app: a)),
      ),
    );
  }
}

class _StatusView extends ConsumerWidget {
  const _StatusView({required this.app});

  final ProfessionalApplication app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final approved = app.status == VerificationStatus.approved;
    return ListView(
      children: [
        EmptyState(
          icon: approved ? Icons.verified_rounded : Icons.hourglass_top_rounded,
          title: approved ? '¡Tu perfil fue aprobado!' : 'Postulación ${app.status.label.toLowerCase()}',
          message: approved ? 'Ya puedes recibir pedidos. Activa tu disponibilidad desde el modo profesional.' : 'Nuestro equipo está revisando tus datos y documentos. Te avisaremos en Notificaciones, dentro de la app.',
          action: approved
              ? PrimaryButton(
                  label: 'Ir al modo profesional',
                  expand: false,
                  onPressed: () async {
                    final ok = await runGuarded(
                      context,
                      () => ref.read(backendProvider).setActiveRole(AppRole.professional),
                    );
                    if (ok) ref.invalidate(accountProvider);
                    if (ok && context.mounted) context.go(Routes.proHome);
                  },
                )
              : SecondaryButton(label: 'Volver al inicio', expand: false, onPressed: () => context.go(Routes.home)),
        ),
        if (app.status == VerificationStatus.submitted || app.status == VerificationStatus.underReview)
          const PageBody(child: IdentityCheckCard()),
      ],
    );
  }
}

class _ApplicationForm extends ConsumerStatefulWidget {
  const _ApplicationForm({required this.app});

  final ProfessionalApplication app;

  @override
  ConsumerState<_ApplicationForm> createState() => _ApplicationFormState();
}

class _ApplicationFormState extends ConsumerState<_ApplicationForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.app.displayName.isNotEmpty ? widget.app.displayName : ref.read(accountProvider).value?.fullName ?? '',
  );
  late final _bio = TextEditingController(text: widget.app.bio);
  late final _years = TextEditingController(text: widget.app.yearsExperience?.toString() ?? '');
  late final _price = TextEditingController(text: widget.app.priceNote);
  late int? _primary = widget.app.primaryCategoryId;
  late int? _cityId = widget.app.cityId ?? ref.read(accountProvider).value?.cityId;
  late final Set<int> _categories = {...widget.app.categoryIds};
  late final Set<int> _zones = {...widget.app.zoneIds};
  late int _docs = widget.app.documentCount;
  bool _saving = false;
  bool _acceptedRules = false;
  bool _uploading = false;
  int _stage = 0;
  final _scroll = ScrollController();

  /// Los datos tal como están guardados (o como llegaron): si cambian, salir
  /// pregunta antes. Los documentos se suben al momento y no cuentan.
  late String _savedSnapshot = _snapshot();

  String _snapshot() => [
    _name.text.trim(),
    _bio.text.trim(),
    _years.text.trim(),
    _price.text.trim(),
    _primary,
    _cityId,
    ([..._categories]..sort()).join(','),
    ([..._zones]..sort()).join(','),
  ].join('|');

  /// Cambia de etapa y vuelve al principio de la lista.
  void _goTo(int stage) {
    setState(() => _stage = stage);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _years.dispose();
    _price.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Pasa a la etapa siguiente si lo visible está completo, y guarda el borrador.
  Future<void> _next() async {
    if (!_formKey.currentState!.validate()) return;
    if (_stage == 0 && _primary == null) return;
    // Sin municipio todavía no se puede guardar; se elige en la etapa 2.
    if (_stage == 0 && _cityId == null) return _goTo(1);
    if (await _save(quiet: true) && mounted) _goTo(_stage + 1);
  }

  Future<bool> _save({bool quiet = false}) async {
    // Solo se validan los campos de la etapa visible; lo demás se revisó al avanzar.
    if (!_formKey.currentState!.validate()) return false;
    if (_primary == null || _cityId == null) {
      showMessage(context, _primary == null ? 'Elige tu servicio principal.' : 'Elige el municipio donde trabajas.');
      _goTo(_primary == null ? 0 : 1);
      return false;
    }
    // Solo algunas ciudades tienen zonas; en el resto se trabaja por radio.
    final zones = _cityId == null ? const <Zone>[] : ref.read(zonesProvider(_cityId!)).value ?? const <Zone>[];
    if (_stage >= 1 && zones.isNotEmpty && _zones.isEmpty) {
      showMessage(context, 'Elige al menos una zona donde trabajas.');
      return false;
    }
    final snapshot = _snapshot();
    final ok = await runGuarded(
      context,
      () => ref
          .read(backendProvider)
          .saveApplication(
            displayName: _name.text.trim(),
            primaryCategoryId: _primary!,
            cityId: _cityId!,
            bio: _bio.text.trim(),
            yearsExperience: int.tryParse(_years.text),
            priceNote: _price.text.trim().isEmpty ? null : _price.text.trim(),
            categoryIds: {..._categories, _primary!},
            zoneIds: _zones,
          ),
      success: quiet ? null : 'Borrador guardado',
    );
    if (ok && mounted) setState(() => _savedSnapshot = snapshot);
    return ok;
  }

  Future<void> _pickDocument(String docType) async {
    // Guardamos primero para que exista la postulación donde colgar el documento.
    if (!await _save(quiet: true) || !mounted) return;
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, imageQuality: 85);
    if (file == null || !mounted) return;
    setState(() => _uploading = true);
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).uploadDocument(docType: docType, bytes: bytes, fileName: file.name),
      success: 'Documento subido',
    );
    if (!mounted) return;
    setState(() {
      _uploading = false;
      if (ok) _docs++;
    });
  }

  Future<void> _submit() async {
    if (!_acceptedRules) {
      showMessage(context, 'Para enviar, acepta las Reglas para profesionales y la Política de comisiones.');
      return;
    }
    setState(() => _saving = true);
    final saved = await _save(quiet: true);
    final api = ref.read(backendProvider);
    final ok =
        saved &&
        mounted &&
        await runGuarded(context, () async {
          await api.recordConsent(LegalDoc.proRules.key, legalVersion);
          await api.recordConsent(LegalDoc.commissions.key, legalVersion);
          await api.submitApplication();
        }, success: '¡Postulación enviada! Te avisaremos cuando esté revisada.');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref
        ..invalidate(applicationProvider)
        ..invalidate(accountProvider);
    }
  }

  @override
  Widget build(BuildContext context) => UnsavedChangesScope(
    dirty: _snapshot() != _savedSnapshot,
    homeWhenFirst: true,
    message: 'Tu postulación tiene cambios sin guardar. Usa "Guardar borrador" para no perderlos.',
    child: _form(context),
  );

  Widget _form(BuildContext context) {
    final categories = ref.watch(categoriesProvider).value ?? const <ServiceCategory>[];
    final ordered = orderCategories(categories, slug: (c) => c.slug, name: (c) => c.name);
    final zones = _cityId == null ? const <Zone>[] : ref.watch(zonesProvider(_cityId!)).value ?? const <Zone>[];
    final text = Theme.of(context).textTheme;
    return Form(
      key: _formKey,
      onChanged: () => setState(() {}),
      child: ListView(
        key: const Key('application-form'),
        controller: _scroll,
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.sm),
                if (widget.app.status == VerificationStatus.rejected && widget.app.reviewNote != null) ...[
                  InfoBanner(
                    tone: StatusTone.danger,
                    icon: Icons.feedback_outlined,
                    text: 'Comentario del equipo: ${widget.app.reviewNote}',
                  ),
                  const SizedBox(height: HySpacing.md),
                ],
                const InfoBanner(
                  icon: Icons.verified_user_outlined,
                  tone: StatusTone.success,
                  text: 'Verificamos a cada profesional para que los clientes confíen en ti. Es gratis y tus documentos se guardan de forma privada.',
                ),
                _StageBar(
                  stage: _stage,
                  onTap: (i) {
                    if (i < _stage) _goTo(i);
                  },
                ),
                if (_stage == 0) ...[
                  const SectionHeader(title: 'Mis servicios'),
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Nombre que verán los clientes',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    validator: (v) => (v ?? '').trim().length < 3 ? 'Escribe tu nombre' : null,
                  ),
                  const SizedBox(height: HySpacing.md),
                  DropdownButtonFormField<int>(
                    key: const Key('application-primary'),
                    initialValue: _primary,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Servicio principal',
                      prefixIcon: Icon(Icons.handyman_outlined),
                    ),
                    items: [for (final c in ordered) DropdownMenuItem(value: c.id, child: Text(c.name))],
                    onChanged: (v) => setState(() {
                      _primary = v;
                      _categories.remove(v);
                    }),
                    validator: (v) => v == null ? 'Elige tu servicio principal' : null,
                  ),
                  const SizedBox(height: HySpacing.md),
                  Text('Otros servicios que ofreces (opcional)', style: text.titleSmall),
                  const SizedBox(height: HySpacing.xs),
                  Wrap(
                    spacing: HySpacing.xs,
                    runSpacing: HySpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final c in ordered.where((c) => _categories.contains(c.id) && c.id != _primary))
                        InputChip(
                          key: Key('extra-${c.slug}'),
                          label: Text(c.name),
                          onDeleted: () => setState(() => _categories.remove(c.id)),
                          deleteButtonTooltipMessage: 'Quitar ${c.name}',
                        ),
                      TextButton.icon(
                        key: const Key('add-extra-services'),
                        onPressed: () async {
                          final picked = await pickExtraServices(
                            context,
                            categories: ordered,
                            primaryId: _primary,
                            selected: _categories,
                          );
                          if (picked != null && mounted) {
                            setState(() {
                              _categories
                                ..clear()
                                ..addAll(picked);
                            });
                          }
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar otros servicios'),
                      ),
                    ],
                  ),
                  const SizedBox(height: HySpacing.md),
                  TextFormField(
                    controller: _years,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                    decoration: const InputDecoration(
                      labelText: 'Años de experiencia',
                      prefixIcon: Icon(Icons.timeline),
                    ),
                  ),
                  const SizedBox(height: HySpacing.md),
                  TextFormField(
                    controller: _bio,
                    maxLines: 4,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Cuéntales a los clientes sobre tu trabajo',
                      alignLabelWithHint: true,
                    ),
                    validator: (v) => (v ?? '').trim().length < 20 ? 'Escribe al menos 20 caracteres' : null,
                  ),
                  const SizedBox(height: HySpacing.xs),
                  TextFormField(
                    controller: _price,
                    decoration: const InputDecoration(
                      labelText: 'Precios de referencia (opcional)',
                      hintText: 'Ej.: Visita Bs 50, el resto según el trabajo',
                      prefixIcon: Icon(Icons.sell_outlined),
                    ),
                  ),
                ],
                if (_stage == 1) ...[
                  const SectionHeader(title: 'Dónde trabajo'),
                  CityField(
                    key: const Key('application-city'),
                    value: _cityId,
                    label: 'Municipio donde trabajas',
                    onChanged: (v) => setState(() {
                      _cityId = v;
                      _zones.clear();
                    }),
                    validator: (v) => v == null ? 'Elige tu municipio' : null,
                  ),
                  const SizedBox(height: HySpacing.sm),
                  if (_cityId != null && zones.isEmpty)
                    Text(
                      'Después de la aprobación marcas en el mapa tu base y hasta dónde llegas.',
                      style: text.bodyMedium?.copyWith(color: HyColors.textSecondary),
                    ),
                  Wrap(
                    spacing: HySpacing.xs,
                    runSpacing: HySpacing.xs,
                    children: [
                      for (final z in zones)
                        FilterChip(
                          label: Text(z.name),
                          selected: _zones.contains(z.id),
                          onSelected: (v) => setState(() => v ? _zones.add(z.id) : _zones.remove(z.id)),
                        ),
                    ],
                  ),
                  const SizedBox(height: HySpacing.md),
                  _ServiceAreaTile(beforeOpen: () => _save(quiet: true)),
                ],
                if (_stage == 2) ...[
                  const SectionHeader(title: 'Verificación'),
                  Text(
                    'Sube una foto clara de tu carnet de identidad (anverso y reverso). Solo el equipo de verificación puede verlos.',
                    style: text.bodyLarge?.copyWith(color: HyColors.textSecondary),
                  ),
                  const SizedBox(height: HySpacing.sm),
                  // Uno debajo del otro: lado a lado no entran en celulares angostos.
                  SecondaryButton(
                    key: const Key('doc-ci-anverso'),
                    label: 'Subir carnet (anverso)',
                    icon: Icons.upload_file,
                    onPressed: _uploading ? null : () => _pickDocument('ci_anverso'),
                  ),
                  const SizedBox(height: HySpacing.xs),
                  SecondaryButton(
                    key: const Key('doc-ci-reverso'),
                    label: 'Subir carnet (reverso)',
                    icon: Icons.upload_file,
                    onPressed: _uploading ? null : () => _pickDocument('ci_reverso'),
                  ),
                  for (final c in categories.where(
                    (c) => c.isSensitive && (_categories.contains(c.id) || _primary == c.id),
                  )) ...[
                    const SizedBox(height: HySpacing.sm),
                    InfoBanner(
                      icon: Icons.verified_user_outlined,
                      tone: StatusTone.warning,
                      text:
                          c.proNote ??
                          'Para ofrecer ${c.name} necesitas un documento adicional aceptado por el equipo.',
                    ),
                    for (final doc in c.requiredDocs) ...[
                      const SizedBox(height: HySpacing.xs),
                      SecondaryButton(
                        key: Key('doc-${c.slug}-$doc'),
                        label: switch (doc) {
                          'certificado' => 'Subir título o matrícula',
                          'nombramiento_notarial' => 'Subir nombramiento',
                          'documentos_grua' => 'Subir licencia, RUAT y SOAT',
                          _ => 'Subir antecedentes',
                        },
                        icon: Icons.upload_file,
                        onPressed: _uploading ? null : () => _pickDocument(doc),
                      ),
                    ],
                  ],
                  const SizedBox(height: HySpacing.xs),
                  if (_uploading)
                    const LinearProgressIndicator(color: HyColors.primary)
                  else
                    Row(
                      children: [
                        Icon(
                          _docs > 0 ? Icons.check_circle : Icons.info_outline,
                          color: _docs > 0 ? HyColors.green : HyColors.textMuted,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(_docs == 0 ? 'Todavía no subiste documentos' : '$_docs documento(s) subido(s)'),
                        ),
                      ],
                    ),
                  const SizedBox(height: HySpacing.lg),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(value: _acceptedRules, onChanged: (v) => setState(() => _acceptedRules = v ?? false)),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text.rich(
                            TextSpan(
                              style: const TextStyle(fontSize: 16, color: HyColors.text),
                              children: [
                                const TextSpan(text: 'Leí y acepto las '),
                                TextSpan(
                                  text: 'Reglas para profesionales',
                                  style: const TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w700),
                                  recognizer: TapGestureRecognizer()
                                    ..onTap = () => showLegalDoc(context, LegalDoc.proRules),
                                ),
                                const TextSpan(text: ' y la '),
                                TextSpan(
                                  text: 'Política de comisiones',
                                  style: const TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w700),
                                  recognizer: TapGestureRecognizer()
                                    ..onTap = () => showLegalDoc(context, LegalDoc.commissions),
                                ),
                                const TextSpan(text: '.'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const InfoBanner(
                    icon: Icons.badge_outlined,
                    text:
                        'Después de enviar, verificas tu identidad (carnet, selfie y prueba de vida) desde esta misma pantalla. '
                        'Una persona del equipo revisa todo antes de aprobarte.',
                  ),
                ],
                const SizedBox(height: HySpacing.lg),
                if (_stage < 2)
                  PrimaryButton(
                    key: const Key('application-next'),
                    label: 'Siguiente',
                    icon: Icons.arrow_forward_rounded,
                    onPressed: _saving ? null : _next,
                  )
                else
                  PrimaryButton(
                    key: const Key('application-submit'),
                    label: 'Enviar postulación',
                    icon: Icons.send_rounded,
                    loading: _saving,
                    onPressed: _submit,
                  ),
                const SizedBox(height: HySpacing.sm),
                SecondaryButton(
                  key: const Key('application-save-draft'),
                  label: 'Guardar borrador',
                  onPressed: _saving ? null : () => _save(),
                ),
                if (_stage > 0) ...[
                  const SizedBox(height: HySpacing.xs),
                  TextButton(
                    key: const Key('application-back'),
                    onPressed: () => _goTo(_stage - 1),
                    child: const Text('Atrás'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Las tres etapas de la postulación. Se puede volver a una anterior tocándola.
class _StageBar extends StatelessWidget {
  const _StageBar({required this.stage, required this.onTap});

  final int stage;
  final ValueChanged<int> onTap;

  static const _labels = ['Mis servicios', 'Dónde trabajo', 'Verificación'];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: HySpacing.sm),
    child: Row(
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          if (i > 0) const SizedBox(width: HySpacing.xs),
          Expanded(
            child: Semantics(
              button: i < stage,
              selected: i == stage,
              label: 'Etapa ${i + 1} de 3: ${_labels[i]}',
              excludeSemantics: true,
              child: InkWell(
                key: Key('application-stage-$i'),
                borderRadius: BorderRadius.circular(HyRadii.sm),
                onTap: i < stage ? () => onTap(i) : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: i <= stage ? HyColors.primary : HyColors.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: HySpacing.xxs),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${i + 1}. ${_labels[i]}',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: i == stage ? FontWeight.w800 : FontWeight.w600,
                            color: i == stage ? HyColors.text : HyColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Base y radio para recibir pedidos ¡Ya! (se puede marcar antes de la aprobación).
class _ServiceAreaTile extends ConsumerWidget {
  const _ServiceAreaTile({required this.beforeOpen});

  final Future<bool> Function() beforeOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = ref.watch(serviceLocationProvider).value;
    return AppCard(
      key: const Key('application-service-area'),
      padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: HySpacing.xxs),
      onTap: () async {
        // La base se guarda junto a la postulación, así que primero va el borrador.
        if (await beforeOpen() && context.mounted) {
          await context.push(Routes.serviceArea);
          ref.invalidate(serviceLocationProvider);
        }
      },
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.my_location, color: HyColors.primary),
        title: const Text('Base y radio de trabajo (GPS)', style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          loc == null
              ? 'Opcional ahora. Define qué pedidos ¡Ya! te llegan.'
              : 'Radio de ${loc.radiusKm} km desde tu base. Toca para cambiarlo.',
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
