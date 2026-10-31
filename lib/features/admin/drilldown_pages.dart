import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/drilldown.dart';
import '../../data/models/staff.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../management/cases_pages.dart';
import '../management/management_common.dart';
import 'admin_common.dart';
import 'ai_control_center_page.dart';
import 'finance_pages.dart';
import '../../core/widgets/word_safe_text.dart';

/// Lo que hay detrás de cada número del panel: pedidos, seguridad y fraude, y
/// billeteras. Las listas salen de la base con las mismas definiciones que el
/// panel (0041) y el servidor decide quién ve qué; aquí solo se muestra.

final opsBookingsProvider = FutureProvider.autoDispose.family<Listed<OpsBooking>, (BookingFilter, String)>(
  (ref, k) => ref.watch(backendProvider).opsBookings(k.$1, query: k.$2),
);
final opsBookingDetailProvider = FutureProvider.autoDispose.family<OpsBookingDetail, String>(
  (ref, id) => ref.watch(backendProvider).opsBookingDetail(id),
);
final riskItemsProvider = FutureProvider.autoDispose.family<Listed<RiskItem>, RiskKind>(
  (ref, kind) => ref.watch(backendProvider).riskItems(kind),
);
final ownerWalletsProvider = FutureProvider.autoDispose.family<WalletList, (String, WalletSort)>(
  (ref, k) => ref.watch(backendProvider).ownerWallets(query: k.$1, sort: k.$2),
);

/// "Mostrando 100 de 230" cuando la lista trae solo los primeros.
Widget _countLine(int shown, int total, String noun) => Padding(
  padding: const EdgeInsets.only(bottom: HySpacing.xs),
  child: Text(
    shown < total ? 'Mostrando $shown de $total $noun. Busca para encontrar el resto.' : '$total $noun',
    key: const Key('drilldown-count'),
    style: const TextStyle(color: HyColors.textSecondary),
  ),
);

/// Buscador con espera corta, para no pedir a la base en cada letra.
class DrilldownSearchField extends StatefulWidget {
  const DrilldownSearchField({super.key, required this.hint, required this.onChanged, this.fieldKey});

  final String hint;
  final ValueChanged<String> onChanged;
  final Key? fieldKey;

  @override
  State<DrilldownSearchField> createState() => _DrilldownSearchFieldState();
}

class _DrilldownSearchFieldState extends State<DrilldownSearchField> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.fieldKey,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(hintText: widget.hint, prefixIcon: const Icon(Icons.search)),
    onChanged: (v) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), () => widget.onChanged(v.trim()));
    },
  );
}

/// Chips en una fila que se desliza (en 320 px no caben todos).
Widget drilldownChipRow<T>(List<(T, String)> options, T selected, ValueChanged<T> onSelected, String keyPrefix) =>
    SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (value, label) in options)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: HySpacing.xs),
              child: ChoiceChip(
                key: Key('$keyPrefix-$value'),
                label: Text(label),
                selected: selected == value,
                onSelected: (_) => onSelected(value),
              ),
            ),
        ],
      ),
    );

// ===================================================================== Pedidos
class OpsBookingsPage extends ConsumerStatefulWidget {
  const OpsBookingsPage({super.key, this.initialFilter = BookingFilter.today});

  final BookingFilter initialFilter;

  @override
  ConsumerState<OpsBookingsPage> createState() => _OpsBookingsPageState();
}

class _OpsBookingsPageState extends ConsumerState<OpsBookingsPage> {
  late BookingFilter _filter = widget.initialFilter;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final key = (_filter, _query);
    final value = ref.watch(opsBookingsProvider(key));
    return Scaffold(
      appBar: AppBar(title: OneLineText(_filter.title)),
      body: AdminList<OpsBooking>(
        value: value.whenData((l) => l.items),
        onRefresh: () => ref.refresh(opsBookingsProvider(key).future),
        emptyIcon: Icons.receipt_long_outlined,
        emptyTitle: _query.isEmpty ? 'No hay pedidos en "${_filter.label.toLowerCase()}".' : 'Ningún pedido coincide.',
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            drilldownChipRow(
              [for (final f in BookingFilter.values) (f, f.label)],
              _filter,
              (f) => setState(() => _filter = f),
              'bookings-filter',
            ),
            const SizedBox(height: HySpacing.sm),
            DrilldownSearchField(
              fieldKey: const Key('bookings-search'),
              hint: 'Código, cliente o profesional',
              onChanged: (q) => setState(() => _query = q),
            ),
            const SizedBox(height: HySpacing.sm),
            if (value case AsyncData(:final value) when value.items.isNotEmpty)
              _countLine(value.items.length, value.total, value.total == 1 ? 'pedido' : 'pedidos'),
          ],
        ),
        itemBuilder: (context, b) => _BookingCard(booking: b),
      ),
    );
  }
}

