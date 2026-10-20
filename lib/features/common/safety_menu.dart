import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/admin.dart';
import '../../data/providers.dart';

/// Menú "⋮" para reportar o bloquear a otra persona.
class SafetyMenuButton extends ConsumerWidget {
  const SafetyMenuButton({super.key, required this.userId, required this.name, this.bookingId});

  final String userId;
  final String name;
  final String? bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).value;
    if (account == null || account.id == userId) return const SizedBox.shrink();
    final blocked = account.blockedIds.contains(userId);
    return PopupMenuButton<String>(
      tooltip: 'Más opciones',
      icon: const Icon(Icons.more_vert),
      onSelected: (v) => v == 'report'
          ? showReportSheet(context, userId: userId, name: name, bookingId: bookingId)
          : _toggleBlock(context, ref, blocked),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'report',
          child: ListTile(leading: Icon(Icons.flag_outlined), title: Text('Reportar')),
        ),
        PopupMenuItem(
          value: 'block',
          child: ListTile(
            leading: Icon(blocked ? Icons.lock_open : Icons.block),
            title: Text(blocked ? 'Desbloquear' : 'Bloquear'),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleBlock(BuildContext context, WidgetRef ref, bool blocked) async {
    final api = ref.read(backendProvider);
    if (!blocked &&
        !await confirmDialog(
          context,
          title: '¿Bloquear a $name?',
          message:
              'No podrán escribirse por chat y no le llegarán tus pedidos ¡Ya! (ni a ti los suyos). '
              'Si hay un trabajo en curso, cancélalo o repórtalo. Puedes desbloquear cuando quieras.',
          confirm: 'Bloquear',
          destructive: true,
        )) {
      return;
    }
    if (!context.mounted) return;
    final ok = await runGuarded(
      context,
      () => blocked ? api.unblockUser(userId) : api.blockUser(userId),
      success: blocked ? 'Desbloqueaste a $name' : 'Bloqueaste a $name',
    );
    if (ok) ref.invalidate(accountProvider);
  }
}

Future<void> showReportSheet(BuildContext context, {required String userId, required String name, String? bookingId}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ReportSheet(userId: userId, name: name, bookingId: bookingId),
    );

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.userId, required this.name, this.bookingId});

  final String userId;
  final String name;
  final String? bookingId;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  ReportReason? _reason;
  final _details = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final ok = await runGuarded(
      context,
      () => ref
          .read(backendProvider)
          .reportUser(userId: widget.userId, reason: _reason!, details: _details.text, bookingId: widget.bookingId),
      success: 'Gracias. Nuestro equipo revisará tu reporte.',
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      HySpacing.page,
      0,
      HySpacing.page,
      MediaQuery.viewInsetsOf(context).bottom + HySpacing.lg,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reportar a ${widget.name}', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: HySpacing.xs),
          const Text(
            'Tu reporte es confidencial: la otra persona no sabrá quién lo hizo.',
            style: TextStyle(color: HyColors.textSecondary, fontSize: 15),
          ),
          const SizedBox(height: HySpacing.sm),
          RadioGroup<ReportReason>(
            groupValue: _reason,
            onChanged: (v) => setState(() => _reason = v),
            child: Column(
              children: [
                for (final r in ReportReason.values)
                  RadioListTile<ReportReason>(contentPadding: EdgeInsets.zero, value: r, title: Text(r.label)),
              ],
            ),
          ),
          TextField(
            controller: _details,
            maxLines: 4,
            minLines: 2,
            maxLength: 1500,
            decoration: const InputDecoration(labelText: 'Cuéntanos qué pasó (opcional)'),
          ),
          const InfoBanner(icon: Icons.local_police_outlined, text: 'Si estás en peligro, llama a la Policía al 110.'),
          const SizedBox(height: HySpacing.md),
          PrimaryButton(label: 'Enviar reporte', loading: _sending, onPressed: _reason == null ? null : _send),
        ],
      ),
    ),
  );
}
