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
    for (final entry in _codes.entries) {
      if (raw.contains(entry.key)) return AppError(entry.value, code: entry.key);
    }
    final lower = raw.toLowerCase();
    if (lower.contains('invalid login credentials')) {
      return const AppError('Correo o contraseña incorrectos.', code: 'invalid_credentials');
    }
    if (lower.contains('email not confirmed')) {
      return const AppError('Primero confirma tu correo con el código que te enviamos.', code: 'email_not_confirmed');
    }
    if (lower.contains('user already registered') || lower.contains('already been registered')) {
      return const AppError('Ya existe una cuenta con ese correo. Prueba ingresar.', code: 'user_exists');
    }
    if (lower.contains('token has expired') || lower.contains('otp') && lower.contains('invalid')) {
      return const AppError('El código no es válido o ya venció. Pide uno nuevo.', code: 'otp_invalid');
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

  static const _codes = {
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
  };
}
