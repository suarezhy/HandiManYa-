import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../../core/widgets/word_safe_text.dart';

/// Lista de chats. Sirve para ambos modos: cada chat está ligado a una
/// solicitud y muestra al otro participante.
class ConversationsPage extends ConsumerWidget {
  const ConversationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(conversationsProvider);
    return Scaffold(
      appBar: AppBar(title: const OneLineText('Mensajes')),
      body: list.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(conversationsProvider)),
        data: (items) => RefreshIndicator(
          color: HyColors.primary,
          onRefresh: () async => ref.invalidate(conversationsProvider),
          child: items.isEmpty
              ? ListView(
                  children: const [
                    EmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: 'Aún no tienes conversaciones',
                      message: 'El chat se abre cuando un profesional acepta una solicitud.',
                    ),
                  ],
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(indent: 88),
                  itemBuilder: (context, i) {
                    final c = items[i];
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: HySizes.maxContentWidth),
                        child: ListTile(
                          minTileHeight: 84,
                          contentPadding: const EdgeInsets.symmetric(horizontal: HySpacing.page),
                          leading: PersonAvatar(name: c.otherName, size: 52),
                          title: Text(
                            c.otherName,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: c.unreadCount > 0 ? FontWeight.w800 : FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            c.lastMessagePreview ?? 'Solicitud ${c.bookingCode} · ${c.bookingStatus.label}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15),
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (c.lastMessageAt != null)
                                Text(
                                  Fmt.relative(c.lastMessageAt!),
                                  style: const TextStyle(color: HyColors.textMuted, fontSize: 13),
                                ),
                              if (c.unreadCount > 0) ...[
                                const SizedBox(height: 4),
                                Badge(label: Text('${c.unreadCount}'), backgroundColor: HyColors.primary),
                              ],
                            ],
                          ),
                          onTap: () => context.push(Routes.chat(c.id)),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
