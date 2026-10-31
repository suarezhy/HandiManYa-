import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/widgets/buttons.dart';
import '../../data/providers.dart';

/// Primera pantalla de Flutter. Repite exactamente la pantalla nativa de
/// arranque (mismo logo, tamaño, lugar y fondo; ver tool/make_splash.py), así
/// el paso de una a otra no se ve; en Android 12+ la nativa es solo el fondo.
/// La ruedita sale solo si la carga tarda.
class SplashPage extends ConsumerStatefulWidget {
  const SplashPage({super.key});

  /// Medidas del logo en dp; las mismas que la imagen de arranque nativa
  /// (35 % más grande que en Build 15; Issue #13).
  static const logoSize = Size(237, 46);

  /// Cuánto se espera antes de mostrar la ruedita: si todo carga antes de un
  /// segundo, no aparece.
  static const spinnerDelay = Duration(seconds: 1);

  @override
  ConsumerState<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends ConsumerState<SplashPage> {
  Timer? _timer;
  bool _slow = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(SplashPage.spinnerDelay, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    ref.listen(accountProvider, (_, next) {
      if (_retrying && !next.isLoading) setState(() => _retrying = false);
    });
    return Scaffold(
      backgroundColor: HyColors.background,
      body: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            Center(
              child: Image.asset(
                'assets/brand/splash_logo.png',
                key: const Key('splash-logo'),
                width: SplashPage.logoSize.width,
                height: SplashPage.logoSize.height,
                semanticLabel: 'HandiMan ¡Ya!',
              ),
            ),
            Positioned(
              left: HySpacing.xl,
              right: HySpacing.xl,
              top: box.maxHeight / 2 + SplashPage.logoSize.height / 2 + HySpacing.xxl,
              // Al reintentar se ve la ruedita, no el error anterior.
              child: account.hasError && !_retrying
                  ? Column(
                      children: [
                        Text(
                          AppError.from(account.error!).message,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: HySpacing.lg),
                        PrimaryButton(
                          label: 'Reintentar',
                          onPressed: () {
                            setState(() => _retrying = true);
                            ref.invalidate(accountProvider);
                          },
                          expand: false,
                        ),
                        TextButton(
                          onPressed: () => ref.read(backendProvider).signOut(),
                          child: const Text('Cerrar sesión'),
                        ),
                      ],
                    )
                  : Center(
                      child: AnimatedOpacity(
                        opacity: _slow ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: _slow
                            ? const SizedBox.square(
                                dimension: 28,
                                child: CircularProgressIndicator(
                                  key: Key('splash-loading'),
                                  strokeWidth: 3,
                                  color: HyColors.primary,
                                ),
                              )
                            : const SizedBox.square(dimension: 28),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
