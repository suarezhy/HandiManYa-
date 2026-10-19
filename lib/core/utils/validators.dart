/// Validaciones de formularios con mensajes en español.
abstract final class Validators {
  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static String? required(String? v, [String field = 'Este campo']) =>
      (v == null || v.trim().isEmpty) ? '$field es obligatorio' : null;

  static String? email(String? v) {
    if (v == null || v.trim().isEmpty) return 'Escribe tu correo electrónico';
    if (!_email.hasMatch(v.trim())) return 'Revisa tu correo, parece incompleto';
    return null;
  }

  static String? password(String? v) {
    if (v == null || v.isEmpty) return 'Escribe una contraseña';
    if (v.length < 8) return 'Usa al menos 8 caracteres';
    if (!RegExp(r'[A-Za-z]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) {
      return 'Combina letras y números';
    }
    return null;
  }

  static String? fullName(String? v) {
    if (v == null || v.trim().length < 3) return 'Escribe tu nombre y apellido';
    if (v.trim().length > 120) return 'El nombre es demasiado largo';
    return null;
  }

  /// Celular boliviano: 8 dígitos que empiezan con 6 o 7. Acepta espacios,
  /// guiones y el prefijo +591.
  static String? boliviaPhone(String? v) {
    if (v == null || v.trim().isEmpty) return 'Escribe tu número de celular';
    return normalizeBoliviaPhone(v) == null ? 'Debe ser un celular de 8 dígitos, por ejemplo 71234567' : null;
  }

  /// Devuelve el número en formato +591XXXXXXXX, o null si no es válido.
  static String? normalizeBoliviaPhone(String v) {
    var digits = v.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('591') && digits.length == 11) digits = digits.substring(3);
    if (!RegExp(r'^[67]\d{7}$').hasMatch(digits)) return null;
    return '+591$digits';
  }

  static String? otp(String? v) {
    if (v == null || !RegExp(r'^\d{6}$').hasMatch(v.trim())) return 'El código tiene 6 números';
    return null;
  }
}
