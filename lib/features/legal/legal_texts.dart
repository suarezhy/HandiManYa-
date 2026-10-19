import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// BORRADOR. Estos textos deben ser revisados por un abogado en Bolivia
/// antes de publicar la app.
const termsDraft = '''BORRADOR — pendiente de revisión legal.

1. HandiMan ¡Ya! es una plataforma que conecta a clientes con profesionales independientes. Los profesionales no son empleados de HandiMan ¡Ya!.

2. El cliente paga el servicio directamente al profesional (efectivo o QR). HandiMan ¡Ya! no recibe ese pago ni lo garantiza.

3. Los profesionales pasan por una verificación de identidad antes de ser aprobados. La verificación no garantiza el resultado de cada trabajo.

4. Las calificaciones deben ser honestas y basadas en un trabajo real.

5. Puedes pedir la eliminación de tu cuenta desde tu perfil en cualquier momento.''';

const privacyDraft = '''BORRADOR — pendiente de revisión legal.

• Guardamos tu nombre, correo, celular y ciudad para operar tu cuenta.
• Tu dirección exacta solo la ve el profesional que acepta tu solicitud, y solo mientras el trabajo está activo.
• Antes de aceptar, el profesional solo ve la zona general (por ejemplo, "Zona Norte").
• Los documentos de identidad de los profesionales se guardan en almacenamiento privado y solo los revisa el equipo de verificación.
• No seguimos tu ubicación en segundo plano.
• Puedes pedir que eliminemos tus datos desde tu perfil.''';

Future<void> showLegalSheet(BuildContext context, {required String title, required String body}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      builder: (c, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(HySpacing.page, 0, HySpacing.page, HySpacing.xxl),
        children: [
          Text(title, style: Theme.of(c).textTheme.headlineSmall),
          const SizedBox(height: HySpacing.md),
          Text(body, style: Theme.of(c).textTheme.bodyLarge),
        ],
      ),
    ),
  );
}
