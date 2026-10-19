import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/category_icon.dart';

class CategoryTile extends StatelessWidget {
  const CategoryTile({super.key, required this.label, required this.icon, required this.onTap});

  final String label;
  final String icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = categoryColors(icon);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: HyColors.surface,
        borderRadius: BorderRadius.circular(HyRadii.lg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(HyRadii.lg),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(HyRadii.lg),
              border: Border.all(color: HyColors.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: HySpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: HySizes.iconTile,
                  height: HySizes.iconTile,
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(HyRadii.md)),
                  child: Icon(categoryIcon(icon), color: fg, size: 30),
                ),
                const SizedBox(height: HySpacing.xs),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.15),
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
