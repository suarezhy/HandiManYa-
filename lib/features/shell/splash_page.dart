import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/buttons.dart';
import '../../data/providers.dart';

class SplashPage extends ConsumerWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(HySpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BrandLogo(height: 56),
                const SizedBox(height: HySpacing.xxl),
                if (account.hasError) ...[
                  Text(
                    AppError.from(account.error!).message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: HySpacing.lg),
                  PrimaryButton(label: 'Reintentar', onPressed: () => ref.invalidate(accountProvider), expand: false),
                  TextButton(onPressed: () => ref.read(backendProvider).signOut(), child: const Text('Cerrar sesión')),
                ] else
                  const CircularProgressIndicator(color: HyColors.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
