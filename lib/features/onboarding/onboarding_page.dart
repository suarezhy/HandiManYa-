import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/buttons.dart';
import '../../data/providers.dart';
import '../../router.dart';

class _Slide {
  const _Slide(this.image, this.title, this.body, this.icon);

  final String image;
  final String title;
  final String body;
  final IconData icon;
}

const _slides = [
  _Slide(
    'assets/images/onboarding_1.jpg',
    'Profesionales de confianza cerca de ti',
    'Plomeros, electricistas, albañiles, limpieza y mucho más en Santa Cruz, Cochabamba y La Paz. Todos verificados.',
    Icons.verified_user_outlined,
  ),
  _Slide(
    'assets/images/onboarding_2.jpg',
    '¿Lo necesitas ahora? Pídelo ¡Ya!',
    'Toca "Lo necesito ahora", cuéntanos qué pasó y avisamos a los profesionales disponibles en tu zona.',
    Icons.bolt_rounded,
  ),
  _Slide(
    'assets/images/onboarding_3.jpg',
    'Conversa y coordina desde la app',
    'Chatea con el profesional, recibe su cotización y sigue el estado de tu solicitud en todo momento.',
    Icons.chat_bubble_outline,
  ),
  _Slide(
    'assets/images/onboarding_4.jpg',
    'Trabajo bien hecho, con tranquilidad',
    'Pagas directo al profesional en efectivo o QR cuando termina, y calificas su trabajo para ayudar a otros.',
    Icons.thumb_up_alt_outlined,
  ),
];

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _controller = PageController();
  int _index = 0;

  bool get _last => _index == _slides.length - 1;

  Future<void> _finish() async {
    await ref.read(onboardingSeenProvider.notifier).markSeen();
    if (mounted) context.go(Routes.access);
  }

  void _next() {
    if (_last) {
      _finish();
    } else {
      _controller.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: HyColors.surface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: HySizes.maxContentWidth),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.xs, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Align(alignment: Alignment.centerLeft, child: BrandLogo(height: 34)),
                      ),
                      if (!_last) TextButton(onPressed: _finish, child: const Text('Omitir')),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _slides.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) {
                      final s = _slides[i];
                      return LayoutBuilder(
                        builder: (context, box) => SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: HySpacing.md),
                              _Picture(slide: s, height: (box.maxHeight * 0.6).clamp(220, 620)),
                              const SizedBox(height: HySpacing.xl),
                              Semantics(header: true, child: Text(s.title, style: text.headlineMedium)),
                              const SizedBox(height: HySpacing.sm),
                              Text(s.body, style: text.bodyLarge?.copyWith(color: HyColors.textSecondary)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.page, HySpacing.lg),
                  child: Column(
                    children: [
                      Semantics(
                        label: 'Paso ${_index + 1} de ${_slides.length}',
                        excludeSemantics: true,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < _slides.length; i++)
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 250),
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                width: i == _index ? 28 : 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: i == _index ? HyColors.primary : HyColors.border,
                                  borderRadius: BorderRadius.circular(HyRadii.pill),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: HySpacing.lg),
                      PrimaryButton(label: _last ? 'Empezar' : 'Continuar', onPressed: _next),
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

class _Picture extends StatelessWidget {
  const _Picture({required this.slide, required this.height});

  final _Slide slide;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(HyRadii.xl),
              // La foto completa, sin recortar ni agrandar; detrás, la misma
              // foto desenfocada rellena el espacio que sobra.
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Image.asset(
                      slide.image,
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                      errorBuilder: (_, _, _) => Container(color: HyColors.primarySoft),
                    ),
                  ),
                  ColoredBox(color: HyColors.navy.withValues(alpha: 0.15)),
                  Image.asset(
                    slide.image,
                    fit: BoxFit.contain,
                    semanticLabel: 'Ilustración: ${slide.title}',
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: HySpacing.md,
            bottom: HySpacing.md,
            child: Container(
              padding: const EdgeInsets.all(HySpacing.sm),
              decoration: BoxDecoration(
                color: HyColors.navy,
                borderRadius: BorderRadius.circular(HyRadii.lg),
                boxShadow: HyShadows.raised,
              ),
              child: Icon(slide.icon, color: Colors.white, size: 30),
            ),
          ),
        ],
      ),
    );
  }
}
