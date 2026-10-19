import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/category_icon.dart';
import '../../core/widgets/common.dart';
import '../../data/providers.dart';
import '../../router.dart';

class AllCategoriesPage extends ConsumerWidget {
  const AllCategoriesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Todos los servicios')),
      body: categories.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(categoriesProvider)),
        data: (list) => ListView.separated(
          padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xs, HySpacing.page, HySpacing.xxl),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(height: HySpacing.sm),
          itemBuilder: (context, i) {
            final c = list[i];
            final (fg, bg) = categoryColors(c.icon);
            return AppCard(
              onTap: () => context.go(Routes.category(c.id)),
              child: Row(
                children: [
                  Container(
                    width: HySizes.iconTile,
                    height: HySizes.iconTile,
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(HyRadii.md)),
                    child: Icon(categoryIcon(c.icon), color: fg, size: 30),
                  ),
                  const SizedBox(width: HySpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.name, style: Theme.of(context).textTheme.titleMedium),
                        if (c.description != null)
                          Text(c.description!, style: const TextStyle(color: HyColors.textSecondary, fontSize: 15)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: HyColors.textMuted),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
