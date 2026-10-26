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

  /// Mosaicos del mapa del inicio. Por defecto, los de OpenStreetMap: gratis,
  /// con su atribución a la vista y la caché de flutter_map (el mapa no se
  /// mueve ni se recarga solo, así se piden pocos). Para cambiar de proveedor
  /// basta compilar con otra dirección y su atribución; vacía, no se dibujan.
  static const mapTileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );
  static const mapAttribution = String.fromEnvironment(
    'MAP_ATTRIBUTION',
    defaultValue: '© colaboradores de OpenStreetMap',
  );
  static const mapAttributionUrl = String.fromEnvironment(
    'MAP_ATTRIBUTION_URL',
    defaultValue: 'https://www.openstreetmap.org/copyright',
  );

  static bool get hasBackend => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
