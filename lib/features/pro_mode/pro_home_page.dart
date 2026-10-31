import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/equal_height_row.dart';
import '../../core/widgets/word_safe_text.dart';
import '../../data/models/booking.dart';
import '../../data/models/wallet.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../booking/booking_card.dart';

/// Panel del profesional: disponibilidad para ¡Ya!, pedidos nuevos y saldo.
class ProHomePage extends ConsumerWidget {
  const ProHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashboard = ref.watch(proDashboardProvider);
    final account = ref.watch(accountProvider).value;
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: HySpacing.page,
        title: const BrandLogo(height: 32),
        actions: [
          IconButton(
            tooltip: 'Notificaciones',
            iconSize: 28,
            onPressed: () => context.push(Routes.notifications),
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 9 ? '9+' : '$unread'),
              backgroundColor: HyColors.primary,
              child: const Icon(Icons.notifications_none_rounded),
            ),
          ),
        ],
      ),
      body: dashboard.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(proDashboardProvider)),
        data: (d) => RefreshIndicator(
          color: HyColors.primary,
          onRefresh: () async {
            ref.invalidate(proDashboardProvider);
            ref.invalidate(myBookingsProvider(true));
          },
          child: ListView(
            padding: bottomSafePadding(context),
            children: [
              PageBody(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: HySpacing.xs),
                    Text(
                      '¡Hola, ${Fmt.firstName(account?.fullName ?? '')}!',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: HySpacing.md),
                    _AvailabilityCard(available: d.isAvailable),
                    const SizedBox(height: HySpacing.md),
                    // Las tres del mismo alto, con las palabras enteras.
                    EqualHeightRow(
                      columns: 3,
                      spacing: HySpacing.xs,
                      children: [
                        _Counter(
                          value: d.incoming,
                          label: 'Pedidos\nnuevos',
                          color: HyColors.primary,
                          onTap: () => context.go(Routes.proRequests),
                        ),
                        _Counter(
                          value: d.active,
                          label: 'Trabajos\nactivos',
                          color: HyColors.green,
                          onTap: () => context.go(Routes.proJobs),
                        ),
                        _Counter(
                          value: d.upcoming,
                          label: 'Próximos\nprogramados',
                          color: HyColors.navy,
                          onTap: () => context.go(Routes.proJobs),
                        ),
                      ],
                    ),
                    const SizedBox(height: HySpacing.md),
                    _WalletCard(dashboard: d),
                    const _IncomingSection(),
                    const SectionHeader(title: 'Tu desempeño'),
                    AppCard(
                      child: Column(
                        children: [
                          _MetricRow(
                            icon: Icons.star_rounded,
                            iconColor: HyColors.star,
                            label: 'Calificación',
                            value: d.ratingCount == 0 ? 'Sin reseñas' : '${Fmt.rating(d.ratingAvg)} (${d.ratingCount})',
                          ),
                          const Divider(height: HySpacing.lg),
                          _MetricRow(
                            icon: Icons.task_alt,
                            iconColor: HyColors.green,
                            label: 'Trabajos completados',
                            value: '${d.completedJobs}',
                          ),
                          const Divider(height: HySpacing.lg),
                          _MetricRow(
                            icon: Icons.payments_outlined,
                            iconColor: HyColors.navy,
                            label: 'Ingresos del mes',
                            value: Fmt.bs(d.earningsMonth),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AvailabilityCard extends ConsumerStatefulWidget {
  const _AvailabilityCard({required this.available});

  final bool available;

  @override
  ConsumerState<_AvailabilityCard> createState() => _AvailabilityCardState();
}

class _AvailabilityCardState extends ConsumerState<_AvailabilityCard> {
  bool _busy = false;

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).setAvailability(value),
      success: value ? 'Estás disponible para pedidos ¡Ya!' : 'Ya no recibirás pedidos ¡Ya!',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(proDashboardProvider);
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.available;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(HySpacing.md),
      decoration: BoxDecoration(
        color: on ? HyColors.green : HyColors.navy,
        borderRadius: BorderRadius.circular(HyRadii.xl),
        boxShadow: HyShadows.card,
      ),
      child: Row(
        children: [
          Icon(on ? Icons.bolt_rounded : Icons.bedtime_outlined, color: Colors.white, size: 40),
          const SizedBox(width: HySpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WordSafeText(
                  on ? 'Disponible para ¡Ya!' : 'No disponible',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  on
                      ? 'Te llegarán pedidos de clientes cerca de ti.'
                      : 'Actívalo cuando puedas atender pedidos inmediatos.',
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ],
            ),
          ),
          if (_busy)
            const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
          else
            Semantics(
              label: 'Disponible para pedidos ¡Ya!',
              child: Transform.scale(
                scale: 1.25,
                child: Switch(
                  value: on,
                  onChanged: _toggle,
                  activeThumbColor: Colors.white,
                  activeTrackColor: HyColors.greenDark,
                  inactiveThumbColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.value, required this.label, required this.color, required this.onTap});

  final int value;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AppCard(
    onTap: onTap,
    padding: const EdgeInsets.symmetric(vertical: HySpacing.md, horizontal: HySpacing.xs),
    child: Column(
      children: [
        Text(
          '$value',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: color),
        ),
        WordSafeText(
          label,
          textAlign: TextAlign.center,
          // Tres por fila: en 320 px con letra grande "programados" necesita achicarse más.
          minScale: 0.5,
          style: const TextStyle(color: HyColors.textSecondary, fontSize: 14, height: 1.2),
        ),
      ],
    ),
  );
}

class _WalletCard extends StatelessWidget {
  const _WalletCard({required this.dashboard});

  final ProDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final low = dashboard.walletAvailable < 20;
    return AppCard(
      onTap: () => context.push(Routes.wallet),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: HyColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(HyRadii.md),
            ),
            child: const Icon(Icons.account_balance_wallet_outlined, color: HyColors.primaryDark),
          ),
          const SizedBox(width: HySpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Saldo total', style: TextStyle(color: HyColors.textSecondary)),
                Text(
                  Fmt.bs(dashboard.walletAvailable + dashboard.walletReserved),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                if (low)
                  const Text(
                    'Saldo bajo: recarga para seguir aceptando trabajos.',
                    style: TextStyle(color: HyColors.danger, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

class _IncomingSection extends ConsumerWidget {
  const _IncomingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(myBookingsProvider(true)).value ?? const <BookingSummary>[];
    final incoming = list.where((b) => b.isOffer || b.status.isOpen).take(3).toList();
    if (incoming.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Pedidos para ti',
          actionLabel: 'Ver todos',
          onAction: () => context.go(Routes.proRequests),
        ),
        for (final b in incoming) ...[
          BookingCard(booking: b, asProfessional: true),
          const SizedBox(height: HySpacing.sm),
        ],
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.icon, required this.iconColor, required this.label, required this.value});

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: iconColor),
      const SizedBox(width: HySpacing.sm),
      Expanded(child: WordSafeText(label, style: const TextStyle(fontSize: 16))),
      Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
    ],
  );
}
