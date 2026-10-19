import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/brand_logo.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../../router.dart';

/// Las dos puertas de entrada: cliente o profesional. Es una sola cuenta
/// por persona; la puerta solo define por dónde empieza.
class AccessPage extends ConsumerWidget {
  const AccessPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    void choose(AppRole role) {
      ref.read(entryIntentProvider.notifier).set(role);
      context.push('${Routes.login}?rol=${role == AppRole.professional ? 'pro' : 'cliente'}');
    }

    return Scaffold(
      backgroundColor: HyColors.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(HySpacing.page),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: HySpacing.xl),
                  const Center(child: BrandLogo(height: 52)),
                  const SizedBox(height: HySpacing.sm),
                  Text(
                    'Todo lo que necesitas, en un solo lugar.',
                    textAlign: TextAlign.center,
                    style: text.titleMedium?.copyWith(color: HyColors.textSecondary),
                  ),
                  const SizedBox(height: HySpacing.xxl),
                  Semantics(header: true, child: Text('¿Cómo quieres usar la app?', style: text.headlineSmall)),
                  const SizedBox(height: HySpacing.md),
                  _Door(
                    icon: Icons.home_repair_service_rounded,
                    title: 'Necesito un servicio',
                    subtitle: 'Encuentra profesionales verificados cerca de ti',
                    color: HyColors.primary,
                    onTap: () => choose(AppRole.customer),
                  ),
                  const SizedBox(height: HySpacing.md),
                  _Door(
                    icon: Icons.engineering_rounded,
                    title: 'Soy profesional',
                    subtitle: 'Recibe trabajos en tu zona y haz crecer tus ingresos',
                    color: HyColors.navy,
                    onTap: () => choose(AppRole.professional),
                  ),
                  const SizedBox(height: HySpacing.xl),
                  const Text(
                    'Con la misma cuenta puedes pedir servicios y, si te aprobamos, también trabajar como profesional.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: HyColors.textMuted, fontSize: 15),
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

class _Door extends StatelessWidget {
  const _Door({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(HyRadii.xl),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(HyRadii.xl),
          child: Padding(
            padding: const EdgeInsets.all(HySpacing.lg),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white, size: 30),
                ),
                const SizedBox(width: HySpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(color: Colors.white, fontSize: 16)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
