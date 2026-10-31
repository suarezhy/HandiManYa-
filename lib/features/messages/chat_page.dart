import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../data/models/messaging.dart';
import '../../data/providers.dart';
import '../../router.dart';
import '../common/safety_menu.dart';

/// Chat en tiempo real de una solicitud (Supabase Realtime). Solo los dos
/// participantes pueden leer y escribir; lo controla la base de datos.
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _markRead();
  }

  void _markRead() => ref.read(backendProvider).markRead(widget.conversationId).catchError((_) {});

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await runGuarded(context, () => ref.read(backendProvider).send(widget.conversationId, text));
    if (ok) _input.clear();
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authUserProvider).value?.id;
    final messages = ref.watch(messagesProvider(widget.conversationId));
    final conversation = (ref.watch(conversationsProvider).value ?? const <Conversation>[])
        .where((c) => c.id == widget.conversationId)
        .firstOrNull;
    ref.listen(messagesProvider(widget.conversationId), (_, _) => _markRead());

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(conversation?.otherName ?? 'Chat'),
            if (conversation != null)
              Text(
                'Solicitud ${conversation.bookingCode} · ${conversation.bookingStatus.label}',
                style: const TextStyle(fontSize: 14, color: HyColors.textSecondary, fontWeight: FontWeight.w500),
              ),
          ],
        ),
        actions: [
          if (conversation != null)
            IconButton(
              tooltip: 'Ver solicitud',
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: () => context.push(Routes.booking(conversation.bookingId)),
            ),
          if (conversation?.otherId != null)
            SafetyMenuButton(
              userId: conversation!.otherId!,
              name: conversation.otherName,
              bookingId: conversation.bookingId,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.when(
              loading: () => const LoadingView(),
              error: (e, _) =>
                  ErrorView(error: e, onRetry: () => ref.invalidate(messagesProvider(widget.conversationId))),
              data: (list) => list.isEmpty
                  ? const EmptyState(
                      icon: Icons.waving_hand_outlined,
                      title: 'Saluda y coordina los detalles',
                      message: 'Por tu seguridad, mantén la conversación dentro de la app.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.all(HySpacing.md),
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final m = list[list.length - 1 - i];
                        return _Bubble(message: m, mine: m.senderId == me);
                      },
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              decoration: const BoxDecoration(
                color: HyColors.surface,
                border: Border(top: BorderSide(color: HyColors.border)),
              ),
              padding: const EdgeInsets.fromLTRB(HySpacing.sm, HySpacing.xs, HySpacing.xs, HySpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: 'Escribe un mensaje', counterText: ''),
                    ),
                  ),
                  const SizedBox(width: HySpacing.xs),
                  IconButton.filled(
                    tooltip: 'Enviar',
                    iconSize: 26,
                    style: IconButton.styleFrom(
                      backgroundColor: HyColors.primary,
                      minimumSize: const Size(HySizes.touch, HySizes.touch),
                    ),
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});

  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
          decoration: BoxDecoration(
            color: mine ? HyColors.navy : HyColors.surface,
            border: mine ? null : Border.all(color: HyColors.border),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(HyRadii.lg),
              topRight: const Radius.circular(HyRadii.lg),
              bottomLeft: Radius.circular(mine ? HyRadii.lg : 4),
              bottomRight: Radius.circular(mine ? 4 : HyRadii.lg),
            ),
          ),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (message.body != null)
                Text(message.body!, style: TextStyle(fontSize: 17, color: mine ? Colors.white : HyColors.text)),
              if (message.imagePath != null)
                Text('📷 Foto', style: TextStyle(color: mine ? Colors.white : HyColors.text)),
              const SizedBox(height: 2),
              Text(
                Fmt.time(message.createdAt),
                style: TextStyle(fontSize: 12, color: mine ? Colors.white70 : HyColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
