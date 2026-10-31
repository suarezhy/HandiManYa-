import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/secure_session_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Almacén cifrado en memoria; puede fallar a pedido.
class FakeSecrets implements SecretStore {
  final data = <String, String>{};
  bool failRead = false;
  bool failWrite = false;
  final deleted = <String>[];

  @override
  Future<String?> read(String key) async {
    if (failRead) throw Exception('No se puede descifrar');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw Exception('Keystore no disponible');
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    data.remove(key);
  }
}

const key = 'sb-yldqopeldibwgbwmdnzy-auth-token';
const session = '{"access_token":"a","refresh_token":"r"}';

Future<(SecureSessionStorage, SharedPreferences, FakeSecrets)> make(
  Map<String, Object> prefs, {
  FakeSecrets? secrets,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  final s = secrets ?? FakeSecrets();
  return (SecureSessionStorage(key: key, prefs: p, secrets: s), p, s);
}

void main() {
  test('el nombre de la sesión es el mismo que usa Supabase por defecto', () {
    expect(supabaseSessionKey('https://yldqopeldibwgbwmdnzy.supabase.co'), key);
  });

  group('sesión cifrada', () {
    test('una sesión guardada en texto plano por una versión anterior pasa al almacén cifrado y se borra', () async {
      final (storage, prefs, secrets) = await make({key: session});
      await storage.initialize();
      expect(secrets.data[key], session);
      expect(prefs.containsKey(key), isFalse, reason: 'no queda copia en texto plano');
      expect(await storage.accessToken(), session);
      expect(await storage.hasAccessToken(), isTrue);
    });

    test('si hay sesión en los dos lados, gana la de la versión anterior (la que estaba en uso)', () async {
      final secrets = FakeSecrets()..data[key] = 'vieja';
      final (storage, prefs, _) = await make({
        key: session,
        SecureSessionStorage.installedFlag: true,
      }, secrets: secrets);
      await storage.initialize();
      expect(secrets.data[key], session);
      expect(prefs.containsKey(key), isFalse);
    });

    test('instalación nueva: se borra una sesión que quedó en el llavero de una instalación anterior', () async {
      final secrets = FakeSecrets()..data[key] = session;
      final (storage, prefs, _) = await make({}, secrets: secrets);
      await storage.initialize();
      expect(await storage.accessToken(), isNull);
      expect(prefs.getBool(SecureSessionStorage.installedFlag), isTrue);
    });

    test('app ya instalada: la sesión cifrada se mantiene al abrirla de nuevo', () async {
      final secrets = FakeSecrets()..data[key] = session;
      final (storage, _, _) = await make({SecureSessionStorage.installedFlag: true}, secrets: secrets);
      await storage.initialize();
      expect(await storage.accessToken(), session);
    });

    test('guardar, leer y cerrar sesión (borra también una copia vieja)', () async {
      final (storage, prefs, secrets) = await make({SecureSessionStorage.installedFlag: true});
      await storage.initialize();
      await storage.persistSession(session);
      expect(secrets.data[key], session);
      expect(prefs.containsKey(key), isFalse, reason: 'nunca se escribe en texto plano');
      await prefs.setString(key, 'copia vieja');
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), isFalse);
      expect(prefs.containsKey(key), isFalse);
    });

    test('si el almacén no puede descifrar, se olvida la sesión y se vuelve a entrar con el código', () async {
      final secrets = FakeSecrets()..data[key] = session;
      final (storage, _, _) = await make({SecureSessionStorage.installedFlag: true}, secrets: secrets);
      await storage.initialize();
      secrets.failRead = true;
      expect(await storage.accessToken(), isNull);
      expect(secrets.deleted, contains(key));
    });

    test('si el almacén falla al pasar la sesión, igual se borra el texto plano', () async {
      final secrets = FakeSecrets()..failWrite = true;
      final (storage, prefs, _) = await make({key: session}, secrets: secrets);
      await storage.initialize();
      expect(prefs.containsKey(key), isFalse);
      expect(await storage.accessToken(), isNull);
    });
  });

  group('código PKCE', () {
    test('se guarda cifrado y se borra de los dos lados', () async {
      SharedPreferences.setMockInitialValues({'v-code-verifier': 'viejo'});
      final prefs = await SharedPreferences.getInstance();
      final secrets = FakeSecrets();
      final pkce = SecurePkceStorage(prefs: prefs, secrets: secrets);
      expect(await pkce.getItem(key: 'v-code-verifier'), 'viejo', reason: 'lee uno que dejó una versión anterior');
      await pkce.setItem(key: 'v-code-verifier', value: 'nuevo');
      expect(secrets.data['v-code-verifier'], 'nuevo');
      expect(prefs.containsKey('v-code-verifier'), isFalse);
      await pkce.removeItem(key: 'v-code-verifier');
      expect(await pkce.getItem(key: 'v-code-verifier'), isNull);
    });
  });
}
