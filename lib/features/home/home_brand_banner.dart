import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// Banner de marca del inicio, debajo del buscador. Es solo marca: sin
/// botones ni enlaces, y aparte de la publicidad ([HomeAdSlot]). Crece con la
/// letra del teléfono en vez de cortarse.
class HomeBrandBanner extends StatelessWidget {
  const HomeBrandBanner({super.key});

  // Espacios fijos: "¡Ya!" y "mucho más." nunca quedan solos en una línea.
  static const headline = 'Todo lo que necesitas,\u00a0';
  static const accent = '¡Ya!';
  static const subtitle = 'Soluciones para tu hogar y mucho\u00a0más.';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: '$headline$accent $subtitle',
      excludeSemantics: true,
      child: Container(
        key: const Key('home-brand-banner'),
        constraints: const BoxConstraints(minHeight: 88),
        decoration: BoxDecoration(color: HyColors.navy, borderRadius: BorderRadius.circular(HyRadii.lg)),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            // Rayo de marca, discreto, a la derecha.
            const Positioned(
              right: HySpacing.xs,
              child: Icon(Icons.bolt_rounded, size: 64, color: Color(0x40F25500)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(HySpacing.lg, HySpacing.sm, 56, HySpacing.sm),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    key: const Key('home-brand-headline'),
                    TextSpan(
                      text: headline,
                      children: const [
                        TextSpan(
                          text: accent,
                          style: TextStyle(color: HyColors.primary),
                        ),
                      ],
                    ),
                    style: text.titleMedium?.copyWith(
                      color: HyColors.onPrimary,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    key: const Key('home-brand-subtitle'),
                    style: text.bodySmall?.copyWith(color: const Color(0xFFC9D2E3), height: 1.25),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
