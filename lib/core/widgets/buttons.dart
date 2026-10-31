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
