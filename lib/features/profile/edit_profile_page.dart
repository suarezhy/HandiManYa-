import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/app_error.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../auth/auth_scaffold.dart';
import '../common/city_picker.dart';

class EditProfilePage extends ConsumerWidget {
  const EditProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Información personal')),
      body: account == null ? const LoadingView() : _Form(account: account),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({required this.account});

  final UserProfile account;

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.account.fullName);
  late int? _cityId = widget.account.cityId;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).updateProfile(fullName: _name.text.trim(), cityId: _cityId),
      success: 'Perfil actualizado',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(accountProvider);
      if (_cityId != null) await ref.read(selectedCityProvider.notifier).select(_cityId!);
      if (mounted) context.pop();
    }
  }

  Future<void> _change(Widget sheet) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => sheet,
    );
    if (changed == true) ref.invalidate(accountProvider);
  }

  @override
  Widget build(BuildContext context) {
    final a = ref.watch(accountProvider).value ?? widget.account;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: HySpacing.lg),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nombre completo',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: Validators.fullName,
                ),
                const SizedBox(height: HySpacing.md),
                CityField(
                  key: const Key('edit-profile-city'),
                  value: _cityId,
                  onChanged: (v) => setState(() => _cityId = v),
                ),
                const SizedBox(height: HySpacing.md),
                _ContactRow(
                  key: const Key('profile-phone'),
                  icon: Icons.phone_iphone,
                  label: 'Celular (con este número entras)',
                  value: a.phone == null ? 'Sin número' : formatBoliviaPhone(a.phone!),
                  action: a.phone == null ? 'Agregar' : 'Cambiar',
                  onTap: () => _change(const _ChangePhoneSheet()),
                ),
                const SizedBox(height: HySpacing.md),
                _ContactRow(
                  key: const Key('profile-email'),
                  icon: Icons.mail_outline,
                  label: 'Correo (opcional, sirve para recuperar tu cuenta)',
                  value: a.emailPending != null
                      ? '${a.emailPending} (falta confirmar)'
                      : a.email.isEmpty
                      ? 'Sin correo'
                      : a.email,
                  action: a.emailPending != null
                      ? 'Confirmar'
                      : a.email.isEmpty
                      ? 'Agregar'
                      : 'Cambiar',
                  onTap: () => _change(_ChangeEmailSheet(current: a.email, pending: a.emailPending)),
                ),
                const SizedBox(height: HySpacing.xl),
                PrimaryButton(label: 'Guardar cambios', loading: _saving, onPressed: _save),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final String action;
  final VoidCallback onTap;

  // Toda la fila abre el formulario, no solo el botón: parece un campo y se
  // toca como un campo.
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$label: $value. $action',
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(HyRadii.md),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
        child: Row(
          children: [
            Expanded(child: Text(value, style: const TextStyle(fontSize: 16))),
            TextButton(onPressed: onTap, child: Text(action)),
          ],
        ),
      ),
    ),
  );
}

/// Cambiar de número: código al número nuevo. La cuenta, sus pedidos y su
/// billetera no cambian; solo el número con el que se entra.
class _ChangePhoneSheet extends ConsumerStatefulWidget {
  const _ChangePhoneSheet();

  @override
  ConsumerState<_ChangePhoneSheet> createState() => _ChangePhoneSheetState();
}

class _ChangePhoneSheetState extends ConsumerState<_ChangePhoneSheet> with ResendCooldown {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  var _channel = CodeChannel.whatsapp;
  String? _sentTo;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    final phone = Validators.normalizeBoliviaPhone(_phone.text)!;
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).requestPhoneChange(phone: phone, channel: _channel),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _sentTo = phone;
    });
    if (ok) startCooldown();
  }

  Future<void> _verify() async {
    if (!_form.currentState!.validate() || _busy) return;
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).verifyPhoneChange(phone: _sentTo!, code: _code.text),
      success: 'Listo. Desde ahora entras con ${formatBoliviaPhone(_sentTo!)}.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: _sentTo == null ? 'Cambiar número' : 'Escribe el código',
    subtitle: _sentTo == null
        ? 'Te enviaremos un código al número nuevo. Tus pedidos, tu perfil y tu billetera se mantienen.'
        : 'Lo enviamos por ${_channel.label} al ${formatBoliviaPhone(_sentTo!)}.',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_sentTo == null) ...[
            PhoneField(controller: _phone, label: 'Número nuevo'),
            const SizedBox(height: HySpacing.md),
            ChannelPicker(value: _channel, onChanged: (c) => setState(() => _channel = c)),
            const SizedBox(height: HySpacing.lg),
            PrimaryButton(label: 'Continuar', loading: _busy, onPressed: _send),
          ] else ...[
            CodeField(controller: _code, onCompleted: _verify),
            const SizedBox(height: HySpacing.lg),
            PrimaryButton(label: 'Continuar', loading: _busy, onPressed: _verify),
            TextButton(onPressed: cooldown > 0 || _busy ? null : _send, child: Text(resendLabel)),
          ],
        ],
      ),
    ),
  );
}

