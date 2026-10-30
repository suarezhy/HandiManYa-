import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/messaging.dart';
import '../../data/providers.dart';
import 'push_controller.dart';

/// Avisos en este teléfono: activarlos, probarlos y ver el último envío.
/// Nunca dice "entregado": el servidor solo sabe si Firebase aceptó el aviso.
class PushCard extends ConsumerStatefulWidget {
  const PushCard({super.key});

  @override
  ConsumerState<PushCard> createState() => _PushCardState();
}

class _PushCardState extends ConsumerState<PushCard> {
  // Al volver de los ajustes del teléfono se revisa otra vez el permiso.
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.read(pushControllerProvider.notifier).recheck());

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pushControllerProvider);
    final value = state.value;
    if (value == null || value == PushState.unavailable) return const SizedBox.shrink();
    final controller = ref.read(pushControllerProvider.notifier);

    final (String title, String text, List<Widget> actions) = switch (value) {
      PushState.unsupported when pushNeedsHomeScreen => (
        'Avisos en este iPhone',
        'Para recibir avisos con la app cerrada: en Safari toca Compartir, luego "Agregar a inicio", '
            'y abre HandiMan ¡Ya! desde ese ícono. Mientras tanto te avisamos aquí.',
        const <Widget>[],
      ),
      PushState.unsupported => (
        'Avisos en este navegador',
        'Este navegador no recibe avisos con la app cerrada. Te avisamos aquí, en Notificaciones.',
        const <Widget>[],
      ),
      PushState.denied => (
        'Avisos bloqueados',
        'Los avisos de HandiMan ¡Ya! están bloqueados en este teléfono. '
            'Toca "Abrir ajustes", activa "Permitir notificaciones" y vuelve a la app.',
        [
          FilledButton(
            key: const Key('push-settings'),
            onPressed: () => runGuarded(context, controller.openSettings),
            child: const Text('Abrir ajustes'),
          ),
        ],
      ),
      PushState.off => (
        'Recibe avisos en este teléfono',
        'Pedidos nuevos, mensajes y cambios de tus solicitudes, aunque la app esté cerrada.',
        [
          FilledButton(
            key: const Key('push-enable'),
            onPressed: state.isLoading
                ? null
                : () => runGuarded(context, () async {
                    await controller.enable();
                    // Solo si el servidor guardó el teléfono (con permiso negado no se dice nada).
                    if (ref.read(pushControllerProvider).value == PushState.on && context.mounted) {
                      showMessage(context, 'Avisos activados');
                    }
                  }),
            child: const Text('Activar avisos'),
          ),
        ],
      ),
      PushState.on => (
        'Avisos activados en este teléfono',
        'Te avisamos aunque la app esté cerrada.',
        [
          OutlinedButton(
            key: const Key('push-test'),
            onPressed: () => runGuarded(
              context,
              () async {
                await ref.read(backendProvider).sendTestPush();
                ref.invalidate(pushStatusProvider);
              },
              success:
                  'Aviso de prueba enviado: aparece arriba de la pantalla en unos segundos. Si no lo ves, '
                  'revisa los avisos de HandiMan ¡Ya! en los ajustes del teléfono.',
            ),
            child: const Text('Enviar aviso de prueba'),
          ),
          TextButton(
            key: const Key('push-disable'),
            onPressed: () => runGuarded(context, controller.disable),
            child: const Text('Desactivar'),
          ),
        ],
      ),
      PushState.unavailable => ('', '', const <Widget>[]),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(HySpacing.page, HySpacing.sm, HySpacing.page, HySpacing.xs),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  value == PushState.on ? Icons.notifications_active_outlined : Icons.notifications_none_rounded,
                  color: HyColors.navy,
                ),
                const SizedBox(width: HySpacing.xs),
                Expanded(
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
              ],
            ),
            const SizedBox(height: HySpacing.xxs),
            Text(text, style: const TextStyle(fontSize: 15, color: HyColors.textSecondary)),
            if (value == PushState.on) const _LastSend(),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: HySpacing.sm),
              Wrap(spacing: HySpacing.xs, runSpacing: HySpacing.xs, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

class _LastSend extends ConsumerWidget {
  const _LastSend();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pushStatusProvider).value;
    final line = _line(status);
    if (line == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: HySpacing.xxs),
      child: Text(
        line,
        key: const Key('push-last'),
        style: const TextStyle(fontSize: 14, color: HyColors.textMuted),
      ),
    );
  }

  static String? _line(PushStatus? s) {
    if (s == null || s.lastStatus == null || s.lastCreatedAt == null) return null;
    final when = Fmt.relative(s.lastCreatedAt!);
    return switch (s.lastStatus) {
      'sent' => 'Último aviso: Firebase lo aceptó para enviarlo ($when).',
      'pending' || 'sending' => 'Último aviso: esperando para salir ($when).',
      'failed' => 'Último aviso: no salió ($when). Si no te llegan, desactívalos y vuelve a activarlos.',
      'expired' => 'Último aviso: venció sin salir ($when).',
      _ => null,
    };
  }
}
