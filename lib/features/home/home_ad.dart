import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/widgets/word_safe_text.dart';
import '../../data/models/ads.dart';
import '../../data/providers.dart';

/// Espacio de publicidad del inicio. Sin un anuncio aprobado y vigente no
/// ocupa nada (ni espacio en blanco). Siempre dice "Publicidad" o
/// "Patrocinado".
class HomeAdSlot extends ConsumerWidget {
  const HomeAdSlot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ad = ref.watch(homeAdProvider).value;
    if (ad == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: HySpacing.sm),
      child: HomeAdCard(ad: ad),
    );
  }
}

/// La tarjeta del anuncio. También la usa el Propietario como vista previa
/// ([onTap] null: no abre nada).
class HomeAdCard extends ConsumerWidget {
  const HomeAdCard({super.key, required this.ad, this.preview = false});

  final HomeAd ad;
  final bool preview;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final link = await ref.read(backendProvider).adClick(ad.id);
      final uri = link == null ? null : Uri.tryParse(link);
      if (uri == null || uri.scheme != 'https') return;
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) messenger.showSnackBar(const SnackBar(content: Text('No se pudo abrir el enlace.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(AppError.from(e).message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final tappable = ad.hasLink && !preview;
    return Semantics(
      container: true,
      label: '${ad.label}: ${ad.advertiser}',
      button: tappable,
      child: Material(
        key: const Key('home-ad'),
        color: HyColors.surface,
        borderRadius: BorderRadius.circular(HyRadii.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: tappable ? () => _open(context, ref) : null,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: HyColors.border),
              borderRadius: BorderRadius.circular(HyRadii.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ad.imageUrl != null)
                  AspectRatio(
                    aspectRatio: 3,
                    child: Image.network(
                      ad.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(color: HyColors.surfaceMuted),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(HySpacing.md),
                  child: Row(
                    children: [
                      _Logo(ad: ad),
                      const SizedBox(width: HySpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Etiqueta y negocio; si no entran juntos, el negocio baja.
                            Wrap(
                              spacing: HySpacing.xs,
                              runSpacing: 2,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _AdLabel(ad.label),
                                WordSafeText(
                                  ad.advertiser,
                                  style: text.labelMedium?.copyWith(color: HyColors.textMuted),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            WordSafeText(ad.title, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                            if (ad.body != null && ad.body!.isNotEmpty)
                              WordSafeText(ad.body!, style: text.bodySmall?.copyWith(color: HyColors.textSecondary)),
                          ],
                        ),
                      ),
                      if (tappable) ...[
                        const SizedBox(width: HySpacing.xs),
                        const Icon(Icons.open_in_new_rounded, size: 18, color: HyColors.textMuted),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AdLabel extends StatelessWidget {
  const _AdLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('home-ad-label'),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: HyColors.surfaceMuted, borderRadius: BorderRadius.circular(HyRadii.sm)),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: HyColors.textSecondary, fontWeight: FontWeight.w700),
    ),
  );
}

class _Logo extends StatelessWidget {
  const _Logo({required this.ad});

  final HomeAd ad;

  @override
  Widget build(BuildContext context) {
    final initials = ad.advertiser
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w.characters.first.toUpperCase())
        .join();
    final fallback = Center(
      child: Text(
        initials,
        style: const TextStyle(color: HyColors.primaryDark, fontWeight: FontWeight.w800),
      ),
    );
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(color: HyColors.primarySoft, borderRadius: BorderRadius.circular(HyRadii.md)),
      clipBehavior: Clip.antiAlias,
      child: ad.logoUrl == null
          ? fallback
          : Image.network(ad.logoUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
    );
  }
}