/// Agregar, cambiar o quitar el correo opcional. El correo nuevo solo queda
/// en la cuenta (y sirve para recuperarla) después de escribir el código que
/// le llega: así se comprueba que es de la persona.
class _ChangeEmailSheet extends ConsumerStatefulWidget {
  const _ChangeEmailSheet({required this.current, this.pending});

  final String current;
  final String? pending;

  @override
  ConsumerState<_ChangeEmailSheet> createState() => _ChangeEmailSheetState();
}

class _ChangeEmailSheetState extends ConsumerState<_ChangeEmailSheet> with ResendCooldown {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.pending ?? widget.current);
  final _code = TextEditingController();
  late bool _sent = widget.pending != null;
  bool _busy = false;

  bool get _hasEmail => widget.current.isNotEmpty || widget.pending != null;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _value => _email.text.trim().toLowerCase();

  Future<void> _send() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (_value == widget.current.toLowerCase()) {
      await runGuarded(context, () async => throw AppError.from('HMY_SAME_EMAIL'));
      return;
    }
    setState(() => _busy = true);
    final ok = await runGuarded(context, () => ref.read(backendProvider).requestEmailChange(_value));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _sent = true;
    });
    if (ok) startCooldown();
  }

  Future<void> _verify() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await runGuarded(
      context,
      () => ref.read(backendProvider).verifyEmailChange(email: _value, code: _code.text),
      success: 'Correo confirmado.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  Future<void> _remove() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Quitar el correo?'),
        content: const Text(
          'Ya no podrás recuperar tu cuenta con ese correo. Sigues entrando con tu celular y un código.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Volver')),
          TextButton(
            key: const Key('email-remove-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    final ok = await runGuarded(context, () => ref.read(backendProvider).removeEmail(), success: 'Correo quitado.');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: _sent
        ? 'Escribe el código'
        : widget.current.isEmpty
        ? 'Agregar correo'
        : 'Cambiar correo',
    subtitle: _sent
        ? 'Te enviamos un código a $_value. Revisa también la carpeta de spam. '
              'Hasta que lo confirmes, el correo no sirve para recuperar tu cuenta.'
        : 'Es opcional. Sirve para recuperar tu cuenta si pierdes tu número. '
              'Siempre entras con tu celular, sin contraseña.',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            key: const Key('email-field'),
            controller: _email,
            enabled: !_sent && !_busy,
            autofocus: !_sent,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Correo electrónico',
              hintText: 'nombre@correo.com',
              prefixIcon: Icon(Icons.mail_outline),
            ),
            validator: Validators.email,
            onFieldSubmitted: (_) => _send(),
          ),
          const SizedBox(height: HySpacing.md),
          if (_sent) ...[
            CodeField(controller: _code, onCompleted: _verify, fieldKey: const Key('email-code-field')),
            const SizedBox(height: HySpacing.lg),
            PrimaryButton(
              key: const Key('email-verify'),
              label: 'Confirmar correo',
              loading: _busy,
              onPressed: _verify,
            ),
            TextButton(
              key: const Key('email-resend'),
              onPressed: cooldown > 0 || _busy ? null : _send,
              child: Text(resendLabel),
            ),
            TextButton(
              key: const Key('email-edit'),
              onPressed: _busy ? null : () => setState(() => _sent = false),
              child: const Text('Usar otro correo'),
            ),
          ] else
            PrimaryButton(key: const Key('email-send'), label: 'Enviar código', loading: _busy, onPressed: _send),
          if (_hasEmail) ...[
            const SizedBox(height: HySpacing.sm),
            TextButton.icon(
              key: const Key('email-remove'),
              onPressed: _busy ? null : _remove,
              style: TextButton.styleFrom(foregroundColor: HyColors.danger),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Quitar correo'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, HySpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: HySpacing.xs),
          Text(subtitle, style: const TextStyle(fontSize: 16, color: HyColors.textSecondary)),
          const SizedBox(height: HySpacing.lg),
          child,
        ],
      ),
    ),
  );
}
