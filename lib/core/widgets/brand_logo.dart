import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Logo de HandiMan ¡Ya!: el símbolo "H" y el nombre. "¡Ya!" siempre se
/// escribe con signo de apertura, Y mayúscula, a minúscula y cierre.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.height = 36, this.showWordmark = true, this.onDark = false});

  /// Separación entre "HandiMan" y "¡Ya!", en proporción a la letra.
  static const wordGap = 0.12;

  final double height;
  final bool showWordmark;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final mark = Image.asset(
      'assets/brand/logo_mark.png',
      height: height,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => Icon(Icons.handyman, size: height, color: HyColors.primary),
    );
    if (!showWordmark) return Semantics(label: 'HandiMan ¡Ya!', child: mark);
    return Semantics(
      label: 'HandiMan ¡Ya!',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          SizedBox(width: height * 0.18),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'HandiMan',
                      style: TextStyle(color: onDark ? Colors.white : HyColors.navy),
                    ),
                    // Un espacio normal más el borde de la "¡" separaba demasiado
                    // las dos palabras; esta separación las deja como una marca.
                    WidgetSpan(child: SizedBox(width: height * 0.6 * wordGap)),
                    const TextSpan(
                      text: '¡Ya!',
                      style: TextStyle(color: HyColors.primary),
                    ),
                  ],
                ),
                style: TextStyle(fontSize: height * 0.6, fontWeight: FontWeight.w900, letterSpacing: -0.5, height: 1),
                textScaler: TextScaler.noScaling,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
