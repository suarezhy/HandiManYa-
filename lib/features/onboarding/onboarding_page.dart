import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/text_fit.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/buttons.dart';
import '../../data/providers.dart';
import '../../router.dart';

class _Slide {
  const _Slide(this.image, this.aspectRatio, this.title, this.body);

  final String image;

  /// Ancho / alto del archivo (test/onboarding_layout_test.dart lo compara
  /// con el archivo).
  final double aspectRatio;
  final String title;
  final String body;
}

const _slides = [
  _Slide(
    'assets/images/onboarding_1.jpg',
    570 / 568,
    'Profesionales de confianza cerca de ti',
    'Plomeros, electricistas, albañiles, limpieza y mucho más en toda Bolivia. Todos verificados.',
  ),
  _Slide(
    'assets/images/onboarding_2.jpg',
    518 / 570,
    '¿Lo necesitas ahora? Pídelo ¡Ya!',
    'Toca "Lo necesito ahora", cuéntanos qué pasó y avisamos al instante a los profesionales disponibles más cerca de ti.',
  ),
  _Slide(
    'assets/images/onboarding_3.jpg',
    720 / 689,
    'Conversa y coordina desde la app',
    'Chatea con el profesional, recibe su cotización y sigue el estado de tu solicitud en todo momento.',
  ),
  _Slide(
    'assets/images/onboarding_4.jpg',
    700 / 815,
    'Trabajo bien hecho, con tranquilidad',
    'Pagas directo al profesional en efectivo o QR cuando termina, y calificas su trabajo para ayudar a otros.',
  ),
];

/// Foto y proporción de cada paso, para las pruebas (cada paso tiene su
/// propia foto: 1 equipo, 2 aviso de trabajo nuevo, 3 chat, 4 pulgar arriba).
@visibleForTesting
List<(String, double)> get onboardingImages => [for (final s in _slides) (s.image, s.aspectRatio)];

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
    return Scaffold(
      backgroundColor: HyColors.surface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: HySizes.maxContentWidth),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xs, HySpacing.xs, 0),
                  // Misma altura con o sin "Omitir": la foto no salta en la
                  // última pantalla.
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: HySizes.touch),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Align(alignment: Alignment.centerLeft, child: BrandLogo(height: 34)),
                        ),
                        if (!_last) TextButton(onPressed: _finish, child: const Text('Omitir')),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _slides.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) => _SlideView(slide: _slides[i]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.page, HySpacing.md),
                  child: Column(
                    children: [
                      Semantics(
                        key: const Key('onboarding-dots'),
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
                      const SizedBox(height: HySpacing.md),
                      PrimaryButton(
                        key: const Key('onboarding-next'),
                        label: _last ? 'Empezar' : 'Continuar',
                        onPressed: _next,
                      ),
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

/// Una pantalla de la bienvenida: la foto entera arriba y el texto debajo.
///
/// Las cuatro fotos van en el mismo marco cuadrado, del mismo tamaño en los
/// cuatro pasos: el alto se calcula con el texto más largo de los cuatro
/// (medido con el tamaño y la negrita del teléfono). Dentro del marco la foto
/// se ve entera (BoxFit.contain): no se recorta ni se estira, y lo que sobra a
/// los lados queda de un gris suave. Si con letra muy grande no cabe todo, la
/// foto queda en un mínimo y la pantalla se desplaza; "Continuar" y los
/// puntos siempre se ven.
class _SlideView extends StatelessWidget {
  const _SlideView({required this.slide});

  final _Slide slide;

  static const _maxImageSide = 420.0;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final titleStyle = text.headlineMedium;
    final bodyStyle = text.bodyLarge?.copyWith(color: HyColors.textSecondary);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth - 2 * HySpacing.page;
        final compact = box.maxHeight < 480;
        final top = compact ? HySpacing.xs : HySpacing.md;
        final gap = compact ? HySpacing.md : HySpacing.xl;
        const bottom = HySpacing.xs;

        double measure(String value, TextStyle? style) {
          final painter = TextPainter(
            text: TextSpan(text: value, style: effectiveTextStyle(context, style)),
            textDirection: direction,
            textScaler: scaler,
            locale: locale,
          )..layout(maxWidth: width);
          final h = painter.height;
          painter.dispose();
          return h;
        }

        // El texto más alto de los cuatro pasos: así la foto mide lo mismo
        // en todos y no salta al pasar de uno a otro.
        final textHeight = [
          for (final s in _slides) measure(s.title, titleStyle) + HySpacing.sm + measure(s.body, bodyStyle),
        ].reduce(max);
        // Un par de píxeles de holgura por redondeo.
        final free = box.maxHeight - top - gap - bottom - textHeight - 2;
        final minImage = (box.maxHeight * 0.3).clamp(96.0, 180.0);
        final side = min(width, free.clamp(minImage, _maxImageSide));

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(HySpacing.page, top, HySpacing.page, bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: (box.maxHeight - top - bottom).clamp(0, double.infinity)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: SizedBox.square(
                    dimension: side,
                    child: _Picture(slide: slide),
                  ),
                ),
                SizedBox(height: gap),
                // El texto ocupa siempre el alto del más largo: la foto y el
                // título quedan a la misma altura en los cuatro pasos.
                ConstrainedBox(
                  constraints: BoxConstraints(minHeight: textHeight),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(header: true, child: Text(slide.title, style: titleStyle)),
                      const SizedBox(height: HySpacing.sm),
                      Text(slide.body, style: bodyStyle),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// La foto completa en un marco cuadrado y redondeado: sin recorte, sin
/// estirar y sin nada encima que tape caras.
class _Picture extends StatelessWidget {
  const _Picture({required this.slide});

  final _Slide slide;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(HyRadii.xl);
    return DecoratedBox(
      key: ValueKey('onboarding-image-${slide.image}'),
      position: DecorationPosition.foreground,
      // Borde suave para que las fotos de fondo blanco no se pierdan.
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: HyColors.border),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: ColoredBox(
          color: HyColors.surfaceMuted,
          child: Image.asset(
            slide.image,
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
            semanticLabel: 'Ilustración: ${slide.title}',
            errorBuilder: (_, _, _) => const ColoredBox(color: HyColors.primarySoft),
          ),
        ),
      ),
    );
  }
}
