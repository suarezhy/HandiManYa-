/// Error que la interfaz puede mostrar tal cual al usuario.
class AppError implements Exception {
  const AppError(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;

  /// Convierte cualquier error en un mensaje claro en español.
  static AppError from(Object error) {
    if (error is AppError) return error;
    final raw = error.toString();
    final otp = _otpError(raw);
    if (otp != null) return otp;
    for (final entry in _codes.entries) {
      if (raw.contains(entry.key)) return AppError(entry.value, code: entry.key);
    }
    final lower = raw.toLowerCase();
    if (lower.contains('token has expired') || lower.contains('otp') && lower.contains('invalid')) {
      return const AppError('El código no es correcto o ya venció. Revísalo o pide uno nuevo.', code: 'otp_invalid');
    }
    if (lower.contains('phone') && (lower.contains('already') || lower.contains('exists'))) {
      return AppError.from('phone_exists');
    }
    if (lower.contains('email') && (lower.contains('already') || lower.contains('exists'))) {
      return AppError.from('email_exists');
    }
    // Supabase Auth: formato que no acepta.
    if (lower.contains('email_address_invalid') || lower.contains('unable to validate email')) {
      return AppError.from('HMY_INVALID_EMAIL');
    }
    // Supabase Auth no pudo mandar el correo (sin servidor de correo propio,
    // correo no autorizado o límite de envíos del proyecto).
    if (lower.contains('error sending') && lower.contains('email') ||
        lower.contains('email_address_not_authorized') ||
        lower.contains('over_email_send_rate_limit') ||
        lower.contains('email rate limit')) {
      return AppError.from('HMY_EMAIL_UNAVAILABLE');
    }
    if (lower.contains('phone provider') || lower.contains('sending sms') || lower.contains('sms_send_failed')) {
      return const AppError(
        'Todavía no podemos enviar códigos a este número. Vuelve a intentar más tarde.',
        code: 'HMY_OTP_UNAVAILABLE',
      );
    }
    if (lower.contains('rate limit') || lower.contains('too many')) {
      return const AppError(
        'Hiciste muchos intentos seguidos. Espera un momento y vuelve a probar.',
        code: 'rate_limit',
      );
    }
    if (lower.contains('socket') ||
        lower.contains('failed host lookup') ||
        lower.contains('network') ||
        lower.contains('clientexception')) {
      return const AppError('No hay conexión a internet. Revisa tu conexión y vuelve a intentar.', code: 'network');
    }
    return const AppError('Algo salió mal. Vuelve a intentar en un momento.');
  }

  /// Errores al pedir o verificar el código de 6 dígitos (vienen del
  /// servicio de envío o de Supabase Auth).
  static AppError? _otpError(String raw) {
    final soon =
        RegExp(r'HMY_OTP_TOO_SOON:(\d+)').firstMatch(raw) ??
        RegExp(r'only request this after (\d+) seconds').firstMatch(raw);
    if (soon != null) {
      return AppError('Espera ${soon.group(1)} segundos para pedir otro código.', code: 'HMY_OTP_TOO_SOON');
    }
    final off = RegExp(r'HMY_OTP_(CHANNEL_OFF|SEND_FAILED|BUDGET):(whatsapp|sms)').firstMatch(raw);
    final pinSoon = RegExp(r'HMY_ARRIVAL_PIN_TOO_SOON:(\d+)').firstMatch(raw);
    if (pinSoon != null) {
      return AppError(
        'Espera ${pinSoon.group(1)} segundos para generar otro código.',
        code: 'HMY_ARRIVAL_PIN_TOO_SOON',
      );
    }
    if (off != null) {
      final (name, other) = off.group(2) == 'whatsapp' ? ('WhatsApp', 'SMS') : ('SMS', 'WhatsApp');
      return AppError(switch (off.group(1)) {
        'CHANNEL_OFF' => 'Todavía no enviamos códigos por $name. Prueba por $other.',
        'BUDGET' =>
          'Todavía no podemos enviar códigos por $name a este número. Intenta más tarde o escríbenos desde otro número.',
        _ => 'No pudimos enviar el código por $name. Vuelve a intentar o prueba por $other.',
      }, code: 'HMY_OTP_${off.group(1)}');
    }
    return null;
  }

  static const _codes = {
    'HMY_NO_PROFESSIONALS_AVAILABLE': 'No hay profesionales disponibles ahora para este servicio en tu zona. Prueba en otra zona o programa para después.',
    'HMY_ALREADY_TAKEN': 'Otro profesional ya tomó este pedido.',
    'HMY_IDENTITY_PAUSED':
        'La verificación de identidad está en pausa por ahora. Tu postulación sigue en revisión; te avisaremos.',
    'HMY_IDENTITY_OFF': 'La verificación de identidad todavía no está disponible. Tu postulación sigue en revisión.',
    'HMY_IDENTITY_SEND_FAILED': 'No pudimos abrir la verificación de identidad. Vuelve a intentar en unos minutos.',
    'HMY_IDENTITY_UNAVAILABLE': 'No pudimos abrir la verificación de identidad. Vuelve a intentar en unos minutos.',
    'HMY_IDENTITY_ALREADY_APPROVED': 'Tu identidad ya está verificada.',
    'HMY_IDENTITY_ATTEMPT_LIMIT':
        'Ya hiciste 3 intentos este mes. Escríbenos a soporte y una persona revisará tu caso.',
    'HMY_ID_DOCUMENTS_REQUIRED':
        'Para aprobar, primero acepta el carnet de identidad (frente y reverso) en Documentos.',
    'HMY_IDENTITY_CHECK_REQUIRED':
        'Para aprobar, primero tiene que haber una verificación de identidad real aprobada (las de prueba no cuentan).',
    'HMY_CAP_REQUIRED': 'Para autorizar un gasto, fija un tope mensual mayor que cero.',
    'HMY_NO_SANDBOX': 'Este proveedor no tiene modo de prueba.',
    'HMY_ARRIVAL_NOT_VERIFIED': 'Primero el cliente tiene que verificar tu llegada con el código.',
    'HMY_ARRIVAL_NO_PIN': 'Todavía no hay un código vigente. Pídele al profesional que toque "He llegado".',
    'HMY_ARRIVAL_PIN_LIMIT':
        'Ya se generaron 3 códigos para este trabajo. Escríbenos a soporte para verificar la llegada.',
    'HMY_ARRIVAL_ALREADY_VERIFIED': 'La llegada ya está verificada.',
    'HMY_INVALID_PIN': 'Escribe los 6 números del código.',
    'HMY_TRIP_NOT_ACTIVE': 'La ubicación solo se comparte mientras vas en camino.',
    'HMY_TOO_MANY_SHARES': 'Ya compartiste este viaje con 3 contactos. Anula uno para compartir con otro.',
    'HMY_SHARE_NOT_FOUND': 'Este enlace ya no está disponible: venció, fue anulado o el trabajo terminó.',
    'HMY_TOO_MANY_ATTEMPTS': 'Hubo demasiados intentos. Espera un rato o escríbenos a soporte.',
    'HMY_OTP_LIMIT': 'Pediste muchos códigos seguidos. Espera una hora y vuelve a intentar.',
    'HMY_OTP_TOO_MANY_ATTEMPTS': 'Escribiste mal el código varias veces. Pide un código nuevo.',
    'HMY_OTP_NOT_CONFIGURED': 'El envío de códigos no está disponible ahora. Vuelve a intentar en un momento.',
    'HMY_OTP_UNAVAILABLE': 'El envío de códigos no está disponible ahora. Vuelve a intentar en un momento.',
    'HMY_INVALID_PHONE': 'Escribe un celular de Bolivia de 8 dígitos, por ejemplo 71234567.',
    'HMY_INVALID_CHANNEL': 'Elige WhatsApp o SMS.',
    'HMY_INVALID_NAME': 'Escribe tu nombre y apellido.',
    'HMY_INVALID_PHOTO': 'No pudimos usar esa foto. Prueba con otra (JPG o PNG, hasta 5 MB).',
    'HMY_INVALID_CITY': 'Elige tu ciudad.',
    'HMY_TERMS_REQUIRED': 'Para continuar, acepta los Términos de uso y la Política de privacidad.',
    'HMY_SAME_PHONE': 'Ese ya es tu número.',
    'HMY_INVALID_EMAIL': 'Revisa el correo electrónico. Debe ser como nombre@correo.com.',
    'HMY_SAME_EMAIL': 'Ese ya es tu correo.',
    'HMY_PHONE_REQUIRED': 'Para quitar el correo, tu cuenta necesita un celular confirmado.',
    'HMY_EMAIL_UNAVAILABLE': 'Todavía no podemos enviar el código a correos. Vuelve a intentar más tarde.',
    'phone_exists': 'Ese número ya tiene una cuenta. Si es tuyo, entra con ese número.',
    'email_exists': 'Ese correo ya está en otra cuenta.',
    'otp_expired': 'El código ya venció. Pide uno nuevo.',
    'otp_invalid': 'El código no es correcto. Revísalo y vuelve a intentar.',
    'HMY_AUTH_REQUIRED': 'Ingresa a tu cuenta para continuar.',
    'HMY_FORBIDDEN': 'No tienes permiso para hacer esto.',
    'HMY_NOT_FOUND': 'No encontramos lo que buscas.',
    'HMY_ROLE_NOT_GRANTED': 'Tu cuenta todavía no tiene acceso de profesional.',
    'HMY_PROFESSIONAL_NOT_APPROVED': 'Tu perfil profesional todavía no fue aprobado.',
    'HMY_PROFESSIONAL_NOT_AVAILABLE':
        'Este profesional no está disponible ahora. Prueba con otro o programa para después.',
    'HMY_CANNOT_BOOK_SELF': 'No puedes solicitarte un servicio a ti mismo.',
    'HMY_INVALID_SCHEDULE': 'Elige una fecha y hora con al menos 30 minutos de anticipación.',
    'HMY_SLOT_TAKEN': 'Ese horario ya está ocupado. Elige otro.',
    'bookings_no_overlap': 'Ya tienes otro trabajo confirmado en ese horario.',
    'HMY_TOO_MANY_OPEN_REQUESTS': 'Tienes varias solicitudes abiertas. Espera respuesta o cancela alguna.',
    'HMY_INVALID_TRANSITION': 'Esta acción ya no está disponible. Actualiza la pantalla.',
    'HMY_INSUFFICIENT_BALANCE': 'Tu saldo no alcanza para aceptar trabajos. Recarga tu billetera.',
    'HMY_REASON_REQUIRED': 'Escribe el motivo.',
    'HMY_INVALID_AMOUNT': 'Revisa el monto.',
    'HMY_CHAT_CLOSED': 'Este chat ya está cerrado.',
    'HMY_REVIEW_NOT_ALLOWED': 'Podrás calificar cuando el trabajo esté completado.',
    'HMY_DOCUMENTS_REQUIRED': 'Sube al menos una foto de tu carnet de identidad.',
    'HMY_APPLICATION_INCOMPLETE': 'Completa tu nombre, ciudad y servicio principal.',
    'HMY_INVALID_METHOD': 'Elige un método de recarga válido.',
    'HMY_TOO_MANY_PENDING': 'Ya tienes recargas pendientes de revisión.',
    'HMY_WALLET_NOT_FOUND': 'Tu billetera se activa cuando tu perfil es aprobado.',
    'HMY_INVALID_LOCATION': 'Esa ubicación no parece estar en Bolivia. Revísala o escribe la dirección.',
    'HMY_INVALID_RADIUS': 'Elige una distancia entre 1 y 50 km.',
    'HMY_INVALID_ZONE': 'Esa zona no pertenece a la ciudad elegida.',
    'HMY_NO_APPLICATION': 'Primero completa tu postulación como profesional.',
    'HMY_TOO_MANY_PHOTOS': 'Puedes subir hasta 5 fotos.',
    'HMY_INVALID_PATH': 'No pudimos guardar el archivo. Vuelve a intentar.',
    'HMY_ACCOUNT_SUSPENDED': 'Tu cuenta está suspendida. Escríbenos desde Ayuda si crees que es un error.',
    'HMY_BLOCKED': 'No puedes contactar a esta persona.',
    'HMY_RATE_LIMITED': 'Hiciste muchas solicitudes seguidas. Espera un rato y vuelve a intentar.',
    'HMY_COMMISSION_REQUIRED': 'Escribe un porcentaje o un cargo fijo.',
    'HMY_NAME_REQUIRED': 'Escribe un nombre.',
    'HMY_NOTE_REQUIRED': 'Escribe una nota corta: queda en la auditoría.',
    'HMY_ALREADY_REVIEWED': 'Esto ya fue revisado. Actualiza la pantalla.',
    'HMY_INVALID_STATUS': 'Esta acción ya no está disponible. Actualiza la pantalla.',
    'HMY_INVALID_PROBLEM': 'Una de las opciones elegidas ya no está disponible. Vuelve a elegir.',
    'HMY_OTHER_REQUIRED': 'Cuéntanos qué necesitas en "Otro".',
    'HMY_TOO_MANY_PROBLEMS': 'Elige hasta 8 opciones.',
    'HMY_YA_NOT_ALLOWED': 'Este servicio no se pide con ¡Ya!. Elige a la persona y programa el día.',
    'HMY_NOT_AUTHENTICATED': 'Ingresa a tu cuenta para continuar.',
    'HMY_CONFIRMATION_REQUIRED': 'Confirma que eres tú para continuar.',
    'HMY_CONFIRMATION_EXPIRED': 'La confirmación venció. Vuelve a confirmar que eres tú.',
    'HMY_CONFIRMATION_USED': 'Cada operación necesita una confirmación nueva. Vuelve a confirmar que eres tú.',
    'HMY_BIOMETRIC_DISABLED':
        'La huella o el rostro no están activados. Confirma con un código o actívalos en Perfil → Seguridad.',
    'HMY_PRO_NOT_CLEARED': 'Este profesional todavía no está habilitado para este servicio. Elige a otra persona.',
  };
}
