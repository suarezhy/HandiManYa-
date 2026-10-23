import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/widgets/buttons.dart';
import 'splash_page.dart';

/// Si la app no logra arrancar (por ejemplo, no puede leer la sesión guardada
/// en el teléfono), lo dice con el mismo logo y fondo del arranque y deja
/// reintentar, en vez de quedarse en blanco.
class StartupErrorApp extends StatefulWidget {
  const StartupErrorApp({super.key, required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  State<StartupErrorApp> createState() => _StartupErrorAppState();
}

class _StartupErrorAppState extends State<StartupErrorApp> {
  var _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: HyColors.background,
      body: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            Center(
              child: Image.asset(
                'assets/brand/splash_logo.png',
                width: SplashPage.logoSize.width,
                height: SplashPage.logoSize.height,
                semanticLabel: 'HandiMan ¡Ya!',
              ),
            ),
            Positioned(
              left: HySpacing.xl,
              right: HySpacing.xl,
              top: box.maxHeight / 2 + SplashPage.logoSize.height / 2 + HySpacing.xxl,
              child: Column(
                children: [
                  Text(
                    'No pudimos abrir la app',
                    key: const Key('startup-error'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: HySpacing.xs),
                  Text(
                    AppError.from(widget.error).message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: HySpacing.lg),
                  PrimaryButton(label: 'Reintentar', loading: _busy, onPressed: _busy ? null : _retry, expand: false),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
