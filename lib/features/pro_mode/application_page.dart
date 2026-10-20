import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/catalog.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../legal/legal_texts.dart';

/// Postulación para ser profesional: datos, zonas, documentos y envío.
class ApplicationPage extends ConsumerWidget {
  const ApplicationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(applicationProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quiero ser profesional'),
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go(Routes.home)),
      ),
      body: app.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(applicationProvider)),
        data: (a) => a.status.canEdit ? _ApplicationForm(app: a) : _StatusView(app: a),
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
          message: approved
              ? 'Ya puedes recibir pedidos. Activa tu disponibilidad desde el modo profesional.'
              : 'Nuestro equipo está revisando tus datos y documentos. Te avisaremos por notificación.',
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

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _years.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<bool> _save({bool quiet = false}) async {
    if (!_formKey.currentState!.validate()) return false;
    if (_zones.isEmpty) {
      showMessage(context, 'Elige al menos una zona donde trabajas.');
      return false;
    }
    return runGuarded(
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
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).value ?? const <ServiceCategory>[];
    final cities = ref.watch(citiesProvider).value ?? const <City>[];
    final zones = _cityId == null ? const <Zone>[] : ref.watch(zonesProvider(_cityId!)).value ?? const <Zone>[];
    final text = Theme.of(context).textTheme;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.only(bottom: HySpacing.xxl),
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
                const SectionHeader(title: '1. Tus datos'),
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
                  initialValue: _primary,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Servicio principal',
                    prefixIcon: Icon(Icons.handyman_outlined),
                  ),
                  items: [for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                  onChanged: (v) => setState(() => _primary = v),
                  validator: (v) => v == null ? 'Elige tu servicio principal' : null,
                ),
                const SizedBox(height: HySpacing.md),
                Text('Otros servicios que ofreces (opcional)', style: text.titleSmall),
                const SizedBox(height: HySpacing.xs),
                Wrap(
                  spacing: HySpacing.xs,
                  runSpacing: HySpacing.xs,
                  children: [
                    for (final c in categories.where((c) => c.id != _primary))
                      FilterChip(
                        label: Text(c.name),
                        selected: _categories.contains(c.id),
                        onSelected: (v) => setState(() => v ? _categories.add(c.id) : _categories.remove(c.id)),
                      ),
                  ],
                ),
                const SizedBox(height: HySpacing.md),
                TextFormField(
                  controller: _years,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                  decoration: const InputDecoration(labelText: 'Años de experiencia', prefixIcon: Icon(Icons.timeline)),
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
                const SectionHeader(title: '2. Dónde trabajas'),
                DropdownButtonFormField<int>(
                  initialValue: _cityId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Ciudad',
                    prefixIcon: Icon(Icons.location_city_outlined),
                  ),
                  items: [for (final c in cities) DropdownMenuItem(value: c.id, child: Text(c.name))],
                  onChanged: (v) => setState(() {
                    _cityId = v;
                    _zones.clear();
                  }),
                  validator: (v) => v == null ? 'Elige tu ciudad' : null,
                ),
                const SizedBox(height: HySpacing.sm),
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
                const SectionHeader(title: '3. Documentos'),
                Text(
                  'Sube una foto clara de tu carnet de identidad (anverso y reverso). Solo el equipo de verificación puede verlos.',
                  style: text.bodyLarge?.copyWith(color: HyColors.textSecondary),
                ),
                const SizedBox(height: HySpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: 'Carnet (anverso)',
                        icon: Icons.upload_file,
                        onPressed: _uploading ? null : () => _pickDocument('id_front'),
                      ),
                    ),
                    const SizedBox(width: HySpacing.sm),
                    Expanded(
                      child: SecondaryButton(
                        label: 'Carnet (reverso)',
                        icon: Icons.upload_file,
                        onPressed: _uploading ? null : () => _pickDocument('id_back'),
                      ),
                    ),
                  ],
                ),
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
                      Text(_docs == 0 ? 'Todavía no subiste documentos' : '$_docs documento(s) subido(s)'),
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
                const SizedBox(height: HySpacing.md),
                PrimaryButton(
                  label: 'Enviar postulación',
                  icon: Icons.send_rounded,
                  loading: _saving,
                  onPressed: _submit,
                ),
                const SizedBox(height: HySpacing.sm),
                SecondaryButton(label: 'Guardar borrador', onPressed: _saving ? null : () => _save()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
