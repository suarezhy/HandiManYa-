import 'package:flutter/material.dart';

import '../../data/models/booking.dart';
import 'buttons.dart';
import '../theme/tokens.dart';
import '../utils/app_error.dart';
import '../utils/formatters.dart';

/// Centra el contenido y limita el ancho en tabletas (iPad).
class PageBody extends StatelessWidget {
  const PageBody({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: HySpacing.page),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: HySizes.maxContentWidth),
      child: Padding(padding: padding, child: child),
    ),
  );
}

/// Relleno para listas a pantalla completa: el final queda por encima de la
/// barra de navegación de Android (botones o gestos) y del indicador de inicio
/// del iPhone. Con padding explícito, ListView ya no lo agrega solo.
EdgeInsets bottomSafePadding(BuildContext context, {double top = 0, double bottom = HySpacing.xxl}) =>
    EdgeInsets.only(top: top, bottom: bottom + MediaQuery.paddingOf(context).bottom);

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(HySpacing.md),
    this.color,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) => Material(
    color: color ?? HyColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(HyRadii.lg),
      side: const BorderSide(color: HyColors.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    ),
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: HySpacing.xl, bottom: HySpacing.sm),
    child: Row(
      children: [
        Expanded(
          child: Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        ),
        if (actionLabel != null) TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    ),
  );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});

  final BookingStatus status;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: HySpacing.sm, vertical: 6),
    decoration: BoxDecoration(color: status.tone.background, borderRadius: BorderRadius.circular(HyRadii.pill)),
    child: Text(
      status.label,
      style: TextStyle(color: status.tone.foreground, fontWeight: FontWeight.w700, fontSize: 14),
    ),
  );
}

class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Profesional verificado',
    excludeSemantics: true,
    child: Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : HySpacing.xs, vertical: 3),
      decoration: BoxDecoration(color: HyColors.greenSoft, borderRadius: BorderRadius.circular(HyRadii.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.verified, size: 16, color: HyColors.greenDark),
          if (!compact) ...[
            const SizedBox(width: 4),
            const Text(
              'Verificado',
              style: TextStyle(color: HyColors.greenDark, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ],
        ],
      ),
    ),
  );
}

class RatingLabel extends StatelessWidget {
  const RatingLabel({super.key, required this.rating, required this.count});

  final double rating;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return const Text('Nuevo · sin reseñas aún', style: TextStyle(color: HyColors.textMuted, fontSize: 14));
    }
    return Semantics(
      label: 'Calificación ${Fmt.rating(rating)} de 5, $count reseñas',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: HyColors.star, size: 20),
          const SizedBox(width: 2),
          Text(Fmt.rating(rating), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Flexible(
            child: Text(
              ' ($count)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: HyColors.textMuted, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class AvailabilityDot extends StatelessWidget {
  const AvailabilityDot({super.key, required this.available});

  final bool available;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: available ? HyColors.green : HyColors.textMuted, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          available ? 'Disponible ahora' : 'No disponible ahora',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: available ? HyColors.greenDark : HyColors.textMuted,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
    ],
  );
}

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.url, this.size = 56});

  final String name;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: HyColors.navy, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        Fmt.initials(name),
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.36),
        textScaler: TextScaler.noScaling,
      ),
    );
    if (url == null) return ExcludeSemantics(child: fallback);
    return ExcludeSemantics(
      child: ClipOval(
        child: Image.network(url!, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: HySpacing.xxl, horizontal: HySpacing.md),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: const BoxDecoration(color: HyColors.primarySoft, shape: BoxShape.circle),
          child: Icon(icon, size: 44, color: HyColors.primaryDark),
        ),
        const SizedBox(height: HySpacing.md),
        Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        if (message != null) ...[
          const SizedBox(height: HySpacing.xs),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: HyColors.textSecondary),
          ),
        ],
        if (action != null) ...[const SizedBox(height: HySpacing.lg), action!],
      ],
    ),
  );
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.cloud_off_rounded,
    title: AppError.from(error).message,
    action: onRetry == null
        ? null
        : SecondaryButton(label: 'Reintentar', icon: Icons.refresh, onPressed: onRetry, expand: false),
  );
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(HySpacing.xxl),
    child: Center(child: CircularProgressIndicator(color: HyColors.primary)),
  );
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.text, this.icon = Icons.info_outline, this.tone = StatusTone.info});

  final String text;
  final IconData icon;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(HySpacing.sm),
    decoration: BoxDecoration(color: tone.background, borderRadius: BorderRadius.circular(HyRadii.md)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: tone.foreground),
        const SizedBox(width: HySpacing.xs),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: tone.foreground, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

void showError(BuildContext context, Object error) => showMessage(context, AppError.from(error).message);

/// Ejecuta una acción mostrando el error en pantalla si falla. Devuelve true si salió bien.
Future<bool> runGuarded(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) showMessage(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Volver')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: HyColors.danger) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Pide un texto (por ejemplo, el motivo de una cancelación).
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  required String confirm,
  String? hint,
  int minLength = 3,
}) {
  final controller = TextEditingController();
  final formKey = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: TextFormField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: InputDecoration(labelText: label, hintText: hint),
          validator: (v) => (v ?? '').trim().length < minLength ? 'Escribe al menos $minLength caracteres' : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Volver')),
        FilledButton(
          onPressed: () {
            if (formKey.currentState!.validate()) Navigator.pop(c, controller.text.trim());
          },
          child: Text(confirm),
        ),
      ],
    ),
  );
}
