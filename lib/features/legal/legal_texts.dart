import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../data/models/booking.dart';

/// Versión de los textos. Si cambia, se vuelve a pedir la aceptación y queda
/// registrada en `consent_records`.
const legalVersion = '2026-10-borrador-5';

const _draftNotice =
    'BORRADOR para revisión legal. No es un texto final ni está aprobado por un abogado. '
    'Los datos marcados [PENDIENTE] los debe completar la empresa, y los marcados [REVISIÓN LEGAL] '
    'son una propuesta que un abogado en Bolivia debe confirmar antes de publicar la app.';

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
HandiMan ¡Ya! es una plataforma digital operada por [PENDIENTE: razón social, NIT y domicilio] que pone en contacto a personas que necesitan un servicio (clientes) con profesionales independientes (profesionales). Los profesionales no son empleados ni agentes de HandiMan ¡Ya!. El contrato del servicio es entre el cliente y el profesional.

2. Tu cuenta
• Entras con tu número de celular de Bolivia (+591). Te enviamos un código de un solo uso por WhatsApp o SMS. No hay contraseña.
• Puedes agregar un correo para recuperar tu cuenta si cambias de número. Es opcional.
• Si tu teléfono lo permite, puedes activar el desbloqueo con huella o rostro. Tu teléfono hace esa verificación; nosotros no recibimos tus datos biométricos. Siempre puedes volver a entrar con un código.
• Debes dar datos reales y cuidar el acceso a tu celular. Una misma cuenta sirve como cliente y, si es aprobada, como profesional.

3. Cómo funciona un pedido
• ¡Ya!: avisamos a los profesionales verificados disponibles cerca de ti; el trabajo se confirma cuando tú y un profesional aceptan el mismo precio.
• Programar: eliges un profesional, día y hora; el profesional acepta, rechaza o envía una cotización.
• El precio lo acuerdan el cliente y el profesional antes de empezar.
• Cuando el profesional llega, el cliente le da un código de llegada para confirmar que es la persona correcta.

4. Pagos del servicio
• El cliente paga directamente al profesional, en efectivo o por QR, cuando termina el trabajo.
• HandiMan ¡Ya! no recibe, no retiene y no garantiza ese pago, y no cobra comisión al cliente.
• Los clientes no tienen billetera en la app.

5. Comisión de los profesionales
Los profesionales pagan una comisión a HandiMan ¡Ya! desde su billetera prepagada (saldo en bolivianos que recargan ellos mismos). Los detalles están en la Política de comisiones y billetera.

6. Verificación de profesionales
• Antes de aprobar a un profesional, una persona del equipo revisa su carnet y, para algunos servicios, su título, matrícula o antecedentes.
• También podemos pedir una verificación de identidad con un proveedor externo (Didit): fotos del carnet, una selfie y una prueba de que la persona está presente.
• La verificación reduce riesgos, pero no garantiza el resultado de cada trabajo.

7. Ubicación
Usamos tu ubicación para encontrar profesionales cerca y, durante un trabajo activo, para mostrar al cliente que el profesional va en camino. Los detalles están en la Política de privacidad.

8. Cancelaciones y disputas
Se rigen por la Política de cancelaciones. Si hay un problema con un trabajo, cualquiera de las partes puede abrir una disputa desde la solicitud.

9. Calificaciones y reportes
Las calificaciones deben ser honestas y sobre un trabajo real. Puedes reportar o bloquear a otra persona desde el chat, su perfil o la solicitud.

10. Seguridad
HandiMan ¡Ya! no es un servicio de emergencias y no envía ayuda. Si estás en peligro, llama a la Policía (110), ambulancia (118) o bomberos (119).

11. Suspensión
Podemos suspender una cuenta que incumpla estos términos, las Reglas para profesionales o el Uso aceptable. Te diremos el motivo y podrás escribirnos desde Ayuda.

12. Responsabilidad
[REVISIÓN LEGAL: propuesta] HandiMan ¡Ya! es un intermediario: no presta los servicios ni es parte del acuerdo entre cliente y profesional. Cada profesional responde por su trabajo. HandiMan ¡Ya! responde por el funcionamiento de la plataforma en la medida que exija la ley boliviana. El alcance exacto debe definirlo un abogado.

13. Cambios
Si cambiamos estos términos te avisaremos en la app y te pediremos aceptar la nueva versión.

14. Ley aplicable y contacto
[PENDIENTE: ley aplicable, jurisdicción, correo y teléfono de contacto.] También puedes escribirnos desde Perfil > Ayuda y soporte.''';

const _privacy = '''Quién es responsable
[PENDIENTE: razón social, NIT, domicilio y contacto del responsable de los datos.]

