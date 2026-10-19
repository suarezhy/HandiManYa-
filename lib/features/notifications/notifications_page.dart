import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/messaging.dart';
import '../../data/providers.dart';
import '../../router.dart';

class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  @override
  void dispose() {
    // Al salir se marcan como leídas.
    ref.read(backendProvider).markAllRead().catchError((_) {});
    super.dispose();
  }

  IconData _icon(AppNotification n) => switch (n.kind) {
    'message' => Icons.chat_bubble_outline,
    'ya_offer' || 'booking_new' => Icons.bolt_rounded,
    'review' => Icons.star_outline_rounded,
    _ => Icons.receipt_long_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(notificationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Notificaciones')),
      body: list.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(notificationsProvider)),
        data: (items) => items.isEmpty
            ? const EmptyState(
                icon: Icons.notifications_none_rounded,
                title: 'No tienes notificaciones',
                message: 'Aquí te avisaremos de tus solicitudes y mensajes.',
              )
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final n = items[i];
                  return ListTile(
                    minTileHeight: 76,
                    tileColor: n.isRead ? null : HyColors.primarySoft,
                    contentPadding: const EdgeInsets.symmetric(horizontal: HySpacing.page, vertical: 4),
                    leading: CircleAvatar(
                      backgroundColor: HyColors.surfaceMuted,
                      child: Icon(_icon(n), color: HyColors.navy),
                    ),
                    title: Text(n.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    subtitle: Text(
                      n.body.isEmpty ? Fmt.relative(n.createdAt) : '${n.body}\n${Fmt.relative(n.createdAt)}',
                      style: const TextStyle(fontSize: 15),
                    ),
                    isThreeLine: n.body.isNotEmpty,
                    onTap: () {
                      if (n.conversationId != null) {
                        context.push(Routes.chat(n.conversationId!));
                      } else if (n.bookingId != null) {
                        context.push(Routes.booking(n.bookingId!));
                      }
                    },
                  );
                },
              ),
      ),
    );
  }
}
