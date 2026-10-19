/// Configuración que llega al compilar con `--dart-define`.
///
/// Sin `SUPABASE_URL` y `SUPABASE_ANON_KEY` la app arranca en modo
/// demostración, con datos de ejemplo guardados solo en memoria.
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Dirección a la que vuelven los enlaces de correo (verificación y
  /// recuperación de contraseña).
  static const authRedirectUrl = String.fromEnvironment(
    'AUTH_REDIRECT_URL',
    defaultValue: 'bo.handimanya.app://auth-callback',
  );

  static const supportEmail = String.fromEnvironment('SUPPORT_EMAIL', defaultValue: 'soporte@handimanya.bo');
  static const supportWhatsapp = String.fromEnvironment('SUPPORT_WHATSAPP');

  static bool get hasBackend => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