Qué datos guardamos
• Cuenta: celular, nombre, municipio, y si los agregas, correo (para recuperar la cuenta) y foto de perfil.
• Ingreso: cuándo pediste un código y por qué canal (WhatsApp o SMS). No guardamos los códigos.
• Desbloqueo con huella o rostro: solo si está activado (sí o no). La huella o el rostro los revisa tu teléfono y no nos llegan.
• Solicitudes: servicio, descripción, fotos del problema, dirección y punto en el mapa.
• Profesionales: perfil, servicios, zona de trabajo, carnet y otros documentos, billetera y movimientos.
• Verificación de identidad (profesionales): el resultado que nos envía Didit (aprobado o rechazado, tipo de documento, puntajes de coincidencia y de presencia, avisos). Las fotos y la selfie las procesa Didit.
• Chat, calificaciones, reportes, disputas y mensajes a soporte.
• Avisos push: si los activas, el identificador de avisos de cada teléfono y si cada aviso salió. Lo borras al desactivarlos o al cerrar sesión.
• Qué versión de estos textos aceptaste y cuándo.

Para qué los usamos
Para que funcione la app: encontrar profesionales cercanos, enviar pedidos, verificar a los profesionales, prevenir fraudes, atender reportes y disputas, y cobrar comisiones a los profesionales. No vendemos tus datos.

Ubicación
• Tomamos tu ubicación solo cuando tocas "Usar mi ubicación" o mientras se usa una función que la necesita. No te seguimos en segundo plano.
• Antes de aceptar un pedido, los profesionales ven solo un punto aproximado (alrededor de 1 km) y la distancia.
• La dirección exacta la ve solo el profesional que acepta, mientras el trabajo está activo.
• La ubicación base de un profesional no se muestra a los clientes.
• Mientras el profesional va en camino, su app comparte su ubicación con el cliente de ese pedido (con la app abierta, y la puede pausar). Se guarda solo el último punto y se borra al confirmar la llegada o al cancelar.
• Con "Compartir mi viaje", quien recibe el enlace ve el nombre del profesional, el estado y su ubicación mientras viene, nunca tu dirección ni tu teléfono. El enlace vence en 12 horas o al terminar el trabajo.

Quién ve tus datos
• El profesional de tu pedido ve tu nombre, la dirección (cuando acepta) y lo que escribes en el chat.
• Fotos del problema: tú, los profesionales que reciben la oferta y el que la acepta.
• Carnet, documentos y comprobantes de recarga: solo su dueño y el equipo de verificación.
• El equipo ve lo necesario para atender reportes y disputas, y cada acción suya queda registrada.

Proveedores
• Supabase (base de datos y archivos), cuyos servidores pueden estar fuera de Bolivia. [PENDIENTE: región y acuerdos con el proveedor.]
• Didit (verificación de identidad de profesionales).
• Firebase Cloud Messaging de Google (avisos push, solo si los activas). El aviso lleva un título y una frase general, nunca el texto de tus mensajes, descripciones ni direcciones.
• El proveedor de WhatsApp o SMS que envía los códigos. [PENDIENTE: nombre del proveedor cuando se contrate.]

Cuánto tiempo
[PENDIENTE: plazos de conservación por tipo de dato, a definir con un abogado.]

Tus opciones
Puedes ver y corregir tus datos en Perfil y pedir que borremos tu cuenta en Perfil > Eliminar mi cuenta. Hoy ese pedido lo revisa una persona del equipo. Algunos registros (movimientos de billetera, reportes y aceptación de términos) pueden conservarse el tiempo que exija la ley. Para otras solicitudes escríbenos desde Ayuda.

[REVISIÓN LEGAL: confirmar qué exige la normativa boliviana sobre datos personales, consentimiento y transferencia de datos fuera del país.]''';

const _cancellations = '''Cliente
• Puedes cancelar sin costo mientras ningún profesional haya aceptado.
• Después de que un profesional acepta, también puedes cancelar sin costo. Le avisaremos al profesional; si ya está en camino, escríbele por el chat.
• Cancelar seguido puede limitar tu cuenta.
• Como el pago es directo al profesional, HandiMan ¡Ya! no cobra ni devuelve dinero al cliente.

Profesional
• Decir "No puedo" antes de aceptar no tiene costo.
• Si cancelas un trabajo después de aceptarlo, se descuentan Bs 3,00 de tu billetera, una sola vez. Si tu saldo no alcanza, se descuenta lo que haya (nunca queda negativo) y el equipo revisa el resto.
• Si cancelaste por una emergencia o por una falla de la app, escríbenos desde Ayuda: el equipo puede devolverte la penalización.
• Si el trabajo se cancela antes de que el cliente marque "Ya pagué", no se cobra comisión.

Si alguien no se presenta
Repórtalo desde la solicitud ("Reportar un problema"). El equipo revisa el caso con las dos partes.

Disputas
Si hay un problema con un trabajo en curso o terminado, cualquiera de las dos partes puede abrir una disputa. El equipo decide si el trabajo se da por completado o se cancela, y explica la decisión a ambos. Esa decisión afecta solo a la comisión del profesional y a las cuentas en la app; el pago del servicio es un asunto entre el cliente y el profesional.

[PENDIENTE: plazos y demás penalidades, a definir con un abogado.]''';

const _commissions = '''Esta política es para profesionales. Los clientes no tienen billetera ni pagan comisión.

Mi billetera
• Tu billetera tiene saldo en bolivianos (Bs) y solo sirve para pagar las comisiones de la plataforma.
• Para recibir pedidos necesitas saldo suficiente.
• Recargas por transferencia o QR y registras el pago en "Recargar saldo" con el comprobante. El equipo lo verifica y lo acredita. La app nunca suma saldo sin esa verificación.

