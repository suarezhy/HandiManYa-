import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';

/// Versión de los textos. Si cambia, se vuelve a pedir la aceptación y queda
/// registrada en `consent_records`.
const legalVersion = '2026-10-borrador';

const _draftNotice =
    'BORRADOR — pendiente de revisión por un abogado en Bolivia. Los datos entre corchetes [PENDIENTE] '
    'deben completarse antes de publicar la app. Este texto no afirma cumplir ninguna ley en particular.';

/// Documentos legales. La clave coincide con `consent_records.document`.
enum LegalDoc {
  terms('terminos', 'Términos y condiciones', _terms),
  privacy('privacidad', 'Política de privacidad', _privacy),
  cancellations('cancelaciones', 'Política de cancelaciones', _cancellations),
  commissions('comisiones', 'Política de comisiones y billetera', _commissions),
  proRules('reglas_profesionales', 'Reglas para profesionales', _proRules),
  acceptableUse('uso_aceptable', 'Uso aceptable', _acceptableUse);

  const LegalDoc(this.key, this.title, this.body);
  final String key;
  final String title;
  final String body;
}

const _terms = '''1. Quiénes somos
HandiMan ¡Ya! es una plataforma digital operada por [PENDIENTE: razón social, NIT y domicilio] que conecta a personas que necesitan un servicio (clientes) con profesionales independientes (profesionales). Los profesionales no son empleados ni agentes de HandiMan ¡Ya!.

2. Tu cuenta
Debes dar datos reales (nombre, celular, correo y ciudad) y cuidar tu contraseña. Una persona puede usar la misma cuenta como cliente y, si es aprobada, como profesional.

3. Cómo funciona un pedido
• ¡Ya!: avisamos a los profesionales verificados disponibles cerca de ti y el primero que acepta toma el trabajo.
• Programar: eliges un profesional, día y hora; el profesional acepta, rechaza o envía una cotización.
El precio final lo acuerdan el cliente y el profesional.

4. Pagos
El cliente paga directamente al profesional (efectivo o QR) cuando termina el trabajo. HandiMan ¡Ya! no recibe ese pago ni lo garantiza. Los profesionales pagan una comisión a la plataforma desde su billetera prepagada (ver Política de comisiones).

5. Verificación
Revisamos el documento de identidad de cada profesional antes de aprobarlo. La verificación reduce riesgos pero no garantiza el resultado de cada trabajo.

6. Calificaciones y reportes
Las calificaciones deben ser honestas y sobre un trabajo real. Puedes reportar o bloquear a otra persona desde el chat, su perfil o la solicitud.

7. Suspensión
Podemos suspender una cuenta que incumpla estos términos, las Reglas para profesionales o el Uso aceptable. Te diremos el motivo y podrás escribirnos desde Ayuda.

8. Responsabilidad
[PENDIENTE: alcance de la responsabilidad de la plataforma, a definir con el abogado.]

9. Cambios
Si cambiamos estos términos te avisaremos en la app y te pediremos aceptar la nueva versión.

10. Contacto
[PENDIENTE: correo y teléfono de contacto.] También puedes escribirnos desde Perfil > Ayuda y soporte.''';

const _privacy = '''Qué datos guardamos
• Cuenta: nombre, correo, celular, ciudad y foto (si la subes).
• Solicitudes: servicio, descripción, fotos del problema, dirección y punto en el mapa (si usas el GPS).
• Profesionales: datos del perfil, documentos de identidad, zona de trabajo, billetera y movimientos.
• Mensajes del chat, calificaciones, reportes y mensajes a soporte.
• Qué versión de estos textos aceptaste y cuándo.

Para qué los usamos
Para operar la app: mostrar profesionales cercanos, enviar pedidos, verificar identidades, prevenir fraudes, atender reclamos y cobrar comisiones a los profesionales.

Ubicación
• Solo tomamos tu ubicación cuando tocas "Usar mi ubicación". No te seguimos en segundo plano.
• Antes de aceptar tu pedido, los profesionales solo ven un punto aproximado (alrededor de 1 km) y la distancia.
• La dirección exacta solo la ve el profesional que acepta, mientras el trabajo está activo.
• La ubicación base de un profesional no se muestra a los clientes.
• Mientras el profesional va en camino, su app comparte su ubicación con el cliente de ese pedido (solo con la pantalla abierta y la puede pausar). Se guarda solo el último punto y se borra al verificar la llegada o al cancelar.
• Si usas "Compartir mi viaje", la persona que recibe el enlace ve el nombre del profesional, el estado del servicio y su ubicación mientras viene, nunca tu dirección ni tu teléfono. El enlace vence en 12 horas o al terminar el trabajo.

Quién ve tus datos
• Fotos del problema: tú, los profesionales que reciben la oferta y el que la acepta.
• Documentos de identidad y comprobantes de recarga: solo el dueño y el equipo de verificación.
• El equipo de administración ve lo necesario para atender reportes y disputas, y cada acción suya queda registrada.

Dónde se guardan
En los servidores de nuestro proveedor de base de datos (Supabase), que pueden estar fuera de Bolivia. [PENDIENTE: región elegida y acuerdos con el proveedor.]

Cuánto tiempo
[PENDIENTE: plazos de conservación por tipo de dato, a definir con el abogado.]

Tus opciones
Puedes ver y corregir tus datos en Perfil, y pedir que borremos tu cuenta desde Perfil > Eliminar mi cuenta. Para otras solicitudes escríbenos desde Ayuda.

Contacto
[PENDIENTE: responsable de datos y correo de contacto.]''';

