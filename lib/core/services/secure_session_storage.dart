import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lo mínimo que se necesita de un almacén cifrado (en las pruebas, uno en memoria).
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Llavero de iOS y Keystore de Android.
class DeviceSecretStore implements SecretStore {
  const DeviceSecretStore();

  static const _storage = FlutterSecureStorage(
    // Disponible después del primer desbloqueo, para que la sesión se renueve
    // en segundo plano; nunca sale del teléfono (ni a iCloud ni a otro equipo).
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device, synchronizable: false),
    // Si Android ya no puede descifrar (por ejemplo, tras restaurar un respaldo),
    // borra el dato en vez de fallar: la persona vuelve a entrar con su código.
    aOptions: AndroidOptions(resetOnError: true),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Nombre con el que Supabase guarda la sesión (el mismo que usaba antes).
String supabaseSessionKey(String supabaseUrl) => 'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';

/// La sesión de Supabase (tokens de acceso y de renovación) en el almacén
/// cifrado del teléfono, no en SharedPreferences.
///
/// Al iniciar:
/// - Una sesión que quedó en SharedPreferences (versiones anteriores) se pasa
///   al almacén cifrado y se borra de SharedPreferences.
/// - En iOS el llavero sobrevive a desinstalar la app. Si la app es una
///   instalación nueva, se borra lo que hubiera quedado, para que nadie entre
///   con la sesión de una instalación anterior.
/// Al cerrar sesión, Supabase llama a [removePersistedSession] y se borra todo.
class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage({required this.key, required this.prefs, this.secrets = const DeviceSecretStore()});

  final String key;
  final SharedPreferences prefs;
  final SecretStore secrets;

  /// Marca de "esta instalación ya inició": vive en SharedPreferences, que sí se
  /// borra al desinstalar.
  static const installedFlag = 'hmy_installed';

  @override
  Future<void> initialize() async {
    final legacy = prefs.getString(key);
    final freshInstall = !prefs.containsKey(installedFlag);
    try {
      if (freshInstall && legacy == null) {
        await secrets.delete(key);
      }
      if (legacy != null) {
        // La sesión más reciente es la que estaba en uso: la de SharedPreferences.
        await secrets.write(key, legacy);
      }
    } catch (_) {
      // Si el almacén cifrado falla, no se deja la sesión en texto plano:
      // la persona vuelve a entrar con su código.
    }
    await prefs.remove(key);
    await prefs.setBool(installedFlag, true);
  }

  @override
  Future<bool> hasAccessToken() async => (await accessToken()) != null;

  @override
  Future<String?> accessToken() async {
    try {
      return await secrets.read(key);
    } catch (_) {
      await _forget();
      return null;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) => secrets.write(key, persistSessionString);

  @override
  Future<void> removePersistedSession() async {
    await _forget();
    // Por si una versión anterior dejó una copia.
    await prefs.remove(key);
  }

  Future<void> _forget() async {
    try {
      await secrets.delete(key);
    } catch (_) {
      // Ya no se puede leer; no hay nada útil que borrar.
    }
  }
}

/// El código de verificación PKCE de Supabase (inicios con enlace), también cifrado.
class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage({required this.prefs, this.secrets = const DeviceSecretStore()});

  final SharedPreferences prefs;
  final SecretStore secrets;

  @override
  Future<String?> getItem({required String key}) async {
    try {
      return await secrets.read(key) ?? prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setItem({required String key, required String value}) async {
    await secrets.write(key, value);
    await prefs.remove(key);
  }

  @override
  Future<void> removeItem({required String key}) async {
    try {
      await secrets.delete(key);
    } finally {
      await prefs.remove(key);
    }
  }
}

/// Opciones de Supabase con la sesión cifrada. En la web no hay un almacén
/// cifrado confiable (el de flutter_secure_storage es experimental): queda el
/// de Supabase por defecto.
FlutterAuthClientOptions secureAuthOptions(String supabaseUrl, SharedPreferences prefs) => kIsWeb
    ? const FlutterAuthClientOptions()
    : FlutterAuthClientOptions(
        localStorage: SecureSessionStorage(key: supabaseSessionKey(supabaseUrl), prefs: prefs),
        pkceAsyncStorage: SecurePkceStorage(prefs: prefs),
      );
