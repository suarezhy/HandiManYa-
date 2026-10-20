import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';

/// Elige fotos de la cámara o la galería (hasta [max]). Las fotos se achican
/// en el teléfono para que suban rápido con datos móviles.
Future<PhotoUpload?> pickPhoto(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Tomar una foto'),
            onTap: () => Navigator.pop(c, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Elegir de la galería'),
            onTap: () => Navigator.pop(c, ImageSource.gallery),
          ),
          const SizedBox(height: HySpacing.sm),
        ],
      ),
    ),
  );
  if (source == null) return null;
  try {
    final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
    if (file == null) return null;
    return PhotoUpload(bytes: await file.readAsBytes(), fileName: file.name);
  } catch (_) {
    if (context.mounted) showMessage(context, 'No pudimos abrir la cámara o la galería. Revisa los permisos.');
    return null;
  }
}

class PhotoPickerRow extends StatelessWidget {
  const PhotoPickerRow({super.key, required this.photos, required this.onChanged, this.max = 5});

  final List<PhotoUpload> photos;
  final ValueChanged<List<PhotoUpload>> onChanged;
  final int max;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Fotos del problema (opcional)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 2),
        const Text(
          'Ayudan al profesional a entender el trabajo. Las verá solo quien reciba tu pedido.',
          style: TextStyle(color: HyColors.textSecondary, fontSize: 15),
        ),
        const SizedBox(height: HySpacing.sm),
        Wrap(
          spacing: HySpacing.sm,
          runSpacing: HySpacing.sm,
          children: [
            for (var i = 0; i < photos.length; i++)
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(HyRadii.md),
                    child: Image.memory(photos[i].bytes, width: 88, height: 88, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: -10,
                    top: -10,
                    child: IconButton.filled(
                      tooltip: 'Quitar foto',
                      iconSize: 18,
                      style: IconButton.styleFrom(backgroundColor: HyColors.navy, minimumSize: const Size(32, 32)),
                      onPressed: () => onChanged([...photos]..removeAt(i)),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            if (photos.length < max)
              Semantics(
                button: true,
                label: 'Agregar foto',
                child: InkWell(
                  borderRadius: BorderRadius.circular(HyRadii.md),
                  onTap: () async {
                    final p = await pickPhoto(context);
                    if (p != null) onChanged([...photos, p]);
                  },
                  child: Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: HyColors.surface,
                      borderRadius: BorderRadius.circular(HyRadii.md),
                      border: Border.all(color: HyColors.border, width: 1.5),
                    ),
                    padding: const EdgeInsets.all(4),
                    // Con letra grande se achica en vez de desbordarse.
                    child: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_a_photo_outlined, color: HyColors.primaryDark),
                          SizedBox(height: 4),
                          Text('Agregar', style: TextStyle(fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Muestra fotos ya guardadas (URL firmada o bytes en el modo demostración).
class BookingPhotosStrip extends StatelessWidget {
  const BookingPhotosStrip({super.key, required this.photos});

  final List<BookingPhoto> photos;

  Widget _image(BookingPhoto p, {BoxFit fit = BoxFit.cover, double? size}) => p.bytes != null
      ? Image.memory(p.bytes!, width: size, height: size, fit: fit)
      : Image.network(
          p.url!,
          width: size,
          height: size,
          fit: fit,
          errorBuilder: (_, _, _) => Container(
            width: size,
            height: size,
            color: HyColors.surfaceMuted,
            child: const Icon(Icons.broken_image_outlined),
          ),
        );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: HySpacing.xs),
        itemBuilder: (context, i) => Semantics(
          button: true,
          label: 'Ver foto ${i + 1} de ${photos.length}',
          child: GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              builder: (c) => Dialog(
                insetPadding: const EdgeInsets.all(HySpacing.md),
                child: Stack(
                  children: [
                    InteractiveViewer(child: _image(photos[i], fit: BoxFit.contain)),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: IconButton.filled(
                        tooltip: 'Cerrar',
                        onPressed: () => Navigator.pop(c),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            child: ClipRRect(borderRadius: BorderRadius.circular(HyRadii.md), child: _image(photos[i], size: 96)),
          ),
        ),
      ),
    );
  }
}
