/// Token de avisos push de este teléfono ya registrado en la base, para
/// soltarlo al cerrar sesión (así la cuenta que sale no recibe avisos en un
/// teléfono que ya no usa).
abstract final class PushTokens {
  static String? current;
}
