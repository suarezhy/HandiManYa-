import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/models/booking.dart';
import '../../data/models/costs.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../security/confirm_identity.dart';
import 'admin_common.dart';

StatusTone _tone(VerificationStatus s) => switch (s) {
  VerificationStatus.approved => StatusTone.success,
  VerificationStatus.rejected || VerificationStatus.suspended => StatusTone.danger,
  VerificationStatus.submitted || VerificationStatus.underReview => StatusTone.warning,
  _ => StatusTone.neutral,
};

class AdminApplicationsPage extends ConsumerWidget {
  const AdminApplicationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Postulaciones'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Por revisar'),
              Tab(text: 'Todas'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final s in const ['pending', 'all']) _List(status: s),
          ],
        ),
      ),
    );
  }
}

class _List extends ConsumerWidget {
  const _List({required this.status});

  final String status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminList<AdminApplication>(
      value: ref.watch(adminApplicationsProvider(status)),
      onRefresh: () => ref.refresh(adminApplicationsProvider(status).future),
      emptyTitle: 'No hay postulaciones por revisar',
      itemBuilder: (context, a) => AppCard(
        onTap: () => context.push(Routes.adminApplication(a.userId)),
        child: Row(
          children: [
            PersonAvatar(name: a.displayName, size: 52),
            const SizedBox(width: HySpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  InfoLine(Icons.handyman_outlined, [a.categoryName, a.cityName].whereType<String>().join(' · ')),
                  InfoLine(
                    Icons.schedule,
                    a.submittedAt == null ? 'Sin enviar' : 'Enviada ${Fmt.relative(a.submittedAt!)}',
                  ),
                ],
              ),
            ),
            ToneChip(a.status.label, _tone(a.status)),
          ],
        ),
      ),
    );
  }
}

class AdminApplicationDetailPage extends ConsumerWidget {
  const AdminApplicationDetailPage({super.key, required this.professionalId});

  final String professionalId;

  void _refresh(WidgetRef ref) {
    ref
      ..invalidate(adminApplicationDetailProvider(professionalId))
      ..invalidate(adminApplicationsProvider)
      ..invalidate(adminDashboardProvider);
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, VerificationStatus decision) async {
    final backend = ref.read(backendProvider);
    String? note;
    switch (decision) {
      case VerificationStatus.approved:
        if (!await confirmDialog(
          context,
          title: '¿Aprobar a este profesional?',
          message: 'Podrá recibir pedidos ¡Ya! y aparecerá con la insignia "Verificado".',
          confirm: 'Aprobar',
        )) {
          return;
        }
      case VerificationStatus.rejected:
      case VerificationStatus.reverificationRequired:
        note = await promptText(
          context,
          title: decision == VerificationStatus.rejected ? 'Rechazar postulación' : 'Pedir corrección',
          label: 'Motivo (lo verá el profesional)',
          hint: 'Ej.: la foto del carnet no se lee',
          confirm: decision == VerificationStatus.rejected ? 'Rechazar' : 'Enviar',
        );
        if (note == null) return;
      default:
        break;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => backend.reviewApplication(professionalId, decision, note: note),
      success: 'Listo: ${decision.label.toLowerCase()}',
    );
    if (ok) _refresh(ref);
  }

