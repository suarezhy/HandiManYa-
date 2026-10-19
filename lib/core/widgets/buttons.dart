import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Botón principal con estado de carga. Ocupa todo el ancho por defecto.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
    this.expand = true,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final bool expand;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final child = loading
        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 24), const SizedBox(width: HySpacing.xs)],
              Flexible(child: Text(label, textAlign: TextAlign.center)),
            ],
          );
    final button = FilledButton(
      onPressed: loading ? null : onPressed,
      style: color == null
          ? null
          : FilledButton.styleFrom(backgroundColor: color, disabledBackgroundColor: color!.withValues(alpha: 0.5)),
      child: Semantics(liveRegion: loading, label: loading ? 'Cargando' : null, child: child),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, required this.onPressed, this.icon, this.expand = true});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final button = icon == null
        ? OutlinedButton(
            onPressed: onPressed,
            child: Text(label, textAlign: TextAlign.center),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label, textAlign: TextAlign.center),
          );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// El gran botón "¡Ya!" del inicio: pedir ayuda ahora.
class YaButton extends StatelessWidget {
  const YaButton({super.key, required this.onPressed, this.subtitle = 'Un profesional cerca de ti, ahora'});

  final VoidCallback onPressed;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Lo necesito ahora. $subtitle',
      excludeSemantics: true,
      child: Material(
        color: HyColors.primary,
        borderRadius: BorderRadius.circular(HyRadii.xl),
        elevation: 0,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(HyRadii.xl),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: HySpacing.lg, vertical: HySpacing.lg),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(HyRadii.xl), boxShadow: HyShadows.raised),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const Text(
                    '¡Ya!',
                    style: TextStyle(color: HyColors.primary, fontWeight: FontWeight.w900, fontSize: 19),
                    textScaler: TextScaler.noScaling,
                  ),
                ),
                const SizedBox(width: HySpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Lo necesito ahora',
                        style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, height: 1.2),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