const _cancellations = '''Cliente
• Puedes cancelar sin costo mientras ningún profesional haya aceptado.
• Después de que un profesional acepta, también puedes cancelar, pero te pediremos el motivo. Avísale por el chat si ya está en camino.
• Cancelar seguido puede limitar tu cuenta.

Profesional
• Si aceptas un trabajo, es un compromiso. Cancelar sin un motivo justificado puede afectar tu calificación y tu cuenta.
• Si el trabajo se cancela, la comisión reservada vuelve a tu saldo disponible.

Si alguien no se presenta
Repórtalo desde la solicitud ("Reportar un problema"). Nuestro equipo revisa el caso con las dos partes.

Disputas
Si hay un problema con un trabajo en curso o terminado, cualquiera de las dos partes puede abrir una disputa. El equipo de administración decide si el trabajo se da por completado o se cancela, y explica la decisión a ambos.

[PENDIENTE: plazos, penalidades y devoluciones, a definir con el abogado.]''';

const _commissions = '''Esta política es para profesionales.

Billetera prepagada
• Para recibir pedidos necesitas saldo en tu billetera.
• Recargas por transferencia o QR y registras el pago en la app con el comprobante. El equipo lo verifica y lo acredita. La app nunca suma saldo sin esa verificación.

Comisión
• La comisión, la reserva y el saldo mínimo los define la administración por categoría y ciudad, y se muestran en la app antes de que aceptes un trabajo.
• Al aceptar un trabajo se reserva un monto de tu saldo.
• La comisión se cobra cuando el trabajo se completa (o al aceptar, si así lo indica la regla).
• Si el trabajo se cancela, la reserva vuelve a tu saldo disponible.

Registro
Cada movimiento queda en tu historial y no se puede borrar ni modificar. Los ajustes manuales del equipo siempre llevan un motivo.

Cambios
Si cambian los montos te avisaremos antes en la app. [PENDIENTE: aviso mínimo, facturación y devolución de saldo no usado, a definir con el abogado y el contador.]''';

const _proRules = '''Para ser parte de HandiMan ¡Ya!:

1. Datos reales: tu nombre, foto, documentos y experiencia deben ser verdaderos y estar vigentes.
2. Precio claro: acuerda el precio o envía una cotización antes de empezar. No cobres más de lo acordado sin el visto bueno del cliente.
3. Puntualidad: si aceptas, llega a tiempo. Si te retrasas, avisa por el chat.
4. Respeto: trata con respeto a los clientes y su casa. No se permite discriminar, acosar ni amenazar.
5. Privacidad: usa la dirección y los datos del cliente solo para ese trabajo.
6. Seguridad: trabaja con cuidado y no hagas trabajos para los que no estás preparado.
7. Disponibilidad: activa "Disponible" solo cuando realmente puedas atender pedidos.
8. Calificaciones: no pidas ni ofrezcas nada a cambio de una buena calificación.

Si no cumples estas reglas, podemos pedirte una nueva verificación, suspender tu perfil o cerrar tu cuenta. Siempre te diremos el motivo.''';

const _acceptableUse = '''No está permitido usar HandiMan ¡Ya! para:
• Hacer pedidos falsos o de broma.
• Insultar, acosar, amenazar o discriminar a otra persona.
• Enviar fotos o mensajes sexuales, violentos u ofensivos.
• Pedir u ofrecer servicios ilegales.
• Hacerse pasar por otra persona o usar documentos ajenos.
• Intentar entrar a cuentas ajenas, copiar datos o afectar el funcionamiento de la app.
• Publicar datos personales de otras personas.

Puedes reportar cualquier abuso desde el chat, el perfil o la solicitud. Revisamos cada reporte y podemos suspender cuentas. Si estás en peligro, llama a la Policía al 110.''';

Future<void> showLegalDoc(BuildContext context, LegalDoc doc) =>
    showLegalSheet(context, title: doc.title, body: doc.body);

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
          const SizedBox(height: HySpacing.sm),
          const InfoBanner(icon: Icons.edit_note, tone: StatusTone.warning, text: _draftNotice),
          const SizedBox(height: HySpacing.md),
          Text(body, style: Theme.of(c).textTheme.bodyLarge?.copyWith(height: 1.45)),
          const SizedBox(height: HySpacing.md),
          Text('Versión $legalVersion', style: const TextStyle(color: HyColors.textMuted)),
        ],
      ),
    ),
  );
}