final _demandProvider = FutureProvider.autoDispose.family<DemandBookings?, (DemandKind, String, String?)>(
  (ref, k) => ref.watch(backendProvider).demandBookings(k.$1, k.$2, department: k.$3),
);

/// Los pedidos de los últimos 30 días que cuenta una fila de demanda del
/// panel (municipio, departamento o categoría), con la misma definición.
class DemandBookingsPage extends ConsumerWidget {
  const DemandBookingsPage({
    super.key,
    required this.kind,
    required this.name,
    this.department,
    this.coverageGap = false,
  });

  final DemandKind kind;
  final String name;
  final String? department;

  /// Abierta desde "Sin cobertura".
  final bool coverageGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (kind, name, department);
    final value = ref.watch(_demandProvider(key));
    return Scaffold(
      appBar: AppBar(title: OneLineText(name)),
      body: AdminList<OpsBooking>(
        value: value.whenData((d) => d?.bookings.items ?? const []),
        onRefresh: () => ref.refresh(_demandProvider(key).future),
        emptyIcon: Icons.receipt_long_outlined,
        emptyTitle: value.value == null && value.hasValue
            ? 'Esta lista se activa con la próxima actualización del servidor.'
            : 'Sin pedidos en los últimos 30 días.',
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                switch (kind) {
                  DemandKind.municipality => 'Municipio',
                  DemandKind.department => 'Departamento',
                  DemandKind.category => 'Categoría',
                },
                ?department,
                'pedidos de los últimos 30 días (sin borradores)',
              ].join(' · '),
              style: const TextStyle(color: HyColors.textSecondary),
            ),
            const SizedBox(height: HySpacing.xs),
            if (value.value case final d?) ...[
              _countLine(d.bookings.items.length, d.bookings.total, d.bookings.total == 1 ? 'pedido' : 'pedidos'),
              if (d.professionals != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: HySpacing.sm),
                  child: InfoBanner(
                    key: const Key('demand-coverage'),
                    icon: d.professionals == 0 ? Icons.location_off_outlined : Icons.groups_outlined,
                    text: d.professionals == 0
                        ? 'Ningún profesional aprobado tiene base en este municipio. '
                              'Puede haber quien atienda desde otro municipio por radio.'
                        : '${d.professionals} profesional(es) aprobado(s) con base aquí.',
                  ),
                ),
            ],
          ],
        ),
        itemBuilder: (context, b) => _BookingCard(booking: b),
      ),
    );
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({required this.booking});

  final OpsBooking booking;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    return AppCard(
      key: Key('ops-booking-${b.code}'),
      onTap: () => context.push(Routes.opsBooking(b.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${b.categoryName ?? 'Servicio'} · ${b.code}',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              ToneChip(b.status.label, b.status.tone),
            ],
          ),
          InfoLine(Icons.place_outlined, [?b.cityName, ?b.zoneName].join(' · ')),
          InfoLine(
            Icons.person_outline,
            'Cliente: ${b.customerName} · Profesional: ${b.professionalName ?? 'sin asignar'}',
          ),
          InfoLine(
            Icons.schedule,
            '${b.mode == BookingMode.now ? '¡Ya!' : 'Programado'} · ${Fmt.dateTime(b.createdAt)}',
          ),
          if (b.finalAmount != null || b.commissionCaptured != null)
            InfoLine(
              Icons.payments_outlined,
              [
                if (b.finalAmount != null) 'Pagado al profesional ${Fmt.bs(b.finalAmount!)}',
                if (b.commissionCaptured != null) 'comisión ${Fmt.bs(b.commissionCaptured!)}',
              ].join(' · '),
            ),
          if (b.hasDispute || b.openCaseId != null)
            Padding(
              padding: const EdgeInsets.only(top: HySpacing.xxs),
              child: Wrap(
                spacing: HySpacing.xxs,
                children: [
                  if (b.hasDispute) const ToneChip('Disputa abierta', StatusTone.danger),
                  if (b.openCaseId != null) const ToneChip('Caso abierto', StatusTone.warning),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class OpsBookingDetailPage extends ConsumerWidget {
  const OpsBookingDetailPage({super.key, required this.bookingId});

  final String bookingId;

  Future<void> _openCase(BuildContext context, WidgetRef ref, OpsBooking b) async {
    final picked = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OpenCaseSheet(code: b.code),
    );
    if (picked == null || !context.mounted) return;
    final (category, reason) = picked;
    if (!await confirmDialog(
      context,
      title: '¿Abrir un caso para el pedido ${b.code}?',
      message:
          'Queda en Casos para asignarlo y darle seguimiento. '
          '${category == 'routine' ? '' : 'Por ser ${category == 'safety' ? 'de seguridad' : 'posible fraude'}, entra como urgente. '}'
          'No le avisa al cliente ni al profesional.',
      confirm: 'Abrir caso',
    )) {
      return;
    }
    if (!context.mounted) return;
    int? id;
    final ok = await runGuarded(
      context,
      () async => id = await ref.read(backendProvider).openBookingCase(b.id, reason, category: category),
      success: 'Caso abierto. Lo encuentras en Casos.',
    );
    if (!ok || !context.mounted) return;
    refreshOps(ref);
    ref.invalidate(opsBookingDetailProvider(bookingId));
    ref.invalidate(opsBookingsProvider);
    ref.invalidate(adminDashboardProvider);
    if (id != null) unawaited(context.push(Routes.staffCase(id!)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(opsBookingDetailProvider(bookingId));
    final role = ref.watch(accountProvider).value?.managementRole;
    return Scaffold(
      appBar: AppBar(title: OneLineText(detail.value == null ? 'Pedido' : 'Pedido ${detail.value!.booking.code}')),
      body: switch (detail) {
        AsyncData(:final value) => RefreshIndicator(
          onRefresh: () => ref.refresh(opsBookingDetailProvider(bookingId).future),
          child: _BookingDetailBody(
            detail: value,
            role: role,
            onOpenCase: () => _openCase(context, ref, value.booking),
          ),
        ),
        AsyncError(:final error) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(opsBookingDetailProvider(bookingId)),
        ),
        _ => const LoadingView(),
      },
    );
  }
}

class _BookingDetailBody extends StatelessWidget {
  const _BookingDetailBody({required this.detail, required this.role, required this.onOpenCase});

  final OpsBookingDetail detail;
  final StaffRole? role;
  final VoidCallback onOpenCase;

  @override
  Widget build(BuildContext context) {
    final b = detail.booking;
    final bookingCase = detail.cases
        .where((c) => c.kind == OpsCaseKind.booking && c.status != OpsCaseStatus.resolved)
        .firstOrNull;
    final hasMoney = b.finalAmount != null || b.commissionReserved != null || b.quoteAmount != null;
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
                  Expanded(child: Text(b.categoryName ?? 'Servicio', style: Theme.of(context).textTheme.headlineSmall)),
                  ToneChip(b.status.label, b.status.tone),
                ],
              ),
              const SizedBox(height: HySpacing.xs),
              _Row('Código', b.code),
              _Row('Tipo', b.mode == BookingMode.now ? '¡Ya! (ahora)' : 'Programado'),
              _Row('Lugar', [?b.cityName, ?b.zoneName].join(' · ')),
              _Row('Cliente', b.customerName),
              _Row('Profesional', b.professionalName ?? 'Sin profesional todavía'),
              _Row('Pedido', Fmt.dateTime(b.createdAt)),
              if (b.scheduledStart != null) _Row('Programado para', Fmt.dateTime(b.scheduledStart!)),
              if (b.completedAt != null) _Row('Completado', Fmt.dateTime(b.completedAt!)),
              if (b.cancelledAt != null) _Row('Cancelado', Fmt.dateTime(b.cancelledAt!)),
              if (b.cancelReason != null) _Row('Motivo de cancelación', b.cancelReason!),
              if (b.paymentMethod != null) _Row('Pago al profesional', b.paymentMethod!.label),
              const SizedBox(height: HySpacing.xs),
              const InfoBanner(
                key: Key('booking-privacy'),
                icon: Icons.lock_outline,
                text: 'La dirección exacta y la ubicación en vivo solo las ven el cliente y el profesional.',
              ),
              if (hasMoney) ...[
                const SectionHeader(title: 'Dinero (solo propietario)'),
                if (b.quoteAmount != null) _Row('Cotizado', Fmt.bs(b.quoteAmount!)),
                if (b.finalAmount != null) _Row('Pagado al profesional', Fmt.bs(b.finalAmount!)),
                if (b.commissionCaptured != null) _Row('Comisión cobrada', Fmt.bs(b.commissionCaptured!)),
                const Text(
                  'El cliente paga al profesional. La plataforma solo cobra la comisión de su billetera.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
              ],
              if ((detail.description ?? '').isNotEmpty) ...[
                const SectionHeader(title: 'Lo que pidió el cliente'),
                Text(detail.description!, style: const TextStyle(fontSize: 16)),
              ],
              if (detail.disputeReason != null) ...[
                const SectionHeader(title: 'Disputa'),
                _Row('Estado', detail.disputeStatus == 'open' ? 'Abierta' : 'Resuelta'),
                _Row('Motivo', detail.disputeReason!),
                if (detail.disputeResolution != null) _Row('Resolución', detail.disputeResolution!),
                if (detail.disputeStatus == 'open')
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const Key('booking-go-dispute'),
                      onPressed: () => context.push(Routes.adminDisputes),
                      icon: const Icon(Icons.gavel_outlined),
                      label: Text(role == StaffRole.owner ? 'Resolver en Disputas' : 'Ver en Disputas'),
                    ),
                  ),
              ],
              const SectionHeader(title: 'Qué puedes hacer'),
              if (bookingCase != null)
                FilledButton.icon(
                  key: const Key('booking-view-case'),
                  onPressed: () => context.push(Routes.staffCase(bookingCase.id)),
                  icon: const Icon(Icons.assignment_outlined),
                  label: const Text('Ver el caso abierto'),
                )
              else
                FilledButton.icon(
                  key: const Key('booking-open-case'),
                  onPressed: onOpenCase,
                  icon: const Icon(Icons.assignment_add),
                  label: const Text('Abrir un caso para revisarlo'),
                ),
              const SizedBox(height: HySpacing.xxs),
              const Text(
                'Un caso se puede asignar a un empleado, anotar y escalar. Queda en el historial de cambios.',
                style: TextStyle(color: HyColors.textSecondary, fontSize: 13),
              ),
              if (detail.cases.isNotEmpty) ...[
                const SectionHeader(title: 'Casos de este pedido'),
                for (final c in detail.cases) CaseCard(item: c),
              ],
              const SectionHeader(title: 'Historial del pedido'),
              if (detail.events.isEmpty)
                const Text('Sin cambios registrados.', style: TextStyle(color: HyColors.textSecondary))
              else
                for (final e in detail.events.reversed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: HySpacing.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.circle, size: 10, color: e.to.tone.foreground),
                        const SizedBox(width: HySpacing.xs),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.to.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(
                                [Fmt.dateTime(e.at), ?e.actorLabel].join(' · '),
                                style: const TextStyle(color: HyColors.textSecondary, fontSize: 13),
                              ),
                              if ((e.note ?? '').isNotEmpty) Text(e.note!),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.xxs),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: value),
        ],
      ),
    ),
  );
}

