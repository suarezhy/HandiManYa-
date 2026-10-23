import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/user.dart';
import '../../data/providers.dart';
import '../common/photo_picker.dart';

/// Foto de perfil con un botón de cámara: agregar, cambiar, ver o quitar.
class ProfilePhotoButton extends ConsumerWidget {
  const ProfilePhotoButton({super.key, required this.account, this.size = 64});

  final UserProfile account;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Semantics(
    button: true,
    label: account.hasPhoto ? 'Cambiar foto de perfil' : 'Agregar foto de perfil',
    child: InkWell(
      key: const Key('profile-photo'),
      customBorder: const CircleBorder(),
      onTap: () => _open(context, ref),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PersonAvatar(name: account.fullName, url: account.photoUrl, bytes: account.photoBytes, size: size),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: HyColors.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.photo_camera, color: Colors.white, size: 14),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, HySpacing.xs),
                child: Text('Foto de perfil', style: Theme.of(c).textTheme.titleLarge),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, HySpacing.xs),
                child: Text(
                  'La ven los clientes o profesionales con quienes tienes un pedido. Tu carnet no se muestra.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
              ),
              if (account.hasPhoto)
                ListTile(
                  key: const Key('profile-photo-view'),
                  leading: const Icon(Icons.visibility_outlined),
                  title: const Text('Ver foto'),
                  onTap: () => Navigator.pop(c, 'view'),
                ),
              ListTile(
                key: const Key('profile-photo-camera'),
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Tomar una foto'),
                onTap: () => Navigator.pop(c, 'camera'),
              ),
              ListTile(
                key: const Key('profile-photo-gallery'),
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Elegir de la galería'),
                onTap: () => Navigator.pop(c, 'gallery'),
              ),
              if (account.hasPhoto)
                ListTile(
                  key: const Key('profile-photo-remove'),
                  leading: const Icon(Icons.delete_outline, color: HyColors.danger),
                  title: const Text('Quitar foto', style: TextStyle(color: HyColors.danger)),
                  onTap: () => Navigator.pop(c, 'remove'),
                ),
              const SizedBox(height: HySpacing.sm),
            ],
          ),
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    final api = ref.read(backendProvider);
    switch (action) {
      case 'view':
        await showPhotoPreview(
          context,
          account.photoBytes != null
              ? Image.memory(account.photoBytes!, fit: BoxFit.contain)
              : Image.network(account.photoUrl!, fit: BoxFit.contain),
        );
      case 'remove':
        final ok = await confirmDialog(
          context,
          title: '¿Quitar tu foto?',
          message: 'Se mostrarán tus iniciales en su lugar.',
          confirm: 'Quitar',
          destructive: true,
        );
        if (ok && context.mounted && await runGuarded(context, api.removeProfilePhoto, success: 'Foto quitada')) {
          ref.invalidate(accountProvider);
        }
      default:
        XFile? file;
        try {
          // Foto chica: suficiente para un círculo y rápida de subir con datos móviles.
          file = await ImagePicker().pickImage(
            source: action == 'camera' ? ImageSource.camera : ImageSource.gallery,
            maxWidth: 800,
            maxHeight: 800,
            imageQuality: 80,
            preferredCameraDevice: CameraDevice.front,
          );
        } catch (_) {
          if (context.mounted) showMessage(context, 'No pudimos abrir la cámara o la galería. Revisa los permisos.');
          return;
        }
        if (file == null || !context.mounted) return;
        final bytes = await file.readAsBytes();
        if (!context.mounted) return;
        final ok = await runGuarded(
          context,
          () => api.setProfilePhoto(bytes: bytes, fileName: file!.name),
          success: 'Foto actualizada',
        );
        if (ok) ref.invalidate(accountProvider);
    }
  }
}
