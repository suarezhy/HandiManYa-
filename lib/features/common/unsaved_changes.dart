import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../router.dart';

/// Atrás en una pantalla con un formulario: el botón de la barra, el gesto
/// atrás de Android y el deslizamiento desde el borde en iOS pasan todos por
/// aquí.
///
/// - Con [stepBack], atrás vuelve al paso anterior del mismo formulario.
/// - Con cambios sin guardar ([dirty]), pregunta "¿Salir sin guardar?".
/// - Sin cambios sale directo (en iOS se puede deslizar desde el borde; con
///   cambios sin guardar Flutter desactiva ese deslizamiento y queda el botón,
///   que pregunta).
/// - Con [homeWhenFirst], si no hay pantalla anterior (se llegó directo),
///   atrás lleva al inicio en vez de cerrar la app, igual que su botón.
class UnsavedChangesScope extends StatelessWidget {
  const UnsavedChangesScope({
    super.key,
    required this.dirty,
    required this.child,
    this.stepBack,
    this.homeWhenFirst = false,
    this.message,
  });

  final bool dirty;
  final Widget child;
  final VoidCallback? stepBack;
  final bool homeWhenFirst;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final first = homeWhenFirst && (ModalRoute.of(context)?.isFirst ?? false);
    return PopScope(
      canPop: !dirty && stepBack == null && !first,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (stepBack != null) return stepBack!();
        if (dirty && !await confirmLeaveUnsaved(context, message: message)) return;
        if (context.mounted) leavePage(context);
      },
      child: child,
    );
  }
}

/// "¿Salir sin guardar?". Devuelve true solo si la persona elige "Salir".
Future<bool> confirmLeaveUnsaved(BuildContext context, {String? message}) async {
  final leave = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('¿Salir sin guardar?'),
      content: Text(message ?? 'Si sales ahora, se pierden los cambios que hiciste.'),
      actions: [
        TextButton(
          key: const Key('unsaved-keep-editing'),
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Seguir editando'),
        ),
        FilledButton(
          key: const Key('unsaved-leave'),
          style: FilledButton.styleFrom(backgroundColor: HyColors.danger),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Salir'),
        ),
      ],
    ),
  );
  return leave ?? false;
}

/// Sale de la pantalla sin pasar por su [PopScope]: vuelve a la anterior o,
/// si no hay, al inicio.
void leavePage(BuildContext context) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
  } else {
    context.go(Routes.home);
  }
}