Comisión
• La comisión (10 % del precio acordado, salvo que la administración defina otra por servicio o ciudad) se muestra antes de que aceptes un trabajo.
• Nada se reserva ni se descuenta al acordar el precio ni al empezar el trabajo.
• La comisión se cobra una sola vez, cuando el cliente marca "Ya pagué" después de que terminaste el trabajo. Confirmar el trabajo terminado o marcar "Recibí el pago" no la cobran.
• Para acordar un precio, tu saldo tiene que cubrir su comisión y la de tus otros trabajos acordados que todavía no se cobraron. Si no alcanza, no puedes acordar ese precio. Tu saldo nunca queda negativo.
• Si el cliente marcó "Ya pagué" pero no recibiste el pago, toca "No recibí el pago" en la solicitud dentro de los 7 días. El equipo lo revisa y, si el cliente no pagó, te devuelve la comisión.
• Si el precio cambia con una contraoferta que los dos aceptan, la comisión se calcula sobre el nuevo total.
• Si una disputa termina con el trabajo cancelado, la comisión cobrada vuelve a tu saldo.
• Si cancelas un trabajo después de aceptarlo, se descuenta una penalización de Bs 3,00 (ver Cancelaciones).
• El pago del cliente por el servicio es todo tuyo: lo recibes directamente en efectivo o por QR.

Historial de movimientos
Cada movimiento queda en tu historial y no se puede borrar ni modificar. Los ajustes manuales del equipo siempre llevan un motivo.

Cambios
Si cambian los montos te avisaremos antes en la app. [PENDIENTE: aviso mínimo, facturación y devolución de saldo no usado, a definir con un abogado y un contador.]''';

const _proRules = '''Para ser parte de HandiMan ¡Ya!:

1. Datos reales: tu nombre, foto, documentos y experiencia deben ser verdaderos y estar vigentes.
2. Solo servicios para los que estás habilitado: si un servicio exige título, matrícula o nombramiento (por ejemplo, abogados o notarios), ofrécelo solo si lo tienes y lo subiste para su revisión.
3. Precio claro: acuerda el precio antes de empezar. Si el trabajo cambia, envía una contraoferta con el nuevo total; no cobres más de lo acordado sin que el cliente la acepte.
4. Puntualidad: si aceptas, llega a tiempo. Si te retrasas, avisa por el chat.
5. Respeto: trata con respeto a los clientes y su casa. No se permite discriminar, acosar ni amenazar.
6. Privacidad: usa la dirección y los datos del cliente solo para ese trabajo.
7. Seguridad: trabaja con cuidado y no hagas trabajos para los que no estás preparado.
8. Disponibilidad: activa "Disponible" solo cuando realmente puedas atender pedidos.
9. Calificaciones: no pidas ni ofrezcas nada a cambio de una buena calificación.

Si no cumples estas reglas, podemos pedirte una nueva verificación, suspender tu perfil o cerrar tu cuenta. Siempre te diremos el motivo.''';

const _acceptableUse = '''No está permitido usar HandiMan ¡Ya! para:
• Hacer pedidos falsos o de broma.
• Insultar, acosar, amenazar o discriminar a otra persona.
• Enviar fotos o mensajes sexuales, violentos u ofensivos.
• Pedir u ofrecer servicios ilegales, o servicios regulados sin la habilitación exigida.
• Hacerse pasar por otra persona o usar documentos ajenos.
• Intentar entrar a cuentas ajenas, copiar datos o afectar el funcionamiento de la app.
• Publicar datos personales de otras personas.

Puedes reportar cualquier abuso desde el chat, el perfil o la solicitud. Revisamos cada reporte y podemos suspender cuentas. HandiMan ¡Ya! no es un servicio de emergencias: si estás en peligro, llama a la Policía al 110.''';

/// Abre el documento en una pantalla completa con flecha para volver. Se
/// apila sobre la pantalla actual, así que al volver se conserva lo que el
/// usuario ya había escrito (por ejemplo, en el registro) y su desplazamiento.
Future<void> showLegalDoc(BuildContext context, LegalDoc doc) =>
    showLegalSheet(context, title: doc.title, body: doc.body);

Future<void> showLegalSheet(BuildContext context, {required String title, required String body}) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LegalDocPage(title: title, body: body),
      ),
    );

class LegalDocPage extends StatelessWidget {
  const LegalDocPage({super.key, required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('legal-back'),
          tooltip: 'Volver',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('legal-body'),
          padding: bottomSafePadding(
            context,
            top: HySpacing.sm,
          ).add(const EdgeInsets.symmetric(horizontal: HySpacing.page)),
          children: [
            const InfoBanner(icon: Icons.edit_note, tone: StatusTone.warning, text: _draftNotice),
            const SizedBox(height: HySpacing.md),
            Text(body, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45)),
            const SizedBox(height: HySpacing.md),
            Text('Versión $legalVersion', style: const TextStyle(color: HyColors.textMuted)),
          ],
        ),
      ),
    );
  }
}
