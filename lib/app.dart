import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'core/theme/tokens.dart';
import 'data/providers.dart';
import 'features/security/app_lock.dart';
import 'router.dart';

class HandiManYaApp extends ConsumerWidget {
  const HandiManYaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final demo = ref.watch(isDemoProvider);
    return MaterialApp.router(
      title: 'HandiMan ¡Ya!',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      locale: const Locale('es', 'BO'),
      supportedLocales: const [Locale('es', 'BO'), Locale('es')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
      builder: (context, child) {
        // Respeta el tamaño de letra del teléfono, con un tope para que nada
        // se rompa en pantallas chicas.
        final media = MediaQuery.of(context);
        final scaled = media.copyWith(textScaler: media.textScaler.clamp(minScaleFactor: 1, maxScaleFactor: 1.6));
        return MediaQuery(
          data: scaled,
          child: AppLockGate(child: demo ? _DemoFrame(child: child!) : child!),
        );
      },
    );
  }
}

/// Cinta discreta que recuerda que los datos son de ejemplo.
class _DemoFrame extends StatelessWidget {
  const _DemoFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: HyColors.navy,
          child: SafeArea(
            bottom: false,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: 6),
              child: const Text(
                'Modo demostración · datos de ejemplo',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
        ),
      ],
    );
  }
}
