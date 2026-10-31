import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';
import '../../data/models/costs.dart';
import '../../data/providers.dart';

final identityCheckProvider = FutureProvider.autoDispose<IdentityCheck>(
  (ref) => ref.watch(backendProvider).identityCheck(),
);

/// Verificación de identidad del profesional (carnet, selfie y prueba de vida
/// con Didit). Es un paso más de la revisión: la decisión la toma una persona.
class IdentityCheckCard extends ConsumerStatefulWidget {
  const IdentityCheckCard({super.key});

  @override
  ConsumerState<IdentityCheckCard> createState() => _IdentityCheckCardState();
}

class _IdentityCheckCardState extends ConsumerState<IdentityCheckCard> {
  bool _sandbox = false;
  bool _busy = false;

  Future<void> _start() async {
    setState(() => _busy = true);
    await runGuarded(context, () async {
      final s = await ref.read(backendProvider).startIdentityCheck();
      if (mounted) setState(() => _sandbox = s.sandbox);
      final ok = await launchUrl(Uri.parse(s.url), mode: LaunchMode.externalApplication);
      if (!ok && mounted) showMessage(context, 'No pudimos abrir la verificación. Vuelve a intentar.');
    });
    if (mounted) setState(() => _busy = false);
    ref.invalidate(identityCheckProvider);
  }

  @override
  Widget build(BuildContext context) {
    final check = ref.watch(identityCheckProvider).value ?? IdentityCheck.none;
    final sandbox = _sandbox || (check.status != IdentityStatus.none && check.sandbox);
    final done = check.status == IdentityStatus.approved || check.status == IdentityStatus.inReview;
    return AppCard(
      key: const Key('identity-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Verifica tu identidad', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          const SizedBox(height: 4),
          const Text(
            'Con tu carnet (anverso y reverso) y una selfie. Después, una persona del equipo revisa todo antes de aprobarte.',
            style: TextStyle(color: HyColors.textSecondary),
          ),
          if (check.status != IdentityStatus.none) ...[
            const SizedBox(height: HySpacing.xs),
            Text('Estado: ${check.status.label}', key: const Key('identity-status')),
          ],
          if (sandbox) ...[
            const SizedBox(height: HySpacing.xs),
            const InfoBanner(
              key: Key('identity-sandbox'),
              icon: Icons.science_outlined,
              tone: StatusTone.warning,
              text: 'Modo de prueba: no uses tu carnet real. Este resultado no cuenta como verificación.',
            ),
          ],
          if (!done) ...[
            const SizedBox(height: HySpacing.sm),
            PrimaryButton(
              key: const Key('identity-start'),
              label: check.status == IdentityStatus.none ? 'Verificar mi identidad' : 'Continuar la verificación',
              icon: Icons.badge_outlined,
              loading: _busy,
              onPressed: _busy ? null : _start,
            ),
          ],
        ],
      ),
    );
  }
}
