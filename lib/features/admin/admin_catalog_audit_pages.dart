import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/providers.dart';
import 'admin_common.dart';
import 'admin_services_pages.dart';
import '../../core/widgets/word_safe_text.dart';

// ======================================================================= Catálogo
class AdminCatalogPage extends ConsumerWidget {
  const AdminCatalogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const OneLineText('Catálogo'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Categorías'),
              Tab(text: 'Ciudades'),
              Tab(text: 'Banners'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            const AdminServiceCategoriesTab(),
            _ToggleList(
              provider: adminCitiesProvider,
              onToggle: (id, v) => ref.read(backendProvider).setCityActive(id, v),
              afterChange: () => ref.invalidate(citiesProvider),
              help: 'Una ciudad apagada no aparece para elegir. Los pedidos que ya existen no cambian.',
            ),
            _ToggleList(
              provider: adminPromotionsProvider,
              onToggle: (id, v) => ref.read(backendProvider).setPromotionActive(id, v),
              afterChange: () => ref.invalidate(promotionsProvider),
              help: 'El banner activo aparece en el inicio de los clientes.',
              footer: SecondaryButton(
                label: 'Nuevo banner',
                icon: Icons.add,
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => const _NewBannerSheet(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleList extends ConsumerWidget {
  const _ToggleList({
    required this.provider,
    required this.onToggle,
    required this.afterChange,
    required this.help,
    this.footer,
  });

  final FutureProvider<List<CatalogItem>> provider;
  final Future<void> Function(int id, bool active) onToggle;
  final VoidCallback afterChange;
  final String help;
  final Widget? footer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminList<CatalogItem>(
      value: ref.watch(provider),
      onRefresh: () => ref.refresh(provider.future),
      emptyTitle: 'Todavía no hay nada aquí',
      emptyIcon: Icons.inbox_outlined,
      header: Padding(
        padding: const EdgeInsets.only(bottom: HySpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InfoBanner(text: help),
            if (footer != null) ...[const SizedBox(height: HySpacing.sm), footer!],
          ],
        ),
      ),
      itemBuilder: (context, item) => AppCard(
        padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: 4),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          subtitle: item.subtitle == null ? null : Text(item.subtitle!),
          value: item.isActive,
          onChanged: (v) async {
            final ok = await runGuarded(context, () => onToggle(item.id, v));
            if (ok) {
              ref.invalidate(provider);
              afterChange();
            }
          },
        ),
      ),
    );
  }
}

class _NewBannerSheet extends ConsumerStatefulWidget {
  const _NewBannerSheet();

  @override
  ConsumerState<_NewBannerSheet> createState() => _NewBannerSheetState();
}

class _NewBannerSheetState extends ConsumerState<_NewBannerSheet> {
  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  int? _city;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().length < 3) {
      showMessage(context, 'Escribe un título.');
      return;
    }
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).createPromotion(title: _title.text, subtitle: _subtitle.text, cityId: _city),
      success: 'Banner creado',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref
        ..invalidate(adminPromotionsProvider)
        ..invalidate(promotionsProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cities = ref.watch(citiesProvider).value ?? const [];
    return Padding(
      padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, sheetBottomInset(context) + HySpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Nuevo banner', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: HySpacing.md),
          TextField(
            controller: _title,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Título', hintText: 'Ej.: ¿Se cortó la luz?'),
          ),
          TextField(
            controller: _subtitle,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'Texto (opcional)'),
          ),
          DropdownButtonFormField<int?>(
            initialValue: _city,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Dónde se muestra'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('Toda Bolivia')),
              for (final c in cities) DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
            ],
            onChanged: (v) => setState(() => _city = v),
          ),
          const SizedBox(height: HySpacing.md),
          PrimaryButton(label: 'Crear banner', loading: _saving, onPressed: _save),
        ],
      ),
    );
  }
}

// ======================================================================= Auditoría
class AdminAuditPage extends ConsumerWidget {
  const AdminAuditPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Auditoría')),
      body: AdminList<AuditEntry>(
        value: ref.watch(auditLogProvider),
        onRefresh: () => ref.refresh(auditLogProvider.future),
        emptyTitle: 'Todavía no hay acciones registradas',
        emptyIcon: Icons.history,
        header: const Padding(
          padding: EdgeInsets.only(bottom: HySpacing.sm),
          child: InfoBanner(
            icon: Icons.lock_outline,
            text: 'Cada acción de un administrador queda aquí y no se puede borrar ni editar.',
          ),
        ),
        itemBuilder: (context, e) => AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              InfoLine(Icons.person_outline, '${e.actorName} · ${Fmt.dateTime(e.createdAt)}'),
              if (e.details.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  shape: const Border(),
                  title: const Text('Ver detalle', style: TextStyle(fontSize: 15)),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent('  ').convert(e.details),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
