import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';

class EditProfilePage extends ConsumerWidget {
  const EditProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Editar perfil')),
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
  late final _phone = TextEditingController(text: widget.account.phone?.replaceFirst('+591', '') ?? '');
  late int? _cityId = widget.account.cityId;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await runGuarded(
      context,
      () => ref
          .read(backendProvider)
          .updateProfile(
            fullName: _name.text.trim(),
            phone: Validators.normalizeBoliviaPhone(_phone.text),
            cityId: _cityId,
          ),
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

  @override
  Widget build(BuildContext context) {
    final cities = ref.watch(citiesProvider).value ?? const [];
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: HySpacing.lg),
        children: [
          PageBody(
            child: Column(
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
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d +\-]')),
                    LengthLimitingTextInputFormatter(16),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Celular',
                    prefixIcon: Icon(Icons.phone_iphone),
                    prefixText: '+591 ',
                  ),
                  validator: Validators.boliviaPhone,
                ),
                const SizedBox(height: HySpacing.md),
                DropdownButtonFormField<int>(
                  initialValue: _cityId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Ciudad',
                    prefixIcon: Icon(Icons.location_city_outlined),
                  ),
                  items: [for (final c in cities) DropdownMenuItem(value: c.id, child: Text(c.name))],
                  onChanged: (v) => setState(() => _cityId = v),
                ),
                const SizedBox(height: HySpacing.md),
                InputDecorator(
                  decoration: const InputDecoration(labelText: 'Correo', prefixIcon: Icon(Icons.mail_outline)),
                  child: Text(widget.account.email, style: const TextStyle(color: HyColors.textSecondary)),
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
