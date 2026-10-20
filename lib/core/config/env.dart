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

  /// Página pública del viaje compartido (la versión web de la app), sin la
  /// barra final; el enlace queda como `<url>/viaje/<código>`. Vacía: todavía
  /// no está publicada y la app no ofrece enviar el enlace.
  static const tripShareUrl = String.fromEnvironment('TRIP_SHARE_URL');

  static bool get hasBackend => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