  Future<void> _reviewDoc(BuildContext context, WidgetRef ref, AdminDocument d, DocumentStatus status) async {
    String? note;
    if (status == DocumentStatus.rejected) {
      note = await promptText(context, title: 'Rechazar documento', label: 'Motivo', confirm: 'Rechazar');
      if (note == null) return;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(context, () => ref.read(backendProvider).reviewDocument(d.id, status, note: note));
    if (ok) _refresh(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(adminApplicationDetailProvider(professionalId));
    return Scaffold(
      appBar: AppBar(title: const Text('Postulación')),
      body: switch (detail) {
        AsyncData(:final value) => _detail(context, ref, value),
        AsyncError(:final error) => ErrorView(error: error, onRetry: () => _refresh(ref)),
        _ => const LoadingView(),
      },
    );
  }

  Widget _detail(BuildContext context, WidgetRef ref, AdminApplicationDetail d) {
    final a = d.summary;
    final pending = a.status == VerificationStatus.submitted || a.status == VerificationStatus.underReview;
    return ListView(
      padding: bottomSafePadding(context),
      children: [
        PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: HySpacing.md),
              Row(
                children: [
                  PersonAvatar(name: a.displayName, size: 64),
                  const SizedBox(width: HySpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.displayName, style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 4),
                        ToneChip(a.status.label, _tone(a.status)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HySpacing.md),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InfoLine(Icons.person_outline, 'Nombre en la cuenta: ${a.fullName}'),
                    if (a.phone != null) InfoLine(Icons.phone_outlined, a.phone!),
                    if (a.email != null) InfoLine(Icons.mail_outline, a.email!),
                    InfoLine(Icons.location_city, a.cityName ?? 'Sin ciudad'),
                    InfoLine(
                      Icons.handyman_outlined,
                      [a.categoryName, ...d.categories].whereType<String>().toSet().join(', '),
                    ),
                    if (d.zones.isNotEmpty) InfoLine(Icons.map_outlined, 'Zonas: ${d.zones.join(', ')}'),
                    if (d.yearsExperience != null) InfoLine(Icons.timeline, '${d.yearsExperience} años de experiencia'),
                    if ((d.bio ?? '').isNotEmpty) ...[
                      const SizedBox(height: HySpacing.xs),
                      Text(d.bio!, style: const TextStyle(fontSize: 16)),
                    ],
                  ],
                ),
              ),
              _IdentitySection(detail: d, onChanged: () => _refresh(ref)),
              SectionHeader(title: 'Documentos (${d.documents.length})'),
              if (d.documents.isEmpty)
                const InfoBanner(
                  icon: Icons.warning_amber_rounded,
                  tone: StatusTone.warning,
                  text: 'No subió documentos. No lo apruebes sin verificar su identidad.',
                ),
              for (final doc in d.documents)
                Padding(
                  padding: const EdgeInsets.only(bottom: HySpacing.sm),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(doc.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                            ),
                            ToneChip(doc.status.label, switch (doc.status) {
                              DocumentStatus.accepted => StatusTone.success,
                              DocumentStatus.rejected => StatusTone.danger,
                              DocumentStatus.pending => StatusTone.warning,
                            }),
                          ],
                        ),
                        const SizedBox(height: HySpacing.xs),
                        EvidenceImage(url: doc.url, bytes: doc.bytes, label: doc.label, height: 200),
                        if (doc.reviewNote != null) InfoLine(Icons.notes, doc.reviewNote!),
                        const SizedBox(height: HySpacing.xs),
                        Row(
                          children: [
                            Expanded(
                              child: SecondaryButton(
                                label: 'Rechazar',
                                onPressed: doc.status == DocumentStatus.rejected
                                    ? null
                                    : () => _reviewDoc(context, ref, doc, DocumentStatus.rejected),
                              ),
                            ),
                            const SizedBox(width: HySpacing.xs),
                            Expanded(
                              child: PrimaryButton(
                                label: 'Aceptar',
                                color: HyColors.greenDark,
                                onPressed: doc.status == DocumentStatus.accepted
                                    ? null
                                    : () => _reviewDoc(context, ref, doc, DocumentStatus.accepted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              const SectionHeader(title: 'Decisión'),
              if (a.status == VerificationStatus.approved)
                const InfoBanner(
                  icon: Icons.verified,
                  tone: StatusTone.success,
                  text: 'Este profesional ya está aprobado.',
                )
              else ...[
                PrimaryButton(
                  label: 'Aprobar profesional',
                  icon: Icons.verified_outlined,
                  color: HyColors.greenDark,
                  onPressed: () => _decide(context, ref, VerificationStatus.approved),
                ),
                const SizedBox(height: HySpacing.xs),
                if (pending) ...[
                  SecondaryButton(
                    label: 'Pedir corrección',
                    icon: Icons.edit_note,
                    onPressed: () => _decide(context, ref, VerificationStatus.reverificationRequired),
                  ),
                  const SizedBox(height: HySpacing.xs),
                ],
                SecondaryButton(
                  label: 'Rechazar',
                  icon: Icons.block,
                  onPressed: a.status == VerificationStatus.rejected
                      ? null
                      : () => _decide(context, ref, VerificationStatus.rejected),
                ),
              ],
              if (d.history.isNotEmpty) ...[
                const SectionHeader(title: 'Historial'),
                for (final h in d.history)
                  InfoLine(
                    Icons.circle,
                    '${Fmt.dateTime(h.at)} · ${h.status.label}${h.note == null ? '' : ': ${h.note}'}',
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Verificación de identidad (Didit): una señal para quien revisa. El
/// resultado no aprueba ni rechaza a nadie, y una prueba del sandbox nunca
/// cuenta como verificación real. Los antecedentes van aparte, en Documentos.
class _IdentitySection extends ConsumerWidget {
  const _IdentitySection({required this.detail, required this.onChanged});

  final AdminApplicationDetail detail;
  final VoidCallback onChanged;

  static StatusTone _tone(IdentityStatus s) => switch (s) {
    IdentityStatus.approved => StatusTone.success,
    IdentityStatus.declined || IdentityStatus.failed => StatusTone.danger,
    IdentityStatus.inReview => StatusTone.warning,
    _ => StatusTone.neutral,
  };

  Future<void> _setRequired(BuildContext context, WidgetRef ref, bool required) async {
    String? method;
    if (!required) {
      final c = await confirmIdentity(
        context,
        operation: 'Dejar de exigir la verificación de identidad real para aprobar',
        submitLabel: 'Confirmar',
      );
      if (c == null) return;
      method = c.serverMethod;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).setIdentityCheckRequired(required, authMethod: method),
      success: required ? 'Desde ahora, aprobar exige una verificación real.' : 'Ya no se exige.',
    );
    if (ok) onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checks = detail.identityChecks;
    return Column(
      key: const Key('identity-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'Verificación de identidad'),
        if (checks.isEmpty)
          const InfoBanner(
            icon: Icons.badge_outlined,
            tone: StatusTone.warning,
            text: 'Sin verificación de identidad. Revisa el carnet y la selfie a mano antes de decidir.',
          ),
        for (final c in checks)
          Padding(
            padding: const EdgeInsets.only(bottom: HySpacing.xs),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: HySpacing.xs,
                    runSpacing: 4,
                    children: [
                      ToneChip(c.status.label, _tone(c.status)),
                      if (c.sandbox) const ToneChip('Prueba (no cuenta)', StatusTone.info),
                    ],
                  ),
                  if (c.documentType != null) InfoLine(Icons.badge_outlined, 'Documento: ${c.documentType}'),
                  if (c.livenessScore != null)
                    InfoLine(
                      Icons.face_retouching_natural,
                      'Prueba de vida: ${c.livenessScore!.toStringAsFixed(0)}/100',
                    ),
                  if (c.faceMatchScore != null)
                    InfoLine(
                      Icons.compare_outlined,
                      'Parecido con el carnet: ${c.faceMatchScore!.toStringAsFixed(0)}%',
                    ),
                  if (c.warnings.isNotEmpty) InfoLine(Icons.warning_amber_rounded, 'Avisos: ${c.warnings.join(', ')}'),
                  if (c.createdAt != null) InfoLine(Icons.schedule, Fmt.dateTime(c.createdAt!.toLocal())),
                  if (c.vendorDeleted) const InfoLine(Icons.delete_outline, 'Datos ya borrados en Didit'),
                ],
              ),
            ),
          ),
        SwitchListTile(
          key: const Key('identity-required'),
          contentPadding: EdgeInsets.zero,
          value: detail.identityCheckRequired,
          title: const Text('Exigir verificación real para aprobar'),
          subtitle: const Text('Vale para todas las postulaciones. Las pruebas del sandbox no cuentan.'),
          onChanged: (v) => _setRequired(context, ref, v),
        ),
      ],
    );
  }
}