class _OpenCaseSheet extends StatefulWidget {
  const _OpenCaseSheet({required this.code});

  final String code;

  @override
  State<_OpenCaseSheet> createState() => _OpenCaseSheetState();
}

class _OpenCaseSheetState extends State<_OpenCaseSheet> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();
  String _category = 'routine';

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(HySpacing.page),
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Revisar el pedido ${widget.code}', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: HySpacing.sm),
              const Text('¿De qué se trata?', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: HySpacing.xs),
              Wrap(
                spacing: HySpacing.xs,
                runSpacing: HySpacing.xs,
                children: [
                  for (final (k, label) in const [
                    ('routine', 'Seguimiento'),
                    ('safety', 'Seguridad'),
                    ('fraud', 'Posible fraude'),
                  ])
                    ChoiceChip(
                      key: Key('open-case-$k'),
                      label: Text(label),
                      selected: _category == k,
                      onSelected: (_) => setState(() => _category = k),
                    ),
                ],
              ),
              const SizedBox(height: HySpacing.sm),
              TextFormField(
                key: const Key('open-case-reason'),
                controller: _reason,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Qué hay que revisar (queda registrado)'),
                validator: (v) => (v ?? '').trim().length < 5 ? 'Escribe qué hay que revisar' : null,
              ),
              const SizedBox(height: HySpacing.sm),
              FilledButton(
                key: const Key('open-case-continue'),
                onPressed: () {
                  if (!_form.currentState!.validate()) return;
                  Navigator.pop(context, (_category, _reason.text.trim()));
                },
                child: const Text('Continuar'),
              ),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Volver')),
            ],
          ),
        ),
      ),
    ),
  );
}

