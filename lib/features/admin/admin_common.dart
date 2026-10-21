import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';

// Datos del panel. Se recargan con ref.invalidate después de cada acción.
final adminDashboardProvider = FutureProvider<AdminDashboard>((ref) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).adminDashboard();
});
final adminApplicationsProvider = FutureProvider.family<List<AdminApplication>, String>(
  (ref, status) => ref.watch(backendProvider).adminApplications(status: status),
);
final adminApplicationDetailProvider = FutureProvider.family<AdminApplicationDetail, String>(
  (ref, id) => ref.watch(backendProvider).adminApplicationDetail(id),
);
final adminTopupsProvider = FutureProvider.family<List<AdminTopup>, String>(
  (ref, status) => ref.watch(backendProvider).adminTopups(status: status),
);
final adminReportsProvider = FutureProvider.family<List<AdminReport>, String>(
  (ref, status) => ref.watch(backendProvider).adminReports(status: status),
);
final adminDisputesProvider = FutureProvider.family<List<AdminDispute>, String>(
  (ref, status) => ref.watch(backendProvider).adminDisputes(status: status),
);
final adminTicketsProvider = FutureProvider.family<List<AdminTicket>, String>(
  (ref, status) => ref.watch(backendProvider).adminTickets(status: status),
);
final adminUsersProvider = FutureProvider.family<List<AdminUser>, String>(
  (ref, query) => ref.watch(backendProvider).adminUsers(query),
);
final commissionRulesProvider = FutureProvider<List<CommissionRule>>(
  (ref) => ref.watch(backendProvider).commissionRules(),
);
final adminCategoriesProvider = FutureProvider<List<CatalogItem>>(
  (ref) => ref.watch(backendProvider).adminCategories(),
);
final adminCitiesProvider = FutureProvider<List<CatalogItem>>((ref) => ref.watch(backendProvider).adminCities());
final adminPromotionsProvider = FutureProvider<List<CatalogItem>>(
  (ref) => ref.watch(backendProvider).adminPromotions(),
);
final auditLogProvider = FutureProvider<List<AuditEntry>>((ref) => ref.watch(backendProvider).auditLog());

/// Lista con estados de carga, error y vacío, y "tirar para actualizar".
class AdminList<T> extends StatelessWidget {
  const AdminList({
    super.key,
    required this.value,
    required this.onRefresh,
    required this.itemBuilder,
    required this.emptyTitle,
    this.emptyIcon = Icons.check_circle_outline,
    this.header,
  });

  final AsyncValue<List<T>> value;
  final Future<void> Function() onRefresh;
  final Widget Function(BuildContext, T) itemBuilder;
  final String emptyTitle;
  final IconData emptyIcon;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: bottomSafePadding(context, top: HySpacing.sm),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?header,
                ...switch (value) {
                  AsyncData(:final value) when value.isEmpty => [EmptyState(icon: emptyIcon, title: emptyTitle)],
                  AsyncData(:final value) => [
                    for (final item in value)
                      Padding(
                        padding: const EdgeInsets.only(bottom: HySpacing.sm),
                        child: itemBuilder(context, item),
                      ),
                  ],
                  AsyncError(:final error) => [ErrorView(error: error, onRetry: onRefresh)],
                  _ => [const LoadingView()],
                },
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Etiqueta de estado con color.
class ToneChip extends StatelessWidget {
  const ToneChip(this.label, this.tone, {super.key});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: 4),
    decoration: BoxDecoration(color: tone.background, borderRadius: BorderRadius.circular(HyRadii.pill)),
    child: Text(
      label,
      style: TextStyle(color: tone.foreground, fontWeight: FontWeight.w700, fontSize: 13),
    ),
  );
}

/// Línea "Etiqueta: valor" para las fichas del panel.
class InfoLine extends StatelessWidget {
  const InfoLine(this.icon, this.text, {super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: HyColors.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: const TextStyle(color: HyColors.textSecondary, fontSize: 15)),
        ),
      ],
    ),
  );
}

/// Foto de un documento o comprobante. Se agranda al tocarla.
class EvidenceImage extends StatelessWidget {
  const EvidenceImage({super.key, this.url, this.bytes, this.height = 160, required this.label});

  final String? url;
  final Uint8List? bytes;
  final double height;
  final String label;

  Widget _image(BoxFit fit) {
    if (bytes != null) return Image.memory(bytes!, fit: fit);
    if (url != null) {
      return Image.network(url!, fit: fit, errorBuilder: (_, _, _) => const _NoImage('No se pudo cargar la imagen'));
    }
    return const _NoImage('Imagen de ejemplo (modo demostración)');
  }

  @override
  Widget build(BuildContext context) {
    final has = bytes != null || url != null;
    return Semantics(
      label: label,
      button: has,
      child: InkWell(
        borderRadius: BorderRadius.circular(HyRadii.md),
        onTap: has
            ? () => showDialog<void>(
                context: context,
                builder: (c) => Dialog(
                  insetPadding: const EdgeInsets.all(HySpacing.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: InteractiveViewer(child: _image(BoxFit.contain))),
                      TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cerrar')),
                    ],
                  ),
                ),
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(HyRadii.md),
          child: SizedBox(height: height, width: double.infinity, child: _image(BoxFit.cover)),
        ),
      ),
    );
  }
}

class _NoImage extends StatelessWidget {
  const _NoImage(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    color: HyColors.surfaceMuted,
    alignment: Alignment.center,
    padding: const EdgeInsets.all(HySpacing.sm),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_outlined, size: 36, color: HyColors.textMuted),
          const SizedBox(height: 4),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: HyColors.textMuted),
          ),
        ],
      ),
    ),
  );
}

/// Pide una nota opcional (por ejemplo, al aprobar).
Future<String?> promptOptional(
  BuildContext context, {
  required String title,
  required String label,
  required String confirm,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        maxLines: 3,
        minLines: 1,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Volver')),
        FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: Text(confirm)),
      ],
    ),
  );
}
