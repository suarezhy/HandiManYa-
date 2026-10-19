import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../data/providers.dart';

Future<void> showCityPicker(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (c) => Consumer(
      builder: (c, ref, _) {
        final cities = ref.watch(citiesProvider).value ?? const [];
        final selected = ref.watch(currentCityProvider);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, HySpacing.sm),
                child: Text('¿En qué ciudad estás?', style: Theme.of(c).textTheme.titleLarge),
              ),
              for (final city in cities)
                ListTile(
                  minTileHeight: HySizes.touch + 8,
                  leading: Icon(
                    city.id == selected?.id ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: city.id == selected?.id ? HyColors.primary : HyColors.textMuted,
                  ),
                  title: Text(city.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  onTap: () {
                    ref.read(selectedCityProvider.notifier).select(city.id);
                    Navigator.pop(c);
                  },
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(HySpacing.page, HySpacing.xs, HySpacing.page, HySpacing.md),
                child: Text('Pronto llegamos a más ciudades de Bolivia.', style: TextStyle(color: HyColors.textMuted)),
              ),
            ],
          ),
        );
      },
    ),
  );
}