// ===================================================================== Seguridad y fraude
class RiskItemsPage extends ConsumerStatefulWidget {
  const RiskItemsPage({super.key, this.initialKind = RiskKind.safety});

  final RiskKind initialKind;

  @override
  ConsumerState<RiskItemsPage> createState() => _RiskItemsPageState();
}

class _RiskItemsPageState extends ConsumerState<RiskItemsPage> {
  late RiskKind _kind = widget.initialKind;

  void _open(RiskItem i) {
    if (i.source == 'ai') {
      final id = int.tryParse(i.id);
      if (id != null) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AiItemDetailPage(itemId: id)));
    } else if (i.caseId != null) {
      context.push(Routes.staffCase(i.caseId!));
    } else {
      context.push(Routes.adminReports);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(riskItemsProvider(_kind));
    return Scaffold(
      appBar: AppBar(title: OneLineText(_kind.title)),
      body: AdminList<RiskItem>(
        value: value.whenData((l) => l.items),
        onRefresh: () => ref.refresh(riskItemsProvider(_kind).future),
        emptyIcon: Icons.verified_user_outlined,
        emptyTitle: _kind == RiskKind.safety
            ? 'No hay incidentes de seguridad abiertos.'
            : 'No hay alertas de fraude abiertas.',
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            drilldownChipRow(
              [for (final k in RiskKind.values) (k, k.title)],
              _kind,
              (k) => setState(() => _kind = k),
              'risk-kind',
            ),
            const SizedBox(height: HySpacing.sm),
            InfoBanner(
              icon: Icons.shield_outlined,
              tone: StatusTone.warning,
              text: _kind == RiskKind.safety
                  ? 'Reportes por acoso y casos de seguridad abiertos. Cada uno lo revisa una persona: '
                        'tómalo, anota lo que sepas y suspende la cuenta si hace falta.'
                  : 'Reportes por fraude o cobro indebido, casos de fraude y avisos del Centro IA. '
                        'Nada se cierra ni se suspende solo: lo decide una persona.',
            ),
            const SizedBox(height: HySpacing.sm),
            if (value case AsyncData(:final value) when value.items.isNotEmpty)
              _countLine(value.items.length, value.total, value.total == 1 ? 'abierto' : 'abiertos'),
          ],
        ),
        itemBuilder: (context, i) => AppCard(
          key: Key('risk-${i.source}-${i.id}'),
          onTap: () => _open(i),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(i.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                  ToneChip(
                    i.severityLabel,
                    i.severity == 'critical' || i.severity == 'high' ? StatusTone.danger : StatusTone.warning,
                  ),
                ],
              ),
              InfoLine(Icons.source_outlined, '${i.sourceLabel} · ${i.statusLabel}'),
              if (i.person != null)
                InfoLine(Icons.person_outline, i.source == 'report' ? 'Sobre: ${i.person}' : 'Asignado a ${i.person}'),
              InfoLine(Icons.schedule, Fmt.relative(i.createdAt)),
              if ((i.detail ?? '').isNotEmpty) Text('"${i.detail}"', maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: HySpacing.xxs),
              Text(
                i.source == 'ai' ? 'Abrir en el Centro IA' : 'Abrir el caso',
                style: const TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===================================================================== Billeteras
class OwnerWalletsPage extends ConsumerStatefulWidget {
  const OwnerWalletsPage({super.key, this.initialSort = WalletSort.available});

  final WalletSort initialSort;

  @override
  ConsumerState<OwnerWalletsPage> createState() => _OwnerWalletsPageState();
}

class _OwnerWalletsPageState extends ConsumerState<OwnerWalletsPage> {
  late WalletSort _sort = widget.initialSort;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final key = (_query, _sort);
    final value = ref.watch(ownerWalletsProvider(key));
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Billeteras de profesionales')),
      body: AdminList<OwnerWallet>(
        value: value.whenData((l) => l.items),
        onRefresh: () => ref.refresh(ownerWalletsProvider(key).future),
        emptyIcon: Icons.account_balance_wallet_outlined,
        emptyTitle: _query.isEmpty ? 'Todavía no hay billeteras.' : 'Ninguna billetera coincide.',
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (value case AsyncData(:final value))
              AppCard(
                key: const Key('wallets-totals'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Row('Disponible en total', Fmt.bs(value.available)),
                    _Row('Billeteras', '${value.total}'),
                    const SizedBox(height: HySpacing.xxs),
                    const Text(
                      'Es dinero de los profesionales (recargas), no un ingreso de la plataforma. '
                      'La comisión se descuenta solo cuando el cliente marca "Ya pagué".',
                      style: TextStyle(color: HyColors.textSecondary),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: HySpacing.sm),
            drilldownChipRow(
              [for (final s in WalletSort.values) (s, s.label)],
              _sort,
              (s) => setState(() => _sort = s),
              'wallets-sort',
            ),
            const SizedBox(height: HySpacing.sm),
            DrilldownSearchField(
              fieldKey: const Key('wallets-search'),
              hint: 'Nombre del profesional',
              onChanged: (q) => setState(() => _query = q),
            ),
            const SizedBox(height: HySpacing.sm),
          ],
        ),
        itemBuilder: (context, w) => AppCard(
          key: Key('wallet-${w.professionalId}'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FinanceMovementsPage(professionalId: w.professionalId, professionalName: w.name),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(w.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              InfoLine(Icons.account_balance_wallet_outlined, 'Saldo ${Fmt.bs(w.available + w.reserved)}'),
              InfoLine(
                Icons.history,
                [
                  ?w.cityName,
                  w.lastMovementAt == null ? 'Sin movimientos' : 'Último movimiento ${Fmt.relative(w.lastMovementAt!)}',
                ].join(' · '),
              ),
              if (w.pendingTopups > 0)
                Padding(
                  padding: const EdgeInsets.only(top: HySpacing.xxs),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ToneChip(
                      w.pendingTopups == 1 ? '1 recarga por revisar' : '${w.pendingTopups} recargas por revisar',
                      StatusTone.brand,
                    ),
                  ),
                ),
              const SizedBox(height: HySpacing.xxs),
              const Text(
                'Ver movimientos',
                style: TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===================================================================== Decisiones del Centro IA
/// Decisiones del Centro IA abiertas desde un número del panel, con su
/// flecha para volver.
class AiDecisionsPage extends StatelessWidget {
  const AiDecisionsPage({super.key, this.highOnly = false});

  final bool highOnly;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: OneLineText(highOnly ? 'Alertas IA altas o críticas' : 'Pendientes del Centro IA')),
    body: AiDecisionsList(highOnly: highOnly),
  );
}
